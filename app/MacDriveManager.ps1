# ============================================================
#  Mac Drive Manager
#  Detect, mount, sync and safely eject an HFS+ (Mac) drive on Windows,
#  using WSL2 + usbipd as the bridge.
#
#  Long operations run in a background runspace and stream their output to a
#  temp file, which the UI timer tails. That keeps the window repainting, so
#  the spinner and progress bar stay smooth instead of freezing.
#
#  Configuration lives in ../macdrive.conf
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------- paths & config ----------------

$script:ROOT = Split-Path -Parent $PSScriptRoot
$confPath    = Join-Path $script:ROOT 'macdrive.conf'

if (-not (Test-Path $confPath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "macdrive.conf not found at:`n$confPath`n`nCopy macdrive.conf.example to macdrive.conf and edit it.",
        'Mac Drive Manager', 'OK', 'Error') | Out-Null
    exit 1
}

$conf = @{}
foreach ($line in (Get-Content $confPath)) {
    if ($line -match '^\s*([A-Z_]+)\s*=\s*"(.*)"\s*$') {
        $conf[$matches[1]] = $matches[2] -replace '\\\\', '\'
    }
}

function To-WslPath {
    param([string]$WinPath)
    $p = (Resolve-Path $WinPath).Path -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)$') { return '/mnt/' + $matches[1].ToLower() + $matches[2] }
    return $p
}

$scriptsWsl = To-WslPath (Join-Path $script:ROOT 'scripts')

$script:USBIPD    = $conf['USBIPD']
$script:HWID      = $conf['HWID']
$script:DISTRO    = $conf['DISTRO']
$script:LOCAL     = $conf['LOCAL_WIN']
$script:MOUNTPT   = $conf['MOUNTPOINT']
$script:DRIVENAME = $conf['DRIVE_NAME']
$script:MODEL     = $conf['DRIVE_MODEL']
$script:SETTINGS  = Join-Path $script:ROOT 'settings.json'

$script:MOUNT_SH  = "$scriptsWsl/macdrive-mount.sh"
$script:UMOUNT_SH = "$scriptsWsl/macdrive-umount.sh"
$script:DOWN_SH   = "$scriptsWsl/macdrive-sync-down.sh"
$script:UP_SH     = "$scriptsWsl/macdrive-sync-up.sh"
$script:STAT_SH   = "$scriptsWsl/macdrive-sync-status.sh"

$bs = [string][char]92
$script:UNC = $bs + $bs + 'wsl.localhost' + $bs + $script:DISTRO + ($script:MOUNTPT -replace '/', $bs)

$script:AutoSync  = $true
$script:LastState = $null
$script:Job       = $null
$script:Phase     = 0.0     # animation clock
$script:Busy      = $false
$script:BusyText  = ''

# ---------------- colors ----------------
$cBg    = [System.Drawing.Color]::FromArgb(32, 34, 40)
$cCard  = [System.Drawing.Color]::FromArgb(45, 48, 56)
$cCard2 = [System.Drawing.Color]::FromArgb(39, 42, 49)
$cText  = [System.Drawing.Color]::White
$cDim   = [System.Drawing.Color]::FromArgb(158, 164, 175)
$cGreen = [System.Drawing.Color]::FromArgb(70, 210, 120)
$cAmber = [System.Drawing.Color]::FromArgb(235, 180, 60)
$cBlue  = [System.Drawing.Color]::FromArgb(90, 160, 240)
$cGrey  = [System.Drawing.Color]::FromArgb(120, 125, 135)
$cBtn   = [System.Drawing.Color]::FromArgb(62, 66, 78)
$cGo    = [System.Drawing.Color]::FromArgb(28, 110, 70)
$cWarn  = [System.Drawing.Color]::FromArgb(150, 70, 30)
$cEdit  = [System.Drawing.Color]::FromArgb(75, 55, 140)

# ---------------- helpers ----------------

function Clean-Text {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace "`0", '')
}

# Read a file that another process is actively appending to. Get-Content opens
# it in a way that intermittently throws "used by another process" against a
# live writer, which would silently drop log lines.
function Read-SharedText {
    param([string]$Path)
    try {
        $fs = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)
        $sr  = New-Object System.IO.StreamReader($fs)
        $txt = $sr.ReadToEnd()
        $sr.Close(); $fs.Close()
        return $txt
    } catch { return $null }
}

# Synchronous - only for fast calls (status polling).
function Invoke-Wsl {
    param([string]$BashArgs)
    $out = & wsl.exe -d $script:DISTRO -u root -- bash -c $BashArgs 2>&1 | Out-String
    return [pscustomobject]@{ Output = (Clean-Text $out).Trim(); Code = $LASTEXITCODE }
}

function Load-Settings {
    if (Test-Path $script:SETTINGS) {
        try {
            $j = Get-Content $script:SETTINGS -Raw | ConvertFrom-Json
            if ($null -ne $j.autoSync) { return [bool]$j.autoSync }
        } catch { }
    }
    return $true
}

function Save-Settings {
    try {
        ([pscustomobject]@{ autoSync = $script:AutoSync } | ConvertTo-Json) |
            Set-Content -Path $script:SETTINGS -Encoding utf8
    } catch { }
}

function Get-DriveState {
    $state = [pscustomobject]@{
        Present = $false; Where = 'Unplugged'; Mounted = $false
        BusId = ''; Device = ''; Size = ''; Used = ''; Avail = ''; Note = ''
    }
    if (-not (Test-Path $script:USBIPD)) { $state.Note = 'usbipd-win not found'; return $state }

    $raw  = Clean-Text ((& $script:USBIPD list 2>&1 | Out-String))
    $line = ($raw -split "`r?`n") | Where-Object { $_ -match [regex]::Escape($script:HWID) } | Select-Object -First 1
    if (-not $line) { return $state }

    $state.Present = $true
    if ($line -match '^\s*(\S+)\s') { $state.BusId = $matches[1] }

    # Match STATE at END of line only. The DEVICE column can contain the word
    # "Attached" (e.g. "USB Attached SCSI"), so searching the whole line lies.
    $st = ''
    if ($line -match '(Not shared|Shared|Attached)\s*$') { $st = $matches[1] }

    switch ($st) {
        'Attached'   { $state.Where = 'WSL' }
        'Not shared' { $state.Where = 'Windows'; $state.Note = 'not shared - run install/03-bind-drive.ps1 as Admin once' }
        default      { $state.Where = 'Windows' }
    }

    if ($state.Where -eq 'WSL') {
        $m = Invoke-Wsl ("mountpoint -q $($script:MOUNTPT); echo rc=`$?")
        $state.Mounted = ($m.Output -match 'rc=0')
        if ($state.Mounted) {
            $d = Invoke-Wsl "df -h $($script:MOUNTPT) | tail -1"
            $p = ($d.Output -split '\s+')
            if ($p.Count -ge 4) {
                $state.Device = $p[0]; $state.Size = $p[1]; $state.Used = $p[2]; $state.Avail = $p[3]
            }
        }
    }
    return $state
}

function Find-Project {
    if (-not (Test-Path $script:LOCAL)) { return $null }
    return Get-ChildItem -Path $script:LOCAL -Filter '*.prproj' -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# ---------------- background work ----------------
# The operation body runs in its own runspace. It cannot see this scope, so
# everything it needs is passed in, and it reports progress by appending to
# $OutFile, which the UI timer tails.

$script:OpBody = {
    param($Op, $Conf, $OutFile)

    # Open the progress file with FileShare::ReadWrite so the UI can tail it
    # while we are still writing. Add-Content locks it exclusively enough that
    # the reader intermittently fails with "used by another process".
    $fs = New-Object System.IO.FileStream(
        $Conf.OutFile,
        [System.IO.FileMode]::Append,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite)
    $sw = New-Object System.IO.StreamWriter($fs)
    $sw.AutoFlush = $true

    function Emit { param($m) $sw.WriteLine($m) }
    function RunWsl {
        param($cmd)
        $o = & wsl.exe -d $Conf.Distro -u root -- bash -c $cmd 2>&1 | Out-String
        $o = $o -replace "`0", ''
        foreach ($l in ($o -split "`r?`n")) { if ($l.Trim()) { Emit ('  ' + $l.Trim()) } }
        return $LASTEXITCODE
    }

    try {
    switch ($Op) {

        'mount' {
            $alive = Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" -ErrorAction SilentlyContinue |
                     Where-Object { $_.CommandLine -match 'sleep' }
            if (-not $alive) {
                Emit 'Starting the Linux helper (keeps the mount alive)...'
                Start-Process -WindowStyle Hidden wsl.exe `
                    -ArgumentList '-d', $Conf.Distro, '-u', 'root', '--', 'sleep', 'infinity'
                Start-Sleep -Seconds 3
            }

            if ($Conf.NeedAttach) {
                Emit 'Attaching the drive to WSL...'
                $a = & $Conf.Usbipd attach --wsl --hardware-id $Conf.Hwid 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) {
                    Emit ('ERROR attaching: ' + ($a -replace "`0", '').Trim())
                    Emit '##FAIL##'; return
                }
                Start-Sleep -Seconds 4
            }

            Emit 'Mounting read/write...'
            if ((RunWsl ('bash ' + $Conf.MountSh)) -ne 0) { Emit '##FAIL##'; return }

            if ($Conf.AutoSync) {
                Emit 'Auto-sync ON - pulling to the local working copy...'
                RunWsl ('bash ' + $Conf.DownSh) | Out-Null
            }
            Emit '##OK##'
        }

        'down' {
            Emit 'Pulling from the drive...'
            $rc = RunWsl ('bash ' + $Conf.DownSh)
            if ($rc -eq 0) { Emit '##OK##' } else { Emit '##FAIL##' }
        }

        'up' {
            Emit 'Pushing to the drive...'
            $rc = RunWsl ('bash ' + $Conf.UpSh)
            if ($rc -eq 0) { Emit '##OK##' } else { Emit '##FAIL##' }
        }

        'eject' {
            if ($Conf.SyncFirst) {
                Emit 'Sending local changes back before ejecting...'
                if ((RunWsl ('bash ' + $Conf.UpSh)) -ne 0) {
                    Emit 'SYNC FAILED - stopping. The drive was NOT ejected, so nothing is lost.'
                    Emit '##FAIL##'; return
                }
            }
            Emit 'Flushing writes and unmounting...'
            if ((RunWsl ('bash ' + $Conf.UmountSh)) -ne 0) {
                Emit 'EJECT FAILED - a file is still open. Close any app using the drive and retry.'
                Emit '##FAIL##'; return
            }
            & $Conf.Usbipd detach --hardware-id $Conf.Hwid 2>&1 | Out-Null
            Emit 'Released the drive back to Windows.'
            Emit '##EJECTED##'
        }
    }
    }
    finally {
        try { $sw.Flush(); $sw.Close(); $fs.Close() } catch { }
    }
}

function Start-Operation {
    param(
        [string]$Op,
        [string]$BusyText,
        [hashtable]$Extra = @{}
    )

    $outFile = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'mdm-' + [Guid]::NewGuid().ToString('N') + '.log')
    New-Item -ItemType File -Path $outFile -Force | Out-Null

    $c = @{
        Distro   = $script:DISTRO
        Usbipd   = $script:USBIPD
        Hwid     = $script:HWID
        MountSh  = $script:MOUNT_SH
        UmountSh = $script:UMOUNT_SH
        DownSh   = $script:DOWN_SH
        UpSh     = $script:UP_SH
        AutoSync = $script:AutoSync
        OutFile  = $outFile
    }
    foreach ($k in $Extra.Keys) { $c[$k] = $Extra[$k] }

    $ps = [PowerShell]::Create()
    $null = $ps.AddScript($script:OpBody.ToString()).AddArgument($Op).AddArgument($c).AddArgument($outFile)

    $script:Job = [pscustomobject]@{
        PS = $ps; Handle = $ps.BeginInvoke(); File = $outFile; Pos = 0; Op = $Op
    }

    $script:Busy     = $true
    $script:BusyText = $BusyText
    Set-Controls $false
    $bar.Visible = $true
    $spin.Visible = $true
    $lblState.Text = $BusyText
    $dot.Visible = $false
}

function Finish-Operation {
    param([string]$Outcome)

    $script:Busy  = $false
    $bar.Visible  = $false
    $spin.Visible = $false
    $dot.Visible  = $true
    Set-Controls $true

    try { Remove-Item -LiteralPath $script:Job.File -Force -ErrorAction SilentlyContinue } catch { }
    $op = $script:Job.Op
    $script:Job.PS.Dispose()
    $script:Job = $null

    if ($Outcome -eq 'EJECTED') {
        Write-Log '================================'
        Write-Log ' EJECTED - SAFE TO UNPLUG NOW'
        Write-Log '================================'
        $dot.ForeColor  = $cBlue
        $lblState.Text  = 'Ejected - safe to unplug'
        $lblDetail.Text = 'Writes flushed, volume unmounted cleanly, drive released.'
        Set-Controls $true
        $btnDown.Enabled = $false; $btnUp.Enabled = $false; $btnEject.Enabled = $false
        return
    }

    if ($Outcome -eq 'FAIL') { Write-Log 'Operation did not complete.' }
    elseif ($op -eq 'mount') { Write-Log 'Mounted read/write.' }

    Refresh-Ui
}

# ---------------- form ----------------

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'Mac Drive Manager'
$form.Size            = New-Object System.Drawing.Size(660, 700)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.BackColor       = $cBg
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
$form.Opacity         = 0        # faded in on load

$lblTitle           = New-Object System.Windows.Forms.Label
$lblTitle.Text      = $script:DRIVENAME
$lblTitle.Font      = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $cText
$lblTitle.Location  = New-Object System.Drawing.Point(20, 16)
$lblTitle.Size      = New-Object System.Drawing.Size(380, 30)
$form.Controls.Add($lblTitle)

$lblModel           = New-Object System.Windows.Forms.Label
$lblModel.Text      = $script:MODEL + '  -  HFS+ (Mac OS Extended)'
$lblModel.ForeColor = $cDim
$lblModel.Location  = New-Object System.Drawing.Point(22, 46)
$lblModel.Size      = New-Object System.Drawing.Size(380, 20)
$form.Controls.Add($lblModel)

# --- auto-sync toggle ---
$lblTog           = New-Object System.Windows.Forms.Label
$lblTog.Text      = 'Auto-sync'
$lblTog.ForeColor = $cDim
$lblTog.TextAlign = 'MiddleRight'
$lblTog.Location  = New-Object System.Drawing.Point(468, 18)
$lblTog.Size      = New-Object System.Drawing.Size(80, 20)
$form.Controls.Add($lblTog)

$lblTogState           = New-Object System.Windows.Forms.Label
$lblTogState.Font      = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
$lblTogState.TextAlign = 'MiddleRight'
$lblTogState.ForeColor = $cGreen
$lblTogState.Location  = New-Object System.Drawing.Point(468, 44)
$lblTogState.Size      = New-Object System.Drawing.Size(80, 18)
$form.Controls.Add($lblTogState)

$tog           = New-Object System.Windows.Forms.Panel
$tog.Location  = New-Object System.Drawing.Point(556, 16)
$tog.Size      = New-Object System.Drawing.Size(62, 30)
$tog.BackColor = $cBg
$tog.Cursor    = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($tog)

# Knob position is animated, so the toggle slides instead of jumping.
$script:TogPos = 1.0

$tog.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $w = $sender.Width; $h = $sender.Height
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $h, $h, 90, 180)
    $path.AddArc($w - $h, 0, $h, $h, 270, 180)
    $path.CloseFigure()

    $t = $script:TogPos
    $r = [int](78 + (40 - 78) * $t); $gg = [int](82 + (150 - 82) * $t); $b = [int](94 + (95 - 94) * $t)
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($r, $gg, $b))
    $g.FillPath($brush, $path); $brush.Dispose()

    $pad = 4; $kd = $h - ($pad * 2)
    $kx = $pad + ($w - $kd - ($pad * 2)) * $t
    $g.FillEllipse([System.Drawing.Brushes]::White, [float]$kx, [float]$pad, [float]$kd, [float]$kd)
    $path.Dispose()
})

# --- drive status card ---
$panel           = New-Object System.Windows.Forms.Panel
$panel.Location  = New-Object System.Drawing.Point(20, 78)
$panel.Size      = New-Object System.Drawing.Size(600, 92)
$panel.BackColor = $cCard
$form.Controls.Add($panel)

$dot           = New-Object System.Windows.Forms.Label
$dot.Text      = [string][char]0x25CF
$dot.Font      = New-Object System.Drawing.Font('Segoe UI', 26)
$dot.Location  = New-Object System.Drawing.Point(14, 12)
$dot.Size      = New-Object System.Drawing.Size(44, 46)
$dot.ForeColor = $cGrey
$panel.Controls.Add($dot)

# Spinner replaces the dot while an operation runs.
$spin           = New-Object System.Windows.Forms.Panel
$spin.Location  = New-Object System.Drawing.Point(16, 20)
$spin.Size      = New-Object System.Drawing.Size(30, 30)
$spin.BackColor = $cCard
$spin.Visible   = $false
$panel.Controls.Add($spin)

$spin.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $pad = 3
    $rect = New-Object System.Drawing.RectangleF($pad, $pad, $sender.Width - ($pad*2), $sender.Height - ($pad*2))
    $penBg = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(70, 75, 88)), 3
    $g.DrawEllipse($penBg, $rect); $penBg.Dispose()
    $start = ($script:Phase * 220) % 360
    $sweep = 90 + 45 * [Math]::Sin($script:Phase * 2.2)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(90, 185, 255)), 3
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawArc($pen, $rect, [float]$start, [float]$sweep)
    $pen.Dispose()
})

$lblState           = New-Object System.Windows.Forms.Label
$lblState.Text      = 'Starting...'
$lblState.Font      = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$lblState.ForeColor = $cText
$lblState.Location  = New-Object System.Drawing.Point(58, 14)
$lblState.Size      = New-Object System.Drawing.Size(530, 26)
$panel.Controls.Add($lblState)

$lblDetail           = New-Object System.Windows.Forms.Label
$lblDetail.ForeColor = $cDim
$lblDetail.Location  = New-Object System.Drawing.Point(60, 42)
$lblDetail.Size      = New-Object System.Drawing.Size(528, 44)
$panel.Controls.Add($lblDetail)

# Indeterminate progress bar: a soft highlight sliding along a track.
$bar           = New-Object System.Windows.Forms.Panel
$bar.Location  = New-Object System.Drawing.Point(60, 74)
$bar.Size      = New-Object System.Drawing.Size(520, 6)
$bar.BackColor = $cCard
$bar.Visible   = $false
$panel.Controls.Add($bar)

$bar.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $w = $sender.Width; $h = $sender.Height

    $track = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(62, 66, 78))
    $g.FillRectangle($track, 0, 0, $w, $h); $track.Dispose()

    # Ease in/out so the highlight glides rather than scrolling linearly.
    $t = ($script:Phase * 0.55) % 2.0
    if ($t -gt 1.0) { $t = 2.0 - $t }
    $e2 = $t * $t * (3.0 - 2.0 * $t)

    $segW = [int]($w * 0.34)
    $x    = [int](($w + $segW) * $e2) - $segW

    $r = New-Object System.Drawing.Rectangle($x, 0, $segW, $h)
    if ($segW -gt 0) {
        $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $r,
            [System.Drawing.Color]::FromArgb(0, 90, 185, 255),
            [System.Drawing.Color]::FromArgb(255, 90, 185, 255),
            [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
        $blend = New-Object System.Drawing.Drawing2D.ColorBlend 3
        $blend.Colors = @(
            [System.Drawing.Color]::FromArgb(0, 90, 185, 255),
            [System.Drawing.Color]::FromArgb(235, 120, 200, 255),
            [System.Drawing.Color]::FromArgb(0, 90, 185, 255))
        $blend.Positions = @(0.0, 0.5, 1.0)
        $lg.InterpolationColors = $blend
        $g.FillRectangle($lg, $r)
        $lg.Dispose()
    }
})

# --- local working copy card ---
$panel2           = New-Object System.Windows.Forms.Panel
$panel2.Location  = New-Object System.Drawing.Point(20, 178)
$panel2.Size      = New-Object System.Drawing.Size(600, 70)
$panel2.BackColor = $cCard2
$form.Controls.Add($panel2)

$lblLocalHdr           = New-Object System.Windows.Forms.Label
$lblLocalHdr.Text      = 'WORK HERE  -  local working copy'
$lblLocalHdr.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblLocalHdr.ForeColor = $cText
$lblLocalHdr.Location  = New-Object System.Drawing.Point(16, 10)
$lblLocalHdr.Size      = New-Object System.Drawing.Size(360, 18)
$panel2.Controls.Add($lblLocalHdr)

$lblLocal           = New-Object System.Windows.Forms.Label
$lblLocal.ForeColor = $cDim
$lblLocal.Location  = New-Object System.Drawing.Point(16, 30)
$lblLocal.Size      = New-Object System.Drawing.Size(570, 36)
$lblLocal.Text      = $script:LOCAL
$panel2.Controls.Add($lblLocal)

# --- buttons, with a hover lift ---
function New-Btn {
    param($Text, $X, $Y, $W, $Accent)
    $b           = New-Object System.Windows.Forms.Button
    $b.Text      = $Text
    $b.Location  = New-Object System.Drawing.Point($X, $Y)
    $b.Size      = New-Object System.Drawing.Size($W, 38)
    $b.FlatStyle = 'Flat'
    $b.ForeColor = [System.Drawing.Color]::White
    $b.BackColor = $Accent
    $b.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $b.FlatAppearance.BorderSize = 0
    $b.Tag = $Accent
    $b.Add_MouseEnter({
        $base = $this.Tag
        $this.BackColor = [System.Drawing.Color]::FromArgb(
            [Math]::Min(255, $base.R + 28),
            [Math]::Min(255, $base.G + 28),
            [Math]::Min(255, $base.B + 28))
    })
    $b.Add_MouseLeave({ $this.BackColor = $this.Tag })
    return $b
}

$btnStatus = New-Btn 'Check Status'      20  262 136 $cBtn
$btnMount  = New-Btn 'Mount Read/Write'  164 262 150 $cGo
$btnDown   = New-Btn 'Get from Drive'    322 262 140 $cBtn
$btnUp     = New-Btn 'Send to Drive'     470 262 150 $cBtn
$btnOpen   = New-Btn 'Open Project'      20  308 200 $cEdit
$btnFolder = New-Btn 'Open Local Folder' 228 308 170 $cBtn
$btnEject  = New-Btn 'Eject Safely'      406 308 214 $cWarn
$form.Controls.AddRange(@($btnStatus,$btnMount,$btnDown,$btnUp,$btnOpen,$btnFolder,$btnEject))

$lblLog           = New-Object System.Windows.Forms.Label
$lblLog.Text      = 'Status window'
$lblLog.ForeColor = $cDim
$lblLog.Location  = New-Object System.Drawing.Point(20, 358)
$lblLog.Size      = New-Object System.Drawing.Size(200, 18)
$form.Controls.Add($lblLog)

$log             = New-Object System.Windows.Forms.TextBox
$log.Multiline   = $true
$log.ScrollBars  = 'Vertical'
$log.ReadOnly    = $true
$log.Location    = New-Object System.Drawing.Point(20, 379)
$log.Size        = New-Object System.Drawing.Size(600, 240)
$log.BackColor   = [System.Drawing.Color]::FromArgb(22, 24, 29)
$log.ForeColor   = [System.Drawing.Color]::FromArgb(205, 212, 222)
$log.Font        = New-Object System.Drawing.Font('Consolas', 9)
$log.BorderStyle = 'FixedSingle'
$form.Controls.Add($log)

$lblHint           = New-Object System.Windows.Forms.Label
$lblHint.Text      = 'Eject Safely always flushes writes first. Never unplug without it.'
$lblHint.ForeColor = $cAmber
$lblHint.Location  = New-Object System.Drawing.Point(20, 628)
$lblHint.Size      = New-Object System.Drawing.Size(600, 20)
$form.Controls.Add($lblHint)

# ---------------- behaviour ----------------

function Write-Log {
    param([string]$Msg)
    $log.AppendText('[' + (Get-Date).ToString('HH:mm:ss') + '] ' + $Msg + "`r`n")
}

function Set-Controls {
    param([bool]$On)
    foreach ($b in @($btnStatus,$btnMount,$btnDown,$btnUp,$btnOpen,$btnFolder,$btnEject)) {
        $b.Enabled = $On
    }
    $tog.Enabled = $On
}

function Update-ToggleUi {
    if ($script:AutoSync) { $lblTogState.Text = 'ON';  $lblTogState.ForeColor = $cGreen }
    else                  { $lblTogState.Text = 'OFF'; $lblTogState.ForeColor = $cDim }
}

function Refresh-Local {
    if (Test-Path $script:LOCAL) {
        $proj = Find-Project
        $n = Get-ChildItem $script:LOCAL -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Sum Length
        $txt = $script:LOCAL + '   ' + $n.Count + ' files, ' + [math]::Round($n.Sum / 1GB, 2) + ' GB'
        if ($proj) { $txt += "`r`n" + 'Project: ' + $proj.Name + '   (saved ' + $proj.LastWriteTime.ToString('MMM d HH:mm') + ')' }
        $lblLocal.Text = $txt
    } else {
        $lblLocal.Text = $script:LOCAL + "`r`n" + 'No local copy yet - press Get from Drive.'
    }
}

function Refresh-Ui {
    param([bool]$Announce = $false)
    if ($script:Busy) { return }

    $s = Get-DriveState
    $script:LastState = $s
    Refresh-Local
    $hasLocal = Test-Path $script:LOCAL

    if (-not $s.Present) {
        $dot.ForeColor = $cGrey
        $lblState.Text = 'Drive not detected'
        $lblDetail.Text = 'Plug the drive in, then press Check Status.'
        $btnMount.Enabled = $false; $btnDown.Enabled = $false
        $btnUp.Enabled = $false;    $btnEject.Enabled = $false
        $btnOpen.Enabled = $hasLocal; $btnFolder.Enabled = $hasLocal
        if ($Announce) { Write-Log 'Drive not detected.' }
        return
    }

    if ($s.Mounted) {
        $dot.ForeColor = $cGreen
        $lblState.Text = 'Connected - read/write ready'
        $lblDetail.Text = $s.Device + '   ' + $s.Used + ' used of ' + $s.Size + '   (' + $s.Avail + ' free)' + "`r`n" + $script:UNC
        $btnMount.Enabled = $false; $btnDown.Enabled = $true
        $btnUp.Enabled = $hasLocal; $btnEject.Enabled = $true
        $btnOpen.Enabled = $hasLocal; $btnFolder.Enabled = $hasLocal
        if ($Announce) { Write-Log ('Mounted read/write at ' + $script:UNC) }
    }
    else {
        $dot.ForeColor = $cAmber
        $lblState.Text = 'Plugged in - not mounted'
        $t = 'Detected on bus ' + $s.BusId + '. Press Mount Read/Write.'
        if ($s.Note) { $t += "`r`n" + $s.Note }
        $lblDetail.Text = $t
        $btnMount.Enabled = $true; $btnDown.Enabled = $false
        $btnUp.Enabled = $false;   $btnEject.Enabled = $false
        $btnOpen.Enabled = $hasLocal; $btnFolder.Enabled = $hasLocal
        if ($Announce) { Write-Log ('Drive present on bus ' + $s.BusId + ' but not mounted.') }
    }
}

$tog.Add_Click({
    $script:AutoSync = -not $script:AutoSync
    Save-Settings
    Update-ToggleUi
    if ($script:AutoSync) { Write-Log 'Auto-sync ON  - pulls after mounting, pushes before ejecting.' }
    else                  { Write-Log 'Auto-sync OFF - use Get from Drive / Send to Drive manually.' }
})

$btnStatus.Add_Click({
    Write-Log 'Checking...'
    Refresh-Ui -Announce $true
})

$btnMount.Add_Click({
    $s = Get-DriveState
    if (-not $s.Present) { Write-Log 'ERROR: drive is not plugged in.'; return }
    Write-Log 'Mounting...'
    Start-Operation -Op 'mount' -BusyText 'Mounting...' -Extra @{ NeedAttach = ($s.Where -ne 'WSL') }
})

$btnDown.Add_Click({
    Write-Log 'Pulling from the drive...'
    Start-Operation -Op 'down' -BusyText 'Copying from drive...'
})

$btnUp.Add_Click({
    Write-Log 'Pushing to the drive...'
    Start-Operation -Op 'up' -BusyText 'Copying to drive...'
})

$btnOpen.Add_Click({
    $proj = Find-Project
    if (-not $proj) { Write-Log 'No project file found in the local copy.'; return }
    Write-Log ('Opening: ' + $proj.Name + '  (local copy - fast. Eject syncs it back.)')
    try { Start-Process -FilePath $proj.FullName }
    catch { Write-Log ('ERROR launching: ' + $_.Exception.Message) }
})

$btnFolder.Add_Click({
    if (Test-Path $script:LOCAL) { Start-Process explorer.exe $script:LOCAL }
    else { Write-Log 'No local copy yet.' }
})

$btnEject.Add_Click({
    $syncFirst = $false
    if (Test-Path $script:LOCAL) {
        if ($script:AutoSync) { $syncFirst = $true }
        else {
            $r = Invoke-Wsl ('bash ' + $script:STAT_SH)
            $up = 0
            if ($r.Output -match 'PENDING_UP=(\d+)') { $up = [int]$matches[1] }
            if ($up -gt 0) {
                $ans = [System.Windows.Forms.MessageBox]::Show(
                    ("$up file(s) are newer locally and not on the drive yet.`n`nSync them before ejecting?"),
                    'Unsynced changes', 'YesNoCancel', 'Warning')
                if ($ans -eq 'Cancel') { Write-Log 'Eject cancelled.'; return }
                if ($ans -eq 'Yes')    { $syncFirst = $true }
                else { Write-Log 'Skipping sync - local changes stay only on the local copy.' }
            }
        }
    }
    Write-Log 'Ejecting...'
    Start-Operation -Op 'eject' -BusyText 'Ejecting...' -Extra @{ SyncFirst = $syncFirst }
})

# ---------------- animation / polling loop ----------------
# One fast timer drives every moving thing. Heavier work is rate-limited by
# frame count so the animation itself stays cheap.

$script:Frame      = 0
$script:FadeIn     = $true
$script:SplashDone = $false

$anim          = New-Object System.Windows.Forms.Timer
$anim.Interval = 20                      # ~50 fps
$anim.Add_Tick({
    $script:Frame++
    $script:Phase += 0.02

    # fade the window in on launch
    if ($script:FadeIn) {
        $o = $form.Opacity + 0.07
        if ($o -ge 1.0) { $o = 1.0; $script:FadeIn = $false }
        $form.Opacity = $o
    }

    # ease the auto-sync knob toward its target
    $target = if ($script:AutoSync) { 1.0 } else { 0.0 }
    if ([Math]::Abs($script:TogPos - $target) -gt 0.001) {
        $script:TogPos += ($target - $script:TogPos) * 0.25
        $tog.Invalidate()
    }

    if ($script:Busy) {
        $spin.Invalidate()
        $bar.Invalidate()

        # animated ellipsis on the status line
        if ($script:Frame % 25 -eq 0) {
            $dots = '.' * (1 + (($script:Frame / 25) % 3))
            $lblState.Text = ($script:BusyText -replace '\.+$', '') + $dots
        }

        # Stream the background job's output into the log.
        #
        # The writer appends while we read, so the last line can be caught
        # half-written. Only consume it once the file ends with a newline;
        # otherwise hold it back for the next tick. Without this the tailer
        # prints a truncated line and then skips past the rest of it.
        if ($script:Job -and ($script:Frame % 5 -eq 0)) {
            try {
                $raw = Read-SharedText $script:Job.File
                if ($raw) {
                    $complete = $raw.EndsWith("`n")
                    $lines = $raw -split "`r?`n"
                    if ($lines.Count -gt 0 -and $lines[-1] -eq '') {
                        if ($lines.Count -eq 1) { $lines = @() }
                        else { $lines = $lines[0..($lines.Count - 2)] }
                    }
                    $avail = if ($complete) { $lines.Count } else { $lines.Count - 1 }
                    for ($i = $script:Job.Pos; $i -lt $avail; $i++) {
                        $line = $lines[$i]
                        if ($line -notmatch '^##') { Write-Log $line }
                    }
                    if ($avail -gt $script:Job.Pos) { $script:Job.Pos = $avail }
                }
            } catch { }
        }

        if ($script:Job -and $script:Job.Handle.IsCompleted) {
            $outcome = 'OK'
            try {
                # The writer has stopped, so everything in the file is complete
                # now - flush whatever the tailer was still holding back.
                $txt = Read-SharedText $script:Job.File; $all = @(); if ($txt) { $all = @($txt -split "`r?`n" | Where-Object { $_ -ne '' }) }
                for ($i = $script:Job.Pos; $i -lt $all.Count; $i++) {
                    if ($all[$i] -notmatch '^##') { Write-Log $all[$i] }
                }
                $script:Job.Pos = $all.Count

                if ($all -match '##EJECTED##')  { $outcome = 'EJECTED' }
                elseif ($all -match '##FAIL##') { $outcome = 'FAIL' }
            } catch { }
            try { $script:Job.PS.EndInvoke($script:Job.Handle) | Out-Null } catch { }
            Finish-Operation $outcome
        }
        return
    }

    # first state check, once the fade has finished
    if ($script:NeedFirstCheck -and -not $script:FadeIn) {
        $script:NeedFirstCheck = $false
        $spin.Invalidate(); [System.Windows.Forms.Application]::DoEvents()
        Refresh-Ui -Announce $true
        $spin.Visible = $false; $dot.Visible = $true
        return
    }

    # idle: cheap presence poll every ~5s
    if ($script:Frame % 250 -eq 0) { Refresh-Ui }
})

$form.Add_Shown({
    $script:AutoSync = Load-Settings
    $script:TogPos   = if ($script:AutoSync) { 1.0 } else { 0.0 }
    Update-ToggleUi
    Write-Log 'Mac Drive Manager ready.'
    Write-Log ('Auto-sync is ' + $(if ($script:AutoSync) { 'ON' } else { 'OFF' }) + '.')

    # Defer the first state check until the fade-in has finished, so the window
    # animates in cleanly instead of stalling on usbipd/wsl calls.
    $dot.Visible = $false; $spin.Visible = $true
    $lblState.Text = 'Looking for your drive...'
    $script:NeedFirstCheck = $true
})

$form.Add_FormClosing({
    $anim.Stop()
    if ($script:Job) {
        try { $script:Job.PS.Dispose() } catch { }
    }
})

$anim.Start()
[void]$form.ShowDialog()
$anim.Stop()


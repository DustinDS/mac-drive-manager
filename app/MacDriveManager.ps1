# ============================================================
#  Mac Drive Manager
#  Detect, mount, sync and safely eject an HFS+ (Mac) drive on Windows,
#  using WSL2 + usbipd as the bridge.
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

# WSL shuts down an idle distro, which silently drops the mount. Hold it open.
function Ensure-KeepAlive {
    $alive = Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -match 'sleep' }
    if (-not $alive) {
        Start-Process -WindowStyle Hidden wsl.exe `
            -ArgumentList '-d', $script:DISTRO, '-u', 'root', '--', 'sleep', 'infinity'
        Start-Sleep -Seconds 3
        return $true
    }
    return $false
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

function Get-PendingCounts {
    $res = [pscustomobject]@{ Up = -1; Down = -1 }
    if (-not (Test-Path $script:LOCAL)) { return $res }
    $r = Invoke-Wsl ('bash ' + $script:STAT_SH)
    if ($r.Output -match 'PENDING_UP=(\d+)')   { $res.Up   = [int]$matches[1] }
    if ($r.Output -match 'PENDING_DOWN=(\d+)') { $res.Down = [int]$matches[1] }
    return $res
}

function Find-Project {
    if (-not (Test-Path $script:LOCAL)) { return $null }
    return Get-ChildItem -Path $script:LOCAL -Filter '*.prproj' -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
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

# --- auto-sync toggle (top right) ---
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

$tog.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $w = $sender.Width; $h = $sender.Height
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $h, $h, 90, 180)
    $path.AddArc($w - $h, 0, $h, $h, 270, 180)
    $path.CloseFigure()
    if ($script:AutoSync) { $fill = [System.Drawing.Color]::FromArgb(40, 150, 95) }
    else                  { $fill = [System.Drawing.Color]::FromArgb(78, 82, 94) }
    $brush = New-Object System.Drawing.SolidBrush $fill
    $g.FillPath($brush, $path); $brush.Dispose()
    $pad = 4; $kd = $h - ($pad * 2)
    if ($script:AutoSync) { $kx = $w - $kd - $pad } else { $kx = $pad }
    $g.FillEllipse([System.Drawing.Brushes]::White, $kx, $pad, $kd, $kd)
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

$lblState           = New-Object System.Windows.Forms.Label
$lblState.Text      = 'Checking...'
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
    [System.Windows.Forms.Application]::DoEvents()
}

function Write-Out {
    param($Result)
    foreach ($ln in ($Result.Output -split "`r?`n")) {
        if ($ln.Trim()) { Write-Log ('  ' + $ln.Trim()) }
    }
}

function Set-Busy {
    param([bool]$On)
    foreach ($b in @($btnStatus,$btnMount,$btnDown,$btnUp,$btnOpen,$btnFolder,$btnEject)) {
        $b.Enabled = -not $On
    }
    if ($On) { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    else     { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-ToggleUi {
    if ($script:AutoSync) { $lblTogState.Text = 'ON';  $lblTogState.ForeColor = $cGreen }
    else                  { $lblTogState.Text = 'OFF'; $lblTogState.ForeColor = $cDim }
    $tog.Invalidate()
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
    Set-Busy $true
    Write-Log 'Checking...'
    Refresh-Ui -Announce $true
    if ($script:LastState.Mounted -and (Test-Path $script:LOCAL)) {
        $p = Get-PendingCounts
        if ($p.Up -ge 0)   { Write-Log ('  ' + $p.Up + ' file(s) newer locally (would go TO the drive)') }
        if ($p.Down -ge 0) { Write-Log ('  ' + $p.Down + ' file(s) newer on the drive (would come DOWN)') }
    }
    Set-Busy $false
})

$btnMount.Add_Click({
    Set-Busy $true
    Write-Log 'Mounting...'
    $s = Get-DriveState
    if (-not $s.Present) { Write-Log 'ERROR: drive is not plugged in.'; Set-Busy $false; Refresh-Ui; return }

    if (Ensure-KeepAlive) { Write-Log 'Started the Linux helper (keeps the mount alive).' }

    if ($s.Where -ne 'WSL') {
        Write-Log 'Attaching the drive...'
        $att = & $script:USBIPD attach --wsl --hardware-id $script:HWID 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log ('ERROR attaching: ' + (Clean-Text $att).Trim())
            Set-Busy $false; Refresh-Ui; return
        }
        Start-Sleep -Seconds 4
    }

    Write-Out (Invoke-Wsl ('bash ' + $script:MOUNT_SH))
    Refresh-Ui

    if ($script:LastState.Mounted) {
        Write-Log 'Mounted read/write.'
        if ($script:AutoSync) {
            Write-Log 'Auto-sync ON - pulling to the local working copy...'
            Write-Out (Invoke-Wsl ('bash ' + $script:DOWN_SH))
            Refresh-Local
        }
    } else { Write-Log 'Mount did not complete.' }
    Set-Busy $false
})

$btnDown.Add_Click({
    Set-Busy $true
    Write-Log 'Pulling from the drive...'
    $r = Invoke-Wsl ('bash ' + $script:DOWN_SH)
    Write-Out $r
    Refresh-Local
    Set-Busy $false
})

$btnUp.Add_Click({
    Set-Busy $true
    Write-Log 'Pushing to the drive...'
    Write-Out (Invoke-Wsl ('bash ' + $script:UP_SH))
    Set-Busy $false
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
    Set-Busy $true

    if (Test-Path $script:LOCAL) {
        if ($script:AutoSync) {
            Write-Log 'Auto-sync ON - sending local changes back before ejecting...'
            $r = Invoke-Wsl ('bash ' + $script:UP_SH)
            Write-Out $r
            if ($r.Code -ne 0) {
                Write-Log 'SYNC FAILED - stopping. The drive was NOT ejected, so nothing is lost.'
                Set-Busy $false; Refresh-Ui; return
            }
        }
        else {
            $p = Get-PendingCounts
            if ($p.Up -gt 0) {
                $ans = [System.Windows.Forms.MessageBox]::Show(
                    ("$($p.Up) file(s) are newer locally and not on the drive yet.`n`nSync them before ejecting?"),
                    'Unsynced changes', 'YesNoCancel', 'Warning')
                if ($ans -eq 'Cancel') { Write-Log 'Eject cancelled.'; Set-Busy $false; Refresh-Ui; return }
                if ($ans -eq 'Yes') {
                    $r = Invoke-Wsl ('bash ' + $script:UP_SH)
                    Write-Out $r
                    if ($r.Code -ne 0) { Write-Log 'SYNC FAILED - drive NOT ejected.'; Set-Busy $false; Refresh-Ui; return }
                } else { Write-Log 'Skipping sync - local changes stay only on the local copy.' }
            }
        }
    }

    Write-Log 'Flushing writes and unmounting...'
    $u = Invoke-Wsl ('bash ' + $script:UMOUNT_SH)
    Write-Out $u
    if ($u.Code -ne 0) {
        Write-Log 'EJECT FAILED - a file is still open. Close any app using the drive and retry.'
        Set-Busy $false; Refresh-Ui; return
    }

    $null = & $script:USBIPD detach --hardware-id $script:HWID 2>&1
    Write-Log 'Released the drive back to Windows.'
    Write-Log '================================'
    Write-Log ' EJECTED - SAFE TO UNPLUG NOW'
    Write-Log '================================'

    $dot.ForeColor  = $cBlue
    $lblState.Text  = 'Ejected - safe to unplug'
    $lblDetail.Text = 'Writes flushed, volume unmounted cleanly, drive released.'
    Set-Busy $false
    $btnMount.Enabled = $true
    $btnDown.Enabled = $false; $btnUp.Enabled = $false; $btnEject.Enabled = $false
})

# Light auto-refresh: drive presence only, no rsync scans here.
$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ if ($btnStatus.Enabled) { Refresh-Ui } })
$timer.Start()

$form.Add_Shown({
    $script:AutoSync = Load-Settings
    Update-ToggleUi
    Write-Log 'Mac Drive Manager ready.'
    Write-Log ('Auto-sync is ' + $(if ($script:AutoSync) { 'ON' } else { 'OFF' }) + '.')
    Refresh-Ui -Announce $true
})

[void]$form.ShowDialog()
$timer.Stop()

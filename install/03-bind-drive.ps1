# One-time: share the drive with usbipd so it can be attached to WSL.
# RUN AS ADMINISTRATOR. The binding persists across reboots.
# Afterwards, attaching needs no elevation.

$conf = @{}
Get-Content (Join-Path $PSScriptRoot '..\macdrive.conf') |
  Where-Object { $_ -match '^\s*([A-Z_]+)\s*=\s*"(.*)"\s*$' } |
  ForEach-Object { if ($_ -match '^\s*([A-Z_]+)\s*=\s*"(.*)"\s*$') { $conf[$matches[1]] = $matches[2] } }

$usbipd = $conf['USBIPD']
$hwid   = $conf['HWID']

Write-Host "Binding $hwid ..." -ForegroundColor Cyan
& $usbipd bind --hardware-id $hwid
& $usbipd list

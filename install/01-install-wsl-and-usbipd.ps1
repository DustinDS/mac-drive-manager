# One-time host setup. RUN AS ADMINISTRATOR.
#
# Prerequisite you must do yourself first: enable CPU virtualization in BIOS.
#   AMD  -> "SVM Mode"          (often under OC, or Advanced > CPU Features)
#   Intel-> "Intel VT-x" / "Virtualization Technology"
# Verify afterwards: Task Manager > Performance > CPU > Virtualization: Enabled

$ErrorActionPreference = 'Stop'

$admin = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host 'Run this in an elevated PowerShell.' -ForegroundColor Red; exit 1 }

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
if (-not $cpu.VirtualizationFirmwareEnabled -and
    -not (Get-CimInstance Win32_ComputerSystem).HypervisorPresent) {
    Write-Host 'Virtualization is disabled in firmware. Enable it in BIOS first.' -ForegroundColor Red
    exit 1
}

Write-Host '[1/4] Enabling Windows features...' -ForegroundColor Cyan
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart

Write-Host '[2/4] Installing usbipd-win...' -ForegroundColor Cyan
winget install --exact --id dorssel.usbipd-win `
  --accept-source-agreements --accept-package-agreements --disable-interactivity

Write-Host '[3/4] Installing WSL...' -ForegroundColor Cyan
wsl.exe --install --no-distribution

Write-Host '[4/4] Installing Ubuntu...' -ForegroundColor Cyan
# --no-launch avoids the interactive first-run username prompt.
wsl.exe --install -d Ubuntu --no-launch

Write-Host ''
Write-Host 'Done. Reboot, then run install/02-build-hfsplus-module.sh inside WSL.' -ForegroundColor Green

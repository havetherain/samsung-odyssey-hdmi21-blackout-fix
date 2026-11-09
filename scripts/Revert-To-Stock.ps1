<#
.SYNOPSIS
    Restores stock monitor EDID configuration by removing EDID_OVERRIDE and reloading the GPU driver.

.DESCRIPTION
    Immediately reverts all EDID_OVERRIDE changes applied by Fix-HDMI21-Blackout.ps1:
    1. Removes the Device Parameters\EDID_OVERRIDE registry key from matching MONITOR instances.
    2. Restarts the NVIDIA GPU driver via pnputil (/disable-device and /enable-device) so Windows and
       nvlddmkm immediately re-read the unpatched hardware EDID (48 Gbps FRL 6 + ALLM On) from the monitor.
    3. Also lists any saved .reg backups in the backups/ folder if full manual registry import is desired.

.PARAMETER TargetHardwareId
    Monitor Hardware ID filter. Defaults to "SAME069" (Samsung Odyssey G70D S32DG700 HDMI VRR mode).
    Specify "*" to remove EDID_OVERRIDE from all detected monitors.

.PARAMETER DryRun
    Previews which EDID_OVERRIDE keys would be removed without modifying the registry or restarting the GPU.
#>

[CmdletBinding()]
param(
    [string]$TargetHardwareId = "SAME069",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator) -and -not $DryRun) {
    Write-Error "Administrator privileges are required to remove EDID_OVERRIDE. Please run PowerShell as Administrator (or use -DryRun)."
    exit 1
}

Write-Host "==============================================================================" -ForegroundColor White
Write-Host " Samsung Odyssey G7 (S32DG700 / G70D) - Revert to Stock EDID" -ForegroundColor White
Write-Host (" Target Monitor Filter : {0} | DryRun : {1}" -f $TargetHardwareId, $DryRun.IsPresent) -ForegroundColor Gray
Write-Host "==============================================================================" -ForegroundColor White
Write-Host ""

Write-Host "[Step 1] Searching for active EDID_OVERRIDE registry keys..." -ForegroundColor Yellow

$displayRoot = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY"
$hwKeys = Get-ChildItem -Path $displayRoot -ErrorAction SilentlyContinue
$removedCount = 0

foreach ($hwKey in $hwKeys) {
    $hwId = $hwKey.PSChildName
    if ($TargetHardwareId -ne "*" -and ($hwId -notlike "*$TargetHardwareId*")) {
        continue
    }

    $instKeys = Get-ChildItem -Path $hwKey.PSPath -ErrorAction SilentlyContinue
    foreach ($instKey in $instKeys) {
        $instId = $instKey.PSChildName
        $overridePath = Join-Path $instKey.PSPath "Device Parameters\EDID_OVERRIDE"

        if (Test-Path $overridePath) {
            if ($DryRun) {
                Write-Host ("  [DryRun] Would remove EDID_OVERRIDE from MONITOR\{0}\{1}" -f $hwId, $instId) -ForegroundColor DarkGray
            } else {
                Remove-Item -Path $overridePath -Recurse -Force
                Write-Host ("  Removed EDID_OVERRIDE from MONITOR\{0}\{1}" -f $hwId, $instId) -ForegroundColor Green
            }
            $removedCount++
        }
    }
}

if ($removedCount -eq 0) {
    Write-Host "  No active EDID_OVERRIDE keys found for filter '$TargetHardwareId'. Monitor is already on stock EDID." -ForegroundColor Cyan
}

Write-Host ""
Write-Host "[Step 2] Reloading GPU Driver to re-fetch hardware EDID..." -ForegroundColor Yellow

$nvGpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | Where-Object {
    $_.PNPDeviceID -like "PCI\VEN_10DE*"
})

if ($DryRun) {
    foreach ($gpu in $nvGpus) {
        Write-Host ("  [DryRun] Would restart GPU driver: {0} ({1})" -f $gpu.Name, $gpu.PNPDeviceID) -ForegroundColor DarkGray
    }
} else {
    Write-Host "  Note: Screen will briefly flicker for 2 - 4 seconds while the driver reloads." -ForegroundColor Cyan
    Start-Sleep -Seconds 1
    try {
        foreach ($gpu in $nvGpus) {
            Write-Host ("  Disabling GPU : {0}..." -f $gpu.Name)
            $null = & pnputil.exe /disable-device "$($gpu.PNPDeviceID)"
        }
        Start-Sleep -Seconds 2
    } finally {
        foreach ($gpu in $nvGpus) {
            Write-Host ("  Re-enabling GPU: {0}..." -f $gpu.Name)
            $null = & pnputil.exe /enable-device "$($gpu.PNPDeviceID)"
        }
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$backupDir = Join-Path $repoRoot "backups"
if (Test-Path $backupDir) {
    $regFiles = @(Get-ChildItem -Path $backupDir -Filter "*.reg" -ErrorAction SilentlyContinue)
    if ($regFiles.Count -gt 0) {
        Write-Host ""
        Write-Host "Available Registry Backups in backups/:" -ForegroundColor Gray
        foreach ($f in $regFiles) {
            Write-Host ("  - {0}" -f $f.FullName) -ForegroundColor DarkGray
        }
    }
}

Write-Host ""
Write-Host "==============================================================================" -ForegroundColor White
Write-Host " Revert Completed! Stock hardware EDID will be used on next handshake/reboot." -ForegroundColor Green
Write-Host "==============================================================================" -ForegroundColor White

<#
.SYNOPSIS
    Restores stock monitor EDID configuration by removing EDID_OVERRIDE, restoring cached EDID, and reloading the GPU driver.

.DESCRIPTION
    Immediately reverts all EDID changes applied by Fix-HDMI21-Blackout.ps1:
    1. Removes the Device Parameters\EDID_OVERRIDE registry key from matching MONITOR instances.
    2. Restores the original unpatched hardware EDID binary from backups/ (48 Gbps FRL 6 + ALLM On) back to
       Device Parameters\EDID when an unpatched .bin backup is available (or falls back to the oldest matching .bin).
    3. Restarts the NVIDIA GPU driver via pnputil (/disable-device and /enable-device) so Windows and
       nvlddmkm immediately re-read the stock hardware EDID from the monitor.
    4. Lists saved .reg backups in the backups/ folder if full manual registry import is desired.

.PARAMETER TargetHardwareId
    Monitor Hardware ID filter. Defaults to "SAME069" (Samsung Odyssey G70D S32DG700 HDMI VRR mode).
    Specify "*" to remove EDID_OVERRIDE from all detected monitors.

.PARAMETER DryRun
    Previews which EDID_OVERRIDE keys and EDID binaries would be restored without modifying the registry or restarting the GPU.
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

function Test-IsStockEdidBytes {
    param([byte[]]$EdidBytes)
    if (-not $EdidBytes -or $EdidBytes.Length -lt 256) { return $false }
    for ($i = 132; $i -le ($EdidBytes.Length - 11); $i++) {
        if ($EdidBytes[$i + 1] -eq 0xD8 -and $EdidBytes[$i + 2] -eq 0x5D -and $EdidBytes[$i + 3] -eq 0xC4) {
            $tag = ($EdidBytes[$i] -shr 5) -band 0x07
            if ($tag -eq 3) {
                $maxFrl = ($EdidBytes[$i + 7] -shr 4) -band 0x0F
                $allm = ($EdidBytes[$i + 8] -shr 1) -band 0x01
                return ($maxFrl -eq 6 -or $allm -eq 1)
            }
        }
    }
    return $false
}

if (-not (Test-IsAdministrator) -and -not $DryRun) {
    Write-Error "Administrator privileges are required to remove EDID_OVERRIDE. Please run PowerShell as Administrator (or use -DryRun)."
    exit 1
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$backupDir = Join-Path $repoRoot "backups"

Write-Host "==============================================================================" -ForegroundColor White
Write-Host " Samsung Odyssey G7 (S32DG700 / G70D) - Revert to Stock EDID" -ForegroundColor White
Write-Host (" Target Monitor Filter : {0} | DryRun : {1}" -f $TargetHardwareId, $DryRun.IsPresent) -ForegroundColor Gray
Write-Host "==============================================================================" -ForegroundColor White
Write-Host ""

Write-Host "[Step 1] Removing EDID_OVERRIDE and restoring cached EDID from backups..." -ForegroundColor Yellow

$displayRoot = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY"
$hwKeys = Get-ChildItem -Path $displayRoot -ErrorAction SilentlyContinue
$removedCount = 0
$restoredCount = 0

foreach ($hwKey in $hwKeys) {
    $hwId = $hwKey.PSChildName
    if ($TargetHardwareId -ne "*" -and ($hwId -notlike "*$TargetHardwareId*")) {
        continue
    }

    $instKeys = Get-ChildItem -Path $hwKey.PSPath -ErrorAction SilentlyContinue
    foreach ($instKey in $instKeys) {
        $instId = $instKey.PSChildName
        $devParamsPath = Join-Path $instKey.PSPath "Device Parameters"
        $overridePath = Join-Path $devParamsPath "EDID_OVERRIDE"

        $hadOverrideHere = (Test-Path $overridePath)
        if ($hadOverrideHere) {
            if ($DryRun) {
                Write-Host ("  [DryRun] Would remove EDID_OVERRIDE from MONITOR\{0}\{1}" -f $hwId, $instId) -ForegroundColor DarkGray
            } else {
                Remove-Item -Path $overridePath -Recurse -Force
                Write-Host ("  Removed EDID_OVERRIDE from MONITOR\{0}\{1}" -f $hwId, $instId) -ForegroundColor Green
            }
            $removedCount++
        }

        if ((Test-Path $devParamsPath) -and (Test-Path $backupDir)) {
            $safeInstName = ($instId -replace '[^a-zA-Z0-9_-]', '_')
            $binCandidates = @(Get-ChildItem -Path $backupDir -Filter ("EDID_{0}_{1}_*.bin" -f $hwId, $safeInstName) -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
            if ($binCandidates.Count -eq 0 -and $hadOverrideHere) {
                $binCandidates = @(Get-ChildItem -Path $backupDir -Filter ("EDID_{0}_*.bin" -f $hwId) -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
            }

            if ($binCandidates.Count -gt 0) {
                $chosenBin = $null
                foreach ($cand in $binCandidates) {
                    $candBytes = [System.IO.File]::ReadAllBytes($cand.FullName)
                    if (Test-IsStockEdidBytes -EdidBytes $candBytes) {
                        $chosenBin = $cand
                        break
                    }
                }
                if ($null -eq $chosenBin) {
                    $chosenBin = $binCandidates[0]
                }

                $restoreBytes = [System.IO.File]::ReadAllBytes($chosenBin.FullName)
                if ($DryRun) {
                    Write-Host ("  [DryRun] Would restore Device Parameters\EDID for MONITOR\{0}\{1} from {2} ({3} bytes)" -f $hwId, $instId, $chosenBin.Name, $restoreBytes.Length) -ForegroundColor DarkGray
                } else {
                    Set-ItemProperty -Path $devParamsPath -Name "EDID" -Value $restoreBytes -Type Binary
                    Write-Host ("  Restored Device Parameters\EDID for MONITOR\{0}\{1} from {2}" -f $hwId, $instId, $chosenBin.Name) -ForegroundColor Green
                }
                $restoredCount++
            }
        }
    }
}

if ($removedCount -eq 0) {
    Write-Host "  No active EDID_OVERRIDE keys found for filter '$TargetHardwareId'." -ForegroundColor Cyan
}
if ($restoredCount -eq 0) {
    Write-Host "  No raw .bin EDID backups found in backups/; hardware EDID will refresh on monitor power cycle / PnP reload." -ForegroundColor Gray
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

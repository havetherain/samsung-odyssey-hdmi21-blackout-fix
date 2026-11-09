<#
.SYNOPSIS
    Automated HDMI 2.1 Blackout Workaround Script for Samsung Odyssey G7 (S32DG700 / G70D) + NVIDIA RTX GPUs.

.DESCRIPTION
    Performs the following steps:
    1. Creates timestamped Registry (.reg) and raw EDID (.bin) backups in the local backups/ folder.
    2. Dynamically locates the CTA-861 HDMI Forum VSDB (IEEE OUI D8-5D-C4) inside the monitor's EDID Block 1 (Bytes 128 - 255).
    3. Patches HF-VSDB to stabilize HDMI 2.1 FRL link training while preserving 4K 144Hz 10bpc RGB (DSC 1.2):
       - Max_FRL_Rate     : 6 (48 Gbps / 12 Gbps x 4 lanes) -> 5 (40 Gbps / 10 Gbps x 4 lanes) [0x6B -> 0x5B]
       - ALLM             : 1 (Enabled)                     -> 0 (Disabled)                    [0x02 -> 0x00]
       - DSC_Max_FRL_Rate : 6 (48 Gbps / 12 Gbps x 4 lanes) -> 5 (40 Gbps / 10 Gbps x 4 lanes) [0x64 -> 0x54]
    4. Recalculates the CTA-861 Block 1 checksum (Byte 127) and registers it under Device Parameters\EDID_OVERRIDE ("1").
    5. Temporarily unloads the NVIDIA GPU driver via pnputil /disable-device, purges persistent zombie override binaries
       (ScalingConfig, ColorformatConfig, VideoInfoframeOverride) from nvlddmkm\State\DisplayDatabase, and re-enables the GPU.

.PARAMETER TargetHardwareId
    Monitor Hardware ID filter. Defaults to "SAME069" (Samsung Odyssey G70D S32DG700 HDMI VRR mode).
    Specify "*" to target any detected HDMI 2.1 monitor with an HF-VSDB block.

.PARAMETER DryRun
    Simulates all byte calculations and prints the before/after hex diff without modifying the registry or restarting the GPU.
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

function ConvertTo-HexString {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return "(empty)" }
    return ($Bytes | ForEach-Object { $_.ToString("X2") }) -join " "
}

function Find-HfVsdbOffset {
    param([byte[]]$BlockBytes)
    if (-not $BlockBytes -or $BlockBytes.Length -lt 128) { return -1 }

    for ($i = 4; $i -le ($BlockBytes.Length - 11); $i++) {
        if ($BlockBytes[$i + 1] -eq 0xD8 -and $BlockBytes[$i + 2] -eq 0x5D -and $BlockBytes[$i + 3] -eq 0xC4) {
            $header = $BlockBytes[$i]
            $tag = ($header -shr 5) -band 0x07
            if ($tag -eq 3) {
                return $i
            }
        }
    }
    return -1
}

if (-not (Test-IsAdministrator) -and -not $DryRun) {
    Write-Error "Administrator privileges are required to write EDID_OVERRIDE. Please run PowerShell as Administrator (or use -DryRun)."
    exit 1
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$backupDir = Join-Path $repoRoot "backups"
if (-not (Test-Path $backupDir)) {
    $null = New-Item -Path $backupDir -ItemType Directory -Force
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

Write-Host "==============================================================================" -ForegroundColor White
Write-Host " Samsung Odyssey G7 (S32DG700 / G70D) HDMI 2.1 Blackout Fix" -ForegroundColor White
Write-Host (" Target Monitor Filter : {0} | DryRun : {1}" -f $TargetHardwareId, $DryRun.IsPresent) -ForegroundColor Gray
Write-Host "==============================================================================" -ForegroundColor White
Write-Host ""

# Step 1: Registry Backup
Write-Host "[Step 1] Backing up DISPLAY and NVIDIA DisplayDatabase registry keys..." -ForegroundColor Yellow
if (-not $DryRun) {
    $displayRegBackup = Join-Path $backupDir "DISPLAY_Backup_$timestamp.reg"
    $nvDbRegBackup = Join-Path $backupDir "nvlddmkm_DisplayDatabase_Backup_$timestamp.reg"

    $null = & reg.exe export "HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY" $displayRegBackup /y 2>$null
    Write-Host ("  Saved DISPLAY registry backup       : {0}" -f $displayRegBackup) -ForegroundColor Green

    if (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\State\DisplayDatabase") {
        $null = & reg.exe export "HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\State\DisplayDatabase" $nvDbRegBackup /y 2>$null
        Write-Host ("  Saved DisplayDatabase registry backup: {0}" -f $nvDbRegBackup) -ForegroundColor Green
    }
} else {
    Write-Host "  [DryRun] Skipping reg.exe export." -ForegroundColor DarkGray
}

# Step 2: Locate and Patch EDID Block 1 (HF-VSDB)
Write-Host ""
Write-Host "[Step 2] Scanning DISPLAY instances for HDMI 2.1 HF-VSDB (D8 5D C4)..." -ForegroundColor Yellow

$displayRoot = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY"
$hwKeys = Get-ChildItem -Path $displayRoot -ErrorAction SilentlyContinue
$patchedCount = 0

foreach ($hwKey in $hwKeys) {
    $hwId = $hwKey.PSChildName
    if ($TargetHardwareId -ne "*" -and ($hwId -notlike "*$TargetHardwareId*")) {
        continue
    }

    $instKeys = Get-ChildItem -Path $hwKey.PSPath -ErrorAction SilentlyContinue
    foreach ($instKey in $instKeys) {
        $instId = $instKey.PSChildName
        $devParamsPath = Join-Path $instKey.PSPath "Device Parameters"
        if (-not (Test-Path $devParamsPath)) { continue }

        $edidProp = Get-ItemProperty -Path $devParamsPath -Name "EDID" -ErrorAction SilentlyContinue
        if (-not $edidProp -or -not $edidProp.EDID) { continue }
        [byte[]]$rawEdid = $edidProp.EDID

        if ($rawEdid.Length -lt 256) {
            Write-Host ("  Skipping MONITOR\{0}\{1} (EDID is {2} bytes, no Block 1 extension)" -f $hwId, $instId, $rawEdid.Length) -ForegroundColor DarkGray
            continue
        }

        [byte[]]$block1 = [byte[]]::new(128)
        [Array]::Copy($rawEdid, 128, $block1, 0, 128)

        $hfOffset = Find-HfVsdbOffset -BlockBytes $block1
        if ($hfOffset -lt 0) {
            Write-Host ("  Skipping MONITOR\{0}\{1} (No HF-VSDB D8-5D-C4 found in Block 1)" -f $hwId, $instId) -ForegroundColor DarkGray
            continue
        }

        $headerByte = $block1[$hfOffset]
        $payloadLen = $headerByte -band 0x1F
        $totalLen = $payloadLen + 1

        [byte[]]$beforeHf = [byte[]]::new($totalLen)
        [Array]::Copy($block1, $hfOffset, $beforeHf, 0, $totalLen)
        $beforeChecksum = $block1[127]

        # Save raw binary backup if not already backed up
        $safeInstName = ($instId -replace '[^a-zA-Z0-9_-]', '_')
        $binBackupPath = Join-Path $backupDir ("EDID_{0}_{1}_{2}.bin" -f $hwId, $safeInstName, $timestamp)
        if (-not $DryRun) {
            [System.IO.File]::WriteAllBytes($binBackupPath, $rawEdid)
        }

        # Patch Byte 7 (offset + 7): Max_FRL_Rate -> 5 (40Gbps = 10Gbps x 4 lanes)
        $origByte7 = $block1[$hfOffset + 7]
        $block1[$hfOffset + 7] = [byte](($origByte7 -band 0x0F) -bor 0x50)

        # Patch Byte 8 (offset + 8): ALLM (Bit 1) -> 0 (Disabled)
        $origByte8 = $block1[$hfOffset + 8]
        $block1[$hfOffset + 8] = [byte]($origByte8 -band 0xFD)

        # Patch Byte 12 (offset + 12): DSC_Max_FRL_Rate -> 5 (40Gbps = 10Gbps x 4 lanes) if present
        $origByte12 = $null
        if ($payloadLen -ge 12) {
            $origByte12 = $block1[$hfOffset + 12]
            $block1[$hfOffset + 12] = [byte](($origByte12 -band 0x0F) -bor 0x50)
        }

        # Recalculate Block 1 Checksum (Byte 127)
        $sum = 0
        for ($i = 0; $i -lt 127; $i++) {
            $sum += [int]$block1[$i]
        }
        $newChecksum = [byte]((256 - ($sum % 256)) % 256)
        $block1[127] = $newChecksum

        [byte[]]$afterHf = [byte[]]::new($totalLen)
        [Array]::Copy($block1, $hfOffset, $afterHf, 0, $totalLen)

        Write-Host ""
        Write-Host ("  Target Monitor  : MONITOR\{0}\{1}" -f $hwId, $instId) -ForegroundColor Cyan
        Write-Host ("    HF-VSDB Offset: Block 1 Byte {0} - {1}" -f $hfOffset, ($hfOffset + $totalLen - 1))
        Write-Host ("    Before Bytes  : {0} (Checksum: 0x{1:X2})" -f (ConvertTo-HexString -Bytes $beforeHf), $beforeChecksum)
        Write-Host ("    After Bytes   : {0} (Checksum: 0x{1:X2})" -f (ConvertTo-HexString -Bytes $afterHf), $newChecksum) -ForegroundColor Green
        Write-Host ("    Changes       : Byte 7 (0x{0:X2}->0x{1:X2}, Max_FRL=5), Byte 8 (0x{2:X2}->0x{3:X2}, ALLM=0), Byte 12 (0x{4:X2}->0x{5:X2}, DSC_FRL=5)" -f $origByte7, $block1[$hfOffset + 7], $origByte8, $block1[$hfOffset + 8], $(if ($null -ne $origByte12) { $origByte12 } else { 0 }), $(if ($null -ne $origByte12) { $block1[$hfOffset + 12] } else { 0 }))

        if (-not $DryRun) {
            $overridePath = Join-Path $devParamsPath "EDID_OVERRIDE"
            if (-not (Test-Path $overridePath)) {
                $null = New-Item -Path $overridePath -Force
            }
            Set-ItemProperty -Path $overridePath -Name "1" -Value $block1 -Type Binary
            Write-Host "    Saved to      : Device Parameters\EDID_OVERRIDE [Value '1' (REG_BINARY, 128 bytes)]" -ForegroundColor Green
        } else {
            Write-Host "    [DryRun] Would write 128-byte patched Block 1 to Device Parameters\EDID_OVERRIDE\1" -ForegroundColor DarkGray
        }

        $patchedCount++
    }
}

if ($patchedCount -eq 0) {
    Write-Warning "No matching HDMI 2.1 HF-VSDB monitor instances were found for filter '$TargetHardwareId'."
}

# Step 3: Unload NVIDIA GPU via pnputil, Clean DisplayDatabase Zombie Keys, and Reload GPU
Write-Host ""
Write-Host "[Step 3] Purging NVIDIA nvlddmkm DisplayDatabase Zombie Overrides..." -ForegroundColor Yellow

$nvDbPath = "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\State\DisplayDatabase"
$zombieNames = @("ScalingConfig", "ColorformatConfig", "VideoInfoframeOverride")

$nvGpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | Where-Object {
    $_.PNPDeviceID -like "PCI\VEN_10DE*"
})

if ($DryRun) {
    foreach ($gpu in $nvGpus) {
        Write-Host ("  [DryRun] Would disable NVIDIA GPU: {0} ({1})" -f $gpu.Name, $gpu.PNPDeviceID) -ForegroundColor DarkGray
    }
    if (Test-Path $nvDbPath) {
        Get-ChildItem -Path $nvDbPath -ErrorAction SilentlyContinue | ForEach-Object {
            $profName = $_.PSChildName
            if ($profName -like "ADAPTER_*" -or $profName -like "CONNECTOR_*" -or $profName -like "NOEDID_*") { return }
            $props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
            foreach ($z in $zombieNames) {
                if ($props.PSObject.Properties[$z]) {
                    Write-Host ("  [DryRun] Would delete zombie value '{0}' from profile '{1}'" -f $z, $profName) -ForegroundColor DarkGray
                }
            }
        }
    }
    foreach ($gpu in $nvGpus) {
        Write-Host ("  [DryRun] Would re-enable NVIDIA GPU: {0} ({1})" -f $gpu.Name, $gpu.PNPDeviceID) -ForegroundColor DarkGray
    }
} else {
    Write-Host "  Note: Screen will briefly go black for 2 - 4 seconds while the NVIDIA driver unloads and reloads." -ForegroundColor Cyan
    Start-Sleep -Seconds 1

    try {
        foreach ($gpu in $nvGpus) {
            Write-Host ("  Disabling GPU : {0} ({1})..." -f $gpu.Name, $gpu.PNPDeviceID)
            $null = & pnputil.exe /disable-device "$($gpu.PNPDeviceID)"
        }

        Start-Sleep -Seconds 2

        if (Test-Path $nvDbPath) {
            $subKeys = Get-ChildItem -Path $nvDbPath -ErrorAction SilentlyContinue
            foreach ($subKey in $subKeys) {
                $profName = $subKey.PSChildName
                if ($profName -like "ADAPTER_*" -or $profName -like "CONNECTOR_*" -or $profName -like "NOEDID_*") {
                    continue
                }
                if ($TargetHardwareId -ne "*" -and ($profName -notlike "*$TargetHardwareId*")) {
                    continue
                }

                $props = Get-ItemProperty -Path $subKey.PSPath -ErrorAction SilentlyContinue
                foreach ($z in $zombieNames) {
                    if ($props.PSObject.Properties[$z]) {
                        Remove-ItemProperty -Path $subKey.PSPath -Name $z -Force -ErrorAction SilentlyContinue
                        Write-Host ("  Deleted zombie key : {0} from {1}" -f $z, $profName) -ForegroundColor Green
                    }
                }
            }
        }
    } finally {
        Start-Sleep -Seconds 1
        foreach ($gpu in $nvGpus) {
            Write-Host ("  Re-enabling GPU: {0} ({1})..." -f $gpu.Name, $gpu.PNPDeviceID)
            $null = & pnputil.exe /enable-device "$($gpu.PNPDeviceID)"
        }
    }
}

Write-Host ""
Write-Host "==============================================================================" -ForegroundColor White
Write-Host " Completed! EDID_OVERRIDE (40Gbps FRL 5 + ALLM Off) & DisplayDatabase Cleanup" -ForegroundColor Green
Write-Host " Recommended: Perform a clean Windows reboot to ensure full link lock." -ForegroundColor White
Write-Host "==============================================================================" -ForegroundColor White


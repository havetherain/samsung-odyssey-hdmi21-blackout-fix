<#
.SYNOPSIS
    Automated HDMI 2.1 Blackout Workaround Script for Samsung Odyssey G7 (S32DG700 / G70D) + NVIDIA RTX GPUs.

.DESCRIPTION
    Performs the following steps:
    1. Creates timestamped Registry (.reg) and raw EDID (.bin) backups in the local backups/ folder.
    2. Removes disconnected Ghost Monitor PnP devices (such as stale HDMI 2.0 SAME068 or duplicate UID0 entries)
       that share connector addresses or pollute SetDisplayConfig() enumeration.
    3. Dynamically locates the CTA-861 HDMI Forum VSDB (IEEE OUI D8-5D-C4) inside the monitor's EDID Block 1 (Bytes 128 - 255).
    4. Patches HF-VSDB to stabilize HDMI 2.1 FRL link training while preserving 4K 144Hz 10bpc RGB (DSC 1.2):
       - Max_FRL_Rate     : 6 (48 Gbps / 12 Gbps x 4 lanes) -> Target FRL (default 4 = 32 Gbps / 8 Gbps x 4 lanes, [0x6B -> 0x4B])
       - ALLM             : 1 (Enabled)                     -> 0 (Disabled)                                     [0x02 -> 0x00]
       - DSC_Max_FRL_Rate : 6 (48 Gbps / 12 Gbps x 4 lanes) -> Target FRL (default 4 = 32 Gbps / 8 Gbps x 4 lanes, [0x64 -> 0x44])
    5. Recalculates the CTA-861 Block 1 checksum (Byte 127), registers full multi-block EDID_OVERRIDE ("0", "1", "2"),
       and synchronizes the cached Device Parameters\EDID binary.
    6. Stops NVDisplay.ContainerLocalSystem, unloads the NVIDIA GPU via pnputil /disable-device, purges stale ghost
       subkeys (SAME068*) and scaling/override binaries across DisplayDatabase (including NOEDID_* and monitor profiles)
       and MonitorDataStore, then re-enables the GPU and restarts NVDisplay.ContainerLocalSystem.

.PARAMETER TargetHardwareId
    Monitor Hardware ID filter. Defaults to "SAME069" (Samsung Odyssey G70D S32DG700 HDMI VRR mode).
    Specify "*" to target any detected HDMI 2.1 monitor with an HF-VSDB block.

.PARAMETER TargetFrlRate
    Target HDMI 2.1 FRL rate code (3 = 24 Gbps [6G x 4], 4 = 32 Gbps [8G x 4], 5 = 40 Gbps [10G x 4]).
    Defaults to 4 (32 Gbps) for maximum clock margin while still providing nearly 2x the 15 - 18 Gbps needed
    for lossless 4K 144Hz 10bpc RGB with DSC 1.2.

.PARAMETER DryRun
    Simulates all byte calculations, ghost monitor removals, and registry cleanups without modifying the system.
#>

[CmdletBinding()]
param(
    [string]$TargetHardwareId = "SAME069",
    [ValidateRange(3, 5)]
    [int]$TargetFrlRate = 4,
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

function Get-FrlRateLabel {
    param([int]$FrlRate)
    switch ($FrlRate) {
        3 { return "3 (24 Gbps = 6 Gbps x 4 lanes)" }
        4 { return "4 (32 Gbps = 8 Gbps x 4 lanes)" }
        5 { return "5 (40 Gbps = 10 Gbps x 4 lanes)" }
        default { return "$FrlRate" }
    }
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
Write-Host (" Target Filter : {0} | Target FRL : {1} | DryRun : {2}" -f $TargetHardwareId, (Get-FrlRateLabel -FrlRate $TargetFrlRate), $DryRun.IsPresent) -ForegroundColor Gray
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

# Step 2: Ghost Monitor PnP Cleanup
Write-Host ""
Write-Host "[Step 2] Cleaning up disconnected Ghost Monitor PnP devices..." -ForegroundColor Yellow

$allMonitors = @(Get-PnpDevice -Class Monitor -ErrorAction SilentlyContinue)
$ghostMonitors = @($allMonitors | Where-Object {
    $_.Status -ne "OK" -and (
        $TargetHardwareId -eq "*" -or
        $_.InstanceId -like "*$TargetHardwareId*" -or
        ($TargetHardwareId -eq "SAME069" -and $_.InstanceId -like "*SAME068*")
    )
})

if ($ghostMonitors.Count -eq 0) {
    Write-Host "  No disconnected ghost monitors found matching filter '$TargetHardwareId'." -ForegroundColor Green
} else {
    foreach ($ghost in $ghostMonitors) {
        $instId = $ghost.InstanceId
        $regGhostPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$instId"
        if ($DryRun) {
            Write-Host ("  [DryRun] Would remove ghost monitor: {0} ({1}, Status={2})" -f $instId, $ghost.FriendlyName, $ghost.Status) -ForegroundColor DarkGray
        } else {
            Write-Host ("  Removing ghost monitor: {0} ({1}, Status={2})..." -f $instId, $ghost.FriendlyName, $ghost.Status) -ForegroundColor Cyan
            $null = & pnputil.exe /remove-device "$instId" 2>&1
            if (Test-Path $regGhostPath) {
                Remove-Item -Path $regGhostPath -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-Host ("    Removed ghost device : {0}" -f $instId) -ForegroundColor Green
        }
    }
}

# Step 3: Locate and Patch EDID Block 1 (HF-VSDB), Write Full EDID_OVERRIDE (0/1/2), and Sync Cached EDID
Write-Host ""
Write-Host "[Step 3] Scanning DISPLAY instances for HDMI 2.1 HF-VSDB (D8 5D C4)..." -ForegroundColor Yellow

$displayRoot = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY"
$hwKeys = Get-ChildItem -Path $displayRoot -ErrorAction SilentlyContinue
$patchedCount = 0
$frlUpperNibble = [byte]($TargetFrlRate -shl 4)

foreach ($hwKey in $hwKeys) {
    $hwId = $hwKey.PSChildName
    if ($TargetHardwareId -ne "*" -and ($hwId -notlike "*$TargetHardwareId*")) {
        continue
    }

    $instKeys = Get-ChildItem -Path $hwKey.PSPath -ErrorAction SilentlyContinue
    foreach ($instKey in $instKeys) {
        $instId = $instKey.PSChildName
        $pnpStatus = ($allMonitors | Where-Object { $_.InstanceId -eq "DISPLAY\$hwId\$instId" } | Select-Object -First 1)
        if (-not $DryRun -and $pnpStatus -and $pnpStatus.Status -ne "OK") {
            continue
        }

        $devParamsPath = Join-Path $instKey.PSPath "Device Parameters"
        if (-not (Test-Path $devParamsPath)) { continue }

        $edidProp = Get-ItemProperty -Path $devParamsPath -Name "EDID" -ErrorAction SilentlyContinue
        if (-not $edidProp -or -not $edidProp.EDID) { continue }
        [byte[]]$rawEdid = [byte[]]$edidProp.EDID.Clone()

        if ($rawEdid.Length -lt 256) {
            Write-Host ("  Skipping MONITOR\{0}\{1} (EDID is {2} bytes, no Block 1 extension)" -f $hwId, $instId, $rawEdid.Length) -ForegroundColor DarkGray
            continue
        }

        [byte[]]$block0 = [byte[]]::new(128)
        [Array]::Copy($rawEdid, 0, $block0, 0, 128)

        [byte[]]$block1 = [byte[]]::new(128)
        [Array]::Copy($rawEdid, 128, $block1, 0, 128)

        $hasBlock2 = ($rawEdid.Length -ge 384)
        [byte[]]$block2 = $null
        if ($hasBlock2) {
            $block2 = [byte[]]::new(128)
            [Array]::Copy($rawEdid, 256, $block2, 0, 128)
        }

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

        # Save raw binary backup before modifying
        $safeInstName = ($instId -replace '[^a-zA-Z0-9_-]', '_')
        $binBackupPath = Join-Path $backupDir ("EDID_{0}_{1}_{2}.bin" -f $hwId, $safeInstName, $timestamp)
        if (-not $DryRun) {
            [System.IO.File]::WriteAllBytes($binBackupPath, $rawEdid)
        }

        # Patch Byte 7 (offset + 7): Max_FRL_Rate -> TargetFrlRate (default 4 = 32Gbps)
        $origByte7 = $block1[$hfOffset + 7]
        $block1[$hfOffset + 7] = [byte](($origByte7 -band 0x0F) -bor $frlUpperNibble)

        # Patch Byte 8 (offset + 8): ALLM (Bit 1) -> 0 (Disabled)
        $origByte8 = $block1[$hfOffset + 8]
        $block1[$hfOffset + 8] = [byte]($origByte8 -band 0xFD)

        # Patch Byte 12 (offset + 12): DSC_Max_FRL_Rate -> TargetFrlRate (default 4 = 32Gbps) if present
        $origByte12 = $null
        if ($payloadLen -ge 12) {
            $origByte12 = $block1[$hfOffset + 12]
            $block1[$hfOffset + 12] = [byte](($origByte12 -band 0x0F) -bor $frlUpperNibble)
        }

        # Recalculate Block 1 Checksum (Byte 127)
        $sum = 0
        for ($i = 0; $i -lt 127; $i++) {
            $sum += [int]$block1[$i]
        }
        $newChecksum = [byte]((256 - ($sum % 256)) % 256)
        $block1[127] = $newChecksum

        # Synchronize patched Block 1 into full cached EDID array
        [Array]::Copy($block1, 0, $rawEdid, 128, 128)

        [byte[]]$afterHf = [byte[]]::new($totalLen)
        [Array]::Copy($block1, $hfOffset, $afterHf, 0, $totalLen)

        Write-Host ""
        Write-Host ("  Target Monitor  : MONITOR\{0}\{1}" -f $hwId, $instId) -ForegroundColor Cyan
        Write-Host ("    HF-VSDB Offset: Block 1 Byte {0} - {1}" -f $hfOffset, ($hfOffset + $totalLen - 1))
        Write-Host ("    Before Bytes  : {0} (Checksum: 0x{1:X2})" -f (ConvertTo-HexString -Bytes $beforeHf), $beforeChecksum)
        Write-Host ("    After Bytes   : {0} (Checksum: 0x{1:X2})" -f (ConvertTo-HexString -Bytes $afterHf), $newChecksum) -ForegroundColor Green
        Write-Host ("    Changes       : Byte 7 (0x{0:X2}->0x{1:X2}, Max_FRL={2}), Byte 8 (0x{3:X2}->0x{4:X2}, ALLM=0), Byte 12 (0x{5:X2}->0x{6:X2}, DSC_FRL={2})" -f $origByte7, $block1[$hfOffset + 7], $TargetFrlRate, $origByte8, $block1[$hfOffset + 8], $(if ($null -ne $origByte12) { $origByte12 } else { 0 }), $(if ($null -ne $origByte12) { $block1[$hfOffset + 12] } else { 0 }))

        if (-not $DryRun) {
            $overridePath = Join-Path $devParamsPath "EDID_OVERRIDE"
            if (-not (Test-Path $overridePath)) {
                $null = New-Item -Path $overridePath -Force
            }
            Set-ItemProperty -Path $overridePath -Name "0" -Value $block0 -Type Binary
            Set-ItemProperty -Path $overridePath -Name "1" -Value $block1 -Type Binary
            if ($hasBlock2) {
                Set-ItemProperty -Path $overridePath -Name "2" -Value $block2 -Type Binary
            }
            Set-ItemProperty -Path $devParamsPath -Name "EDID" -Value $rawEdid -Type Binary
            $blockListStr = if ($hasBlock2) { "'0', '1', '2'" } else { "'0', '1'" }
            Write-Host ("    Saved to      : EDID_OVERRIDE ({0}) & synchronized cached EDID ({1} bytes)" -f $blockListStr, $rawEdid.Length) -ForegroundColor Green
        } else {
            $blockListStr = if ($hasBlock2) { "'0', '1', '2'" } else { "'0', '1'" }
            Write-Host ("    [DryRun] Would write blocks {0} to EDID_OVERRIDE and sync {1}-byte cached EDID" -f $blockListStr, $rawEdid.Length) -ForegroundColor DarkGray
        }

        $patchedCount++
    }
}

if ($patchedCount -eq 0) {
    Write-Warning "No matching HDMI 2.1 HF-VSDB monitor instances were found for filter '$TargetHardwareId'."
}

# Step 4: Stop NVDisplay.ContainerLocalSystem, Unload GPU via pnputil, Deep Clean DisplayDatabase & MonitorDataStore, Reload
Write-Host ""
Write-Host "[Step 4] Deep-Cleaning NVIDIA DisplayDatabase & MonitorDataStore..." -ForegroundColor Yellow

$nvDbPath = "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\State\DisplayDatabase"
$monDataStorePath = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\MonitorDataStore"
$nvServiceName = "NVDisplay.ContainerLocalSystem"
$scalingAndOverrideNames = @(
    "ScalingConfig",
    "ColorformatConfig",
    "VideoInfoframeOverride",
    "SmoothScalingData",
    "SmoothScalingMultiplierData",
    "UpScalingData",
    "UpScalingMultiplierData"
)

$nvGpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | Where-Object {
    $_.PNPDeviceID -like "PCI\VEN_10DE*"
})

$activeSame068 = @($allMonitors | Where-Object { $_.Status -eq "OK" -and $_.InstanceId -like "*SAME068*" })
$cleanSame068Profiles = ($TargetHardwareId -eq "SAME069" -and $activeSame068.Count -eq 0)

if ($DryRun) {
    $nvSvc = Get-Service -Name $nvServiceName -ErrorAction SilentlyContinue
    if ($nvSvc) {
        Write-Host ("  [DryRun] Would stop service '{0}' (Current Status: {1})" -f $nvServiceName, $nvSvc.Status) -ForegroundColor DarkGray
    }
    foreach ($gpu in $nvGpus) {
        Write-Host ("  [DryRun] Would disable NVIDIA GPU: {0} ({1})" -f $gpu.Name, $gpu.PNPDeviceID) -ForegroundColor DarkGray
    }
    if (Test-Path $nvDbPath) {
        Get-ChildItem -Path $nvDbPath -ErrorAction SilentlyContinue | ForEach-Object {
            $profName = $_.PSChildName
            if ($profName -like "ADAPTER_*" -or $profName -like "CONNECTOR_*") { return }
            if ($cleanSame068Profiles -and $profName -like "SAME068*") {
                Write-Host ("  [DryRun] Would remove stale DisplayDatabase subkey: {0}" -f $profName) -ForegroundColor DarkGray
                return
            }
            $props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
            if ($null -ne $props) {
                foreach ($z in $scalingAndOverrideNames) {
                    if ($props.PSObject.Properties[$z]) {
                        Write-Host ("  [DryRun] Would delete '{0}' from DisplayDatabase\{1}" -f $z, $profName) -ForegroundColor DarkGray
                    }
                }
            }
        }
    }
    if ($cleanSame068Profiles -and (Test-Path $monDataStorePath)) {
        Get-ChildItem -Path $monDataStorePath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "SAME068*" } | ForEach-Object {
            Write-Host ("  [DryRun] Would remove stale MonitorDataStore subkey: {0}" -f $_.PSChildName) -ForegroundColor DarkGray
        }
    }
    foreach ($gpu in $nvGpus) {
        Write-Host ("  [DryRun] Would re-enable NVIDIA GPU: {0} ({1})" -f $gpu.Name, $gpu.PNPDeviceID) -ForegroundColor DarkGray
    }
    if ($nvSvc) {
        Write-Host ("  [DryRun] Would restart service '{0}'" -f $nvServiceName) -ForegroundColor DarkGray
    }
} else {
    Write-Host "  Note: Screen will briefly go black for 2 - 4 seconds while the NVIDIA service and driver reload." -ForegroundColor Cyan
    Start-Sleep -Seconds 1

    $nvSvc = Get-Service -Name $nvServiceName -ErrorAction SilentlyContinue
    $wasSvcRunning = ($null -ne $nvSvc -and $nvSvc.Status -eq "Running")

    try {
        if ($wasSvcRunning) {
            Write-Host ("  Stopping service : {0}..." -f $nvServiceName)
            Stop-Service -Name $nvServiceName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }

        foreach ($gpu in $nvGpus) {
            Write-Host ("  Disabling GPU    : {0} ({1})..." -f $gpu.Name, $gpu.PNPDeviceID)
            $null = & pnputil.exe /disable-device "$($gpu.PNPDeviceID)"
        }

        Start-Sleep -Seconds 2

        if (Test-Path $nvDbPath) {
            $subKeys = Get-ChildItem -Path $nvDbPath -ErrorAction SilentlyContinue
            foreach ($subKey in $subKeys) {
                $profName = $subKey.PSChildName
                if ($profName -like "ADAPTER_*" -or $profName -like "CONNECTOR_*") {
                    continue
                }
                if ($cleanSame068Profiles -and $profName -like "SAME068*") {
                    Remove-Item -Path $subKey.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Host ("  Removed stale profile : DisplayDatabase\{0}" -f $profName) -ForegroundColor Green
                    continue
                }

                $props = Get-ItemProperty -Path $subKey.PSPath -ErrorAction SilentlyContinue
                if ($null -eq $props) { continue }
                foreach ($z in $scalingAndOverrideNames) {
                    if ($props.PSObject.Properties[$z]) {
                        Remove-ItemProperty -Path $subKey.PSPath -Name $z -Force -ErrorAction SilentlyContinue
                        Write-Host ("  Deleted value         : {0} from {1}" -f $z, $profName) -ForegroundColor Green
                    }
                }
            }
        }

        if ($cleanSame068Profiles -and (Test-Path $monDataStorePath)) {
            Get-ChildItem -Path $monDataStorePath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "SAME068*" } | ForEach-Object {
                Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host ("  Removed stale store   : MonitorDataStore\{0}" -f $_.PSChildName) -ForegroundColor Green
            }
        }
    } finally {
        Start-Sleep -Seconds 1
        foreach ($gpu in $nvGpus) {
            Write-Host ("  Re-enabling GPU  : {0} ({1})..." -f $gpu.Name, $gpu.PNPDeviceID)
            $null = & pnputil.exe /enable-device "$($gpu.PNPDeviceID)"
        }
        if ($wasSvcRunning) {
            Start-Sleep -Seconds 1
            Write-Host ("  Starting service : {0}..." -f $nvServiceName)
            Start-Service -Name $nvServiceName -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ""
Write-Host "==============================================================================" -ForegroundColor White
Write-Host (" Completed! EDID_OVERRIDE (FRL {0} + ALLM Off) & Deep Cleanup Applied" -f $TargetFrlRate) -ForegroundColor Green
Write-Host " Recommended: Perform a clean Windows reboot to ensure full link lock." -ForegroundColor White
Write-Host "==============================================================================" -ForegroundColor White

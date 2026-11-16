<#
.SYNOPSIS
    Read-only diagnostic script for Samsung Odyssey G7 (S32DG700 / G70D) HDMI 2.1 link stability.

.DESCRIPTION
    Inspects active/registered DISPLAY devices in the Windows Registry without modifying the system:
    1. PnP Monitor status check for disconnected Ghost Monitor devices (e.g., stale HDMI 2.0 SAME068 or duplicate UID0).
    2. Monitor Hardware ID, Driver matching status (Generic PnP vs Samsung Official INF), MaxResolution, and ICMProfile.
    3. Registry Cached EDID and EDID_OVERRIDE (Blocks 0, 1, 2) inspection.
    4. Dynamic lookup and bit-level decoding of the HDMI Forum Vendor-Specific Data Block (HF-VSDB, OUI D8-5D-C4):
       - Max_FRL_Rate (accepting FRL 4 [32 Gbps] and FRL 5 [40 Gbps]), ALLM, VRRmin / VRRmax, DSC 1.2, and Checksum.
    5. NVIDIA nvlddmkm DisplayDatabase inspection distinguishing critical zombie overrides (ColorformatConfig,
       VideoInfoframeOverride, stale SAME068* profiles, non-default ScalingConfig) from driver-default ScalingConfig.
#>

[CmdletBinding()]
param(
    [string]$FilterHardwareId = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-HexString {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return "(empty)" }
    return ($Bytes | ForEach-Object { $_.ToString("X2") }) -join " "
}

function Get-FrlRateDescription {
    param([int]$FrlCode)
    switch ($FrlCode) {
        0 { return "0 (FRL Not Supported / TMDS Only)" }
        1 { return "1 (9 Gbps = 3 Gbps x 3 lanes)" }
        2 { return "2 (18 Gbps = 6 Gbps x 3 lanes)" }
        3 { return "3 (24 Gbps = 6 Gbps x 4 lanes)" }
        4 { return "4 (32 Gbps = 8 Gbps x 4 lanes) [Recommended High-Margin Stable Target]" }
        5 { return "5 (40 Gbps = 10 Gbps x 4 lanes) [Stable Target]" }
        6 { return "6 (48 Gbps = 12 Gbps x 4 lanes) [Stock Maximum - Marginal Lock Risk]" }
        default { return "$FrlCode (Reserved/Unknown)" }
    }
}

function Get-DscMaxSlicesDescription {
    param([int]$SliceCode)
    switch ($SliceCode) {
        0 { return "0 (Not specified)" }
        1 { return "1 (Up to 1 slice)" }
        2 { return "2 (Up to 2 slices)" }
        3 { return "3 (Up to 4 slices)" }
        4 { return "4 (Up to 8 slices)" }
        5 { return "5 (Up to 12 slices)" }
        6 { return "6 (Up to 16 slices)" }
        default { return "$SliceCode (Unknown)" }
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

function Read-HfVsdbInfo {
    param(
        [byte[]]$Block1Bytes,
        [string]$Label
    )

    Write-Host "    [$Label (128 bytes)]" -ForegroundColor Cyan
    if (-not $Block1Bytes -or $Block1Bytes.Length -lt 128) {
        Write-Host "      Status          : Invalid or missing 128-byte CTA-861 block" -ForegroundColor Yellow
        return $null
    }

    $sum = 0
    for ($i = 0; $i -lt 127; $i++) {
        $sum += [int]$Block1Bytes[$i]
    }
    $expectedChecksum = (256 - ($sum % 256)) % 256
    $actualChecksum = [int]$Block1Bytes[127]
    $checksumValid = ($expectedChecksum -eq $actualChecksum)

    $offset = Find-HfVsdbOffset -BlockBytes $Block1Bytes
    if ($offset -lt 0) {
        Write-Host "      HF-VSDB (D8 5D C4) : Not found in this extension block" -ForegroundColor DarkGray
        return $null
    }

    $headerByte = $Block1Bytes[$offset]
    $payloadLen = $headerByte -band 0x1F
    $totalLen = $payloadLen + 1
    $hfBytes = [byte[]]::new($totalLen)
    [Array]::Copy($Block1Bytes, $offset, $hfBytes, 0, $totalLen)

    $version = $hfBytes[4]
    $maxTmdsMhz = [int]$hfBytes[5] * 5
    $scdcPresent = [bool](($hfBytes[6] -band 0x80) -ne 0)
    $maxFrlRate = ($hfBytes[7] -shr 4) -band 0x0F
    $allmBit = ($hfBytes[8] -shr 1) -band 0x01

    $vrrMin = $hfBytes[9] -band 0x3F
    $vrrMaxHi = ($hfBytes[9] -shr 6) -band 0x03
    $vrrMax = ($vrrMaxHi -shl 8) -bor [int]$hfBytes[10]

    $dsc1p2 = [bool](($hfBytes[11] -band 0x80) -ne 0)
    $dscNative420 = [bool](($hfBytes[11] -band 0x40) -ne 0)
    $dscMaxSlices = $hfBytes[11] -band 0x0F
    $dscMaxFrlRate = ($hfBytes[12] -shr 4) -band 0x0F

    Write-Host ("      Block Offset      : Byte {0} - {1} (Block 1 local) / Byte {2} - {3} (Full EDID)" -f $offset, ($offset + $totalLen - 1), ($offset + 128), ($offset + 128 + $totalLen - 1))
    Write-Host ("      Raw HF-VSDB Bytes : {0}" -f (ConvertTo-HexString -Bytes $hfBytes))
    Write-Host ("      HF-VSDB Version   : {0} | Max TMDS: {1} MHz | SCDC_Present: {2}" -f $version, $maxTmdsMhz, $scdcPresent)
    Write-Host ("      Byte 7  (0x{0:X2})    : Max_FRL_Rate     = {1}" -f $hfBytes[7], (Get-FrlRateDescription -FrlCode $maxFrlRate))
    Write-Host ("      Byte 8  (0x{0:X2})    : ALLM             = {1} ({2})" -f $hfBytes[8], $allmBit, $(if ($allmBit -eq 1) { "Enabled - Can trigger re-training on game launch" } else { "Disabled - Blocked" }))
    Write-Host ("      Byte 9-10         : VRR Range        = {0} Hz - {1} Hz (0x{2:X2} 0x{3:X2})" -f $vrrMin, $vrrMax, $hfBytes[9], $hfBytes[10])
    Write-Host ("      Byte 11 (0x{0:X2})    : DSC_1p2          = {1}, DSC_Native_420 = {2}, DSC_Max_Slices = {3}" -f $hfBytes[11], $dsc1p2, $dscNative420, (Get-DscMaxSlicesDescription -SliceCode $dscMaxSlices))
    Write-Host ("      Byte 12 (0x{0:X2})    : DSC_Max_FRL_Rate = {1}" -f $hfBytes[12], (Get-FrlRateDescription -FrlCode $dscMaxFrlRate))
    Write-Host ("      Block 1 Checksum  : 0x{0:X2} (Expected: 0x{1:X2}, Valid: {2})" -f $actualChecksum, $expectedChecksum, $checksumValid)

    return [PSCustomObject]@{
        Offset        = $offset
        RawBytes      = $hfBytes
        MaxFrlRate    = $maxFrlRate
        Allm          = $allmBit
        VrrMin        = $vrrMin
        VrrMax        = $vrrMax
        Dsc1p2        = $dsc1p2
        DscMaxFrlRate = $dscMaxFrlRate
        ChecksumValid = $checksumValid
    }
}

Write-Host "==============================================================================" -ForegroundColor White
Write-Host " Samsung Odyssey G7 (S32DG700 / G70D) HDMI 2.1 Link & Driver Diagnostic Tool" -ForegroundColor White
Write-Host " Mode: Read-Only System Inspection (No Registry Modifications)" -ForegroundColor Gray
Write-Host "==============================================================================" -ForegroundColor White
Write-Host ""

Write-Host "[1] Checking PnP Monitor Devices (Active vs Disconnected Ghost Monitors)..." -ForegroundColor Yellow
$allPnpMonitors = @(Get-PnpDevice -Class Monitor -ErrorAction SilentlyContinue)
$ghostMonitors = @($allPnpMonitors | Where-Object {
    $_.Status -ne "OK" -and (-not $FilterHardwareId -or $_.InstanceId -like "*$FilterHardwareId*")
})
$activeMonitors = @($allPnpMonitors | Where-Object { $_.Status -eq "OK" })
$activeSame068 = @($activeMonitors | Where-Object { $_.InstanceId -like "*SAME068*" })

foreach ($m in $activeMonitors) {
    Write-Host ("  [OK]    {0} ({1})" -f $m.InstanceId, $m.FriendlyName) -ForegroundColor Green
}
foreach ($g in $ghostMonitors) {
    Write-Host ("  [GHOST] {0} ({1}, Status={2})" -f $g.InstanceId, $g.FriendlyName, $g.Status) -ForegroundColor Red
}

Write-Host ""
Write-Host "[2] Inspecting DISPLAY Registry Entries & Monitor Driver Status..." -ForegroundColor Yellow

$displayRoot = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY"
$classRoot = "HKLM:\SYSTEM\CurrentControlSet\Control\Class"
$monitorHwKeys = Get-ChildItem -Path $displayRoot -ErrorAction SilentlyContinue

$foundHfVsdbMonitors = 0
$patchedMonitors = 0
$frl32Monitors = 0

foreach ($hwKey in $monitorHwKeys) {
    $hwId = $hwKey.PSChildName
    if ($FilterHardwareId -and ($hwId -notlike "*$FilterHardwareId*")) {
        continue
    }

    $instanceKeys = Get-ChildItem -Path $hwKey.PSPath -ErrorAction SilentlyContinue
    foreach ($instKey in $instanceKeys) {
        $instId = $instKey.PSChildName
        $instProps = Get-ItemProperty -Path $instKey.PSPath -ErrorAction SilentlyContinue
        $devParamsPath = Join-Path $instKey.PSPath "Device Parameters"
        if (-not (Test-Path $devParamsPath)) { continue }

        $edidProp = Get-ItemProperty -Path $devParamsPath -Name "EDID" -ErrorAction SilentlyContinue
        if (-not $edidProp -or -not $edidProp.EDID) { continue }
        [byte[]]$rawEdid = $edidProp.EDID

        $driverRel = if ($instProps.PSObject.Properties["Driver"]) { $instProps.Driver } else { "(none)" }
        $friendlyDesc = if ($instProps.PSObject.Properties["DeviceDesc"]) { $instProps.DeviceDesc } else { "(unknown)" }

        $maxRes = "(not set)"
        $icmProfile = "(none)"
        $infPath = "(unknown)"
        $matchingId = "(unknown)"

        if ($driverRel -ne "(none)") {
            $classKeyPath = Join-Path $classRoot $driverRel
            if (Test-Path $classKeyPath) {
                $classProps = Get-ItemProperty -Path $classKeyPath -ErrorAction SilentlyContinue
                if ($classProps.PSObject.Properties["MaxResolution"]) { $maxRes = $classProps.MaxResolution }
                if ($classProps.PSObject.Properties["ICMProfile"]) { $icmProfile = $classProps.ICMProfile -join ", " }
                if ($classProps.PSObject.Properties["InfPath"]) { $infPath = $classProps.InfPath }
                if ($classProps.PSObject.Properties["MatchingDeviceId"]) { $matchingId = $classProps.MatchingDeviceId }
            }
        }

        Write-Host ""
        Write-Host ("  Monitor Device : MONITOR\{0}\{1}" -f $hwId, $instId) -ForegroundColor Green
        Write-Host ("    Description  : {0}" -f $friendlyDesc)
        Write-Host ("    Driver Key   : {0} (INF: {1}, Match: {2})" -f $driverRel, $infPath, $matchingId)
        Write-Host ("    MaxResolution: {0} | ICMProfile: {1}" -f $maxRes, $icmProfile)
        Write-Host ("    EDID Length  : {0} bytes ({1} blocks)" -f $rawEdid.Length, [math]::Floor($rawEdid.Length / 128))

        $stockInfo = $null
        if ($rawEdid.Length -ge 256) {
            [byte[]]$stockBlock1 = [byte[]]::new(128)
            [Array]::Copy($rawEdid, 128, $stockBlock1, 0, 128)
            $stockInfo = Read-HfVsdbInfo -Block1Bytes $stockBlock1 -Label "Registry Cached EDID Block 1"
            if ($null -ne $stockInfo) { $foundHfVsdbMonitors++ }
        } else {
            Write-Host "    [Registry Cached EDID Block 1] Not present (EDID is only 128 bytes)" -ForegroundColor DarkGray
        }

        $overrideKeyPath = Join-Path $devParamsPath "EDID_OVERRIDE"
        if (Test-Path $overrideKeyPath) {
            $ovBlocks = @((Get-Item $overrideKeyPath).Property | Sort-Object)
            Write-Host ("    [EDID_OVERRIDE Blocks Present] : {0}" -f ($ovBlocks -join ", ")) -ForegroundColor Cyan
            $ovProp1 = Get-ItemProperty -Path $overrideKeyPath -Name "1" -ErrorAction SilentlyContinue
            if ($ovProp1 -and $ovProp1."1") {
                [byte[]]$ovBlock1 = $ovProp1."1"
                $ovInfo = Read-HfVsdbInfo -Block1Bytes $ovBlock1 -Label "Active EDID_OVERRIDE Block 1"
                if ($null -ne $ovInfo -and $ovInfo.MaxFrlRate -in @(4, 5) -and $ovInfo.Allm -eq 0 -and $ovInfo.DscMaxFrlRate -eq $ovInfo.MaxFrlRate -and $ovInfo.ChecksumValid) {
                    $patchedMonitors++
                    $bwText = if ($ovInfo.MaxFrlRate -eq 4) { "32Gbps (FRL 4)" } else { "40Gbps (FRL 5)" }
                    if ($ovInfo.MaxFrlRate -eq 4) { $frl32Monitors++ }
                    Write-Host ("    [Status] {0} + ALLM Off EDID_OVERRIDE is ACTIVE and VALID." -f $bwText) -ForegroundColor Green
                }
            } else {
                Write-Host "    [EDID_OVERRIDE] Key exists, but value '1' (Block 1 override) is not set." -ForegroundColor Yellow
            }
        } else {
            Write-Host "    [EDID_OVERRIDE] Not configured (Running on Stock EDID)" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "[3] Inspecting NVIDIA nvlddmkm DisplayDatabase for Zombie & Stale Overrides..." -ForegroundColor Yellow

$nvDbPath = "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\State\DisplayDatabase"
$defaultScalingHex = "DB 02 00 00 10 00 00 00 00 01 00 00 EE 00 00 00"
$criticalValueNames = @("ColorformatConfig", "VideoInfoframeOverride")
$criticalFindings = @()
$defaultScalingNotes = @()

if (Test-Path $nvDbPath) {
    $dbSubKeys = Get-ChildItem -Path $nvDbPath -ErrorAction SilentlyContinue
    foreach ($subKey in $dbSubKeys) {
        $profileName = $subKey.PSChildName
        if ($profileName -like "ADAPTER_*" -or $profileName -like "CONNECTOR_*") {
            continue
        }

        if ($FilterHardwareId -and $profileName -notlike "NOEDID_*" -and ($profileName -notlike "*$FilterHardwareId*")) {
            continue
        }

        $props = Get-ItemProperty -Path $subKey.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $props) { continue }

        Write-Host ""
        Write-Host ("  Profile : {0}" -f $profileName) -ForegroundColor Cyan

        if ($profileName -like "SAME068*" -and $activeSame068.Count -eq 0) {
            $criticalFindings += [PSCustomObject]@{ Profile = $profileName; Name = "(Stale SAME068 Profile)"; Value = "Ghost HDMI 2.0 profile still cached" }
            Write-Host "    [!] STALE GHOST PROFILE : SAME068 (HDMI 2.0) profile remains in DisplayDatabase" -ForegroundColor Red
        }

        $hasCriticalInProfile = $false
        foreach ($cName in $criticalValueNames) {
            if ($props.PSObject.Properties[$cName]) {
                $val = $props.$cName
                $hexStr = if ($val -is [byte[]]) { ConvertTo-HexString -Bytes $val } else { "$val" }
                $criticalFindings += [PSCustomObject]@{ Profile = $profileName; Name = $cName; Value = $hexStr }
                $hasCriticalInProfile = $true
                Write-Host ("    [!] CRITICAL ZOMBIE     : {0} = {1}" -f $cName, $hexStr) -ForegroundColor Red
            }
        }

        if ($props.PSObject.Properties["ScalingConfig"]) {
            $scVal = $props.ScalingConfig
            $scHex = if ($scVal -is [byte[]]) { ConvertTo-HexString -Bytes $scVal } else { "$scVal" }
            if ($scHex -eq $defaultScalingHex) {
                $defaultScalingNotes += [PSCustomObject]@{ Profile = $profileName; Value = $scHex }
                Write-Host ("    [Info] Driver Default   : ScalingConfig = {0}" -f $scHex) -ForegroundColor Gray
            } else {
                $criticalFindings += [PSCustomObject]@{ Profile = $profileName; Name = "ScalingConfig (Custom Override)"; Value = $scHex }
                $hasCriticalInProfile = $true
                Write-Host ("    [!] CUSTOM OVERRIDE     : ScalingConfig = {0}" -f $scHex) -ForegroundColor Red
            }
        }

        if (-not $hasCriticalInProfile -and -not ($profileName -like "SAME068*" -and $activeSame068.Count -eq 0)) {
            Write-Host "    Status                  : CLEAN (No Colorformat / VideoInfoframe / Custom Scaling zombies)" -ForegroundColor Green
        }
    }
} else {
    Write-Host "  NVIDIA DisplayDatabase path not found ($nvDbPath)." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "==============================================================================" -ForegroundColor White
Write-Host " Diagnostic Summary" -ForegroundColor White
Write-Host "==============================================================================" -ForegroundColor White
Write-Host ("  - Disconnected Ghost Monitors        : {0}" -f $ghostMonitors.Count)
Write-Host ("  - HDMI 2.1 HF-VSDB Monitors Detected : {0}" -f $foundHfVsdbMonitors)
Write-Host ("  - Monitors with FRL 4/5 + ALLM Off   : {0} (FRL 4 [32Gbps]: {1})" -f $patchedMonitors, $frl32Monitors)
Write-Host ("  - Critical DisplayDatabase Issues    : {0}" -f $criticalFindings.Count)
Write-Host ("  - Driver-Default ScalingConfig Info  : {0}" -f $defaultScalingNotes.Count)

if ($patchedMonitors -gt 0 -and $criticalFindings.Count -eq 0 -and $ghostMonitors.Count -eq 0) {
    if ($frl32Monitors -gt 0) {
        Write-Host "  - Overall Status: OPTIMAL (FRL 4 32Gbps + ALLM Off applied, no ghost monitors, DisplayDatabase clean)" -ForegroundColor Green
    } else {
        Write-Host "  - Overall Status: GOOD (FRL 5 40Gbps active; consider upgrading to FRL 4 [32Gbps] for higher clock margin)" -ForegroundColor Cyan
    }
} else {
    Write-Host "  - Overall Status: ACTION RECOMMENDED (Run scripts\Fix-HDMI21-Blackout.ps1 as Administrator)" -ForegroundColor Yellow
}
Write-Host "==============================================================================" -ForegroundColor White

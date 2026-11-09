<#
.SYNOPSIS
    Read-only diagnostic script for Samsung Odyssey G7 (S32DG700 / G70D) HDMI 2.1 link stability.

.DESCRIPTION
    Inspects active/registered DISPLAY devices in the Windows Registry without modifying the system:
    1. Monitor Hardware ID, Driver matching status (Generic PnP vs Samsung Official INF), MaxResolution, and ICMProfile.
    2. Stock EDID and EDID_OVERRIDE (if present) CTA-861 Extension Block (Block 1).
    3. Dynamic lookup and bit-level decoding of the HDMI Forum Vendor-Specific Data Block (HF-VSDB, OUI D8-5D-C4):
       - Max_FRL_Rate, ALLM, VRRmin / VRRmax, DSC 1.2 capabilities, DSC_Max_FRL_Rate, and Block 1 checksum validation.
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
        4 { return "4 (32 Gbps = 8 Gbps x 4 lanes)" }
        5 { return "5 (40 Gbps = 10 Gbps x 4 lanes) [Recommended Stable Target]" }
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

    # Search CTA-861 Data Block Collection (bytes 4 to dtdStart-1, or full 128-byte block fallback)
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

    # Verify Block 1 checksum
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

Write-Host "[1] Inspecting DISPLAY Registry Entries & Monitor Driver Status..." -ForegroundColor Yellow

$displayRoot = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY"
$classRoot = "HKLM:\SYSTEM\CurrentControlSet\Control\Class"
$monitorHwKeys = Get-ChildItem -Path $displayRoot -ErrorAction SilentlyContinue

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

        if ($rawEdid.Length -ge 256) {
            [byte[]]$stockBlock1 = [byte[]]::new(128)
            [Array]::Copy($rawEdid, 128, $stockBlock1, 0, 128)
            $null = Read-HfVsdbInfo -Block1Bytes $stockBlock1 -Label "Stock EDID Block 1"
        } else {
            Write-Host "    [Stock EDID Block 1] Not present (EDID is only 128 bytes)" -ForegroundColor DarkGray
        }

        $overrideKeyPath = Join-Path $devParamsPath "EDID_OVERRIDE"
        if (Test-Path $overrideKeyPath) {
            $ovProp1 = Get-ItemProperty -Path $overrideKeyPath -Name "1" -ErrorAction SilentlyContinue
            if ($ovProp1 -and $ovProp1."1") {
                [byte[]]$ovBlock1 = $ovProp1."1"
                $null = Read-HfVsdbInfo -Block1Bytes $ovBlock1 -Label "Active EDID_OVERRIDE Block 1"
            } else {
                Write-Host "    [EDID_OVERRIDE] Key exists, but value '1' (Block 1 override) is not set." -ForegroundColor Yellow
            }
        } else {
            Write-Host "    [EDID_OVERRIDE] Not configured (Running on Stock EDID)" -ForegroundColor Yellow
        }
    }
}

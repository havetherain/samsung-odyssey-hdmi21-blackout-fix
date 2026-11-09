# Technical Deep Dive: HDMI 2.1 FRL Link Training, HF-VSDB Patching & NVIDIA `DisplayDatabase` Internals

> **[한국어 가이드 (README.ko.md)](../README.ko.md) | [English Main Guide (README.md)](../README.md)**

This document provides a low-level technical analysis of the intermittent **1 - 2s HDMI 2.1 black screen (video signal dropout)** observed on the **Samsung Odyssey G7 (`S32DG700` / `G70D`, 4K 144Hz, Tizen OS)** paired with an **NVIDIA GeForce RTX 5070 Ti**, including byte-level EDID structures and Windows/NVIDIA kernel driver (`nvlddmkm.sys`) persistence behavior.

---

## 1. Symptom Isolation: Why Cold Boot Works, But Handshake Triggers Fail

### 1.1 Hardware & Software Testbed
| Component | Specification |
| :--- | :--- |
| **CPU** | AMD Ryzen 7 9800X3D (Integrated GPU Explicitly Disabled in BIOS) |
| **Motherboard** | ASUS B850M MAX GAMING WIFI |
| **Memory** | DDR5 32GB @ 4800MHz |
| **GPU** | NVIDIA GeForce RTX 5070 Ti |
| **Monitor** | Samsung Odyssey G7 `S32DG700` (`G70D`, 3840x2160 @ 144Hz, Tizen Smart OS) |
| **Connection** | Ultra High Speed HDMI 2.1 Cable (48Gbps certified) |
| **Monitor Hardware ID** | `MONITOR\SAME069` (`G70D_S32DG70xE (HDMI VRR)`) |

### 1.2 The Deterministic Trigger Pattern
1. **Monitor Power vs. Signal Loss**: During a blackout event, the monitor power LED and backlight state remain active, system audio continues uninterrupted, keyboard/mouse inputs are processed normally, and Windows Event Viewer records **zero `nvlddmkm` TDR/crash events**. Only the HDMI 2.1 video stream drops for **1 - 2 seconds** while the sink (monitor) and source (GPU) re-synchronize.
2. **Cold Boot Stability**: Immediately after a cold boot into Windows 11 at **3840x2160 @ 144Hz, 10bpc, RGB Full, G-SYNC Compatible**, the display runs for hours without a single dropout during desktop usage, YouTube playback, or playing *Grand Theft Auto V*.
3. **Handshake / Re-negotiation Trigger**: The moment any action triggers an **HDMI 2.1 mode switch, InfoFrame update, or SCDC (Status and Control Data Channel) link re-negotiation**—such as:
   - Launching *EA Sports FC 25* (which initializes in a `1280x720` window before switching to fullscreen/borderless and emits an ALLM / VRR transition)
   - Toggling Windows HDR On/Off
   - Changing Color Format (`8bpc`, `YCbCr422`), Content Type reported to the display, or GPU Scaling in the NVIDIA Control Panel
   - The link enters a **Marginal Lock** state. Even after closing the game and returning to the Windows desktop, the monitor continues to black out for 1 - 2 seconds intermittently until the PC is fully rebooted.

---

## 2. Root Cause #1: HDMI 2.1 HF-VSDB (48Gbps FRL 6 & ALLM Re-Training)

### 2.1 Bandwidth Math vs. Advertised FRL Rate
At **3840x2160 @ 144Hz, 10-bit RGB**, the uncompressed video bandwidth requirement is approximately **35.8 - 39.2 Gbps**. However, when **DSC 1.2 (Display Stream Compression)** is active (with 3:1 or 2.4:1 visually lossless compression), the actual video payload transmitted across the HDMI 2.1 link is only **15 - 18 Gbps**.

Despite only needing 15 - 18 Gbps with DSC enabled, the Samsung Odyssey G7 (`MONITOR\SAME069`) advertises:
- `Max_FRL_Rate = 6` (**48 Gbps** = 12 Gbps across 4 lanes)
- `DSC_Max_FRL_Rate = 6` (**48 Gbps** = 12 Gbps across 4 lanes)
- `ALLM = 1` (**Auto Low Latency Mode** enabled)

When a game launches or an InfoFrame change triggers an SCDC re-handshake (especially alongside an ALLM transition on Samsung's Tizen OS scaler), the GPU and monitor re-train at the maximum advertised **12 Gbps per lane (48 Gbps FRL 6)**. At 12 Gbps/lane, high-frequency signal integrity margins are narrow; bit error accumulation in the Character Error Detection (CED) counters on the Tizen HDMI 2.1 receiver causes periodic SCDC link drop and recovery cycles (lasting 1 - 2 seconds each).

### 2.2 Byte-by-Byte Breakdown of the CTA-861 HF-VSDB Block
The monitor's stock EDID is **384 bytes** (Block 0: Base EDID `0 - 127`, Block 1: CTA-861 Extension `128 - 255`, Block 2: Extension `256 - 383`).
Inside **Block 1 (Bytes 128 - 255)**, at local offset **Byte 54 - 67** (Full EDID offset **Byte 182 - 195**), lies the **HDMI Forum Vendor-Specific Data Block (HF-VSDB)** identified by the IEEE OUI `C4-5D-D8` (stored in little-endian byte order as `D8 5D C4`):

```text
Stock HF-VSDB (14 bytes)  : 6D D8 5D C4 01 78 80 6B 02 30 90 C3 64 0B  (Block 1 Checksum: 0xE4)
Patched HF-VSDB (14 bytes): 6D D8 5D C4 01 78 80 5B 00 30 90 C3 54 0B  (Block 1 Checksum: 0x06)
                                                 ^^ ^^          ^^
                                            Byte 7  8          12
```

| HF-VSDB Byte | Block 1 Offset | Stock Hex | Patched Hex | Bitfield Definition | Technical Impact |
| :---: | :---: | :---: | :---: | :--- | :--- |
| **Byte 0** | `54` | `0x6D` | `0x6D` | Bits 7 - 5: `011b` (Vendor-Specific Tag `3`)<br>Bits 4 - 0: `01101b` (Length = 13 bytes) | Standard CTA-861 Data Block header (14 bytes total including header). |
| **Byte 1 - 3** | `55 - 57` | `D8 5D C4` | `D8 5D C4` | IEEE OUI `C4-5D-D8` (HDMI Forum) | Identifies this block as the HDMI 2.1 HF-VSDB. |
| **Byte 4** | `58` | `0x01` | `0x01` | `Version = 1` | HF-VSDB specification version 1. |
| **Byte 5** | `59` | `0x78` | `0x78` | `Max_TMDS_Character_Rate = 120` (`120 * 5 = 600 MHz`) | Legacy HDMI 2.0 TMDS clock limit. |
| **Byte 6** | `60` | `0x80` | `0x80` | Bit 7: `SCDC_Present = 1` | Enables SCDC status/control register communication over DDC/I2C. |
| **Byte 7** | `61` | **`0x6B`** | **`0x5B`** | Bits 7 - 4: **`Max_FRL_Rate`** (`6 -> 5`)<br>Bits 3 - 0: `0xB` (`CNMVRR`, `CinemaVRR`, `MDelta`) | Caps un-compressed FRL link rate from **48 Gbps (12G x 4)** to **40 Gbps (10G x 4)**. |
| **Byte 8** | `62` | **`0x02`** | **`0x00`** | Bit 1: **`ALLM`** (`1 -> 0`) | **Blocks Auto Low Latency Mode (ALLM)** InfoFrame toggles from triggering Tizen Game Mode re-handshakes on game launch. |
| **Byte 9 - 10** | `63 - 64` | `30 90` | `30 90` | Byte 9 Bits 5 - 0: `VRRmin = 48 Hz` (`0x30`)<br>Byte 9 Bits 7 - 6 + Byte 10: `VRRmax = 144 Hz` (`0x090`) | Preserves full hardware HDMI 2.1 VRR / G-SYNC range (**48 - 144 Hz**). |
| **Byte 11** | `65` | `0xC3` | `0xC3` | Bit 7: `DSC_1p2 = 1`<br>Bit 6: `DSC_Native_420 = 1`<br>Bits 3 - 0: `DSC_Max_Slices = 3` (Up to 4 slices) | Preserves full DSC 1.2 visually lossless compression support. |
| **Byte 12** | `66` | **`0x64`** | **`0x54`** | Bits 7 - 4: **`DSC_Max_FRL_Rate`** (`6 -> 5`)<br>Bits 3 - 0: `0x4` | Caps DSC FRL link training rate from **48 Gbps (12G x 4)** to **40 Gbps (10G x 4)**. |
| **Byte 13** | `67` | `0x0B` | `0x0B` | Bits 5 - 0: `DSC_TotalChunkKBytes = 11` | DSC chunk buffer size parameter. |
| **Checksum** | `127` | **`0xE4`** | **`0x06`** | `(256 - (Sum(Byte 0 - 126) % 256)) % 256` | Sum decreases by `0x10 + 0x02 + 0x10 = 0x22`, advancing the 8-bit two's complement checksum from `0xE4` to `0x06`. |

### 2.3 Why 40 Gbps (FRL 5) Preserves Full 4K 144Hz 10bpc RGB
Lowering `Max_FRL_Rate` and `DSC_Max_FRL_Rate` from `6` (48 Gbps) to `5` (40 Gbps):
- Reduces the per-lane symbol clock from **12 Gbps to 10 Gbps**, vastly improving signal-to-noise margin and eliminating CED error accumulation during link training.
- Provides **40 Gbps** of link capacity—more than **2x the 15 - 18 Gbps** needed by 4K 144Hz 10-bit RGB with DSC 1.2, and even sufficient for uncompressed 4K 144Hz 10-bit 4:4:4.
- Disabling `ALLM` (`0x02 -> 0x00`) prevents Windows / games from sending ALLM Vendor-Specific InfoFrames that cause the Samsung Tizen firmware to re-initialize its HDMI port state mid-session.

---

## 3. Root Cause #2: NVIDIA `nvlddmkm` `DisplayDatabase` Zombie Overrides

### 3.1 How NVIDIA Control Panel Creates Indelible Registry State
When troubleshooting HDMI flickering, users commonly experiment with settings in the **NVIDIA Control Panel**:
- Changing Color Format (`RGB` vs `YCbCr422` / `YCbCr444`) or Bit Depth (`8bpc` vs `10bpc`)
- Changing "Content type reported to the display" (Auto / Desktop programs / Full-screen videos / Games)
- Toggling "Perform scaling on: GPU / Display" or checking "Override the scaling mode set by games and programs"

The moment any of these options are modified even once, `nvlddmkm.sys` writes binary configuration blobs into:
```text
HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\State\DisplayDatabase\<MonitorProfile>
```
(For example, `SAME069H1AK500000_0E_07E8_00`).

Specifically, three binary values are created:
1. `ColorformatConfig` (`REG_BINARY`)
2. `VideoInfoframeOverride` (`REG_BINARY`)
3. `ScalingConfig` (`REG_BINARY`, e.g., `DB 02 00 00 10 00 00 00 00 01 00 00 EE 00 00 00`)

**Critical Bug / Behavior**: Clicking **"Restore Defaults"** in the NVIDIA Control Panel does **not** delete these registry values. Instead, it overwrites them with another explicit override structure. Having `VideoInfoframeOverride`, `ColorformatConfig`, or `ScalingConfig` present causes `nvlddmkm.sys` to forcibly inject custom AVI/Vendor InfoFrames and timing overrides during every mode switch, which severely aggravates HDMI 2.1 link dropouts on the Odyssey G70D.

### 3.2 Why `pnputil /disable-device` Is Mandatory Before Deleting
If you open `regedit.exe` and delete `ScalingConfig`, `ColorformatConfig`, and `VideoInfoframeOverride` while the NVIDIA GPU driver is running:
1. The values appear to vanish from the Registry.
2. However, `nvlddmkm.sys` holds the active `DisplayDatabase` state in kernel non-paged pool memory.
3. On system shutdown, reboot, or driver stop, `nvlddmkm.sys` flushes its in-memory state back to `HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\State\DisplayDatabase`, **recreating the deleted zombie keys**.

To permanently purge them without running DDU (Display Driver Uninstaller):
1. Unload `nvlddmkm.sys` first by disabling the GPU device via `pnputil /disable-device "<GPU_Instance_ID>"`.
2. While the driver is unloaded from memory, delete `ScalingConfig`, `ColorformatConfig`, and `VideoInfoframeOverride` from the Registry.
3. Re-enable the GPU via `pnputil /enable-device "<GPU_Instance_ID>"`. The driver initializes with a clean `DisplayDatabase` state and simultaneously loads the new `EDID_OVERRIDE`.

---

## 4. Root Cause #3: Official Monitor INF Matching, Tizen OS & Game Config

### 4.1 Samsung Official `S32DG70xE.inf` vs. `Generic PnP Monitor`
When Windows installs the default `monitor.inf` (`Generic PnP Monitor`), the driver class key (`HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e96e-e325-11ce-bfc1-08002be10318}\000x`) sets:
- `MaxResolution = 1600,1200`
- No `MODES` sync polarity constraints or ICM color profile.

Installing Samsung's official **`S32DG70xE.inf`** driver for **`G70D_S32DG70xE (HDMI VRR)`** (`MONITOR\SAME069`) properly configures:
- `MaxResolution = 3840,2160`
- `MODES\3840,2160 = 30-255,30-144,+,+` (explicit horizontal kHz and vertical 30 - 144Hz timing bounds with positive sync polarity)
- `ICMProfile = S32DG70xE.icm`

Additionally, removing hidden/disconnected **Ghost Monitor** entries in Device Manager (`View -> Show hidden devices`) prevents Windows Desktop Window Manager (DWM) from consulting stale topology entries during fullscreen transitions.

### 4.2 Tizen OS & `EA Sports FC 25` Handshake Minimization
- **Tizen OS Settings**:
  - Disable **`Anynet+ (HDMI-CEC)`** in the monitor's Tizen menu (`Connection -> External Device Manager -> Anynet+ (HDMI-CEC) -> Off`) to stop periodic CEC polling on the HDMI bus.
  - Lock the HDMI input source icon/type to **`PC`** and perform a cold power reset (unplug the monitor power cord for 30 seconds).
- **`EA Sports FC 25` (`%LOCALAPPDATA%\EA Sports FC 25\fcsetup.ini`)**:
  - By default, FC 25 initializes a `1280x720` window before switching to `3840x2160`, forcing back-to-back HDMI mode switches. Setting the exact native desktop parameters eliminates the launch mode-switch:
    ```ini
    WINDOWED_WIDTH = 3840
    WINDOWED_HEIGHT = 2160
    FULLSCREEN = 0
    WINDOWED_BORDERLESS = 1
    REFRESH_RATE = 144
    DYNAMIC_RESOLUTION = 0
    HDR = 0
    ```

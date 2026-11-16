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

## 2. Root Cause #1: HDMI 2.1 HF-VSDB (48Gbps FRL 6 -> 32Gbps FRL 4 & ALLM Re-Training)

### 2.1 Bandwidth Math vs. Advertised FRL Rate
At **3840x2160 @ 144Hz, 10-bit RGB**, the uncompressed video bandwidth requirement is approximately **35.8 - 39.2 Gbps**. However, when **DSC 1.2 (Display Stream Compression)** is active (with 3:1 or 2.4:1 visually lossless compression), the actual video payload transmitted across the HDMI 2.1 link is only **15 - 18 Gbps**.

Despite only needing 15 - 18 Gbps with DSC enabled, the Samsung Odyssey G7 (`MONITOR\SAME069`) advertises:
- `Max_FRL_Rate = 6` (**48 Gbps** = 12 Gbps across 4 lanes)
- `DSC_Max_FRL_Rate = 6` (**48 Gbps** = 12 Gbps across 4 lanes)
- `ALLM = 1` (**Auto Low Latency Mode** enabled)

When a game launches, a driver updates, or the GPU sits in low-power state `P5` (`810 MHz` VRAM clock while driving 4K 144Hz desktop + hardware video decode), an SCDC re-handshake or high-frequency bit error accumulation in the Character Error Detection (CED) counters causes periodic link drop and recovery cycles (lasting 1 - 2 seconds each).

Earlier v1.0.0 testing stepped down only one tier to **FRL 5 (40 Gbps = 10 Gbps/lane)**, which reduced the per-lane symbol clock by just **16.7%**. Under newer driver timings (such as `621.24`) and P5/gaming thermal transitions, 10 Gbps/lane still exhibited marginal lock behavior. Stepping down one additional tier to **FRL 4 (32 Gbps = 8 Gbps/lane)** cuts the per-lane symbol clock by **33.3%** while still delivering nearly **2x the 15 - 18 Gbps** needed for lossless 4K 144Hz 10bpc RGB with DSC 1.2.

### 2.2 Byte-by-Byte Breakdown of the CTA-861 HF-VSDB Block
The monitor's stock EDID is **384 bytes** (Block 0: Base EDID `0 - 127`, Block 1: CTA-861 Extension `128 - 255`, Block 2: Extension `256 - 383`).
Inside **Block 1 (Bytes 128 - 255)**, at local offset **Byte 54 - 67** (Full EDID offset **Byte 182 - 195**), lies the **HDMI Forum Vendor-Specific Data Block (HF-VSDB)** identified by the IEEE OUI `C4-5D-D8` (stored in little-endian byte order as `D8 5D C4`):

```text
Stock HF-VSDB     (48Gbps FRL 6, ALLM=1): 6D D8 5D C4 01 78 80 6B 02 30 90 C3 64 0B  (Block 1 Checksum: 0xE4)
v1.0.0 FRL 5      (40Gbps FRL 5, ALLM=0): 6D D8 5D C4 01 78 80 5B 00 30 90 C3 54 0B  (Block 1 Checksum: 0x06)
v1.1.0 FRL 4 (Def)(32Gbps FRL 4, ALLM=0): 6D D8 5D C4 01 78 80 4B 00 30 90 C3 44 0B  (Block 1 Checksum: 0x26)
                                                               ^^ ^^          ^^
                                                          Byte 7  8          12
```

| HF-VSDB Byte | Block 1 Offset | Stock Hex | v1.1.0 FRL 4 | Bitfield Definition | Technical Impact |
| :---: | :---: | :---: | :---: | :--- | :--- |
| **Byte 0** | `54` | `0x6D` | `0x6D` | Bits 7 - 5: `011b` (Vendor-Specific Tag `3`)<br>Bits 4 - 0: `01101b` (Length = 13 bytes) | Standard CTA-861 Data Block header (14 bytes total including header). |
| **Byte 1 - 3** | `55 - 57` | `D8 5D C4` | `D8 5D C4` | IEEE OUI `C4-5D-D8` (HDMI Forum) | Identifies this block as the HDMI 2.1 HF-VSDB. |
| **Byte 4** | `58` | `0x01` | `0x01` | `Version = 1` | HF-VSDB specification version 1. |
| **Byte 5** | `59` | `0x78` | `0x78` | `Max_TMDS_Character_Rate = 120` (`120 * 5 = 600 MHz`) | Legacy HDMI 2.0 TMDS clock limit. |
| **Byte 6** | `60` | `0x80` | `0x80` | Bit 7: `SCDC_Present = 1` | Enables SCDC status/control register communication over DDC/I2C. |
| **Byte 7** | `61` | **`0x6B`** | **`0x4B`** | Bits 7 - 4: **`Max_FRL_Rate`** (`6 -> 4`)<br>Bits 3 - 0: `0xB` (`CNMVRR`, `CinemaVRR`, `MDelta`) | Caps FRL link rate from **48 Gbps (12G x 4)** to **32 Gbps (8G x 4)** (33.3% clock reduction). |
| **Byte 8** | `62` | **`0x02`** | **`0x00`** | Bit 1: **`ALLM`** (`1 -> 0`) | **Blocks Auto Low Latency Mode (ALLM)** InfoFrame toggles from triggering Tizen Game Mode re-handshakes on game launch. |
| **Byte 9 - 10** | `63 - 64` | `30 90` | `30 90` | Byte 9 Bits 5 - 0: `VRRmin = 48 Hz` (`0x30`)<br>Byte 9 Bits 7 - 6 + Byte 10: `VRRmax = 144 Hz` (`0x090`) | Preserves full hardware HDMI 2.1 VRR / G-SYNC range (**48 - 144 Hz**). |
| **Byte 11** | `65` | `0xC3` | `0xC3` | Bit 7: `DSC_1p2 = 1`<br>Bit 6: `DSC_Native_420 = 1`<br>Bits 3 - 0: `DSC_Max_Slices = 3` (Up to 4 slices) | Preserves full DSC 1.2 visually lossless compression support. |
| **Byte 12** | `66` | **`0x64`** | **`0x44`** | Bits 7 - 4: **`DSC_Max_FRL_Rate`** (`6 -> 4`)<br>Bits 3 - 0: `0x4` | Caps DSC FRL link training rate from **48 Gbps (12G x 4)** to **32 Gbps (8G x 4)**. |
| **Byte 13** | `67` | `0x0B` | `0x0B` | Bits 5 - 0: `DSC_TotalChunkKBytes = 11` | DSC chunk buffer size parameter. |
| **Checksum** | `127` | **`0xE4`** | **`0x26`** | `(256 - (Sum(Byte 0 - 126) % 256)) % 256` | Sum decreases by `0x20 + 0x02 + 0x20 = 0x42`, advancing the 8-bit two's complement checksum from `0xE4` to `0x26` (`0x06` for FRL 5). |

### 2.3 Why 32 Gbps (FRL 4) + Multi-Block `EDID_OVERRIDE` (`0`, `1`, `2`) Maximizes Stability
Lowering `Max_FRL_Rate` and `DSC_Max_FRL_Rate` from `6` (48 Gbps) to `4` (32 Gbps):
- Reduces the per-lane symbol clock by **33.3%** (**12 Gbps -> 8 Gbps/lane**, compared to only 16.7% at FRL 5 / 40 Gbps), providing a wide electrical and signal-to-noise margin even when the GPU sits in `P5` (`810 MHz` VRAM) or runs under gaming thermal load.
- Still delivers **32 Gbps** of link capacity—nearly **2x the 15 - 18 Gbps** actually consumed by 4K 144Hz 10-bit RGB with DSC 1.2.
- Disabling `ALLM` (`0x02 -> 0x00`) prevents Windows / games from sending ALLM Vendor-Specific InfoFrames that cause the Samsung Tizen firmware to re-initialize its HDMI port state mid-session.
- **Full Multi-Block Override & Cached EDID Sync**: Writing all extension blocks (`"0"`, `"1"`, `"2"`) into `EDID_OVERRIDE` and synchronizing `Device Parameters\EDID` ensures `dxgkrnl.sys` and `nvlddmkm.sys` observe a coherent 384-byte EDID without consulting stale unpatched blocks.

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

Specifically, three primary override binary values (along with `SmoothScalingData` / `UpScalingData` caches) are created:
1. `ColorformatConfig` (`REG_BINARY`)
2. `VideoInfoframeOverride` (`REG_BINARY`)
3. `ScalingConfig` (`REG_BINARY`, e.g., `DB 02 00 00 10 00 00 00 00 01 00 00 EE 00 00 00`)

**Critical Bug / Behavior**: Clicking **"Restore Defaults"** in the NVIDIA Control Panel does **not** delete these registry values. Instead, it overwrites them with another explicit override structure. Having `VideoInfoframeOverride`, `ColorformatConfig`, or custom `ScalingConfig` values present causes `nvlddmkm.sys` to forcibly inject custom AVI/Vendor InfoFrames and timing overrides during every mode switch, which severely aggravates HDMI 2.1 link dropouts on the Odyssey G70D.

### 3.2 Why Stopping `NVDisplay.ContainerLocalSystem` + `pnputil /disable-device` Is Mandatory
If you delete `DisplayDatabase` values while `nvlddmkm.sys` or the **`NVDisplay.ContainerLocalSystem`** (`NVDisplay.Container.exe`) user-mode service is active:
1. `nvlddmkm.sys` holds the active `DisplayDatabase` state in kernel non-paged pool memory and flushes it back on driver reload.
2. Even when the GPU is disabled via `pnputil`, a running `NVDisplay.ContainerLocalSystem` service immediately re-writes cached `ScalingConfig` values (within seconds of `pnputil /enable-device`) and can replicate stale settings from **`NOEDID_*`** or ghost **`SAME068*`** profiles.

To purge them cleanly without running DDU (Display Driver Uninstaller):
1. Stop **`NVDisplay.ContainerLocalSystem`** first, then unload `nvlddmkm.sys` by disabling the GPU device via `pnputil /disable-device "<GPU_Instance_ID>"`.
2. Delete stale ghost monitor subkeys (`SAME068*`) from both `DisplayDatabase` and `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\MonitorDataStore`, and remove scaling/override binaries across **all** remaining profiles (including `SAME069*` and `NOEDID_*`).
3. Re-enable the GPU via `pnputil /enable-device "<GPU_Instance_ID>"` and restart **`NVDisplay.ContainerLocalSystem`**. (Note: `nvlddmkm` may recreate a benign driver-default 16-byte `ScalingConfig` marker `DB 02 00 00 10 00 00 00 00 01 00 00 EE 00 00 00` on re-initialization, which is normal once `ColorformatConfig`, `VideoInfoframeOverride`, and stale ghost profiles are gone.)

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

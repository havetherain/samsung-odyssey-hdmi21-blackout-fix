# Samsung Odyssey G7 (`S32DG700` / `G70D`) HDMI 2.1 Black Screen / Flickering Fix

[![Korean Guide](https://img.shields.io/badge/Language-한국어_가이드_(README.ko.md)-blue?style=for-the-badge)](./README.ko.md)
[![Technical Deep Dive](https://img.shields.io/badge/Docs-Technical_Deep_Dive-informational?style=for-the-badge)](./docs/technical-deep-dive.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](./LICENSE)

> **Case Study & Automated PowerShell Workaround** for intermittent **1 - 2s HDMI 2.1 blackouts (video signal dropouts)** on the **Samsung Odyssey G7 (`S32DG700` / `G70D`, 4K 144Hz, Tizen OS)** connected to an **NVIDIA GeForce RTX 5070 Ti** (and RTX 40 / 50 series GPUs).

---

## ⚠️ Disclaimer & Limitations (Read First)

> [!IMPORTANT]
> **This repository is a Case Study & Workaround—NOT an official or universal silver-bullet fix for every HDMI 2.1 black screen issue.**
>
> - **When This Workaround Applies:**
>   Your monitor works completely fine right after a **cold boot** (desktop browsing, YouTube, or certain games like *GTA 5* never flicker), **but** once an **HDMI signal re-synchronization (mode switch / handshake trigger)** occurs—such as launching *EA Sports FC 25*, toggling Windows HDR, or changing color/scaling settings in the NVIDIA Control Panel—the screen begins intermittently blacking out for **1 - 2 seconds** and continues to flicker even after returning to the Windows desktop until you reboot the PC.
> - **When This Workaround Will NOT Help (Exclusions & Hardware Limits):**
>   - Constant "No Signal" or immediate flickering right from boot caused by a **faulty physical HDMI cable**, **GPU HDMI port solder defect**, or **monitor mainboard/scaler hardware defect**.
>   - Specialized workflows that strictly require **uncompressed 48 Gbps (FRL 6)** bandwidth without DSC.
> - **100% Reversible at Any Time:**
>   `Fix-HDMI21-Blackout.ps1` automatically backs up your Registry (`backups/*.reg`) and raw EDID (`backups/*.bin`) before making any changes. You can run **`scripts/Revert-To-Stock.ps1`** at any time to immediately delete the `EDID_OVERRIDE` and restore 100% stock monitor behavior.

---

## 1. System Environment & Symptom Pattern

### 1.1 Hardware & Environment
| Component | Specification |
| :--- | :--- |
| **CPU** | AMD Ryzen 7 9800X3D (iGPU Disabled in BIOS) |
| **Motherboard** | ASUS B850M MAX GAMING WIFI |
| **RAM** | DDR5 32GB @ 4800MHz |
| **GPU** | NVIDIA GeForce RTX 5070 Ti |
| **Monitor** | Samsung Odyssey G7 `S32DG700` (`G70D`, 4K 3840x2160 @ 144Hz, Tizen OS) |
| **Cable** | HDMI 2.1 Ultra High Speed Cable (48Gbps) |

### 1.2 Symptom Characteristics
- **Signal Dropout Only (Not Power Loss):** The monitor does not power off. Only the video signal from the PC to the monitor drops for **1 - 2 seconds** and recovers. System audio, Discord, and keyboard/mouse inputs remain completely normal, and Windows Event Viewer shows **0 `nvlddmkm` crash/TDR logs**.
- **The Decisive Trigger Pattern:**
  - **Cold Boot State:** Zero blackouts during normal desktop work, YouTube playback, or playing *GTA 5*.
  - **Post-Trigger State:** Performing **any action that forces HDMI signal re-negotiation (mode switch / handshake)**—such as launching *EA Sports FC 25*, turning on Windows HDR, or touching NVIDIA Control Panel color or scaling settings—even once causes continuous intermittent blackouts that persist on the desktop even after closing the game, until the system is rebooted.

---

## 2. What Did NOT Work (Failed Attempts & Backfires)

Many commonly suggested online "fixes" either had zero effect or actively made the blackouts drastically worse:

| Attempted Method | Actual Result |
| :--- | :--- |
| **Disabling Windows HAGS (`HwSchMode = 1`) & Disabling MPO (`OverlayTestMode = 5`)** | ❌ **Backfired severely:** Blackout frequency increased dramatically. Immediately reverted both keys back to Windows stock defaults. |
| **Changing NVIDIA Control Panel Color Settings (`8bpc`, `YCbCr422`, `Content type reported to the display`) & Enabling `GPU Scaling Override`** | ❌ **Backfired & polluted Registry:** Every single change immediately made the flickering much worse and left behind **undeletable zombie binary keys** (`ColorformatConfig`, `VideoInfoframeOverride`, `ScalingConfig`) in the `nvlddmkm` Registry database. |
| **Lowering Refresh Rate to 120Hz, Disabling G-SYNC / VRR, or Locking BIOS PCIe to Gen 4** | ❌ **Did not solve:** Once a mode-switch handshake was triggered, the 1 - 2s signal dropouts still occurred. |

---

## 3. The 3 Core Fixes That Solved the Issue

### Fix 1: EDID HDMI 2.1 HF-VSDB Patch (`48Gbps FRL 6 -> 40Gbps FRL 5` & `ALLM Off`)
In the monitor's (`MONITOR\SAME069`, HDMI VRR mode) 384-byte stock EDID, **Block 1 (CTA-861 Extension Block, Bytes 128 - 255)** contains the **HDMI Forum Vendor-Specific Data Block (HF-VSDB, IEEE OUI `C4-5D-D8`, little-endian `D8 5D C4`)** at local offset **Byte 54 - 67**:

- **Stock HF-VSDB Bytes (Checksum `0xE4`):**
  ```text
  6D D8 5D C4 01 78 80 6B 02 30 90 C3 64 0B
  ```
  - **Byte 7 (`0x6B`):** Upper 4 bits `Max_FRL_Rate = 6` (**48 Gbps** = 12 Gbps x 4 lanes)
  - **Byte 8 (`0x02`):** Bit 1 `ALLM = 1` (**Auto Low Latency Mode** enabled)
  - **Byte 9 - 10 (`30 90`):** `VRRmin = 48Hz`, `VRRmax = 144Hz`
  - **Byte 11 (`0xC3`):** `DSC_1p2 = 1`, `DSC_Native_420 = 1`, `DSC_Max_Slices = 3` (Up to 4 slices)
  - **Byte 12 (`0x64`):** Upper 4 bits `DSC_Max_FRL_Rate = 6` (**48 Gbps** = 12 Gbps x 4 lanes)

- **Root Cause:**
  At **4K 144Hz 10bpc RGB**, DSC 1.2 visually lossless compression only uses **15 - 18 Gbps** of actual bandwidth. Yet the monitor's stock EDID demands the maximum **48 Gbps (12 Gbps/lane)** clock and **ALLM**. When launching a game or switching modes triggers an ALLM toggle or link re-negotiation, 12 Gbps/lane FRL link training accumulates bit errors and falls into an unstable synchronization state (**Marginal Lock**).

- **Solution (`EDID_OVERRIDE` Registration):**
  Patch the HF-VSDB bytes to **`6D D8 5D C4 01 78 80 5B 00 30 90 C3 54 0B`** (Block 1 Checksum recalculated to **`0x06`**):
  - **Byte 7:** `0x6B -> 0x5B` (`Max_FRL_Rate = 5`, **40 Gbps** = 10 Gbps x 4 lanes)
  - **Byte 8:** `0x02 -> 0x00` (`ALLM = 0`, blocks Auto Low Latency Mode handshake triggers)
  - **Byte 12:** `0x64 -> 0x54` (`DSC_Max_FRL_Rate = 5`, **40 Gbps** = 10 Gbps x 4 lanes)
  - Recalculate the Block 1 checksum at Index 127 (`(256 - (sum % 256)) % 256`) and save the 128-byte Block 1 to `HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\<MonitorID>\<InstanceID>\Device Parameters\EDID_OVERRIDE` value `"1"` (`REG_BINARY`).
  - **Full 4K 144Hz 10bpc RGB + VRR (48 - 144Hz) is 100% preserved without any visual loss.**

### Fix 2: Permanently Purging Zombie Overrides in NVIDIA `DisplayDatabase`
- Touching Color Format, Content Type, or GPU Scaling in the NVIDIA Control Panel even once leaves persistent binary values—**`ColorformatConfig`**, **`VideoInfoframeOverride`**, and **`ScalingConfig`**—inside `HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\State\DisplayDatabase\<MonitorProfile>`, even after clicking "Restore Defaults".
- If you delete these keys while the NVIDIA driver is running, `nvlddmkm.sys` simply overwrites the Registry with its in-memory cache when shutting down.
- **Solution:** Temporarily disable the GPU via **`pnputil /disable-device`**, delete `ColorformatConfig`, `VideoInfoframeOverride`, and `ScalingConfig` while the driver is unloaded from memory, and re-enable the GPU via **`pnputil /enable-device`**.

### Fix 3: Official Samsung Monitor Driver (`S32DG70xE.inf`) & Auxiliary Setup
1. **Official Samsung Monitor Driver Matching:**
   - Replace Windows default `Generic PnP Monitor` (`MaxResolution = 1600,1200`) with Samsung's official **`G70D_S32DG70xE (HDMI VRR)`** driver (`MONITOR\SAME069`, `MaxResolution = 3840,2160`, `MODES\3840,2160 = 30-255,30-144,+,+`, `ICMProfile = S32DG70xE.icm`) and remove any hidden **Ghost monitor** devices in Device Manager (`View -> Show hidden devices`).
2. **Monitor Tizen OS Settings:**
   - Turn **OFF `Anynet+ (HDMI-CEC)`** in the monitor's Tizen settings, lock the HDMI input device icon to **`PC`**, and perform a **cold power reset** (unplug the monitor power cord and plug it back in).
3. **`EA Sports FC 25` Launch Resolution Stabilization (`%LOCALAPPDATA%\EA Sports FC 25\fcsetup.ini`):**
   - Prevent FC 25 from initializing at `1280x720` and shaking the HDMI link on startup:
     ```ini
     WINDOWED_WIDTH = 3840
     WINDOWED_HEIGHT = 2160
     FULLSCREEN = 0
     WINDOWED_BORDERLESS = 1
     REFRESH_RATE = 144
     DYNAMIC_RESOLUTION = 0
     HDR = 0
     ```

---

## 4. How to Use the Automated PowerShell Scripts

### Step 1: Diagnose Current State (Read-Only, No Admin Required)
Inspect your active monitor hardware ID, driver INF matching, stock vs. override HF-VSDB bitfields, and NVIDIA `DisplayDatabase` zombie keys without modifying anything:
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Diagnose-MonitorLink.ps1
```

### Step 2: Apply the Fix (Run PowerShell as Administrator)
Automatically backs up your Registry (`backups/`), patches the HF-VSDB to **40 Gbps (FRL 5) + ALLM Off** with recalculated Block 1 checksum, and unloads/reloads the NVIDIA GPU via `pnputil` to permanently purge `DisplayDatabase` zombie overrides:
```powershell
# Optional: Preview exact byte changes first without modifying the system
powershell -ExecutionPolicy Bypass -File .\scripts\Fix-HDMI21-Blackout.ps1 -DryRun

# Apply the fix (Requires Administrator privileges; screen will briefly blink for 2 - 4 seconds)
powershell -ExecutionPolicy Bypass -File .\scripts\Fix-HDMI21-Blackout.ps1
```
After running `Fix-HDMI21-Blackout.ps1`, **reboot your PC once** so Windows and `nvlddmkm` initialize cleanly from cold boot with the patched EDID.

### Step 3: Revert to Stock at Any Time (Run PowerShell as Administrator)
If this workaround does not resolve your issue or you wish to return to factory stock settings immediately:
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Revert-To-Stock.ps1
```

---

## 5. Repository Structure

```text
samsung-odyssey-hdmi21-blackout-fix/
├── backups/                        # Auto-generated .reg and .bin backups (ignored by git)
├── docs/
│   └── technical-deep-dive.md      # Byte-level HF-VSDB table & nvlddmkm kernel persistence analysis
├── scripts/
│   ├── Diagnose-MonitorLink.ps1    # Read-only EDID HF-VSDB parser & DisplayDatabase diagnostic tool
│   ├── Fix-HDMI21-Blackout.ps1     # Automated backup + 40Gbps/ALLM EDID_OVERRIDE + pnputil nvlddmkm cleanup
│   └── Revert-To-Stock.ps1         # Instant removal of EDID_OVERRIDE and driver reload to stock state
├── LICENSE                         # MIT License
├── README.md                       # English Guide (Main)
└── README.ko.md                    # Korean Guide (한국어 상세 가이드)
```

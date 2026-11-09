# 삼성 오디세이 G7 (`S32DG700` / `G70D`) HDMI 2.1 간헐적 화면 꺼짐(블랙아웃/깜빡임) 해결 가이드

[![Latest Release](https://img.shields.io/github/v/release/havetherain/samsung-odyssey-hdmi21-blackout-fix?label=ZIP%20다운로드%20(Releases)&style=for-the-badge&color=blueviolet)](https://github.com/havetherain/samsung-odyssey-hdmi21-blackout-fix/releases/latest)
[![English Guide](https://img.shields.io/badge/Language-English_Guide_(README.md)-blue?style=for-the-badge)](./README.md)
[![Technical Deep Dive](https://img.shields.io/badge/Docs-Technical_Deep_Dive-informational?style=for-the-badge)](./docs/technical-deep-dive.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](./LICENSE)

> **삼성 오디세이 G7 (`S32DG700` / `G70D`, 4K 144Hz, 타이젠 OS)** 모니터와 **NVIDIA GeForce RTX 5070 Ti**를 HDMI 2.1로 연결했을 때 발생하던 **간헐적 1 - 2초 화면 꺼짐(블랙아웃/신호 끊김)** 현상을 실제로 해결한 과정과 자동화 PowerShell 스크립트를 공유하는 리포지토리입니다.

---

## 🚀 빠른 시작 (Git 설치 불필요! ZIP 다운로드)

복잡한 Git 명령어(`git clone`)를 사용할 필요가 없습니다:
1. **[GitHub Releases 최신 버전](https://github.com/havetherain/samsung-odyssey-hdmi21-blackout-fix/releases/latest)** 페이지에서 **`samsung-odyssey-hdmi21-blackout-fix-vX.X.X.zip`** 파일을 다운로드합니다.
2. 원하는 폴더에 압축을 풉니다.
3. 마우스 더블 클릭으로 바로 실행할 수 있는 원클릭 실행 파일(`.bat`)을 제공합니다:
   - **`1-Diagnose.bat`**: 현재 모니터 및 드라이버 링크 상태 읽기 전용 진단 (시스템 변경 없음)
   - **`2-Apply-Fix.bat`**: 관리자 권한을 자동으로 요청하며, 레지스트리 백업 -> 40Gbps FRL 5 + ALLM Off 패치 -> NVIDIA `DisplayDatabase` 좀비 키 클린업을 자동으로 실행합니다 (드라이버 재시작으로 화면이 2 - 4초간 깜빡입니다).
   - **`3-Revert-To-Stock.bat`**: 언제든 `EDID_OVERRIDE`를 삭제하고 공장 출고 순정 상태로 즉시 원복합니다.
4. `2-Apply-Fix.bat` 실행 완료 후 **PC를 1회 재부팅**합니다.

---

## ⚠️ 주의 및 한계점 안내 (Disclaimer & Limitations - 필독)

> [!IMPORTANT]
> **본 가이드는 모든 사람의 모니터 깜빡임 및 HDMI 2.1 블랙아웃 현상을 고치는 공식/만능 해결책이 아닙니다.**
>
> - **적용 대상 조건 (Case Study & Workaround):**
>   본 방법은 **"콜드 부팅 직후에는 바탕화면, 유튜브, 일반 게임 등에서 전혀 깜빡이지 않고 정상 작동하다가, 특정 모드 전환/신호 재협상(핸드셰이크) 트리거(예: EA Sports FC 25 실행, Windows HDR 켜기/끄기, NVIDIA 제어판 컬러/스케일링 설정 변경 등)가 한 번이라도 발생한 이후부터 재부팅 전까지 계속 간헐적으로 1 - 2초씩 깜빡이는 특정 증상"**에서 실제로 원인을 규명하고 해결한 사례입니다.
> - **제외 및 한계 조건:**
>   - 부팅 직후부터 상시 신호가 잡히지 않거나 즉시 깜빡이는 **물리적 HDMI 케이블 불량**, **그래픽카드 포트 납땜 불량**, **모니터 메인보드/스케일러 하드웨어 결함**은 소프트웨어 패치로 해결되지 않습니다.
>   - DSC 압축 없이 **48Gbps 무압축 강제 모드**가 반드시 필요한 특수 작업 환경에는 적합하지 않을 수 있습니다.
> - **언제든 100% 순정 복구 가능:**
>   `Fix-HDMI21-Blackout.ps1` 실행 시 수정 전 레지스트리(`backups/*.reg`)와 원본 EDID 바이너리(`backups/*.bin`)를 자동으로 백업하며, 언제든 **`scripts/Revert-To-Stock.ps1`**를 실행하면 즉시 `EDID_OVERRIDE`를 제거하고 순정 상태로 원복할 수 있습니다.

---

## 1. 시스템 환경 및 증상 발생 패턴

### 1.1 테스트 시스템 사양
| 구성 요소 | 상세 사양 |
| :--- | :--- |
| **CPU** | AMD Ryzen 7 9800X3D (BIOS 내장그래픽 iGPU Disabled) |
| **메인보드** | ASUS B850M MAX GAMING WIFI |
| **메모리** | DDR5 32GB @ 4800MHz |
| **그래픽카드** | NVIDIA GeForce RTX 5070 Ti |
| **모니터** | 삼성 오디세이 G7 `S32DG700` (`G70D`, 4K 3840x2160 @ 144Hz, 타이젠 OS 탑재) |
| **케이블** | HDMI 2.1 Ultra High Speed 48Gbps 케이블 |

### 1.2 증상 특징 및 결정적 발생 패턴
- **전원 꺼짐이 아닌 영상 신호 재동기화 현상:** 모니터 전원이 꺼지는 것이 아니라, PC에서 모니터로 가는 영상 신호만 **1 - 2초간 끊겼다 다시 켜지는 현상**입니다. 화면이 꺼진 동안에도 사운드 출력, 키보드/마우스 입력은 모두 정상이며, Windows 이벤트 뷰어 상 `nvlddmkm` 드라이버 크래시/TDR 로그는 **0건**입니다.
- **결정적 발생 패턴:**
  - **콜드 부팅 직후:** 바탕화면 작업, 유튜브 시청, *GTA 5* 플레이 시에는 몇 시간을 사용해도 **단 한 번도 깜빡이지 않음**.
  - **트리거 발생 이후:** **화면 신호 재동기화(모드 전환 / 핸드셰이크)를 유발하는 동작**(예: *EA Sports FC 25* 실행, Windows HDR 켜기, NVIDIA 제어판에서 컬러 설정 또는 스케일링 설정 변경)을 한 번이라도 수행하면, 그때부터 **게임을 종료하고 바탕화면으로 나와도 재부팅하기 전까지 계속 간헐적으로 1 - 2초씩 블랙아웃이 반복됨**.

---

## 2. 실패했거나 오히려 역효과가 났던 방법들 (What Did NOT Work)

인터넷과 커뮤니티에서 흔히 권장되는 아래 방법들은 효과가 없었거나, 오히려 증상을 극도로 악화시켰습니다:

| 시도했던 방법 | 실제 결과 |
| :--- | :--- |
| **Windows 레지스트리 HAGS 끄기(`HwSchMode = 1`) 및 MPO 비활성화(`OverlayTestMode = 5`)** | ❌ **심각한 역효과:** 적용 직후 깜빡임 빈도가 극도로 심해져서 즉시 순정 상태로 복구함. |
| **NVIDIA 제어판 컬러 설정 변경(`8bpc`, `YCbCr422`, `디스플레이에 보고되는 콘텐츠 유형`) 및 `GPU 스케일링 오버라이드` 켜기** | ❌ **역효과 및 좀비 레지스트리 생성:** 설정을 바꿀 때마다 즉시 깜빡임이 훨씬 심해졌으며, 이후 '기본값 복원'을 눌러도 레지스트리(`nvlddmkm\State\DisplayDatabase`)에 지워지지 않는 좀비 설정값(`ColorformatConfig`, `VideoInfoframeOverride`, `ScalingConfig`)을 남김. |
| **단순 주사율 120Hz 낮추기, G-SYNC/VRR 끄기, BIOS PCIe Gen 4 고정** | ❌ **해결 안 됨:** 모드 전환 트리거 이후 발생하는 1 - 2초 블랙아웃 현상이 동일하게 재발함. |

---

## 3. 실제로 문제를 해결한 3가지 핵심 조치

### 조치 1: EDID 내 HDMI 2.1 HF-VSDB 패치 (`48Gbps FRL 6 -> 40Gbps FRL 5` 안정화 및 `ALLM 차단`)
모니터(`MONITOR\SAME069`, HDMI VRR 모드)의 순정 EDID(384바이트) 중 **Block 1(CTA-861 확장 블록, Byte 128 - 255)**의 로컬 오프셋 **Byte 54 - 67**에 위치한 **HDMI Forum VSDB(IEEE OUI `C4-5D-D8`, 리틀 엔디안 `D8 5D C4`)** 원본 바이트는 다음과 같습니다:

- **순정 HF-VSDB 원본 바이트 (Block 1 체크섬 `0xE4`):**
  ```text
  6D D8 5D C4 01 78 80 6B 02 30 90 C3 64 0B
  ```
  - **Byte 7 (`0x6B`):** 상위 4비트 `Max_FRL_Rate = 6` (**48Gbps** = 12Gbps x 4 lanes)
  - **Byte 8 (`0x02`):** Bit 1 `ALLM = 1` (**Auto Low Latency Mode** 자동 저지연 모드 켜짐)
  - **Byte 9 - 10 (`30 90`):** `VRRmin = 48Hz`, `VRRmax = 144Hz`
  - **Byte 11 (`0xC3`):** `DSC_1p2 = 1`, `DSC_Native_420 = 1`, `DSC_Max_Slices = 3` (최대 4 슬라이스)
  - **Byte 12 (`0x64`):** 상위 4비트 `DSC_Max_FRL_Rate = 6` (**48Gbps** = 12Gbps x 4 lanes)

- **원인 분석:**
  **4K 144Hz 10bpc RGB**는 DSC 1.2 압축 시 실제로 약 **15 - 18Gbps**의 대역폭만 사용함에도, 모니터 순정 EDID가 최고 클럭인 **48Gbps(12Gbps/lane)**와 **ALLM**을 요구합니다. 게임 실행 등으로 ALLM 신호나 모드 재협상이 일어날 때 12Gbps/lane 링크 트레이닝에서 에러가 누적되어 불안정한 동기화(**Marginal Lock**) 상태에 빠지게 됩니다.

- **해결 방법 (`EDID_OVERRIDE` 등록):**
  HF-VSDB 바이트를 **`6D D8 5D C4 01 78 80 5B 00 30 90 C3 54 0B`**(Block 1 체크섬 **`0x06`**)로 수정합니다:
  - **Byte 7:** `0x6B -> 0x5B` (`Max_FRL_Rate = 5`, **40Gbps** = 10Gbps x 4 lanes)
  - **Byte 8:** `0x02 -> 0x00` (`ALLM = 0`, 자동 저지연 모드 신호 차단)
  - **Byte 12:** `0x64 -> 0x54` (`DSC_Max_FRL_Rate = 5`, **40Gbps** = 10Gbps x 4 lanes)
  - Block 1의 마지막 바이트(Index 127) 체크섬(`(256 - (합계 % 256)) % 256`)을 재계산하여 `HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\<모니터ID>\<인스턴스ID>\Device Parameters\EDID_OVERRIDE`의 `"1"`(`REG_BINARY`)에 저장합니다.
  - **결과:** **4K 144Hz 10bpc RGB 무손실 화질 및 VRR(48 - 144Hz)이 100% 그대로 유지**되면서 12Gbps/lane 오버클럭성 링크 트레이닝 에러와 ALLM 재협상 트리거가 원천 차단됩니다.

### 조치 2: NVIDIA 드라이버 내부 `DisplayDatabase`의 좀비 오버라이드 데이터 영구 삭제
- NVIDIA 제어판에서 컬러 설정, 콘텐츠 유형, 스케일링을 한 번이라도 건드리면 이후 '기본값'으로 돌려놓아도 `HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\State\DisplayDatabase\<모니터프로필>`에 **`ColorformatConfig`**, **`VideoInfoframeOverride`**, **`ScalingConfig`** 바이너리가 지워지지 않고 남아 모드 전환 시마다 깜빡임을 유발합니다.
- 드라이버가 켜져 있을 때 레지스트리에서 지우면 드라이버 종료/재부팅 시 커널 메모리 캐시가 다시 레지스트리에 덮어써지므로, 반드시 **`pnputil /disable-device`로 GPU를 잠시 비활성화한 상태에서 해당 레지스트리 값들을 삭제하고 `pnputil /enable-device`로 다시 켜서** 영구 삭제해야 합니다.

### 조치 3: 삼성 공식 모니터 드라이버(`S32DG70xE.inf`) 정식 매칭 및 부가 설정
1. **삼성 공식 모니터 드라이버 설치 및 유령(Ghost) 장치 제거:**
   - Windows 기본 `Generic PnP Monitor`(`MaxResolution = 1600,1200`) 대신 삼성 공식 **`G70D_S32DG70xE (HDMI VRR)`** 드라이버(`MONITOR\SAME069`, `MaxResolution = 3840,2160`, `MODES\3840,2160 = 30-255,30-144,+,+`, `ICMProfile = S32DG70xE.icm`)를 설치하고, 장치 관리자(`보기 -> 숨겨진 장치 표시`)에서 비활성 유령(Ghost) 모니터 장치를 모두 제거합니다.
2. **모니터 타이젠(Tizen) OS 설정 및 콜드 리셋:**
   - 모니터 내장 타이젠 OS 설정에서 **`Anynet+ (HDMI-CEC)`를 끄기(Off)**로 설정하고, 입력 기기 아이콘을 **`PC`로 고정**한 뒤 모니터 전원선을 뽑았다 다시 꽂아 콜드 리셋을 수행합니다.
3. **`EA Sports FC 25` 초기 실행 해상도 고정 (`%LOCALAPPDATA%\EA Sports FC 25\fcsetup.ini`):**
   - FC 25 실행 시 초기 창 크기(`1280x720`)로 인해 HDMI 해상도 핸드셰이크가 흔들리지 않도록 아래와 같이 바탕화면 네이티브 해상도와 일치시킵니다:
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

## 4. 자동화 PowerShell 스크립트 사용법

### 1단계: 현재 모니터 및 레지스트리 상태 진단 (읽기 전용 / 관리자 권한 불필요)
시스템을 전혀 수정하지 않고 현재 모니터 하드웨어 ID, 드라이버 매칭 상태, EDID 내 HF-VSDB(`D8 5D C4`)의 FRL/ALLM/DSC 설정값 및 NVIDIA `DisplayDatabase` 좀비 키 존재 여부를 확인합니다:
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Diagnose-MonitorLink.ps1
```

### 2단계: 패치 및 클린업 자동 적용 (PowerShell 관리자 권한 실행 필수)
레지스트리 및 원본 EDID를 `backups/` 폴더에 자동 백업한 뒤, EDID 내 HF-VSDB를 동적으로 찾아 **40Gbps(FRL 5) + ALLM Off 패치 및 체크섬 재계산**을 수행하고, `pnputil`로 GPU를 잠시 언로드하여 NVIDIA `DisplayDatabase` 좀비 키를 영구 삭제합니다:
```powershell
# (선택) 실제 수정 전 바이트 변경 내역만 안전하게 미리보기
powershell -ExecutionPolicy Bypass -File .\scripts\Fix-HDMI21-Blackout.ps1 -DryRun

# 실제 패치 적용 (관리자 권한 필요 / GPU 드라이버 재시작 중 2 - 4초간 화면이 깜빡입니다)
powershell -ExecutionPolicy Bypass -File .\scripts\Fix-HDMI21-Blackout.ps1
```
스크립트 실행이 완료되면 **PC를 1회 재부팅**하여 콜드 부팅 상태에서 패치된 EDID로 링크가 고정되도록 합니다.

### 3단계: 순정 상태로 즉시 원복하기 (PowerShell 관리자 권한 실행)
언제든 패치를 제거하고 공장 출고 순정 상태(48Gbps FRL 6 + ALLM On)로 되돌리고 싶다면 아래 명령어를 실행하세요:
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Revert-To-Stock.ps1
```

---

## 5. 리포지토리 구조

```text
samsung-odyssey-hdmi21-blackout-fix/
├── backups/                        # 스크립트 실행 시 자동 생성되는 레지스트리(.reg) 및 EDID(.bin) 백업 폴더
├── docs/
│   └── technical-deep-dive.md      # EDID HF-VSDB 바이트 구조 비교표 및 nvlddmkm DisplayDatabase 심층 분석 문서
├── scripts/
│   ├── Diagnose-MonitorLink.ps1    # 읽기 전용 EDID HF-VSDB 파서 및 DisplayDatabase 좀비 키 진단 스크립트
│   ├── Fix-HDMI21-Blackout.ps1     # 자동 백업 + 40Gbps/ALLM EDID_OVERRIDE 등록 + pnputil DisplayDatabase 클린업
│   └── Revert-To-Stock.ps1         # EDID_OVERRIDE 즉시 삭제 및 드라이버 재시작 순정 복구 스크립트
├── LICENSE                         # MIT 라이선스
├── README.md                       # 영문 메인 가이드 (English Guide)
└── README.ko.md                    # 한국어 상세 가이드 (Korean Guide)
```

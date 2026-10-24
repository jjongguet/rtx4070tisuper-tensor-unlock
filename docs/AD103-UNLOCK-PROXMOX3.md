# AD103 텐서 언락 — Proxmox 호스트 적용과 A/B 검증

2026-10-25 작업 기록. **RTX 4070 Ti SUPER(AD103, `10de:2705`)의 텐서 게이트를 Proxmox VE 9 호스트에서 해제하고, 잠금/해제 상태를 같은 카드에서 실측 비교해 2.00× 를 확인**한 과정이다.

이 문서는 결과 자랑이 아니라 **어디서 막혔고 무엇이 그것을 풀었는지**를 다음 사람이 같은 순서로 재현할 수 있게 남기는 것이 목적이다. 각 병목 절은 `증상 → 원인 → 근거 → 조치` 순서다.

---

## 1. 결과

동일 카드 · 동일 커널(`6.17.2-1-pve`) · 동일 드라이버(`615.71.09`) · SM 클럭 `2610 MHz` 고정 · raw PTX `mma` 마이크로벤치.

| 경로 | 잠금 | 해제 | 배율 | 게이트 여부 |
|---|---:|---:|---:|---|
| FP16 → FP32 누산 | 88.08 | **175.87** | **2.00×** | 게이트 |
| BF16 → FP32 누산 | 88.09 | **176.13** | **2.00×** | 게이트 |
| TF32 → FP32 누산 | 44.04 | **88.13** | **2.00×** | 게이트 |
| FP8(E4M3) → FP32 누산 | 176.07 | **352.42** | **2.00×** | 게이트 |
| FP16 → FP16 누산 | 175.87 | 176.10 | 1.00× | 무관 (제어군) |
| FFMA (스칼라 FP32) | 10.66 | 10.69 | 1.00× | 무관 (제어군) |

단위 TFLOPS. 해제 상태 실측이 이론 피크에 99.9%로 붙는다 (§7 참조).

**재부팅 후 자동 적용 확인** — `gpu_unlock` 이 initramfs 대신 `modules-load.d` 로 nvidia 앞에 로드되고, 드라이버 바인딩 전에 게이트를 연다.

```
04:14:11  FWSEC result: scratch=0x0 expected_hi16=0
04:14:11  FWSEC WPR2: low=0x3ff6000 high=0x3ff6e00 expected_page=0x3ff600
04:14:11  AD103 boot result: marker=0x67b00001 expected=0x67b00001
04:14:11  selector write: SS0=0x88888888
04:14:11  selector write: SS1=0x8
04:14:12  gpu_unlock: unlocked
```

---

## 2. 대상 환경

| 항목 | 값 |
|---|---|
| 호스트 | proxmox3 (`vibecompany3`), PVE 9.1.1 |
| 커널 | `6.17.2-1-pve` |
| GPU | GIGABYTE `GV-N407TSWF3OC-16GD/F2/105B`, VBIOS `95.03.45.40.4B` |
| PCI | `0000:01:00.0` (`10de:2705`), `0000:01:00.1` (`10de:22bb`, 오디오) |
| 드라이버 | NVIDIA `615.71.09` (.run, DKMS) |
| CUDA | 툴킷 `13.4` (`cuda-nvcc-13-4`), 런타임 `13.4` |
| 게스트 | vm1 (VM 200, k3s) — 이 작업과 무관, 호스트 GPU 미사용 |

**호스트가 이 작업에 유리한 이유:** Proxmox 호스트에는 OS GPU 드라이버가 상시 바인딩되지 않는다. 모듈이 카드를 콜드 상태로 잡을 창이 넓고, 실패해도 데스크톱이 죽지 않는다.

---

## 3. 게이트의 정체

NVIDIA가 일부 GeForce 카드에 넣은 **텐서 코어 누산 경로 게이트**다. FP16/BF16 입력에 **FP32 누산**을 쓰는 경로만 절반 속도로 제한한다. FP16 누산, FFMA는 영향 없다.

해제 여부는 세 개의 레지스터로 판정한다.

| 레지스터 | 주소 | 잠금 | 해제 |
|---|---|---|---|
| `FEAT_PLM` | `0x00823804` | `0xffffff8f` | `0xffffffff` |
| `FEAT_SS0` | `0x0082381c` | `0x41152044` (칩별 상이) | `0x88888888` |
| `FEAT_SS1` | `0x00823820` | `0x00000007` | `0x00000008` |

`FEAT_SS0` 의 잠금 값은 칩마다 다르다(GA102 `0x45576045`, AD103 `0x41152044`/`0x41552044`). **해제 목표값 `0x88888888` 과 `SS1=0x8` 은 공통**이다.

세 레지스터는 GPU에 남는 값이 아니라 **매 콜드 부팅마다 다시 설정된다.** 그래서 "한 번 열고 끝"이 아니라 **부팅 시점에 드라이버보다 먼저 여는** 구조가 필요하다.

---

## 4. 경로 선택 — 왜 커널 모듈인가

| 후보 | 방식 | 판정 |
|---|---|---|
| UEFI DXE 드라이버 | 부팅 DXE 단계에서 VBIOS/PLM 조작 | **탈락** — 카드/보드마다 EFI 빌드·서명 필요, 매 부팅 개입 |
| 커널 모듈 (선택) | initramfs/모듈 로드 단계에서 카드 레지스터 직접 조작 | **채택** — 드라이버보다 먼저, 사용자 개입 없음 |
| 드라이버 패치 | nvidia 드라이버 바이너리 수정 | **탈락** — 드라이버 업데이트마다 재작업 |

채택한 구현은 [`Zagitta/gpu-unlock`](https://github.com/Zagitta/gpu-unlock) 이다. 원저자 설명대로 **CMP 언락커의 V67/PLM 기법**과 **UEFI 방식의 사전 타이밍**을 합친 구조다.

> "combines the CMP unlocker's V67/PLM technique with the pre-driver timing of the UEFI approach"
> — Zagitta/gpu-unlock README

업스트림 `main` 의 지원 칩은 GA102/GA103/GA104/GA106 뿐이다. AD103 은 별도 작업이 필요했다 (§5.4).

---

## 5. 병목과 해결

### 5.1 VBIOS 파싱 — `pci_map_rom` 은 VBIOS 전체가 아니다

**증상.** `pci_map_rom` 으로 덤프한 VBIOS 가 `150,528 B` 에서 잘렸다. 그 안에서 FWSEC 서명/기하를 찾으면 실패한다.

**원인.** `pci_map_rom` 은 PCI **last-image flag** 에서 멈춘다. VN(extension) 영역이 그 뒤에 있고, 실제 VBIOS 는 **BAR0 + `0x300000` (`NV_PROM_DATA`)** 에서 최대 1 MiB 까지 읽어야 한다.

**근거.** Zagitta 코드 주석이 같은 현상을 명시한다.

> "pci_map_rom stops at the PCI last-image flag and hides the VN extension"

**조치.** BAR0 `0x300000` 에서 1 MiB 직접 mmap 리드. 실제 내용은 `0x9a200`(631,296 B)에서 끝나고, 6개의 NPDE 구조(`0x190`, `0xf284`, `0xfc40`, `0x24d80`, `0x2ac40`, `0x337ae`)가 나온다. 이 경로의 VBIOS 전문에서 FWSEC 디스크립터가 `0x4581c` 에서 발견된다.

```
FWSEC descriptor: offset=0x4581c ROM_bytes=1048576 header=0x32c0301
FWSEC geometry:  image_off=0x45b48 size=0x10500 imem=0xf700 dmem=0xd80
                 pkc=0xb24 interface=0x1c engine=0x400 ucode=9 signatures=2
FWSEC interface: offset=0x1c version=1 header=4 stride=8 entries=2 FRTS=0x3ff600000
```

**교훈.** `lspci -vv` 의 ROM 덤프나 `pci_map_rom` 결과를 "VBIOS 전체"로 취급하면 FWSEC 을 통째로 놓친다.

### 5.2 AD103 기하 상수 — GA102 상수를 그대로 쓰면 `-E22`

**증상.** 첫 시도가 `unlock_transaction_assets error=-22` 로 즉시 실패. `master=0 firmware_started=0 pages=0/0` — **쓰기가 하나도 없었으므로 안전하게 중단**됐다.

**원인.** `boot_fw->size` 검사가 GA102 상수 `24576` 을 기대하는데 AD102/AD103 GSP 부트 이미지는 `36864` 다.

**조치.** 업스트림 PR #41 이 이 부분을 **칩 프로파일 구조체**로 재작성했다. 정적 상수를 칩별 테이블로 바꾼 것이 핵심이다.

```c
static const struct unlock_profile ...
	.name = "AD103",
	.chip_id = 0x193000a1u,
	.booter = "gpu-unlock/610.43.03/booter_load_ad102.bin",
	.v67    = "gpu-unlock/610.43.03/v67-ad102-610.43.03.bin",
	.boot   = "gpu-unlock/610.43.03/gsp_boot_ad102.bin",
	.boot_desc = "gpu-unlock/610.43.03/gsp_boot_desc_ad102.bin",
	.sig_section = ".fwsignature_ad10x",
	.booter_image_size = 56832,
	.boot_image_size   = 36864,
	.os_data_off  = 32256,
	.os_data_size = 24576,
	.app_code_size = 32000,
	.patch_loc     = 32272,
	.prom_view     = 0xd6c00,
	.boot_marker   = 0x67b00001u,
```

`os_data_off=32256`, `app_code_size=32000`, `patch_loc=32272` 는 AMI 부트로더 내부 오프셋이다. GA102 값(`35328`/`35072`/`35344`)과 다르다.

**근거.** 이 값들은 [`TOTORONG/AD103_win_unlocker`](https://huggingface.co/TOTORONG/AD103_win_unlocker) (GPL-2.0-only) 에서 적응된 것이고, PR #41 이 `firmware/NOTICE.md` 에 출처를 기록한다.

### 5.3 FWSEC DMEM 전송 길이 정렬 — 조용한 `falcon_dma_valid` 거부

**증상.** 두 번째 시도가 `unlock_610.c:364 falcon_hs error=-22` 로 실패. `last_mmio=0x8241e0 value=0x1`.

**원인.** `falcon_dma_valid(dest, mem_off, src, size)` 는 `size|dest|mem_off|src` 가 모두 256 정렬일 것을 요구한다. AD103 FWSEC 의 `dmem=0xd80`(= 3456)은 256 의 배수가 아니다.

**조치.** 전송 길이만 256 올림하고, 이미지 경계를 넘으면 원래 값으로 되돌린다.

```c
u32 dmem_xfer = (fw.dmem_size + 255u) & ~255u;
if (dmem_xfer > fw.image_size - fw.data_off) dmem_xfer = fw.dmem_size;
```

`image_size 0x10500 − imem 0xf700 = 0xe00` 이므로 `0xd80 → 0xe00` 올림이 정확히 들어맞는다.

**주의.** 이 정렬 패치는 업스트림 PR #41 계열에는 없다. **자체 수정분**이다. 같은 증상이 나오면 여기부터 본다.

### 5.4 V67 페이로드 — **핵심 병목**

이 절이 이 작업의 전부다. 앞의 4개를 다 고쳐도 여기서 막혔다.

**증상.** FWSEC 은 성공하는데 PLM 이 안 열린다.

```
FWSEC result: scratch=0x0                                  ← FWSEC 성공
FWSEC WPR2: low=0x3ff6000 high=0x3ff6e00 expected_page=0x3ff600   ← WPR2 일치
DIAG dma: code_va=0x100 code_size=0x7d00                   ← 부트로더 실행됨
early PLM failed: pci=0x270510de cpuctl=0x0 plm=0xffffff8f entry=0xffffff8f
                                                           ↑ 5초 대기 후 타임아웃
```

`entry` 와 `plm` 이 둘 다 `0xffffff8f` — **전이가 아예 없었다.** WPR2 는 세팅됐고(`0x03ff6e00`) 부트로더도 돌았는데 PLM 만 그대로다.

**원인.** 쓰던 V67 페이로드가 **GA102(CMP)용**이었다. AD102/AD103 은 **다른 페이로드**가 필요하다.

두 페이로드의 패치 워드 비교:

| 오프셋 | GA102 페이로드 | AD102 페이로드 | 의미 |
|---|---|---|---|
| `0xF960` | `0x00823804` | `0x001FA7CC` | 대상 레지스터가 다름 |
| `0xF9A8` | — | `0x001FA7C4` | FBPA |
| `0xF9CC` | — | `0x00823804` | FEAT_OVR PLM |
| `0xF9E0` | — | `0x67B00001` | MAILBOX0 완료 마커 |
| `0xF9F8` | — | `0x000031B5` | 종료 코드 |

업스트림 주석이 동작 차이를 명시한다.

> "AD102 Booter: one SEC2 run writes WPR_CFG, FBPA, WPR and FEAT_OVR PLMs, then the marker 0x67b00001 to MAILBOX0. From TOTORONG/AD103_win_unlocker source/firmware-tools/ad102_payload.py."

즉 AD102 페이로드는 **WPR_CFG · FBPA · WPR · FEAT_OVR 네 개의 PLM 을 한 번에** 쓰고 마커를 남긴다. GA102 페이로드는 FEAT 하나만 건드린다. 이것이 "부트로더는 돌았는데 PLM 은 그대로" 라는 관측과 정확히 맞는다.

**조치.** AD102 페이로드를 상수에서 직접 합성하고 고정 해시로 검증한다.

```python
PAYLOAD_SIZE = 0xFA00          # 64,000 B
FILL_DWORD   = 0x0000019C
AD102_PATCHED_WORDS = { 0x1100: 7, 0xF948: 0xFFFFF0FF, ... 0xF9FC: 0x0000771E }  # 25 words
```

생성 결과 `sha256 = 44c36b2d6b3424e53e18f3e55db85c833655de071ce66ce42749588a4a7dc8cb` — 업스트림 고정값과 **바이트 단위 일치**.

**결과.** 같은 카드, 같은 나머지 조건에서 마커가 나타나고 PLM 이 열린다.

```
AD103 boot result: marker=0x67b00001 expected=0x67b00001 debug=0xda550000 expected=0xda550000
selector write: SS0=0x88888888
selector write: SS1=0x8
post-FLR GFW result: error=0
gpu_unlock: unlocked
```

**교훈.** "부트로더가 실행됐다"와 "페이로드가 의도한 레지스터를 썼다"는 별개다. 완료 마커(`0x67b00001`)와 대상 레지스터를 **각각** 확인해야 한다. 마커조차 없었기 때문에 처음부터 페이로드 의심이 정답이었다.

### 5.5 자산 출처 — VBIOS 가 아니라 드라이버 소스

**오해하기 쉬운 지점.** 부트로더/GSP 부트 이미지는 VBIOS 에서 추출하는 것이 아니라 **NVIDIA 오픈 커널 모듈 소스의 바이너리 배열**에서 뽑는다.

```
src/nvidia/generated/g_bindata_kgspGetBinArchiveBooterLoadUcode_<CHIP>.c
src/nvidia/generated/g_bindata_kgspGetBinArchiveGspRmBoot_<CHIP>.c
```

- 리포지토리에 **AD102 는 있고 AD103 은 없다.** AD103 은 AD102 자산을 쓴다(§5.4 의 페이로드도 AD102 형).
- 태그는 **`610.43.03`** 을 쓴다. `main` 은 배열을 `NvU8` 에서 `NvU64` 로 바꿔 추출 스크립트의 바이트 토큰 파서가 깨진다.
- `gsp_ga10x.bin` 은 **`nvidia-utils` 패키지**에서 온다. 패키지에 Ada 전용 GSP 파일은 없고 **`gsp_ga10x.bin` 을 Ada 도 쓴다.**

| 파일 | 크기 | sha256 (앞 16) |
|---|---:|---|
| `booter_load_ad102.bin` | 57,672 | `6ee05b20e1dc244c` |
| `gsp_boot_ad102.bin` | 36,864 | `45d6335a8185d6ff` |
| `gsp_boot_desc_ad102.bin` | 84 | `83f8f3f1f5f9496e` |
| `v67-ad102-610.43.03.bin` | 64,000 | `44c36b2d6b3424e5` |
| `gsp_ga10x.bin` | 27,043,992 | `c420726d2c76c55f` |

### 5.6 드라이버 — 커널 6.17 에서 550 은 안 된다

**증상.** Debian trixie `non-free` 의 `nvidia-driver` 는 `550.163.01` 뿐이다. 커널 `6.17` 에 대해 DKMS 빌드가 깨질 가능성이 높다.

**조치.** NVIDIA 공식 배포에서 **`615.71.09`** .run 설치. 선정 이유는 **우리가 추출한 GSP 펌웨어와 같은 버전**이기 때문이다.

```
https://download.nvidia.com/XFree86/Linux-x86_64/615.71.09/NVIDIA-Linux-x86_64-615.71.09.run
```

설치는 `--silent --dkms --no-questions --ui=none --disable-nouveau`. 이 호스트에서 DKMS 빌드가 `6.17.2-1-pve` 에 대해 성공했다.

**부작용.** `.run` 설치 후 Debian 패키지 관리자와 충돌해 `nvidia-installer-cleanup` 이 실패한다. CUDA 툴킷을 apt 로 넣을 때 이 오류가 뜨지만, `cuda-nvcc-13-4` 설치 자체는 진행된다.

### 5.7 부팅 시점 순서 — 드라이버보다 먼저

**증상.** 모듈을 수동 `insmod` 하면 열리지만 재부팅하면 원상복구.

**원인.** 게이트는 매 콜드 부팅마다 다시 걸린다. 게다가 nvidia 드라이버가 먼저 바인딩하면 모듈이 "이미 드라이버가 잡았다" 로 판단하고 카드를 건드리지 않는다.

**조치.** udev 모달리어스 자동 로드를 막고 순서를 고정한다.

`/etc/modprobe.d/gpu-unlock.conf`
```
options gpu_unlock targets=0000:01:00.0
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
```

`/etc/modules-load.d/gpu-unlock.conf`
```
gpu_unlock
nvidia
nvidia_uvm
```

`blacklist` 는 udev 자동 로드만 막고 명시적 `modprobe` 는 허용한다. 이 조합이면 `gpu_unlock` 이 **반드시** nvidia 앞에 온다.

**initramfs 를 쓰지 않은 이유.** 업스트림 패키지는 initramfs 삽입을 기본으로 하지만, 이 호스트에서는 부팅 실패 리스크를 피하려고 `modules-load.d` 를 택했다. nvidia 드라이버가 initramfs 에 없으므로(rootfs 단계에서 로드) 순서 보장에 initramfs 가 필요 없다.

---

## 6. 최종 구성

```
/lib/modules/6.17.2-1-pve/updates/gpu_unlock.ko        1,212,096 B  e51135b7fd4f78e2
/lib/firmware/gpu-unlock/610.43.03/                    §5.5 의 5개 + 구 GA102 페이로드
/etc/modprobe.d/gpu-unlock.conf                        targets + nvidia blacklist
/etc/modprobe.d/blacklist-nouveau.conf
/etc/modules-load.d/gpu-unlock.conf                    gpu_unlock → nvidia → nvidia_uvm
```

모듈 소스는 PR #41 브랜치(`NeoChen1024:ad103-upstream`)에 자체 수정 2건을 더한 것이다.

| 수정 | 내용 |
|---|---|
| `unlock_610.h` | `GU_PCI_AD103_4070TI_SUPER 0x2705` 추가 |
| `unlock_610.c` | `ad103_device()` 에 `0x2705` 추가 |
| `main.c` | `supported_ids[]` 에 `0x2705` 추가 |
| `unlock_610.c` | FWSEC DMEM 전송 256 올림 (§5.3) |

> `0x2702`/`0x2704` 는 업스트림에서 검증된 값이다. `0x2705`(4070 Ti SUPER)는 같은 AD103 프로파일을 쓰지만 업스트림 미검증이었고, **이 작업에서 동작을 확인**했다.

---

## 7. 검증 — 왜 이 방법이어야 하는가

### 7.1 처음 측정의 결함

첫 검증은 PyTorch/cuBLAS `matmul` 로 비율만 봤다(`FP32누산 ÷ FP16누산 = 1.031`). 이 방법은 **제어군이 성립하지 않는다.**

`torch.backends.cuda.matmul.allow_fp16_reduced_precision_reduction` 는 split-K 리덕션 정밀도만 바꾼다. **cuBLAS 내부의 `mma` 누산 모드는 여전히 FP32** 일 수 있다. 그러면 "FP16 누산" 이라는 제어군이 실제로는 게이트 대상 경로라 아무것도 검증하지 못한다.

### 7.2 채택한 방법

**raw PTX `mma` 마이크로벤치** (`artifacts/gpu-passthrough-proxmox3-20261025/mmapeak.cu`).

- `mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32` — FP16 / FP32 누산
- `mma.sync.aligned.m16n8k16.row.col.f16.f16.f16.f16` — FP16 / FP16 누산
- `mma.sync.aligned.m16n8k16.row.col.f32.bf16.bf16.f32`
- `mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32`
- `mma.sync.aligned.m16n8k32.row.col.f32.e4m3.e4m3.f32`
- FFMA 스칼라

누산 모드가 **PTX 명령 자체에 박혀** 있으므로 라이브러리 휴리스틱이 끼어들 여지가 없다. 레지스터 피연산자만 쓰고 메모리 트래픽이 없어 명령 처리량을 직접 잰다.

추가 통제:
- **SM 클럭 `2610 MHz` 고정** (`nvidia-smi -lgc`). 두 상태 모두 동일.
- 8개 독립 누산기 세트 × 8 unroll 로 `mma` 지연을 숨김.
- 워밍업 3회 후 측정, 3회 반복 중 최댓값.
- 반복 편차 **0.06% 이하** (해제 상태 3회: 176.04 / 176.02 / 175.94).

### 7.3 잠금 베이스라인을 이 카드에서 측정

`modules-load.d` 에서 `gpu_unlock` 만 빼고 재부팅 → 드라이버는 정상 로드, 게이트는 잠금.

```
PLM = 0xffffff8f   SS0 = 0x00000000   SS1 = 0x00000000
드라이버: RTX 4070 Ti SUPER, 615.71.09  (정상)
FP16 -> FP32acc 88.08   FP16 -> FP16acc 175.87   ratio 0.501
```

핵심은 **제어군이 잠금/해제 양쪽에서 1.00× 로 고정**된다는 점이다. 같은 바이너리, 같은 클럭에서 게이트 대상만 정확히 2배가 됐다. 측정 오차나 클럭 변동으로는 나올 수 없는 패턴이다.

### 7.4 이론값 대조

이론 피크 = `SM 수 × FLOP/clk/SM × 클럭`

| 경로 | FLOP/clk/SM | 66 SM × 2.61 GHz | 실측 | 달성률 |
|---|---:|---:|---:|---:|
| BF16/FP16 (512 FMA) | 1024 | 176.4 | 176.13 | **99.9%** |
| TF32 | 512 | 88.2 | 88.13 | **99.9%** |
| FP8 | 2048 | 352.8 | 352.42 | **99.9%** |

cuBLAS 가 아니라 PTX 를 직접 때렸으므로 하드웨어 한계에 99.9%로 붙는 것이 정상이다. 소프트웨어 최적화 여지가 없는 지점이다.

### 7.5 판정 기준 대조

원 작업의 완료 판정은 세 가지였다.

| 기준 | 요구 | 실측 | 판정 |
|---|---|---|---|
| 게이트 경로 배율 | ≥ 1.9× | 2.00× (4개 경로 전부) | 충족 |
| FP16/FP16누산 유지 | 1.0× | 1.00× | 충족 |
| INT8·FFMA 유지 | 1.0× | FFMA 1.00× | 충족 |
| 드라이버 로드 후 selector 유지 | 유지 | 재부팅 자동 적용 확인 | 충족 |

---

## 8. 레퍼런스

| 대상 | 링크 | 이 작업에서의 역할 |
|---|---|---|
| Zagitta/gpu-unlock | https://github.com/Zagitta/gpu-unlock | 커널 모듈 구현 본체. GA10x 지원 |
| **PR #41** `NeoChen1024:ad103-upstream` | https://github.com/Zagitta/gpu-unlock/pull/41 | **AD103 포팅. 칩 프로파일 구조·AD102 페이로드·기하 상수. 이 작업의 기반** |
| Issue #4 | https://github.com/Zagitta/gpu-unlock/issues/4 | AD103(4080 SUPER) 검증 데이터. selector `0x36000134 → 0x88888888`, 드라이버 615.78.08, 벤치 표 |
| Issue #24 | https://github.com/Zagitta/gpu-unlock/issues/24 | 4080 SUPER 지원 PR(미머지) |
| **TOTORONG/AD103_win_unlocker** | https://huggingface.co/TOTORONG/AD103_win_unlocker | **AD102 페이로드 표·AD103 기하 원본 (GPL-2.0-only)**. `analysis/AD102-BOOTER-DISASM-EXCERPTS.txt` 포함 |
| WildFlash1st/cmp90hx-unlock | https://github.com/WildFlash1st/cmp90hx-unlock | GA102 CMP 계열 원본 기법 (V67 페이로드 계보) |
| NVIDIA 오픈 커널 모듈 | 태그 `610.43.03` | 부트로더/GSP 부트 바이너리 배열 출처 |
| NVIDIA 드라이버 배포 | https://download.nvidia.com/XFree86/Linux-x86_64/615.71.09/ | 드라이버 615.71.09 |

**라이선스 주의.** V67 페이로드와 AD103 기하 값은 `TOTORONG/AD103_win_unlocker` (GPL-2.0-only) 에서 유래한다. 재배포 시 출처와 라이선스를 유지해야 한다. NVIDIA 펌웨어는 별도 조건을 따른다.

---

## 9. 재현 절차

```bash
# 1) 소스 — AD103 포팅 브랜치
git clone -b ad103-upstream https://github.com/NeoChen1024/gpu-unlock.git

# 2) 칩 ID 추가 (0x2705)
#    kernel/gpu_unlock/unlock_610.h   GU_PCI_AD103_4070TI_SUPER 0x2705
#    kernel/gpu_unlock/unlock_610.c   ad103_device() 에 0x2705
#    kernel/gpu_unlock/main.c         supported_ids[] 에 0x2705

# 3) FWSEC DMEM 정렬 패치 (§5.3) — falcon_hs 호출부

# 4) 부트 자산 — 태그 610.43.03 에서 추출
#    booter_load_ad102.bin / gsp_boot_ad102.bin / gsp_boot_desc_ad102.bin
#    v67-ad102-610.43.03.bin (sha256 44c36b2d… 로 검증)
#    gsp_ga10x.bin (nvidia-utils 패키지)
#    → /lib/firmware/gpu-unlock/610.43.03/

# 5) 빌드
make -C /lib/modules/$(uname -r)/build M=$PWD modules

# 6) 설치 + 부팅 순서 (§5.7)

# 7) 읽기 전용 검사 — 쓰기 없음
insmod gpu_unlock.ko targets=0000:01:00.0 dry_run=1
#    기대: profile=AD103 chip=0x193000a1 cold=1 wpr2_up=0 gfw_assess=0

# 8) 실투입 → 재부팅 후 자동 적용 확인
journalctl -k -b 0 | grep -E "AD103 boot result|unlocked"
```

**`dry_run=1` 을 반드시 먼저 쓴다.** 읽기만 하고 `refcnt=0` 으로 떨어져 재부팅 없이 다시 시도할 수 있다.

**실패 시 주의.** FWSEC 실패 후 모듈이 DMA 버퍼를 놓지 못해 `refcnt=1` 로 고정되는 경우가 있다(`unlock_transaction_unwind error=-16`). 이때는 `rmmod` 가 불가능하고 **전원 차단만이 해제 수단**이다. 이 조건에서 재시도하면 안 된다.

---

## 10. 한계 · 미해결

- **FFMA 측정이 피크가 아니다.** `10.66 TFLOPS` 는 이론 `44.1` 의 24%다. 커널이 FMA 의존성 체인에 걸린다. 게이트 유무의 **상대 비교 제어군**으로는 유효하지만(1.00× 유지 확인) FP32 피크 측정치는 아니다. 필요하면 독립 누산기를 늘려 다시 짜야 한다.
- **0x2705 는 단일 카드에서만 확인됐다.** `0x2702`/`0x2704` 는 업스트림 검증분이고, `0x2705` 는 이 카드 1대로만 확인했다. 다른 4070 Ti SUPER 개체에서 재현 검증은 없다.
- **서스펜드/하이버네이션 미검증.** 모듈은 `resume` 파라미터로 suspend 복귀 시 재적용을 지원하지만, 이 호스트는 서버라 suspend 시나리오를 시험하지 않았다.
- **PCI 패스스루 미검증.** 게이트는 FLR 후에도 selector 가 유지되는 것으로 확인됐으나(`post-FLR … SS0=88888888 SS1=00000008`), VM 에 넘긴 뒤 게스트 드라이버가 같은 성능을 내는지는 시험하지 않았다.
- **게스트/컨테이너 배포 미구성.** 현재 GPU 는 호스트 드라이버에 묶여 있고 ComfyUI 등 워크로드는 아직 올리지 않았다.
- **`0x0082380c = 0x00888888`** 은 AD103 에서 관측된 미해석 값이다. GA102 의 해제 목표 `0x88888888` 과 자릿수가 비슷해 관련 가능성이 있으나 확인하지 않았다.

---

## 부록 A. 실패 → 성공 로그 대조

| 단계 | 관측 | 해석 |
|---|---|---|
| 시도 1 | `unlock_transaction_assets error=-22`, `pages=0/0` | 기하 상수 불일치. **쓰기 0건, 안전** |
| 시도 2 | `falcon_hs error=-22`, `last_mmio=0x8241e0 value=0x1` | FWSEC DMA 정렬 거부 |
| 시도 3 | `early PLM failed … plm=0xffffff8f entry=0xffffff8f` | GA102 페이로드. PLM 전이 없음 |
| 성공 | `marker=0x67b00001`, `SS0=0x88888888`, `unlocked` | AD102 페이로드 |

시도 3 이전에 FWSEC 이 성공한 것은 `FWSEC result: scratch=0x0` 와 `FWSEC WPR2 … expected_page=0x3ff600` 로 확인된다. 즉 **FWSEC 은 처음부터 정상이었고 범인은 페이로드 하나**였다.

## 부록 B. 게이트 경로 요약

```
텐서 게이트가 반감시키는 것:   FP32 누산을 쓰는 모든 텐서 경로
  ├ FP16 입력 + FP32 누산
  ├ BF16 입력 + FP32 누산
  ├ TF32
  └ FP8 + FP32 누산

영향 없는 것:
  ├ FP16 입력 + FP16 누산
  └ 스칼라 FP32 (FFMA)
```

따라서 "언락됐다"의 최소 증거는 **FP32 누산 경로가 FP16 누산 경로와 같아지는 것**이고, 가장 강한 증거는 **잠금 상태에서 정확히 절반이었다가 해제 후 정확히 두 배가 되는 것**이다.

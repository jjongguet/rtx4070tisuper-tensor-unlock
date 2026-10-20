# RTX 4070 Ti SUPER (AD103) 텐서 처리량 언락 — 현장 사례

RTX 4070 Ti SUPER 한 장에서 FP16/BF16 FP32-누산과 TF32 Tensor 처리량이 약
2배로 올라간 결과를 정리했다. UEFI 단계에서 적용했고, Windows/Linux 드라이버가
올라온 뒤에도 값이 유지됐다. VBIOS를 굽거나 펌웨어를 영구히 바꾼 건 아니다.

## 결과 (Linux)

Linux, 66 SM, 9회 측정, 측정 클럭 약 2.77 GHz. 같은 부팅 조건에서 잠금 상태와
UEFI 언락 상태를 비교했다. 값은 반올림했다.

| 경로 | 잠금 | 언락 | 배율 |
|---|---:|---:|---:|
| FP16 / FP32-누산 | 94.1 TFLOPS | **184.8 TFLOPS** | **1.96×** |
| BF16 / FP32-누산 | 93.9 TFLOPS | **184.4 TFLOPS** | **1.96×** |
| TF32 | 47.0 TFLOPS | **92.2 TFLOPS** | **1.96×** |
| FP16 / FP16-누산 | 180.6 TFLOPS | 180.3 TFLOPS | 1.00× |
| INT8 | 370.0 TOPS | 368.6 TOPS | 1.00× |
| FFMA (SIMT FP32) | 42.8 TFLOPS | 42.7 TFLOPS | 1.00× |
| cuBLAS n=8192, BF16/FP32 | 90.5 TFLOPS | **179.3 TFLOPS** | **1.98×** |

목표 경로만 2배가 됐고, FP16/FP16-누산·INT8·FFMA는 그대로였다. INT8은 TOPS
단위다. cuBLAS에서도 같은 방향이 확인됐다.

## 관련 사례

비슷한 흐름은 처음이 아니다. Ampere CMP 쪽에서는 PLM을 열고 SS0/SS1을 쓰는
방식이 이미 쓰였다. Ada 4090에서도 FP16 FP32-누산이 FP16-누산의 절반으로
나오는 현상이 리포트됐다. 이 글은 그 흐름을 4070 Ti SUPER 한 장에 적용한
기록이다.

- [NVIDIA forum — Ada GeForce (RTX 4090) FP8 cuBLASLt performance](https://forums.developer.nvidia.com/t/ada-geforce-rtx-4090-fp8-cublaslt-performance/250737)
- [NVIDIA Ada GPU architecture whitepaper](https://images.nvidia.com/aem-dam/Solutions/Data-Center/l4/nvidia-ada-gpu-architecture-whitepaper-V2.02.pdf)

## 환경

- GPU: NVIDIA GeForce RTX 4070 Ti SUPER, AD103, 66 SM
- 디스플레이: iGPU 출력. fire 중 dGPU는 콘솔/디스플레이로 사용하지 않음
- Linux: 커널 7.0, NVIDIA 615.71.09, CUDA 12.0
- Windows: Windows 11, NVIDIA 617.42, CUDA 12.8
- Secure Boot: UEFI 앱 실행을 위해 OFF
- 벤치마크: 9회, 스레드 256/512/1024 × 3

## UEFI에서 한 일

UEFI 앱은 OS 드라이버보다 먼저 돈다. 먼저 보드 VBIOS를 읽어 FWSEC-FRTS
디스크립터, Booter 헤더, GSP 이미지 정보를 찾는다. FWSEC 기하, Booter
signature/fuse 선택, 콜드 WPR2 상태, FEAT/PLM 레이아웃이 맞는지 확인하고,
하나라도 어긋나면 아무것도 쓰지 않고 멈춘다. 이 단계에서는 Falcon도 시작하지
않는다.

검사를 통과하면 GSP Falcon에서 FWSEC를 heavy-secure 모드로 띄우고 WPR2를
잡는다. 이어 SEC2 Booter로 FEAT PLM을 연다. PLM을 여는 것과 rate selector를
쓰는 것은 별개라서, PLM이 열린 뒤에 FP32-누산/TF32 selector를 쓰고 바로 다시
읽어 확인한다.

마지막으로 PCIe FLR을 걸어 GPU를 OS 드라이버가 잡을 수 있는 상태로 되돌린다.
BAR/chip/GFW 준비 상태를 기다리고, 필요한 경우 SEC2 reset을 유지하며, WPR2와
selector가 FLR 후에도 남아 있는지 본다. 그다음 정상 Windows/Linux 부트로더로
chainload하고, 드라이버 초기화 뒤에 값이 그대로인지 다시 확인한다.

selector는 휘발성이다. 전원을 완전히 끄면 기본 값으로 돌아가고, 다음 전원 인가
때 같은 과정을 다시 거쳐야 한다. 커널 모듈, 드라이버 패치, VBIOS 플래시는 쓰지
않았다.

## 보드별로 다른 부분

- VBIOS FWSEC-FRTS 기하, signature 테이블, WPR2 배치
- Booter 이미지, SEC2 엔트리, fuse 버전, signature 선택
- FEAT/PLM 위치와 selector 필드 맵
- payload/DMEM 레이아웃, 스택 프레임, PLM 쓰기 이후 복귀 경로
- 호스트 측 FLR/GFW 레이아웃과 chainload 대상 경로

이 값들은 그대로 이식할 수 있는 상수가 아니다. AD102, AD103, AD104,
AD106/107, GB202는 서로 다르고, 보드 포팅에는 해당 VBIOS와 디스어셈블리
작업이 필요하다.

## 필요한 것

- 대상 카드와, 그 카드에서 검증된 VBIOS/드라이버 조합
- 해당 VBIOS와 드라이버에서 추출한 보드별 FWSEC/Booter/GSP 자산
- 사전 검사, fire, FLR, chainload를 구현한 UEFI 애플리케이션
- iGPU 또는 시리얼 콘솔. fire 중 dGPU가 활성 디스플레이가 아니어야 함
- 서명되지 않은 UEFI 앱 실행을 위한 Secure Boot OFF
- 매 시도 전 완전 콜드 부트. OS 드라이버가 dGPU를 건드리지 않은 상태여야 함
- UEFI 앱과 펌웨어 이미지를 넣을 ESP 공간, 그리고 나중에 chainload할 정상
  OS 부트로더

selector는 휘발성이므로 전원을 완전히 끌 때마다 같은 순서를 다시 실행해야
한다. 웜 리부트는 콜드 부트를 대신하지 못한다.

## 걸린 것들

- **콜드 부트만 유효하다.** dGPU가 전원 인가 이후 OS 드라이버에 의해
  초기화되지 않아야 한다. 웜 리부트로는 재시도가 안 된다.
- **전원 인가당 fire는 1회.** 중간에 실패하면 전원을 끄고 UEFI 로그를
  보존한다. 같은 부팅에서 다시 걸지 않는다.
- **콘솔은 iGPU에 둔다.** 디스플레이가 dGPU에 연결되어 있으면 FLR 중 화면이
  꺼질 수 있다.
- **드라이버 타이밍이 중요하다.** OS 드라이버는 UEFI fire 이후에 로드되어야
  한다. selector는 절전/재개 후에는 유지되지 않는다.
- **보드별 자산이 필요하다.** FWSEC/Booter/PLM 세부는 칩과 VBIOS마다 다르다.
  범용 40시리즈 도구로 묶을 수 없다.

## 범위와 한계

- **RTX 4070 Ti SUPER (AD103)** 한 종류에서만 확인했다.
- 4080, 4090, 4070, 4060, 5090, 노트북 GPU는 포함하지 않는다.
- SM 개수, VBIOS, fuse, 클럭을 바꾸는 작업이 아니다.
- 합성 벤치마크의 상승폭이 실제 애플리케이션의 전체 상승폭을 보장하지는
  않는다. 전력, 메모리 대역폭, 스케줄링의 영향을 받는다.
- 효과는 휘발성이며 테스트 시스템 기준이다.

## 근거 자료

- [`evidence/bench-linux-unlocked.json`](evidence/bench-linux-unlocked.json)
- [`evidence/bench-linux-locked.json`](evidence/bench-linux-locked.json)
- [`evidence/bench-windows-unlocked.json`](evidence/bench-windows-unlocked.json)
- [`evidence/bench-windows-locked.json`](evidence/bench-windows-locked.json)
- [`evidence/fire-success.log`](evidence/fire-success.log)

JSON 파일에는 클럭당 및 TFLOPS 측정 원본이 들어 있다. fire 로그는 자산 경로와
기기 식별 정보를 제거한 UEFI 결과다.

## Original sources / credit (최초 출처)

이 작업은 아래 공개 자료 위에 올라간다. 원본은 각 프로젝트에 있고, 여기서는
AD103 포팅, UEFI pre-OS 경로, 측정과 Windows/Linux 검증을 얹었다.

- **[Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock/tree/0ebdb1c6308b6a2072be5bf04513472942541956)**
  — 커널 모듈과 공유 parser의 원본. `0ebdb1c6308b6a2072be5bf04513472942541956`
  커밋을 기준으로 AD103/AD102 자산에 맞게 포팅했다. GPL-2.0-only.
- **cmpunlocker / NVPermissive (GreenDamTan, RainCandyTech 계열)**
  — Ampere CMP의 PLM/SS0/SS1 selector 연구와 NVPermissive 흐름.
- **[NVIDIA open kernel modules](https://github.com/NVIDIA/open-gpu-kernel-modules)**
  — FWSEC/Booter/GSP 초기화와 VBIOS 구조를 이해할 때 참고했다.
- **[Linux nova FWSEC 문서](https://dri.freedesktop.org/docs/drm/gpu/nova/core/fwsec.html)**
  — FWSEC-FRTS, WPR2, Falcon 초기화 설명.
- **envytools** — Falcon 디스어셈블리와 레지스터 분석 도구.
- **gnu-efi / UEFI 명세** — pre-OS UEFI 앱의 빌드와 chainload.

원본 소스와 라이선스는 각 프로젝트에 귀속된다. 이 저장소에는 소스 코드, 펌웨어,
VBIOS 이미지, 미리 빌드된 EFI 바이너리가 없다.

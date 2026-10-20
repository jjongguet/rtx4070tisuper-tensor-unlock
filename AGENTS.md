# Mission: AD103 UEFI Tensor Unlock

## Objective

RTX 4070 Ti SUPER(AD103)에서 UEFI pre-OS 단계로 FP16/BF16 FP32-누산과 TF32
Tensor issue rate를 약 2배로 올린다. 결과는 Windows/Linux 드라이버 로드 후에도
유지되어야 하며, 전원 차단 시 초기화되는 volatile 상태여야 한다.

이 과제는 **공개 자료만으로 끝나는 문제가 아니다.** 대상 카드, 로컬 VBIOS/드라이버
덤프, 디스어셈블리, 콜드 부트/전원 제어, 복구 환경이 필요하다.

## Prerequisites

- RTX 4070 Ti SUPER, AD103, 66 SM
- iGPU 또는 시리얼 콘솔. fire 중 dGPU가 활성 디스플레이가 아니어야 함
- Secure Boot OFF
- 완전 콜드 부트와 전원 차단이 가능한 환경
- UEFI 앱 빌드 호스트 (Linux/WSL, gnu-efi)
- 로컬 VBIOS PROM 덤프와 NVIDIA 드라이버 자산
- 디스어셈블러와 BAR0 접근 도구
- 기준 성능을 측정할 CUDA 환경과 `ada-tensor-bench`

## Problems

### P1. V67 / ROP chain

AD103 host에서 사용할 AD102-shaped V67 payload를 재구성한다.

- 로컬 Booter disassembly에서 필요한 gadget과 프레임 간격을 찾는다.
- DMEM에 들어갈 write/return/teardown 경로를 만든다.
- payload가 실제로 PLM write를 수행하고 안전하게 빠져나오는지 정적 검증한다.

Acceptance: 정적 검증 통과, preflight 통과, 한 번의 fire에서 PLM open.

### P2. Booter signature / fuse

로컬 Booter header와 fuse 값을 읽고, signature 선택과 복원 경로를 맞춘다.

- fuse version, signature count, patch 위치를 확인한다.
- stock signature를 복원해 이후 드라이버가 정상 부팅하게 한다.

Acceptance: preflight에서 signature/fuse 불일치가 없고, fire 후 stock signature가
복원됨.

### P3. FWSEC geometry / DMEM

로컬 VBIOS의 FWSEC-FRTS를 파싱하고 GSP Falcon에 올릴 이미지를 준비한다.

- IMEM/DMEM 크기와 주소, engine mask, application interface를 확인한다.
- Falcon DMA 블록 크기에 맞게 이미지를 정렬한다.
- WPR2가 기대한 위치에 설정되는지 확인한다.

Acceptance: preflight의 FWSEC geometry가 로컬 VBIOS와 일치하고, fire 후 WPR2
상태가 정상.

### P4. PLM / selector / FLR

PLM을 연 뒤 selector를 쓰고, FLR 후에도 유지되는지 확인한다.

- 읽기 전용 probe로 콜드 PLM/SS/WPR2를 기록한다.
- Booter 이후 PLM open을 확인한다.
- FP32-누산/TF32 selector를 쓰고 즉시 read-back한다.
- PCIe FLR, BAR/chip/GFW 대기, SEC2 reset, WPR2/selector 재확인을 수행한다.

Acceptance: `PLM open`, selector read-back, FLR 후 유지, stock 드라이버 로드 성공.

### P5. Verification constants

P1~P4에서 나온 주소/값/순서를 하나의 검증 표로 정리한다.

- 이 문제는 독립적인 발견 문제가 아니라 **결과 통합**이다.
- 각 상수는 최소 두 번의 콜드 부트와 read-back으로 확인한다.
- 로그, 해시, 실패 케이스를 함께 남긴다.

Acceptance: 재현 가능한 표와 로그가 남고, 같은 절차로 다시 성공한다.

## Milestones

| 단계 | 산출물 | 통과 기준 |
|---|---|---|
| M0 | target manifest, read-only probe | GPU/VBIOS/driver/PLM/SS/WPR2 확인 |
| M1 | Booter/FWSEC disassembly, asset map | 필요한 gadget/기하/서명 필드 확인 |
| M2 | preflight 앱 | 쓰기 없이 모든 검사 통과 |
| M3 | fire 앱 | PLM open + selector write |
| M4 | FLR/드라이버 | stock 드라이버 로드 후 selector 유지 |
| M5 | benchmark | 목표 경로 약 2×, 대조군 약 1× |

## Deliverables

- UEFI 앱/패치 소스 (private 검토용)
- preflight/fire 로그와 해시
- 벤치마크 JSON과 비교표
- 실패 케이스와 복구 절차
- 최종 상수/검증 표

펌웨어, VBIOS ROM, prebuilt EFI는 산출물에 포함하지 않는다.

## Stop conditions

- 대상 GPU ID 또는 VBIOS가 known-good과 다름
- preflight 실패
- `WPR2`가 콜드 상태가 아님
- fire 중 `early PLM`/timeout/서명 오류
- FLR 후 selector가 사라짐
- 드라이버가 GPU를 잡지 못함

실패하면 같은 부팅에서 재시도하지 않는다. 전원을 차단하고 로그를 보존한다.

## Human / remote control

UEFI 재부팅과 전원 차단은 OS 세션 밖에서 일어난다. Agent가 혼자 진행하려면
IPMI, 스마트 플러그, 시리얼 콘솔 같은 out-of-band 제어가 필요하다. 없으면
사람이 재부팅·전원 차단·`ESC` 취소를 담당한다.

## References

- [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock/tree/0ebdb1c6308b6a2072be5bf04513472942541956)
- [NVIDIA open kernel modules](https://github.com/NVIDIA/open-gpu-kernel-modules)
- [Linux nova FWSEC 문서](https://dri.freedesktop.org/docs/drm/gpu/nova/core/fwsec.html)
- [NVIDIA Ada GPU architecture whitepaper](https://images.nvidia.com/aem-dam/Solutions/Data-Center/l4/nvidia-ada-gpu-architecture-whitepaper-V2.02.pdf)
- cmpunlocker / NVPermissive 계열의 Ampere PLM/SS0/SS1 선행 사례
- envytools, gnu-efi, UEFI 명세

세부 결과와 현재 solution의 한계는 [`CASE-STUDY.md`](CASE-STUDY.md)에 있다.

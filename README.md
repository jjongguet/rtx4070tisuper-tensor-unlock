# RTX 4070 Ti SUPER 텐서 언락 — 미션

RTX 4070 Ti SUPER(AD103) 한 장에서 FP16/BF16 FP32-누산과 TF32 Tensor 처리량을
약 2배로 올리는 **로컬 리버싱 과제**다. 완성된 도구를 배포하는 저장소가 아니라,
무엇을 확인하고 어떤 순서로 검증해야 하는지 정리한 미션 브리프다.

- [`AGENTS.md`](AGENTS.md) — 과제 정의, 문제 세트, 마일스톤, 중단 조건
- [`CASE-STUDY.md`](CASE-STUDY.md) — 실제 결과, 측정표, 방법, 한계, 출처
- [`evidence/`](evidence/) — Linux/Windows 벤치마크 JSON과 sanitized fire 로그
- [`docs/AD103-UNLOCK-PROXMOX3.md`](docs/AD103-UNLOCK-PROXMOX3.md) — **Proxmox 호스트 커널 모듈 경로 적용 기록.** 병목별 원인·근거·조치, 잠금/해제 A/B 실측, 재현 절차
- [`tools/mmapeak.cu`](tools/mmapeak.cu) — raw PTX `mma` 마이크로벤치. 누산 모드를 PTX 로 직접 지정해 cuBLAS 휴리스틱을 배제한다

## 범위

- 대상: RTX 4070 Ti SUPER, AD103, 66 SM
- 방식: OS 드라이버 이전 UEFI 단계, volatile
- 제외: 4080, 4090, 4070, 4060, 5090, 노트북 GPU
- 제외: VBIOS 플래시, 영구 펌웨어 변경, prebuilt EFI, NVIDIA 펌웨어/ROM

## 결과 요약

Linux, 같은 부팅 조건, 66 SM, 9회 측정, 약 2.77 GHz.

| 경로 | 잠금 | 언락 | 배율 |
|---|---:|---:|---:|
| FP16 / FP32-누산 | 94.1 TFLOPS | 184.8 TFLOPS | 1.96× |
| BF16 / FP32-누산 | 93.9 TFLOPS | 184.4 TFLOPS | 1.96× |
| TF32 | 47.0 TFLOPS | 92.2 TFLOPS | 1.96× |
| FP16 / FP16-누산 | 180.6 TFLOPS | 180.3 TFLOPS | 1.00× |
| INT8 | 370.0 TOPS | 368.6 TOPS | 1.00× |

`AGENTS.md`의 문제 세트는 이 결과를 목표로 한다. 세부 수치와 환경은
[`CASE-STUDY.md`](CASE-STUDY.md)에 있다.

## 호스트 적용 — 커널 모듈 경로 (Proxmox VE 9)

이 브리프의 기본 방식은 UEFI 단계 volatile 적용이지만, **재부팅마다 자동으로
유지되는 형태가 필요하면 커널 모듈 경로**를 쓴다. proxmox3 호스트에서
`Zagitta/gpu-unlock` PR #41(AD103 포팅)을 기반으로 적용하고 A/B 실측했다.

| 경로 | 잠금 | 해제 | 배율 |
|---|---:|---:|---:|
| FP16 / FP32-누산 | 88.08 | 175.87 | **2.00×** |
| BF16 / FP32-누산 | 88.09 | 176.13 | **2.00×** |
| TF32 / FP32-누산 | 44.04 | 88.13 | **2.00×** |
| FP8(E4M3) / FP32-누산 | 176.07 | 352.42 | **2.00×** |
| FP16 / FP16-누산 | 175.87 | 176.10 | 1.00× |
| FFMA (스칼라 FP32) | 10.66 | 10.69 | 1.00× |

SM 클럭 2610 MHz 고정, raw PTX `mma` 측정. 해제 상태가 이론 피크의 99.9%다.

**핵심 병목은 V67 페이로드였다.** GA102 용 페이로드는 AD103 에서 PLM 을 열지
못한다(부트로더는 실행되지만 대상 레지스터가 다르다). AD102 페이로드는
WPR_CFG · FBPA · WPR · FEAT_OVR 네 개의 PLM 을 한 번에 쓰고 `0x67b00001`
마커를 남긴다. 전체 경위와 재현 절차는
[`docs/AD103-UNLOCK-PROXMOX3.md`](docs/AD103-UNLOCK-PROXMOX3.md).

## 원본/출처

커널 모듈과 공유 parser는 `Zagitta/gpu-unlock`의 pinned commit을 기반으로 한다.
전체 출처와 라이선스는 [`CASE-STUDY.md`](CASE-STUDY.md)의
`Original sources / credit (최초 출처)`에 정리되어 있다.

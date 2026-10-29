# Embedded RISC-V AI Accelerator

교육용 Embedded RISC-V AI Accelerator 실습 자료입니다.
RV32IMAC Wally 환경, Rock-Paper-Scissors CNN 학습·양자화, 정수 C 추론 및 NPU 연동 예제를 포함합니다.

## 구성

| 경로 | 내용 |
| --- | --- |
| `day01/01.AM/RV32IMAC_Wally` | RV32IMAC Wally RTL, ISA/C/CoreMark/CNN 테스트 환경 |
| `day01/02.PM/ver1` | PyTorch 학습, PTQ/QAT, INT8 C 추론 실습 ver1 |
| `day01/02.PM/ver2` | 보완된 학습·양자화·INT8 C 추론 실습 ver2 |
| `day01/02.PM/dataset/rps` | Rock-Paper-Scissors 데이터셋 |
| `day02/01.AM/RV32IMAC_Wally` | CNN 펌웨어 및 NPU 연동 Wally 환경 |

## 빠른 시작

### Ubuntu + Verilator SW/HW 통합 seed

기존 INT8 모델을 사용해 실제 Wally CPU가 tinyNPU를 구동하는 sample 124를 실행합니다.

```bash
bash run_verilator_seed.sh SAMPLES=124 JOBS=2
```

Verilator >= 5.020 및 RV32 ILP32 RISC-V ELF 툴체인이 필요합니다.
설치, PASS 조건, 로그 및 LLM 확장 경계는
[Verilator 통합 가이드](day02/01.AM/RV32IMAC_Wally/hardware/06.Wally_npu_tests/sim/func_sim/README_verilator.md)를 확인하십시오.

### 1. PyTorch/양자화 실습

아래 예시는 `ver2` 기준입니다. 각 단계의 Python 의존성은 해당 디렉터리의 `requirements.txt`를 사용합니다.

```bash
cd day01/02.PM/ver2/pytorch
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
./run_cpu.sh
```

```bash
cd ../ptq
pip install -r requirements.txt
./run_cpu.sh
```

### 2. INT8 C 추론 검증

```bash
cd day01/02.PM/ver2/int8_c
pip install -r requirements.txt
./run_all.sh
```

이 과정은 모델 export, C 커널 빌드, Python/C 결과 비교, 단위 테스트 및 sanitizer 검증을 순서대로 수행합니다.

### 3. RV32IMAC Wally 환경

```bash
cd day02/01.AM/RV32IMAC_Wally
source env.sh
```

RISC-V 툴체인은 기본적으로 `/opt/riscv/bin`을 사용합니다. 세부 환경 변경 사항은 각 `RV32IMAC_Wally/README`를 확인하십시오.

NPU 펌웨어 빌드 예:

```bash
cd day02/01.AM/RV32IMAC_Wally/software/npu
make
make compare
```

## 주요 요구사항

- Linux 또는 WSL 환경
- Python 3 및 `venv`
- GCC/Make
- RV32IMAC 빌드용 `riscv64-unknown-elf` 툴체인
- RTL 시뮬레이션 도구는 각 Wally 실습 환경 설정에 따름

## 참고 사항

- 일부 경로는 심볼릭 링크를 사용하므로 저장소 clone 시 링크를 보존해야 합니다.
- 학습 결과와 빌드 산출물은 실행 환경 및 툴 버전에 따라 달라질 수 있습니다.
- 실습은 `ver2`를 우선 기준으로 사용하고, `ver1`은 비교·기록 목적으로 유지합니다.

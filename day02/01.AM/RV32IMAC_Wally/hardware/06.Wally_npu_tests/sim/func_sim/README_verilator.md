# Ubuntu CPU + tinyNPU integration seed

목적은 open-weight 사내 LLM으로 확장할 CPU + NPU SW/HW 통합 검증 기반을 확보하는 것이다.
첫 Gate는 기존 INT8 CNN으로 실제 Wally RV32IMAC, AHB, DMA, tinyNPU,
C 펌웨어, 계층별 Golden Checker를 함께 실행하는 것이다.
Ubuntu는 시뮬레이션 호스트이며 CPU RTL에서는 bare-metal 펌웨어를 실행한다.

검증 완료: Ubuntu 24.04, Verilator 5.020 / 5.038에서 sample 124 통합 PASS.
두 번의 CNN 추론, NPU 명령 12회, 계층 출력 7,494바이트를 검사했다.
[실행 근거 JSON](seed_evidence/sample_124_verilator.json)과
[실제 RTL 로그](seed_evidence/sample_124_verilator.log)를 함께 보관한다.

## sample 124

- `day01/02.PM/ver2/int8_c/outputs/input_manifest.json`의 0-based 입력 index.
- 372개 테스트 입력 중 125번째이며 원본은 `dataset/rps/test/rock/testrock01-00.png`.
- NPU 입력은 32 x 32 흑백 영상의 양자화 값이다.
- 클래스 순서는 paper / rock / scissors, 기대 정수 출력은 `[54, 87, 41]`, 예측은 rock.
- 동일 입력의 전체 CNN을 두 번 실행하며, 각 실행에서 6개 계층을 검사한다.

## 준비

필수: Linux, Python 3, GCC/G++, Make, Verilator >= 5.020,
RV32 ILP32를 지원하는 `riscv64-unknown-elf` GCC/binutils.
펌웨어 ISA는 `rv32imac_zicsr_zifencei_zicbom`이다.
저장소의 기존 모델과 입력을 사용하므로 이 Gate에는 PyTorch나 재학습이 필요 없다.

Ubuntu의 RISC-V 도구 설치 예:

```bash
sudo apt-get update
sudo apt-get install -y build-essential python3 verilator gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf
verilator --version
```

기존 Verilator 5.038 설치도 사용할 수 있다.
별도 버전이 필요한 경우에만 버전을 고정해 빌드한다:

```bash
sudo apt-get install -y git autoconf flex libfl-dev bison help2man
mkdir -p "$HOME/tools"
git clone --depth 1 --branch v5.038 https://github.com/verilator/verilator.git "$HOME/tools/verilator-5.038-src"
cd "$HOME/tools/verilator-5.038-src"
autoconf
./configure --prefix="$HOME/tools/verilator-5.038"
make -j2 verilator_bin
make install
export PATH="$HOME/tools/verilator-5.038/bin:$PATH"
```

## 실행

이 작업 브랜치의 저장소 루트에서:

```bash
bash run_verilator_seed.sh SAMPLES=124 JOBS=2
```

도구 위치를 명시하려면:

```bash
bash run_verilator_seed.sh SAMPLES=124 JOBS=2 VERILATOR=/path/to/verilator RISCV=/path/to/riscv64-unknown-elf
```

실행 순서: 도구 확인 -> 펌웨어 ELF/메모리 이미지 빌드 -> C Golden 생성 ->
RTL 시뮬레이터 빌드 -> 실제 CPU 펌웨어 실행 -> 결과 및 사이클 수집.
NPU 전용 `testbench_verilator.sv`가 boot/reset/완료 검출과 UART 기록을 담당한다.
CPU/NPU RTL, 설정, 펌웨어와 기존 `npu_monitor.svh` Golden Checker를 공유한다.
기존 VCS용 Makefile은 그대로 별도 실행할 수 있다.

세 클래스 대표 입력 회귀는 통합 시뮬레이션 디렉터리에서 실행한다:

```bash
make -f Makefile.verilator regression
```

## PASS와 Evidence

PASS는 아래 조건을 모두 만족해야 한다.

1. 실제 CPU가 NPU 명령을 12회 실행하고 실제 AHB DMA 전송을 관측한다.
2. 6개 계층 x 2회 = 7,494바이트의 출력을 C Golden과 비교한다.
3. CPU가 읽은 최종 분류 점수, argmax, 상태값이 일치한다.
4. UART 완료와 계층별/전체 추론 사이클의 일관성을 검사한다.
5. RTL 오류, 시간 초과, 누락된 완료 표식은 실행 실패로 처리한다.

산출물은 이 디렉터리의 `build/verilator/`에 생성한다:

- `compile.log`: 빌드 진단.
- `tool_versions.json`: 실제 사용한 도구 버전과 ISA.
- `results/sample_124.log`, `results/uart_124.log`: RTL/펌웨어 로그.
- `results/results.json`: 모델/ELF/RTL/실행파일 SHA256, 검사 범위, 계층별 사이클.
- `results/cycles.csv`: 반복 실행별 추론 사이클.

사이클 측정은 inference call 구간이며 드라이버, cache, DMA, polling을 포함한다.
LUT 전처리, UART 출력, Checker 검증은 이 측정 구간에서 제외한다.

## 확장 경계

현재 tinyNPU는 INT8 CNN용 CONV/FC 가속기이다. 이 Gate의 PASS는 LLM 실행이나
성능을 입증하지 않는다. 이후에는 CPU/NPU 작업 분담 및 tensor/정밀도 계약을 정하고,
Transformer 연산, KV cache, 큰 tensor의 tiling, 외부 메모리 모델을 단계별로 추가한다.
각 확장은 작은 입력/한 토큰의 Golden 대조에서 시작하고, 대규모 실행 성능은
FPGA 또는 실제 하드웨어에서 검증한다.

Verilator의 2-state 동작은 VCS의 4-state X 전파 검증과 범위가 다르다.
통합 기능 회귀를 먼저 확보하고 reset/미초기화 검증은 별도 조건으로 관리한다.

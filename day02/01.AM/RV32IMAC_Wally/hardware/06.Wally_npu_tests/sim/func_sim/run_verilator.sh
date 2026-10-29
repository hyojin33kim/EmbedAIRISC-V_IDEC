#!/usr/bin/env bash
# Usage: bash run_verilator.sh [SAMPLES=124] [JOBS=2] [RISCV=/path/to/tool-prefix]
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
exec make run-verilator "$@"

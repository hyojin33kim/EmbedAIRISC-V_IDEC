#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec make -C "$repo_root/day02/01.AM/RV32IMAC_Wally/hardware/06.Wally_npu_tests/sim/func_sim" \
  -f Makefile.verilator run "$@"

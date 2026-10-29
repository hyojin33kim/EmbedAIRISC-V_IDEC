#!/usr/bin/env bash
# 32×32 FP32 모델을 기존 학습 조건으로 실행하는 스크립트
set -euo pipefail
lab_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "${PYTHON:-python}" "$lab_dir/train.py" --device cpu --shape-augment \
  --extra-train-dir "$lab_dir/extra_data/train" --extra-repeat 16 --patience 0 "$@"

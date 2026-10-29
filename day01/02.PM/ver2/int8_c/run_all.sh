#!/usr/bin/env bash
set -euo pipefail
lab_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$lab_dir"
lab_python="${PYTHON:-python}"
"$lab_python" export_model.py "$@" --output-dir "$lab_dir"
make check build/libint8_integer.so
"$lab_python" prepare_inputs.py
"$lab_python" validate.py --integer-library build/libint8_integer.so
"$lab_python" verify_native_c.py
"$lab_python" -m unittest test_export -v
make sanitize
"$lab_python" verify_native_c.py --executable build/inference_sanitize --output-dir outputs/native_c/sanitizer
./build/inference_sanitize --input outputs/test_inputs_u8.bin --output outputs/c_predictions_sanitize.csv
cmp outputs/c_predictions_u8.csv outputs/c_predictions_sanitize.csv

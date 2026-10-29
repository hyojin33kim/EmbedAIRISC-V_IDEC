"""동일 checkpoint·분할·test 데이터로 실행한 PTQ/QAT 결과를 비교."""

import argparse
import csv
import json
from pathlib import Path


def main():
    base = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ptq-dir", type=Path, default=base / "outputs")
    parser.add_argument("--qat-dir", type=Path, default=base.parent / "qat/outputs")
    parser.add_argument("--output", type=Path, default=base / "comparison.json")
    args = parser.parse_args()
    ptq, qat = [json.loads((p / "metrics.json").read_text()) for p in [args.ptq_dir, args.qat_dir]]
    for key in ["source_sha256", "backend", "classes"]:
        if ptq[key] != qat[key]:
            raise ValueError(f"Incomparable runs: {key} differs")
    calibration = json.loads((args.ptq_dir / "calibration.json").read_text())
    training = json.loads((args.qat_dir / "data_manifest.json").read_text())
    if calibration["split_sha256"] != training["split_sha256"]:
        raise ValueError("Incomparable runs: original split differs")
    signatures = []
    for folder in [args.ptq_dir, args.qat_dir]:
        with (folder / "fp32_predictions.csv").open() as stream:
            signatures.append([(r["image"], r["true_label"], r["predicted_label"])
                               for r in csv.DictReader(stream)])
    if signatures[0] != signatures[1]:
        raise ValueError("Incomparable runs: test images/labels/FP32 predictions differ")
    rows = []
    for name, result in [("PTQ", ptq), ("QAT", qat)]:
        rows.append({"method": name, "test_accuracy": result["test"]["int8"]["accuracy"],
                     "validation_accuracy": result["validation"]["int8"]["accuracy"],
                     "int8_weight_bytes": result["sizes"]["int8_conv_linear_weight_bytes"],
                     "int8_state_dict_bytes": result["sizes"]["int8_state_dict_bytes"],
                     "cpu_median_ms": (result["benchmark"]["int8"] or {}).get("median_ms"),
                     "reload_equal": result["verification"]["save_reload_all_predictions_equal"]})
    report = {"source_sha256": ptq["source_sha256"], "backend": ptq["backend"],
              "fp32_test_accuracy": ptq["test"]["fp32"]["accuracy"], "test_count": len(signatures[0]),
              "comparable_source_split_test": True, "results": rows}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()

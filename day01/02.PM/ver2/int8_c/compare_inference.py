"""동일 이미지의 FP32/QAT/PTQ/C 추론 CLI를 실행해 logits·확률·예측을 비교."""

import argparse
import csv
import json
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent


def compare_results(results, image):
    classes = results["FP32"]["classes"]
    preprocessing = results["FP32"]["preprocessing"]
    for name, result in results.items():
        if result["classes"] != classes or result["preprocessing"] != preprocessing:
            raise ValueError(f"{name} class mapping/preprocessing differs from FP32")
        if result["model_type"] != name:
            raise ValueError(f"{name} received a {result['model_type']} checkpoint")
    if (results["INT8_C"]["model_sha256"] != results["QAT"]["model_sha256"]
            or results["INT8_C"]["source_method"] != "qat"):
        raise ValueError("C export and QAT checkpoint differ. Export the selected QAT model and rebuild C.")
    for result in results.values():
        result["max_logit_abs_error_vs_fp32"] = max(
            abs(result["logits"][name] - results["FP32"]["logits"][name]) for name in classes)
    return {
        "image": str(image), "device": "cpu", "classes": classes, "results": results,
        "all_predictions_equal": len({r["predicted_label"] for r in results.values()}) == 1,
        "qat_c_max_logit_abs_error": max(abs(results["QAT"]["logits"][name] - results["INT8_C"]["logits"][name])
                                         for name in classes),
        "qat_c_max_probability_abs_error": max(abs(results["QAT"]["probabilities"][name] - results["INT8_C"]["probabilities"][name])
                                               for name in classes),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--device", choices=["cpu", "auto"], default="cpu", help="공정한 비교를 위해 네 모델 모두 CPU")
    parser.add_argument("--output-dir", type=Path, default=BASE / "outputs/single_image_comparison")
    parser.add_argument("--fp32-checkpoint", type=Path, default=BASE.parent / "pytorch/outputs/model_fp32.pth")
    parser.add_argument("--qat-checkpoint", type=Path, default=BASE.parent / "qat/outputs/model_int8.pt")
    parser.add_argument("--ptq-checkpoint", type=Path, default=BASE.parent / "ptq/outputs/model_int8.pt")
    parser.add_argument("--c-executable", type=Path, default=BASE / "build/inference")
    args = parser.parse_args(argv)
    image, output_dir = args.image.resolve(), args.output_dir.resolve()
    if not image.is_file():
        parser.error(f"Image not found: {image}")
    runs = [
        ("FP32", BASE.parent / "pytorch", ["--checkpoint", str(args.fp32_checkpoint.resolve())]),
        ("QAT", BASE.parent / "qat", ["--checkpoint", str(args.qat_checkpoint.resolve())]),
        ("PTQ", BASE.parent / "ptq", ["--checkpoint", str(args.ptq_checkpoint.resolve())]),
        ("INT8_C", BASE, []),
    ]
    results = {}
    for name, folder, extra in runs:
        destination = output_dir / name.lower()
        destination.mkdir(parents=True, exist_ok=True)
        entry = [str(args.c_executable.resolve())] if name == "INT8_C" else [sys.executable, str(folder / "inference.py")]
        command = [*entry, "--device", "cpu", "--image", str(image),
                   "--output-dir", str(destination), *extra]
        process = subprocess.run(command, cwd=folder, capture_output=True, text=True)
        (destination / "inference.log").write_text(process.stdout)
        (destination / "inference.stderr.log").write_text(process.stderr)
        if process.returncode:
            parser.exit(1, f"{name} inference failed:\n{process.stderr}\nLogs: {destination}\n")
        results[name] = json.loads((destination / "prediction.json").read_text())
    try:
        report = compare_results(results, image)
    except ValueError as error:
        parser.exit(1, str(error) + "\n")
    (output_dir / "comparison.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    rows = []
    for name, result in results.items():
        rows.append({"model": name, "device": result["device"], "prediction": result["predicted_label"],
                     "confidence": result["confidence"], "max_logit_abs_error_vs_fp32": result["max_logit_abs_error_vs_fp32"],
                     **{f"probability_{label}": result["probabilities"][label] for label in report["classes"]},
                     **{f"logit_{label}": result["logits"][label] for label in report["classes"]}})
    with (output_dir / "comparison.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    header = f"{'Model':<8} {'Prediction':<10} {'Confidence %':>13}"
    header += "".join(f"{label + ' %':>14}" for label in report["classes"])
    print(f"Image: {image}\nDevice: cpu\n{header}")
    for name, result in results.items():
        line = f"{name:<8} {result['predicted_label']:<10} {result['confidence'] * 100:13.6f}"
        line += "".join(f"{result['probabilities'][label] * 100:14.6f}" for label in report["classes"])
        print(line)
    print(f"QAT/C max logit difference: {report['qat_c_max_logit_abs_error']:.9g}")
    print(f"Results: {output_dir}")


if __name__ == "__main__":
    main()

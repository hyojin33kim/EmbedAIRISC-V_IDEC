"""모든 test의 C ↔ 독립 정수 참조 ↔ PyTorch QAT, header/binary/CLI 입출력 검증."""

import argparse
import csv
import ctypes as ct
import hashlib
import json
import subprocess
import tempfile
import time
from pathlib import Path

import numpy as np
import torch

from export_model import BASE, extract_model
from reference import CRuntime, integer_reference
from quant_common import normalize, setup_runtime


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def verify_arrays(runtime, manifest, layers, export_dir):
    binary = (export_dir / "model_data.bin").read_bytes()
    source = {}
    for layer in layers:
        prefix = "model_" + layer["symbol"]
        source.update({f"{prefix}_weight": layer["weight"], f"{prefix}_weight_scale": layer["weight_scales"],
                       f"{prefix}_weight_zero": layer["weight_zero_points"], f"{prefix}_multiplier": layer["multipliers"],
                       f"{prefix}_right_shift": layer["right_shifts"]})
    for name, digest in manifest["sha256"].items():
        check(hashlib.sha256((export_dir / name).read_bytes()).hexdigest() == digest, f"Modified generated file {name}")
    for entry in manifest["binary_arrays"]:
        dtype = np.dtype(entry["dtype"])
        offset, length = entry["offset"], entry["length"]
        check(offset % manifest["alignment"] == 0, "Binary alignment")
        blob = binary[offset:offset + length]
        check(hashlib.sha256(blob).hexdigest() == entry["sha256"], "Binary array hash mismatch")
        expected = np.asarray(source[entry["name"]], dtype=dtype).reshape(-1)
        decoded = np.frombuffer(blob, dtype=dtype)
        check(np.array_equal(decoded, expected), f"Binary/source mismatch: {entry['name']}")
        ctype = {"i": ct.c_int8 if dtype.itemsize == 1 else ct.c_int32, "f": ct.c_float}[dtype.kind]
        compiled = (ctype * expected.size).in_dll(runtime.lib, entry["name"])
        check(ct.addressof(compiled) % manifest["alignment"] == 0, "Compiled header alignment")
        check(np.array_equal(np.ctypeslib.as_array(compiled), expected), f"Header/source mismatch: {entry['name']}")
    return len(manifest["binary_arrays"])


def run_cli(executable, input_path, kind, output_path):
    process = subprocess.run([str(executable), "--input", str(input_path), "--input-type", kind,
                              "--output", str(output_path)], capture_output=True, text=True, check=True)
    with output_path.open() as stream:
        rows = list(csv.DictReader(stream))
    return rows, process.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=BASE / "model_manifest.json")
    parser.add_argument("--input-dir", type=Path, default=BASE / "outputs")
    parser.add_argument("--output-dir", type=Path, default=BASE / "outputs")
    parser.add_argument("--library", type=Path, default=BASE / "build/libint8_model.so")
    parser.add_argument("--integer-library", type=Path, help="MODEL_INTEGER_ONLY build to compare at every stage")
    parser.add_argument("--executable", type=Path, default=BASE / "build/inference")
    parser.add_argument("--min-agreement", type=float, default=100.0, help="PyTorch와 예측 일치율 통과 기준(%)")
    args = parser.parse_args()
    setup_runtime(42, 4)
    started = time.perf_counter()
    manifest = json.loads(args.manifest.read_text())
    inputs = json.loads((args.input_dir / "input_manifest.json").read_text())
    check(inputs["source_model_sha256"] == manifest["source_sha256"], "Stale inputs; prepare_inputs.py again")
    check(hashlib.sha256(Path(manifest["source_checkpoint"]).read_bytes()).hexdigest() == manifest["source_sha256"],
          "QAT checkpoint changed; re-export/rebuild")
    for name, digest in inputs["files_sha256"].items():
        check(hashlib.sha256((args.input_dir / name).read_bytes()).hexdigest() == digest, f"Input file changed: {name}")
    torch_model, artifact, layers, _, _ = extract_model(manifest["source_checkpoint"])
    runtime = CRuntime(args.library, args.manifest)
    firmware = CRuntime(args.integer_library, args.manifest, integer_only=True) if args.integer_library else None
    array_count = verify_arrays(runtime, manifest, layers, args.manifest.parent)
    n = inputs["count"]
    q_inputs = np.fromfile(args.input_dir / "test_inputs_u8.bin", dtype=np.uint8).reshape(n, *manifest["input_shape"])
    gray = np.fromfile(args.input_dir / "test_inputs_gray8.bin", dtype=np.uint8).reshape(n, *manifest["input_shape"])
    floats = normalize(torch.from_numpy(gray.copy()).float() / 255.0, artifact["preprocessing"]["input_mode"])
    stage_names = [f"features.{3*i+2}" for i in range(artifact["model_config"]["conv_blocks"])]
    stage_names += ["classifier.1", "classifier.3"]
    captured = {}

    def hook(name):
        def capture(_module, _args, output):
            captured[name] = output.int_repr().cpu().numpy().copy()
        return capture

    handles = [torch_model.get_submodule(name).register_forward_hook(hook(name)) for name in stage_names]
    stage_stats = [{"name": layer["name"], "compared_values": 0, "mismatched_values": 0,
                    "max_code_error": 0, "absolute_code_error_sum": 0} for layer in layers]
    predictions, max_code_error, abs_logit_sum, exact_output_count = [], 0, 0.0, 0
    reference_exact, input_exact, gray_exact, c_correct, torch_correct, agreement = 0, 0, 0, 0, 0, 0
    classes = artifact["classes"]
    q_outputs, torch_logits_all = [], []
    try:
        for start in range(0, n, 32):
            with torch.inference_mode():
                expected_input = torch_model.quant(floats[start:start + 32]).int_repr().numpy()
                expected_logits = torch_model(floats[start:start + 32]).numpy()
            for local, sample_index in enumerate(range(start, min(start + 32, n))):
                c_quantized = runtime.quantize(floats[sample_index].numpy())
                c_gray = runtime.gray_to_input(gray[sample_index])
                check(np.array_equal(expected_input[local].reshape(-1), q_inputs[sample_index].reshape(-1)), "Stored input quantization")
                check(np.array_equal(c_quantized, q_inputs[sample_index].reshape(-1)), f"C FP32 input differs at {sample_index}")
                check(np.array_equal(c_gray, c_quantized), f"C gray normalization differs at {sample_index}")
                input_exact += 1
                gray_exact += 1
                c_out, c_trace = runtime.infer(q_inputs[sample_index], trace=True)
                if firmware:
                    check(np.array_equal(firmware.gray_to_input(gray[sample_index]), c_quantized),
                          f"Integer firmware LUT mismatch at {sample_index}")
                    fw_out, fw_trace = firmware.infer(q_inputs[sample_index], trace=True)
                    check(np.array_equal(fw_out, c_out), f"Integer firmware output mismatch at {sample_index}")
                    for index, (fw_stage, c_stage) in enumerate(zip(fw_trace, c_trace)):
                        check(np.array_equal(fw_stage, c_stage), f"Integer firmware stage mismatch {sample_index}/{index}")
                ref_out, ref_trace = integer_reference(q_inputs[sample_index], layers)
                check(np.array_equal(c_out, ref_out), f"C/integer reference output mismatch at {sample_index}")
                for index, (c_stage, ref_stage, name) in enumerate(zip(c_trace, ref_trace, stage_names)):
                    check(np.array_equal(c_stage, ref_stage), f"C/reference stage mismatch {sample_index}/{name}")
                    expected = captured[name][local].reshape(-1)
                    difference = np.abs(c_stage.astype(np.int16) - expected.astype(np.int16))
                    stats = stage_stats[index]
                    stats["compared_values"] += difference.size
                    stats["mismatched_values"] += int(np.count_nonzero(difference))
                    stats["max_code_error"] = max(stats["max_code_error"], int(difference.max()))
                    stats["absolute_code_error_sum"] += int(difference.sum())
                reference_exact += 1
                torch_codes = captured[stage_names[-1]][local].reshape(-1)
                code_error = int(np.abs(c_out.astype(np.int16) - torch_codes.astype(np.int16)).max())
                max_code_error = max(max_code_error, code_error)
                exact_output_count += int(code_error == 0)
                scale = np.float32(layers[-1]["output_scale"])
                c_logits = (c_out.astype(np.int32) - layers[-1]["output_zero_point"]).astype(np.float32) * scale
                logit_error = float(np.abs(c_logits - expected_logits[local]).max())
                abs_logit_sum += float(np.abs(c_logits - expected_logits[local]).sum())
                c_pred, torch_pred = int(c_out.argmax()), int(expected_logits[local].argmax())
                label = inputs["samples"][sample_index]["label"]
                c_correct += int(c_pred == label)
                torch_correct += int(torch_pred == label)
                agreement += int(c_pred == torch_pred)
                predictions.append({"image": inputs["samples"][sample_index]["image"], "label_index": label,
                                    "c_predicted_index": c_pred, "c_label": classes[c_pred],
                                    "pytorch_predicted_index": torch_pred, "pytorch_label": classes[torch_pred],
                                    "max_code_error": code_error, "max_logit_error": logit_error})
                q_outputs.append(c_out)
                torch_logits_all.append(expected_logits[local])
            print(f"Validated {min(start + 32, n)}/{n}", flush=True)
    finally:
        for handle in handles:
            handle.remove()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for kind, filename in [("u8", "test_inputs_u8.bin"), ("gray8", "test_inputs_gray8.bin"), ("f32le", "example_input_f32le.bin")]:
        rows, _ = run_cli(args.executable.resolve(), args.input_dir / filename, kind, args.output_dir / f"c_predictions_{kind}.csv")
        expected_count = 1 if kind == "f32le" else n
        check(len(rows) == expected_count, "CLI record count")
        for i, row in enumerate(rows):
            codes = [int(row[f"q{k}"]) for k in range(len(classes))]
            check(np.array_equal(codes, q_outputs[i]), f"CLI/ctypes differs: {kind}/{i}")
    for i in range(min(n, 8)):
        result = runtime.infer_f32(floats[i].numpy())
        expected = (q_outputs[i].astype(np.int32) - layers[-1]["output_zero_point"]).astype(np.float32) * np.float32(layers[-1]["output_scale"])
        check(np.array_equal(result, expected), "C FP32 wrapper differs from integer core")
    # Representable half-way values and all possible gray bytes, no dependence on process FP rounding mode.
    boundary = (np.arange(np.prod(manifest["input_shape"]), dtype=np.float32) - 256.5) * np.float32(manifest["input_scale"])
    with torch.inference_mode():
        expected = torch_model.quant(torch.from_numpy(boundary)).int_repr().numpy()
    check(np.array_equal(runtime.quantize(boundary), expected), "Input rounding boundary test")
    with tempfile.TemporaryDirectory() as temp:
        bad = Path(temp) / "truncated.bin"
        bad.write_bytes(b"\x00")
        check(subprocess.run([str(args.executable.resolve()), "--input", str(bad)], capture_output=True).returncode != 0,
              "CLI must reject partial records")
        bad.write_bytes(b"")
        check(subprocess.run([str(args.executable.resolve()), "--input", str(bad)], capture_output=True).returncode != 0,
              "CLI must reject empty input")
    labeled = sum(sample["label"] is not None for sample in inputs["samples"])
    report = {
        "source_checkpoint": manifest["source_checkpoint"], "source_sha256": manifest["source_sha256"],
        "torch_version": str(torch.__version__), "count": n, "labeled_count": labeled, "classes": classes,
        "weight_arrays_and_parameters_verified": array_count,
        "header_binary_source_arrays_equal": True, "compiled_alignment_verified": True,
        "c_vs_integer_reference_all_stages_exact_images": reference_exact,
        "c_fp32_input_quantization_exact_images": input_exact, "c_gray8_input_exact_images": gray_exact,
        "c_vs_pytorch_prediction_agreement_percent": 100 * agreement / n,
        "c_correct": c_correct, "c_accuracy_percent": 100 * c_correct / labeled if labeled else None,
        "pytorch_correct": torch_correct, "pytorch_accuracy_percent": 100 * torch_correct / labeled if labeled else None,
        "c_vs_pytorch_exact_output_images": exact_output_count, "max_output_code_error": max_code_error,
        "max_logit_abs_error": max(row["max_logit_error"] for row in predictions),
        "logit_mean_absolute_error": abs_logit_sum / (n * len(classes)),
        "stage_errors_vs_pytorch": stage_stats, "cli_u8_gray8_f32le_passed": True,
        "float_wrapper_passed": True, "input_rounding_boundaries_passed": True,
        "truncated_empty_input_rejected": True, "weight_bytes": manifest["weight_bytes"],
        "workspace_bytes": runtime.workspace_size, "validation_seconds": time.perf_counter() - started,
        "integer_only_all_stages_and_lut_exact_images": n if firmware else None,
    }
    (args.output_dir / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    with (args.output_dir / "comparison.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(predictions[0]))
        writer.writeheader()
        writer.writerows(predictions)
    np.save(args.output_dir / "c_output_codes.npy", np.stack(q_outputs))
    np.save(args.output_dir / "pytorch_logits.npy", np.stack(torch_logits_all))
    print(json.dumps({key: value for key, value in report.items() if key != "stage_errors_vs_pytorch"}, indent=2))
    check(report["c_vs_pytorch_prediction_agreement_percent"] >= args.min_agreement,
          "Prediction agreement below requested threshold; inspect comparison.csv and per-layer errors")


if __name__ == "__main__":
    main()

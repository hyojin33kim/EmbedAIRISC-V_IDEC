"""PTQ/QAT의 실제 INT8 모델을 CPU에서 단일 이미지 또는 폴더로 추론."""

import argparse
import json
from pathlib import Path

import torch

from quant_common import (
    DEFAULT_DATA_ROOT, CachedImages, ImageSubset, evaluate, load_int8, loader,
    normalize, prediction_rows, read_grayscale, setup_runtime, summary, write_csv, write_json,
)
from inference_utils import (
    add_device_argument, file_sha256, inference_device, prediction_result, print_prediction,
)


def main(default_model=None, argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", "--checkpoint", dest="model", type=Path,
                        default=default_model or Path(__file__).resolve().parent / "outputs/model_int8.pt")
    inputs = parser.add_mutually_exclusive_group()
    inputs.add_argument("--image", type=Path)
    inputs.add_argument("--data-dir", type=Path)
    add_device_argument(parser, default="cpu", cpu_only=True)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--num-threads", type=int, default=4)
    args = parser.parse_args(argv)
    if args.batch_size < 1 or args.num_threads < 1:
        parser.error("batch-size and num-threads must be positive")
    device = inference_device(parser, args.device, cpu_only=True)
    setup_runtime(42, args.num_threads)
    model, artifact = load_int8(args.model)
    mode, classes = artifact["preprocessing"]["input_mode"], artifact["classes"]
    if args.image is not None:
        x = normalize(read_grayscale(args.image), mode).unsqueeze(0)
        with torch.inference_mode():
            logits = model(x)[0]
        result = prediction_result(
            logits, classes, args.image, device, artifact["method"].upper(), "PyTorch INT8",
            checkpoint=args.model, model_sha256=file_sha256(args.model),
            preprocessing=artifact["preprocessing"],
        )
        print_prediction(result)
        if args.output_dir:
            write_json(args.output_dir / "prediction.json", result)
    else:
        data = CachedImages(args.data_dir or DEFAULT_DATA_ROOT / "test", expected_classes=classes)
        batches = loader(ImageSubset(data, range(len(data.samples)), input_mode=mode), args.batch_size)
        result = evaluate(model, batches, device, len(classes))
        print(f"Model: {artifact['method'].upper()}; Device: {device}; Checkpoint: {args.model.resolve()}")
        print(json.dumps(summary(result), indent=2))
        if args.output_dir:
            write_json(args.output_dir / "metrics.json", {"device": str(device), "classes": classes, **summary(result)})
            write_csv(args.output_dir / "predictions.csv", prediction_rows(data, result))

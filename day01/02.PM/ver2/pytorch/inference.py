"""단일 영상 추론 또는 클래스 폴더 평가. CPU / GPU checkpoint 호환."""

import argparse
from pathlib import Path

import torch
from torch.utils.data import DataLoader

from data import IMAGE_SIZE, DEFAULT_DATA_ROOT, CachedImages, ImageSubset, normalize, read_grayscale
from model import CNNSimpleNet
from utils import evaluate, prediction_rows, setup_runtime, summary, write_csv, write_json
from inference_utils import (
    add_device_argument, file_sha256, inference_device, prediction_result, print_prediction,
)

BASE = Path(__file__).resolve().parent


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="FP32 PyTorch: " + __doc__)
    parser.add_argument("--checkpoint", "--model", dest="checkpoint", type=Path,
                        default=BASE / "outputs" / "model_fp32.pth")
    inputs = parser.add_mutually_exclusive_group()
    inputs.add_argument("--image", type=Path, help="단일 이미지 경로")
    inputs.add_argument("--data-dir", type=Path, help="paper/rock/scissors 하위 폴더가 있는 경로")
    add_device_argument(parser)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--num-threads", type=int, default=4)
    parser.add_argument("--output-dir", type=Path, help="선택: 평가 JSON 및 예측 CSV 저장 경로")
    args = parser.parse_args(argv)
    if args.batch_size < 1 or args.num_threads < 1:
        parser.error("batch-size and num-threads must be positive.")
    args.resolved_device = inference_device(parser, args.device)
    return args


def main(argv=None):
    args = parse_args(argv)
    setup_runtime(seed=42, num_threads=args.num_threads)
    device = args.resolved_device
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    expected = {"image_size": IMAGE_SIZE, "channels": 1,
                "alpha_background": "white", "resize": "bilinear"}
    preprocessing = checkpoint.get("preprocessing", {})
    input_mode = preprocessing.get("input_mode", "signed")
    if (checkpoint.get("format_version") != 2
            or checkpoint.get("model_name") != "CNNSimpleNet"
            or any(preprocessing.get(k) != v for k, v in expected.items())
            or input_mode not in {"foreground", "signed"}):
        raise ValueError("Expected a plain-CNN checkpoint (format_version=2) from the current train.py.")
    classes = checkpoint["classes"]
    model = CNNSimpleNet(**checkpoint["model_config"])
    model.load_state_dict(checkpoint["state_dict"])
    model.to(device).eval()
    if args.image is not None:
        x = normalize(read_grayscale(args.image), input_mode).unsqueeze(0).to(device)
        with torch.inference_mode():
            logits = model(x)[0].cpu()
        result = prediction_result(
            logits, classes, args.image, device, "FP32", "PyTorch",
            checkpoint=args.checkpoint, model_sha256=file_sha256(args.checkpoint),
            preprocessing=preprocessing,
        )
        print_prediction(result)
        if args.output_dir:
            write_json(args.output_dir / "prediction.json", result)
        return

    print(f"Device: {device}; selected epoch: {checkpoint['epoch']}; classes: {classes}")
    data_dir = args.data_dir if args.data_dir is not None else DEFAULT_DATA_ROOT / "test"
    data = CachedImages(data_dir, expected_classes=classes)
    loader = DataLoader(ImageSubset(data, range(len(data.samples)), input_mode=input_mode), batch_size=args.batch_size,
                        shuffle=False, pin_memory=device.type == "cuda")
    result = evaluate(model, loader, device, len(classes))
    print(f"Accuracy: {result['accuracy']:.4f}% ({result['correct']}/{result['count']})")
    print(f"Cross-entropy loss: {result['loss']:.6f}")
    print("Confusion matrix (rows=true, columns=predicted):")
    print("                " + " ".join(f"{name:>10}" for name in classes))
    for name, row in zip(classes, result["confusion_matrix"]):
        print(f"{name:>14}: " + " ".join(f"{count:>10}" for count in row))
    if args.output_dir:
        write_json(args.output_dir / "metrics.json", {
            "device": str(device), "classes": classes, **summary(result),
        })
        write_csv(args.output_dir / "predictions.csv", prediction_rows(data, result))


if __name__ == "__main__":
    main()

"""FP32/PTQ/QAT/C 단일 이미지 추론의 공통 device 옵션과 출력 형식."""

import hashlib
from pathlib import Path

import torch

from utils import resolve_device


def add_device_argument(parser, default="auto", cpu_only=False):
    parser.add_argument(
        "--device", choices=["auto", "cpu", "cuda"], default=default,
        help=("INT8 추론은 cpu/auto에서 CPU 실행; cuda는 지원하지 않음" if cpu_only
              else "추론 장치: cpu/cuda/auto"),
    )


def inference_device(parser, name, cpu_only=False):
    if cpu_only:
        if name == "cuda":
            parser.error("INT8 inference supports CPU only. Use --device cpu or --device auto.")
        return torch.device("cpu")
    try:
        return resolve_device(name)
    except ValueError as error:
        parser.error(str(error))


def file_sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def prediction_result(logits, classes, image, device, model_type, runtime, *,
                      checkpoint, model_sha256, preprocessing):
    """확률은 공통 FP32 softmax. Logits는 각 추론 엔진의 실제 출력."""
    values = torch.as_tensor(logits, dtype=torch.float32).detach().cpu().reshape(-1)
    if len(values) != len(classes) or not torch.isfinite(values).all():
        raise ValueError("Expected finite logits with one value per class")
    probabilities = values.softmax(dim=0)
    predicted = int(values.argmax())
    return {
        "image": str(image), "device": str(device), "model_type": model_type,
        "runtime": runtime, "checkpoint": str(Path(checkpoint).resolve()),
        "model_sha256": model_sha256, "classes": list(classes),
        "preprocessing": preprocessing, "predicted_index": predicted,
        "predicted_label": classes[predicted], "confidence": float(probabilities[predicted]),
        "probabilities": {name: float(probabilities[i]) for i, name in enumerate(classes)},
        "logits": {name: float(values[i]) for i, name in enumerate(classes)},
    }


def print_prediction(result):
    print(f"Model: {result['model_type']}; Device: {result['device']}; Runtime: {result['runtime']}")
    print(f"Checkpoint: {result['checkpoint']}")
    print(f"Prediction: {result['predicted_label']} ({100 * result['confidence']:.4f}%)")
    for name in result["classes"]:
        print(f"  {name}: {100 * result['probabilities'][name]:.6f}% "
              f"(logit={result['logits'][name]:.9g})")

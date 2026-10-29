"""장치 선택, 재현성, 평가와 결과 파일 저장."""

import csv
import json
import os
import random
from pathlib import Path

import numpy as np
import torch
from torch import nn


def resolve_device(name: str) -> torch.device:
    if name == "auto":
        name = "cuda" if torch.cuda.is_available() else "cpu"
    if name == "cuda" and not torch.cuda.is_available():
        raise ValueError("CUDA is unavailable. Use --device cpu or install CUDA-enabled PyTorch.")
    return torch.device(name)


def setup_runtime(seed: int, num_threads: int):
    if num_threads < 1:
        raise ValueError("--num-threads must be at least 1.")
    os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)
    torch.set_num_threads(num_threads)
    torch.backends.cudnn.benchmark = False
    torch.backends.cudnn.deterministic = True
    torch.use_deterministic_algorithms(True)
    # 저장 모델과 실행 연산 모두 FP32로 유지 (TF32 / AMP 사용 안 함).
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False


def seed_worker(worker_id: int):
    worker_seed = torch.initial_seed() % (2**32)
    np.random.seed(worker_seed)
    random.seed(worker_seed)


@torch.inference_mode()
def evaluate(model, loader, device: torch.device, num_classes: int):
    """model.eval()에서 증강 없는 데이터의 sample 평균 loss와 accuracy 계산."""
    model.eval()
    criterion = nn.CrossEntropyLoss(reduction="sum")
    loss_sum = 0.0
    correct = 0
    confusion = torch.zeros(num_classes, num_classes, dtype=torch.int64)
    predicted, probabilities, labels = [], [], []
    for x, y in loader:
        x, y = x.to(device), y.to(device)
        logits = model(x)
        loss_sum += criterion(logits, y).item()
        prediction = logits.argmax(dim=1)
        correct += (prediction == y).sum().item()
        flat = (y * num_classes + prediction).cpu()
        confusion += torch.bincount(flat, minlength=num_classes**2).reshape(
            num_classes, num_classes
        )
        predicted.extend(prediction.cpu().tolist())
        labels.extend(y.cpu().tolist())
        probabilities.extend(logits.softmax(dim=1).cpu().tolist())
    count = len(labels)
    if count == 0:
        raise ValueError("Cannot evaluate an empty dataset.")
    return {
        "loss": loss_sum / count,
        "accuracy": 100.0 * correct / count,
        "correct": correct,
        "count": count,
        "confusion_matrix": confusion.tolist(),  # 행=true, 열=predicted
        "predicted": predicted,
        "labels": labels,
        "probabilities": probabilities,
    }


def summary(result: dict) -> dict:
    return {k: v for k, v in result.items() if k not in {
        "predicted", "labels", "probabilities"
    }}


def write_json(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def write_csv(path: Path, rows: list[dict]):
    if not rows:
        raise ValueError("Cannot write an empty CSV.")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def prediction_rows(data, result: dict) -> list[dict]:
    rows = []
    for (path, _), label, pred, scores in zip(
        data.samples, result["labels"], result["predicted"], result["probabilities"]
    ):
        row = {
            "image": str(Path(path).relative_to(data.root)),
            "true_label": data.classes[label],
            "predicted_label": data.classes[pred],
            "confidence": scores[pred],
            "correct": label == pred,
        }
        row.update({f"p_{name}": scores[i] for i, name in enumerate(data.classes)})
        rows.append(row)
    return rows


@torch.inference_mode()
def describe_model(model: nn.Module) -> dict:
    """가속기에 필요한 계층별 형상과 Conv/FC MAC 수를 기록."""
    allowed = (nn.Conv2d, nn.ReLU, nn.MaxPool2d, nn.Flatten, nn.Linear)
    layers, hooks = [], []

    def record(name):
        def hook(module, inputs, output):
            row = {
                "name": name, "operator": type(module).__name__,
                "input_shape": list(inputs[0].shape), "output_shape": list(output.shape),
                "parameters": sum(p.numel() for p in module.parameters()), "macs": 0,
            }
            if isinstance(module, nn.Conv2d):
                row["bias"] = module.bias is not None
                row["kernel_size"] = list(module.kernel_size)
                row["stride"] = list(module.stride)
                row["padding"] = list(module.padding)
                row["weight_shape"] = list(module.weight.shape)
                row["macs"] = output.numel() * module.weight[0].numel()
            elif isinstance(module, nn.Linear):
                row["bias"] = module.bias is not None
                row["weight_shape"] = list(module.weight.shape)
                row["macs"] = output.numel() * module.in_features
            layers.append(row)
        return hook

    for name, module in model.named_modules():
        if list(module.children()):
            continue
        if not isinstance(module, allowed):
            raise ValueError(f"Unsupported accelerator operator: {name}: {type(module).__name__}")
        hooks.append(module.register_forward_hook(record(name)))
    was_training = model.training
    try:
        model.eval()
        model(torch.zeros(1, 1, 64, 64, device=next(model.parameters()).device))
    finally:
        for hook in hooks:
            hook.remove()
        model.train(was_training)
    parameters = sum(p.numel() for p in model.parameters())
    return {
        "input_shape": [1, 1, 64, 64], "output_shape": layers[-1]["output_shape"],
        "output": "class logits; softmax is outside model",
        "parameter_count": parameters, "fp32_parameter_bytes": parameters * 4,
        "macs_per_image": sum(row["macs"] for row in layers),
        "mac_scope": "Conv/Linear only; excludes bias additions, ReLU and pooling comparisons",
        "operators": sorted({row["operator"] for row in layers}), "layers": layers,
    }

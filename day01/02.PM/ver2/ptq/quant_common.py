"""PTQ/QAT가 공유하는 원본 모델, 데이터 분할, INT8 저장/평가 도구."""

import hashlib
import io
import json
import platform
import sys
import time
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.ao import quantization as aq
from torch.utils.data import ConcatDataset, DataLoader

BASE = Path(__file__).resolve().parent
PYTORCH = BASE.parent / "pytorch"
sys.path.insert(0, str(PYTORCH))
from data import (  # noqa: E402
    IMAGE_SIZE, DEFAULT_DATA_ROOT, CachedImages, ImageSubset, normalize, read_grayscale,
)
from model import CNNSimpleNet  # noqa: E402
from utils import (  # noqa: E402
    evaluate, prediction_rows, resolve_device, setup_runtime as _setup_runtime,
    summary, write_csv, write_json,
)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def setup_runtime(seed, num_threads):
    _setup_runtime(seed, num_threads)
    # PyTorch 2.14 quantized_resize_cpu_는 strict deterministic 모드를 지원하지 않는다.
    # seed/CUDNN 설정은 유지하되 INT8 실습에서 strict 결정성은 요구하지 않는다.
    torch.use_deterministic_algorithms(False)


def add_arguments(parser, output_dir):
    parser.add_argument("--checkpoint", type=Path, default=PYTORCH / "outputs/model_fp32.pth")
    parser.add_argument("--split", type=Path, help="생략하면 checkpoint와 같은 폴더의 split.json")
    parser.add_argument("--data-root", type=Path, default=DEFAULT_DATA_ROOT)
    parser.add_argument("--output-dir", type=Path, default=output_dir)
    parser.add_argument("--backend", choices=["auto", "x86", "fbgemm", "qnnpack"], default="auto")
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--num-threads", type=int, default=4)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--benchmark-runs", type=int, default=50,
                        help="CPU batch=1 시간 측정 반복 수, 0이면 생략")


def initialize(args):
    if args.batch_size < 1 or args.num_threads < 1 or args.benchmark_runs < 0:
        raise ValueError("batch-size/num-threads > 0, benchmark-runs >= 0 required")
    setup_runtime(args.seed, args.num_threads)
    args.output_dir = args.output_dir.resolve()
    if args.output_dir == args.checkpoint.resolve().parent:
        raise ValueError("Use a separate output directory to preserve the FP32 artifacts.")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    return select_backend(args.backend)


def select_backend(name):
    supported = torch.backends.quantized.supported_engines
    if name == "auto":
        name = next((v for v in ("x86", "fbgemm", "qnnpack") if v in supported), None)
    if name not in supported:
        raise ValueError(f"INT8 backend {name!r} unavailable; supported={supported}")
    torch.backends.quantized.engine = name
    return name


def load_fp32(path):
    checkpoint = torch.load(path, map_location="cpu", weights_only=True)
    preprocessing = checkpoint.get("preprocessing", {})
    expected = {"image_size": IMAGE_SIZE, "channels": 1, "alpha_background": "white", "resize": "bilinear"}
    if (checkpoint.get("format_version") != 2
            or checkpoint.get("model_name") != "CNNSimpleNet"
            or any(preprocessing.get(k) != v for k, v in expected.items())
            or preprocessing.get("input_mode") not in {"foreground", "signed"}):
        raise ValueError("Expected the current pytorch/train.py format_version=2 checkpoint.")
    if checkpoint["class_to_idx"] != {name: i for i, name in enumerate(checkpoint["classes"])}:
        raise ValueError("Checkpoint class mapping is inconsistent.")
    model = CNNSimpleNet(**checkpoint["model_config"])
    model.load_state_dict(checkpoint["state_dict"], strict=True)
    return checkpoint, model.eval()


class QuantizableCNN(CNNSimpleNet):
    """기존 계층 이름/weight를 유지하고 모델 입출력에 Q/DQ 경계를 추가."""

    def __init__(self, **config):
        super().__init__(**config)
        self.quant = aq.QuantStub()
        self.dequant = aq.DeQuantStub()

    def forward(self, x):
        x = self.quant(x)
        x = self.classifier(self.features(x))
        return self.dequant(x)

    def fuse(self):
        pairs = [[f"features.{i}", f"features.{i + 1}"]
                 for i in range(0, len(self.features), 3)]
        pairs.append(["classifier.1", "classifier.2"])
        aq.fuse_modules(self, pairs, inplace=True)


def prepare_model(checkpoint, backend, qat=False):
    model = QuantizableCNN(**checkpoint["model_config"])
    model.load_state_dict(checkpoint["state_dict"], strict=True)
    model.eval()
    model.fuse()  # Conv+ReLU, Linear+ReLU; 수치/계층 이름은 유지
    model.qconfig = (aq.get_default_qat_qconfig(backend) if qat
                     else aq.get_default_qconfig(backend))
    if qat:
        model.train()
        aq.prepare_qat(model, inplace=True)
    else:
        aq.prepare(model, inplace=True)
    return model


def load_partitions(args, checkpoint):
    """새로 분할하지 않고 원본 split.json의 경로 목록을 검증해 재사용."""
    split_path = args.split or args.checkpoint.parent / "split.json"
    manifest = json.loads(split_path.read_text(encoding="utf-8"))
    data = CachedImages(args.data_root / "train", expected_classes=checkpoint["classes"])
    if manifest["class_to_idx"] != data.class_to_idx:
        raise ValueError("split.json class mapping differs from checkpoint/dataset.")
    names = [str(Path(p).relative_to(data.root)) for p, _ in data.samples]
    lookup = {name: i for i, name in enumerate(names)}
    train_names, val_names = manifest["train"], manifest["validation"]
    train_set, val_set = set(train_names), set(val_names)
    if (not train_names or not val_names or train_set & val_set
            or len(train_set) != len(train_names) or len(val_set) != len(val_names)
            or train_set | val_set != set(lookup)):
        raise ValueError("split.json must partition all train images without overlap/duplicates.")
    train_indices = [lookup[name] for name in train_names]
    val_indices = [lookup[name] for name in val_names]
    mode = checkpoint["preprocessing"]["input_mode"]
    train_eval = ImageSubset(data, train_indices, input_mode=mode)
    validation = ImageSubset(data, val_indices, input_mode=mode)
    return data, train_indices, train_eval, validation, manifest, split_path


def loader(dataset, batch_size, shuffle=False, seed=42):
    return DataLoader(dataset, batch_size=batch_size, shuffle=shuffle, num_workers=0,
                      generator=torch.Generator().manual_seed(seed))


def balanced_indices(targets, count, seed):
    """클래스별 무작위 순서를 round-robin으로 뽑아 작은 calibration도 균형 유지."""
    if count < 1 or count > len(targets):
        raise ValueError(f"calibration-samples must be in [1, {len(targets)}]")
    rng = np.random.default_rng(seed)
    groups = [list(rng.permutation(np.flatnonzero(np.asarray(targets) == label)))
              for label in sorted(set(targets))]
    result = []
    while len(result) < count:
        for group in groups:
            if group and len(result) < count:
                result.append(int(group.pop()))
    return result


@torch.no_grad()
def calibrate(model, batches):
    model.eval()
    count = 0
    for x, _ in batches:
        model(x.cpu())  # label/gradient/optimizer 없이 activation 범위만 관찰
        count += len(x)
    if not count:
        raise ValueError("Calibration requires at least one image.")
    return count


def qat_training_data(args, checkpoint, data, indices, manifest):
    mode = checkpoint["preprocessing"]["input_mode"]
    train = ImageSubset(data, indices, augment=not args.no_augment,
                        shape_augment=True, input_mode=mode)
    extra_names = manifest.get("extra_train", [])
    repeat = int(manifest.get("extra_repeat", 1))
    if not extra_names:
        return train
    if repeat < 1 or len(set(extra_names)) != len(extra_names):
        raise ValueError("Invalid extra_train/extra_repeat in split.json")
    extra = CachedImages(args.extra_train_dir, expected_classes=checkpoint["classes"])
    lookup = {str(Path(p).relative_to(extra.root)): i for i, (p, _) in enumerate(extra.samples)}
    if not set(extra_names) <= set(lookup):
        raise ValueError("Missing extra training images; check --extra-train-dir.")
    extra_train = ImageSubset(extra, [lookup[p] for p in extra_names],
                              augment=not args.no_augment, shape_augment=True, input_mode=mode)
    return ConcatDataset([train] + [extra_train] * repeat)


def tensor_stats(weight):
    weight = weight.detach().cpu().float()
    return {"shape": list(weight.shape), "count": weight.numel(),
            "min": weight.min().item(), "max": weight.max().item(),
            "mean": weight.mean().item(), "std": weight.std(unbiased=False).item()}


def symmetric_quantize(weight):
    """입문 수식: signed [-127, 127], per-tensor, zero_point=0; all-zero 예외 처리."""
    weight = weight.detach().cpu().float()
    max_abs = weight.abs().max().item()
    scale = max_abs / 127 if max_abs > 0 else 1.0
    q = torch.round(weight / scale).clamp(-127, 127).to(torch.int8)
    dq = q.float() * scale
    return q, scale, dq


def weight_exercise(model, checkpoint_path, output_dir, layer="classifier.1", print_weight=False):
    """수동 양자화 weight 묶음. 이 파일만으로 INT8 실행 모델이 되지는 않음."""
    tensors, statistics = {}, {}
    modules = dict(model.named_modules())
    if layer not in modules or not isinstance(modules[layer], (nn.Conv2d, nn.Linear)):
        raise ValueError(f"--layer must be a Conv/Linear name: {layer}")
    for name, module in modules.items():
        if not isinstance(module, (nn.Conv2d, nn.Linear)):
            continue
        w = module.weight.detach().cpu()
        q, scale, dq = symmetric_quantize(w)
        tensors[name] = {"int_repr": q, "scale": scale, "zero_point": 0}
        error = (w - dq).abs()
        statistics[name] = {
            "fp32": tensor_stats(w), "int8": tensor_stats(q), "dequantized": tensor_stats(dq),
            "scale": scale, "zero_point": 0, "mae": error.mean().item(),
            "max_abs_error": error.max().item(), "rmse": (error.square().mean()).sqrt().item(),
            "fp32_weight_bytes": w.numel() * 4, "int8_weight_bytes": q.numel(),
        }
    torch.save({"format_version": 1, "kind": "manual_symmetric_weight_only",
                "source_sha256": sha256(checkpoint_path), "qmin": -127, "qmax": 127,
                "layers": tensors}, output_dir / "model_int8_weight.pt")
    write_json(output_dir / "weight_statistics.json", statistics)
    w = modules[layer].weight.detach().cpu()
    q, scale, dq = symmetric_quantize(w)
    write_csv(output_dir / "weight_samples.csv", [
        {"flat_index": i, "fp32": a, "int8": b, "dequantized": c, "abs_error": abs(a - c)}
        for i, (a, b, c) in enumerate(zip(w.flatten().tolist()[:64], q.flatten().tolist()[:64],
                                         dq.flatten().tolist()[:64]))
    ])
    print(f"[Weight] {layer}: {json.dumps(statistics[layer], ensure_ascii=False)}", flush=True)
    if print_weight:
        print("FP32:\n", w, "\nINT8:\n", q, "\nDequantized:\n", dq)
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, axes = plt.subplots(1, 3, figsize=(12, 3.5))
    for ax, value, title in zip(axes, [w, q, dq], ["FP32", "INT8 [-127, 127]", "Dequantized"]):
        ax.hist(value.flatten().numpy(), bins=60)
        ax.set_title(f"{layer}: {title}")
        ax.set_xlabel("Weight")
        ax.set_ylabel("Count")
    fig.tight_layout()
    fig.savefig(output_dir / "weight_comparison.png", dpi=150)
    plt.close(fig)
    return statistics


def quantized_layers(model, reference):
    """실제 packed INT8 weight를 꺼내어 scale/zero_point/오차를 검증·기록."""
    rows, tensors = [], {}
    for name, original in reference.named_modules():
        if not isinstance(original, (nn.Conv2d, nn.Linear)):
            continue
        module = model.get_submodule(name)
        weight = module.weight()
        if not weight.is_quantized or weight.dtype != torch.qint8:
            raise AssertionError(f"{name} was not converted to qint8")
        if weight.qscheme() in (torch.per_channel_affine, torch.per_channel_symmetric):
            scales, zeros = weight.q_per_channel_scales(), weight.q_per_channel_zero_points()
            axis = weight.q_per_channel_axis()
        else:
            scales, zeros, axis = torch.tensor([weight.q_scale()]), torch.tensor([weight.q_zero_point()]), None
        tensors[name] = {"int_repr": weight.int_repr(), "scales": scales,
                         "zero_points": zeros, "axis": axis, "shape": list(weight.shape)}
        error = (original.weight.detach().cpu() - weight.dequantize()).abs()
        rows.append({"name": name, "module": type(module).__name__, "dtype": str(weight.dtype),
                     "qscheme": str(weight.qscheme()), "axis": axis,
                     "scales": scales.tolist(), "zero_points": zeros.tolist(),
                     "activation_scale": float(module.scale), "activation_zero_point": int(module.zero_point),
                     "mae_vs_reference": error.mean().item(), "max_abs_error_vs_reference": error.max().item(),
                     "fp32_weight_bytes": weight.numel() * 4, "int8_weight_bytes": weight.numel()})
    return rows, tensors


@torch.no_grad()
def floating_reference(prepared, checkpoint):
    """Fusion/QAT 모듈에서 학습 weight를 꺼내 원래 FP32 구조로 복원."""
    reference = CNNSimpleNet(**checkpoint["model_config"])
    for name, module in reference.named_modules():
        if isinstance(module, (nn.Conv2d, nn.Linear)):
            source = prepared.get_submodule(name)
            if not hasattr(source, "weight"):
                source = source[0]  # PTQ의 fused ConvReLU2d/LinearReLU
            module.weight.copy_(source.weight.detach().cpu())
            if module.bias is not None:
                module.bias.copy_(source.bias.detach().cpu())
    return reference.eval()


def save_int8(model, checkpoint, backend, method, path):
    torch.save({"format_version": 1, "kind": "eager_static_int8_cnn", "method": method,
                "backend": backend, "model_config": checkpoint["model_config"],
                "classes": checkpoint["classes"], "class_to_idx": checkpoint["class_to_idx"],
                "preprocessing": checkpoint["preprocessing"], "state_dict": model.state_dict(),
                "torch_version": str(torch.__version__)}, path)


def load_int8(path):
    artifact = torch.load(path, map_location="cpu", weights_only=True)
    if artifact.get("kind") != "eager_static_int8_cnn" or artifact.get("format_version") != 1:
        raise ValueError("Expected model_int8.pt from this PTQ/QAT exercise.")
    if artifact["preprocessing"]["image_size"] != IMAGE_SIZE:
        raise ValueError(f"Expected {IMAGE_SIZE}x{IMAGE_SIZE} INT8 checkpoint preprocessing.")
    backend = select_backend(artifact["backend"])
    model = QuantizableCNN(**artifact["model_config"]).eval()
    model.fuse()
    model.qconfig = aq.get_default_qconfig(backend)
    # 로드 대상 구조를 먼저 만든다. 이 임시 scale/zero_point는 저장값으로 전부 교체된다.
    aq.prepare(model, inplace=True)
    with torch.no_grad():
        model(torch.zeros(1, 1, IMAGE_SIZE, IMAGE_SIZE))
    aq.convert(model, inplace=True)
    model.load_state_dict(artifact["state_dict"], strict=True)
    return model.eval(), artifact


@torch.inference_mode()
def benchmark(model, sample, runs):
    if not runs:
        return None
    model.eval()
    for _ in range(10):
        model(sample)
    times = []
    for _ in range(runs):
        started = time.perf_counter()
        model(sample)
        times.append((time.perf_counter() - started) * 1000)
    return {"batch_size": 1, "device": "cpu", "runs": runs, "warmup": 10,
            "median_ms": float(np.median(times)), "mean_ms": float(np.mean(times))}


def finish(model, fp32, checkpoint, args, backend, method, validation, reference=None):
    """실제 변환·디스크 왕복·전체 test 평가. test는 학습/calibration/선택 이후 처음 연다."""
    path = args.output_dir / "model_int8.pt"
    model = model.cpu().eval()
    save_int8(model, checkpoint, backend, method, path)
    restored, _ = load_int8(path)
    test_data = CachedImages(args.data_root / "test", expected_classes=checkpoint["classes"])
    test_set = ImageSubset(test_data, range(len(test_data.samples)),
                           input_mode=checkpoint["preprocessing"]["input_mode"])
    test_loader = loader(test_set, args.batch_size)
    n_classes = len(checkpoint["classes"])
    cpu = torch.device("cpu")
    fp32_result = evaluate(fp32, test_loader, cpu, n_classes)
    original_result = evaluate(model, test_loader, cpu, n_classes)
    int8_result = evaluate(restored, test_loader, cpu, n_classes)
    max_logit_error = 0.0
    with torch.inference_mode():
        for x, _ in test_loader:
            a, b = model(x), restored(x)
            if not torch.isfinite(a).all() or not torch.isfinite(b).all():
                raise AssertionError("Nonfinite INT8 logits")
            max_logit_error = max(max_logit_error, (a - b).abs().max().item())
    if max_logit_error != 0 or original_result["predicted"] != int8_result["predicted"]:
        raise AssertionError("Saved/reloaded INT8 predictions differ")
    layers, weights = quantized_layers(restored, reference if reference is not None else fp32)
    torch.save({"kind": "backend_int8_weights", "method": method, "layers": weights},
               args.output_dir / "backend_int8_weights.pt")
    write_json(args.output_dir / "quantization_parameters.json", layers)
    write_csv(args.output_dir / "fp32_predictions.csv", prediction_rows(test_data, fp32_result))
    write_csv(args.output_dir / "int8_predictions.csv", prediction_rows(test_data, int8_result))
    val_loader = loader(validation, args.batch_size)
    # 순수 state_dict 직렬화 크기도 같은 방식으로 비교한다.
    fp_buffer, q_buffer = io.BytesIO(), io.BytesIO()
    torch.save(fp32.state_dict(), fp_buffer)
    torch.save(restored.state_dict(), q_buffer)
    metrics = {
        "method": method, "backend": backend, "inference_device": "cpu",
        "source_checkpoint": str(args.checkpoint.resolve()), "source_sha256": sha256(args.checkpoint),
        "source_epoch": checkpoint["epoch"], "classes": checkpoint["classes"],
        "versions": {"python": platform.python_version(), "torch": str(torch.__version__),
                     "platform": platform.platform()},
        "determinism": "seeded; deterministic_algorithms=False for INT8 kernel support; CUDNN deterministic=True",
        "config": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
        "validation": {"fp32": summary(evaluate(fp32, val_loader, cpu, n_classes)),
                       "int8": summary(evaluate(restored, val_loader, cpu, n_classes))},
        "test": {"fp32": summary(fp32_result), "int8": summary(int8_result)},
        "accuracy_drop_percentage_points": fp32_result["accuracy"] - int8_result["accuracy"],
        "test_prediction_agreement_percent": 100 * sum(a == b for a, b in zip(
            fp32_result["predicted"], int8_result["predicted"])) / int8_result["count"],
        "sizes": {"fp32_conv_linear_weight_bytes": sum(x["fp32_weight_bytes"] for x in layers),
                  "int8_conv_linear_weight_bytes": sum(x["int8_weight_bytes"] for x in layers),
                  "fp32_state_dict_bytes": len(fp_buffer.getvalue()),
                  "int8_state_dict_bytes": len(q_buffer.getvalue()),
                  "source_checkpoint_file_bytes": args.checkpoint.stat().st_size,
                  "int8_checkpoint_file_bytes": path.stat().st_size},
        "benchmark": {"fp32": benchmark(fp32, test_set[0][0].unsqueeze(0), args.benchmark_runs),
                      "int8": benchmark(restored, test_set[0][0].unsqueeze(0), args.benchmark_runs)},
        "verification": {"all_conv_linear_weights_qint8": True, "quantized_layer_count": len(layers),
                         "save_reload_max_logit_error": max_logit_error,
                         "save_reload_all_predictions_equal": True},
    }
    write_json(args.output_dir / "metrics.json", metrics)
    print(f"[{method.upper()}] test FP32={fp32_result['accuracy']:.4f}% "
          f"INT8={int8_result['accuracy']:.4f}% ({int8_result['correct']}/{int8_result['count']})", flush=True)
    print(f"Artifacts: {args.output_dir}", flush=True)
    return metrics

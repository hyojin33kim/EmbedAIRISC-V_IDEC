"""기존 FP32 checkpoint → fake quant 준비 → 미세조정 → CPU INT8 변환."""

import argparse
import copy
import sys
import time
from pathlib import Path

import torch
from torch import nn
from torch.ao import quantization as aq

BASE = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE.parent / "ptq"))
from quant_common import (  # noqa: E402
    PYTORCH, add_arguments, finish, floating_reference, initialize, load_fp32,
    load_partitions, loader, prepare_model, qat_training_data, resolve_device,
    evaluate, sha256, summary, weight_exercise, write_csv, write_json,
)


def train_one_epoch(model, batches, optimizer, device):
    """Fake quant의 STE를 통해 FP32 master weight에 gradient 전달."""
    model.train()
    criterion = nn.CrossEntropyLoss()
    loss_sum, correct, count = 0.0, 0, 0
    for x, y in batches:
        x, y = x.to(device), y.to(device)
        optimizer.zero_grad(set_to_none=True)
        logits = model(x)
        loss = criterion(logits, y)
        if not torch.isfinite(loss):
            raise RuntimeError("Nonfinite QAT loss")
        loss.backward()
        optimizer.step()
        loss_sum += loss.item() * len(y)
        correct += (logits.argmax(1) == y).sum().item()
        count += len(y)
    return {"loss": loss_sum / count, "accuracy": 100 * correct / count, "count": count}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    add_arguments(parser, BASE / "outputs")
    parser.add_argument("--device", choices=["cpu", "cuda", "auto"], default="cpu",
                        help="QAT 학습 장치. 변환과 INT8 추론은 항상 CPU")
    parser.add_argument("--epochs", type=int, default=5)
    parser.add_argument("--lr", type=float, default=1e-5)
    parser.add_argument("--freeze-observer-epoch", type=int, default=3,
                        help="이 epoch 시작부터 range 고정. 0이면 학습 끝까지 갱신")
    parser.add_argument("--extra-train-dir", type=Path, default=PYTORCH / "extra_data/train")
    parser.add_argument("--no-augment", action="store_true")
    args = parser.parse_args()
    if args.epochs < 1 or args.lr <= 0 or args.freeze_observer_epoch < 0:
        parser.error("epochs/lr > 0, freeze-observer-epoch >= 0 required")
    backend = initialize(args)
    device = resolve_device(args.device)

    print("Step 1. 기존 checkpoint와 동일 train/validation 분할 로드", flush=True)
    checkpoint, fp32 = load_fp32(args.checkpoint)
    data, indices, _, validation, manifest, split_path = load_partitions(args, checkpoint)
    train_set = qat_training_data(args, checkpoint, data, indices, manifest)
    train_loader = loader(train_set, args.batch_size, shuffle=True, seed=args.seed)
    val_loader = loader(validation, args.batch_size)
    write_json(args.output_dir / "data_manifest.json", {
        "source_checkpoint_sha256": sha256(args.checkpoint),
        "source_split": str(split_path.resolve()), "split_sha256": sha256(split_path),
        "train": manifest["train"], "validation": manifest["validation"],
        "extra_train": manifest.get("extra_train", []), "extra_train_root": str(args.extra_train_dir.resolve()),
        "extra_repeat": manifest.get("extra_repeat", 0), "samples_per_epoch": len(train_set),
        "validation_train_overlap": 0, "test_used_for_training_or_selection": False,
    })

    print(f"Step 2. Fuse + prepare_qat: FP32 master weight / fake quant (device={device})", flush=True)
    model = prepare_model(checkpoint, backend, qat=True).to(device)
    initial_reference = floating_reference(model, checkpoint)
    if any(not torch.equal(param, fp32.get_parameter(name))
           for name, param in initial_reference.named_parameters()):
        raise AssertionError("QAT did not start from the supplied weights")
    (args.output_dir / "prepared_model.txt").write_text(str(model) + "\n", encoding="utf-8")
    optimizer = torch.optim.Adam(model.parameters(), lr=args.lr, weight_decay=0)
    best_key, best_state, best_epoch = None, None, None
    history = []
    print("Step 3. QAT 미세조정; 실제 INT8 validation으로 epoch 선택", flush=True)
    for epoch in range(1, args.epochs + 1):
        started = time.perf_counter()
        frozen = bool(args.freeze_observer_epoch and epoch >= args.freeze_observer_epoch)
        if frozen:
            model.apply(aq.disable_observer)  # fake quant는 계속 켜져 있다.
        optimization = train_one_epoch(model, train_loader, optimizer, device)
        # eval()만으로 observer가 꺼지지 않는다. 복사본을 고정해 validation 누수 방지.
        candidate = copy.deepcopy(model).cpu().eval()
        candidate.apply(aq.disable_observer)
        fake_val = evaluate(candidate, val_loader, torch.device("cpu"), len(checkpoint["classes"]))
        converted = aq.convert(candidate, inplace=False)
        int8_val = evaluate(converted, val_loader, torch.device("cpu"), len(checkpoint["classes"]))
        key = (int8_val["accuracy"], -int8_val["loss"])
        if best_key is None or key > best_key:
            best_key, best_epoch = key, epoch
            best_state = copy.deepcopy(candidate.state_dict())
        row = {"epoch": epoch, "lr": args.lr, "optimization_loss": optimization["loss"],
               "optimization_accuracy": optimization["accuracy"], "samples": optimization["count"],
               "fake_quant_validation_loss": fake_val["loss"], "fake_quant_validation_accuracy": fake_val["accuracy"],
               "int8_validation_loss": int8_val["loss"], "int8_validation_accuracy": int8_val["accuracy"],
               "observers_frozen": frozen, "seconds": time.perf_counter() - started}
        history.append(row)
        print(f"epoch {epoch}/{args.epochs}: train loss={optimization['loss']:.6f}, "
              f"fake-val={fake_val['accuracy']:.4f}%, int8-val={int8_val['accuracy']:.4f}%, "
              f"observer_frozen={frozen}", flush=True)
    write_csv(args.output_dir / "history.csv", history)

    print(f"Step 4. 선택 epoch={best_epoch}; observer 고정 → eval → CPU convert", flush=True)
    model = model.cpu().eval()
    model.load_state_dict(best_state, strict=True)
    model.apply(aq.disable_observer)
    reference = floating_reference(model, checkpoint)
    change = sum((param - fp32.get_parameter(name)).abs().sum().item()
                 for name, param in reference.named_parameters()) / sum(p.numel() for p in reference.parameters())
    torch.save({"kind": "qat_prepared_state", "state_dict": best_state,
                "source_checkpoint_sha256": sha256(args.checkpoint), "backend": backend,
                "model_config": checkpoint["model_config"], "best_epoch": best_epoch},
               args.output_dir / "model_qat_prepared.pt")
    # Fake quant를 제거한 미세조정 FP32 모델도 원본 format으로 저장.
    finetuned = {**checkpoint, "state_dict": reference.state_dict(), "epoch": best_epoch,
                 "qat_epoch": best_epoch, "source_fp32_epoch": checkpoint["epoch"],
                 "validation": summary(evaluate(reference, val_loader, torch.device("cpu"), len(checkpoint["classes"])))}
    torch.save(finetuned, args.output_dir / "model_qat_fp32.pth")
    weight_exercise(reference, args.output_dir / "model_qat_fp32.pth", args.output_dir)
    int8 = aq.convert(model, inplace=False)
    (args.output_dir / "int8_model.txt").write_text(str(int8) + "\n", encoding="utf-8")
    print("Step 5. INT8 저장/재로드 및 최종 test 평가", flush=True)
    metrics = finish(int8, fp32, checkpoint, args, backend, "qat", validation, reference=reference)
    metrics["qat"] = {"training_device": str(device), "epochs": args.epochs, "best_epoch": best_epoch,
                      "selection": "actual INT8 validation accuracy, then lower loss",
                      "started_from_source_weights": True, "mean_abs_weight_change": change,
                      "parameters_changed": change > 0, "history": history,
                      "weight_error_reference": "finetuned FP32 master weights"}
    write_json(args.output_dir / "metrics.json", metrics)
    plot_history(history, args.output_dir)


def plot_history(history, output_dir):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, axes = plt.subplots(1, 2, figsize=(10, 3.5))
    epochs = [r["epoch"] for r in history]
    for key in ["optimization_loss", "int8_validation_loss"]:
        axes[0].plot(epochs, [r[key] for r in history], marker="o", label=key)
    for key in ["optimization_accuracy", "fake_quant_validation_accuracy", "int8_validation_accuracy"]:
        axes[1].plot(epochs, [r[key] for r in history], marker="o", label=key)
    for ax, title in zip(axes, ["Loss", "Accuracy (%)"]):
        ax.set(xlabel="QAT epoch", ylabel=title)
        ax.legend(fontsize=7)
        ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(output_dir / "qat_history.png", dpi=150)
    plt.close(fig)


if __name__ == "__main__":
    main()

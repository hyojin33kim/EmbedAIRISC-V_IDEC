"""RPS 학습: python train.py --device cuda (또는 cpu/auto)."""

import argparse
import time
from pathlib import Path

import torch
from torch import nn
from torch.utils.data import ConcatDataset, DataLoader

from data import IMAGE_SIZE, DEFAULT_DATA_ROOT, CachedImages, ImageSubset, grouped_split, stratified_split
from model import CNNSimpleNet
from plots import save_plots
from utils import (
    describe_model, evaluate, prediction_rows, resolve_device, seed_worker, setup_runtime,
    summary, write_csv, write_json,
)

DEFAULT_OUTPUT = Path(__file__).resolve().parent / "outputs"


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", type=Path, default=DEFAULT_DATA_ROOT)
    parser.add_argument("--extra-train-dir", type=Path,
                        help="선택: 추가 학습용 클래스 폴더 (validation/test에는 포함하지 않음)")
    parser.add_argument("--extra-repeat", type=int, default=4,
                        help="추가 이미지의 학습 반복 수. 평가에는 각 이미지를 한 번만 사용")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--device", choices=["auto", "cpu", "cuda"], default="auto")
    parser.add_argument("--epochs", type=int, default=150)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--lr", type=float, default=0.001)
    parser.add_argument("--base-channels", type=int, default=8)
    parser.add_argument("--hidden-dim", type=int, default=32)
    parser.add_argument("--conv-blocks", type=int, choices=[3, 4, 5], default=4)
    parser.add_argument("--use-bias", action="store_true", help="선택: Conv/FC bias 추가")
    parser.add_argument("--input-mode", choices=["foreground", "signed"], default="foreground")
    parser.add_argument("--val-ratio", type=float, default=0.2)
    parser.add_argument("--split-mode", choices=["group", "random"], default="group",
                        help="group: 촬영 시퀀스 단위 분리, random: 이미지 단위 계층화 분리")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--num-workers", type=int, default=0)
    parser.add_argument("--num-threads", type=int, default=4)
    parser.add_argument("--patience", type=int, default=40,
                        help="Validation 모델 개선이 없는 epoch 수. 0이면 조기 종료 안 함.")
    parser.add_argument("--no-augment", action="store_true")
    parser.add_argument("--shape-augment", action="store_true",
                        help="학습 전용 손가락 틈 채움·실루엣 증강")
    parser.add_argument("--skip-test", action="store_true",
                        help="개발 중 validation만 평가하고 test는 읽지 않음")
    args = parser.parse_args()
    if args.epochs < 1 or args.batch_size < 1 or args.lr <= 0:
        parser.error("epochs, batch-size and lr must be positive.")
    if args.num_workers < 0 or args.patience < 0:
        parser.error("num-workers and patience must be nonnegative.")
    if args.base_channels < 1 or args.hidden_dim < 1:
        parser.error("base-channels and hidden-dim must be positive.")
    if args.extra_repeat < 1:
        parser.error("extra-repeat must be positive.")
    return args


def train_one_epoch(model, loader, criterion, optimizer, device):
    """교육용 기본 루프: zero_grad → forward → loss → backward → step."""
    model.train()
    loss_sum, correct, count = 0.0, 0, 0
    for x, y in loader:
        x, y = x.to(device), y.to(device)
        optimizer.zero_grad()
        output = model(x)
        loss = criterion(output, y)
        loss.backward()
        optimizer.step()
        loss_sum += loss.item() * y.size(0)
        correct += (output.argmax(dim=1) == y).sum().item()
        count += y.size(0)
    return loss_sum / count, 100.0 * correct / count


def cpu_state(model):
    return {name: tensor.detach().cpu().clone() for name, tensor in model.state_dict().items()}


def main():
    args = parse_args()
    setup_runtime(args.seed, args.num_threads)
    device = resolve_device(args.device)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    print(f"Device: {device}; PyTorch: {torch.__version__}; seed: {args.seed}", flush=True)
    print(f"Loading train images into RAM (grayscale, {IMAGE_SIZE}x{IMAGE_SIZE})...", flush=True)
    data = CachedImages(args.data_root / "train")
    if args.split_mode == "group":
        train_indices, val_indices = grouped_split(data.samples, args.val_ratio, args.seed)
    else:
        train_indices, val_indices = stratified_split(data.targets, args.val_ratio, args.seed)
    datasets = {
        "train": ImageSubset(data, train_indices, augment=not args.no_augment,
                             input_mode=args.input_mode, shape_augment=args.shape_augment),
        "train_eval": ImageSubset(data, train_indices, input_mode=args.input_mode),
        "val": ImageSubset(data, val_indices, input_mode=args.input_mode),
    }
    extra_data = None
    if args.extra_train_dir is not None:
        extra_data = CachedImages(args.extra_train_dir, expected_classes=data.classes)
        extra_indices = range(len(extra_data.samples))
        extra_training = ImageSubset(extra_data, extra_indices, augment=not args.no_augment,
                                     input_mode=args.input_mode, shape_augment=args.shape_augment)
        datasets["train"] = ConcatDataset(
            [datasets["train"]] + [extra_training] * args.extra_repeat
        )
        datasets["train_eval"] = ConcatDataset([
            datasets["train_eval"], ImageSubset(extra_data, extra_indices, input_mode=args.input_mode),
        ])
    generator = torch.Generator().manual_seed(args.seed)

    def make_loader(dataset, shuffle=False):
        return DataLoader(
            dataset, batch_size=args.batch_size, shuffle=shuffle,
            num_workers=args.num_workers, pin_memory=device.type == "cuda",
            worker_init_fn=seed_worker,
            generator=generator if shuffle else None,
            persistent_workers=args.num_workers > 0,
            multiprocessing_context="spawn" if args.num_workers > 0 else None,
        )

    loaders = {name: make_loader(dataset, shuffle=name == "train")
               for name, dataset in datasets.items()}
    manifest = {
        "seed": args.seed, "val_ratio": args.val_ratio, "split_mode": args.split_mode,
        "actual_val_ratio": len(val_indices) / len(data.samples),
        "class_to_idx": data.class_to_idx,
        "train": [str(Path(data.samples[i][0]).relative_to(data.root)) for i in train_indices],
        "validation": [str(Path(data.samples[i][0]).relative_to(data.root)) for i in val_indices],
        "extra_train_root": str(args.extra_train_dir) if extra_data is not None else None,
        "extra_train": [str(Path(p).relative_to(extra_data.root)) for p, _ in extra_data.samples]
                       if extra_data is not None else [],
        "extra_repeat": args.extra_repeat if extra_data is not None else 0,
    }
    write_json(args.output_dir / "split.json", manifest)
    model_config = {"num_classes": len(data.classes),
                    "base_channels": args.base_channels, "hidden_dim": args.hidden_dim,
                    "conv_blocks": args.conv_blocks, "bias": args.use_bias}
    model = CNNSimpleNet(**model_config).to(device)
    criterion = nn.CrossEntropyLoss()
    optimizer = torch.optim.Adam(model.parameters(), lr=args.lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
        optimizer, T_max=args.epochs, eta_min=args.lr * 0.05
    )
    initial_state = cpu_state(model)
    parameter_count = sum(p.numel() for p in model.parameters())
    write_json(args.output_dir / "model_summary.json", describe_model(model))
    print(f"Classes: {data.class_to_idx}; train={len(datasets['train_eval'])}, "
          f"val={len(val_indices)}; extra={len(extra_data.samples) if extra_data else 0}", flush=True)
    print(f"Parameters: {parameter_count:,}; augmentation: {not args.no_augment}", flush=True)
    best_key = (-1.0, float("-inf"))
    best_epoch, stale_epochs = 0, 0
    history = []
    training_started = time.perf_counter()

    for epoch in range(1, args.epochs + 1):
        epoch_started = time.perf_counter()
        lr = optimizer.param_groups[0]["lr"]
        optimization_loss, optimization_accuracy = train_one_epoch(
            model, loaders["train"], criterion, optimizer, device
        )
        train = evaluate(model, loaders["train_eval"], device, len(data.classes))
        val = evaluate(model, loaders["val"], device, len(data.classes))
        current_state = cpu_state(model)
        row = {
            "epoch": epoch, "lr": lr,
            "optimization_loss": optimization_loss,
            "optimization_accuracy": optimization_accuracy,
            "train_loss": train["loss"], "train_accuracy": train["accuracy"],
            "val_loss": val["loss"], "val_accuracy": val["accuracy"],
            "seconds": time.perf_counter() - epoch_started,
        }
        for name, tensor in current_state.items():
            if name.endswith("weight"):
                row[f"weight_delta/{name}"] = (tensor - initial_state[name]).abs().mean().item()
        history.append(row)
        write_csv(args.output_dir / "history.csv", history)

        # Test에 접근하지 않고, validation accuracy 우선 / 동률이면 loss로 선택.
        key = (val["accuracy"], -val["loss"])
        improved = key > best_key
        if improved:
            best_key, best_epoch, stale_epochs = key, epoch, 0
            torch.save({
                "format_version": 2,
                "model_name": "CNNSimpleNet",
                "model_config": model_config,
                "state_dict": current_state,
                "classes": data.classes,
                "class_to_idx": data.class_to_idx,
                "preprocessing": {
                    "image_size": IMAGE_SIZE, "channels": 1,
                    "alpha_background": "white", "input_mode": args.input_mode,
                    **({"mean": 0.5, "std": 0.5} if args.input_mode == "signed" else {}),
                    "resize": "bilinear",
                },
                "epoch": best_epoch, "seed": args.seed,
                "validation": summary(val),
                "torch_version": str(torch.__version__),
            }, args.output_dir / "model_fp32.pth")
        else:
            stale_epochs += 1
        print(
            f"Epoch {epoch:03d}/{args.epochs} | "
            f"train loss={train['loss']:.5f} acc={train['accuracy']:.2f}% | "
            f"val loss={val['loss']:.5f} acc={val['accuracy']:.2f}% | "
            f"{row['seconds']:.2f}s{' *' if improved else ''}", flush=True,
        )
        scheduler.step()
        if args.patience and stale_epochs >= args.patience:
            print(f"Early stopping: {args.patience} epochs without validation improvement.", flush=True)
            break

    training_seconds = time.perf_counter() - training_started
    checkpoint = torch.load(args.output_dir / "model_fp32.pth", map_location="cpu", weights_only=True)
    model.load_state_dict(checkpoint["state_dict"])
    train = evaluate(model, loaders["train_eval"], device, len(data.classes))
    val = evaluate(model, loaders["val"], device, len(data.classes))
    test = None
    if not args.skip_test:
        print(f"Selected epoch {best_epoch}. Loading test split for final evaluation...", flush=True)
        test_data = CachedImages(args.data_root / "test", expected_classes=data.classes)
        test_loader = make_loader(ImageSubset(test_data, range(len(test_data.samples)),
                                             input_mode=args.input_mode))
        test = evaluate(model, test_loader, device, len(data.classes))
        write_csv(args.output_dir / "test_predictions.csv", prediction_rows(test_data, test))
    metrics = {
        "device": str(device), "seed": args.seed, "parameter_count": parameter_count,
        "best_epoch": best_epoch, "epochs_completed": len(history),
        "original_train_count": len(train_indices),
        "extra_train_count": len(extra_data.samples) if extra_data is not None else 0,
        "training_samples_per_epoch": len(datasets["train"]),
        "training_seconds": training_seconds,
        "train": summary(train), "validation": summary(val),
        "test": summary(test) if test is not None else None,
        "target_accuracy": 99.0,
        "target_met": (train["accuracy"] >= 99.0 and test["accuracy"] >= 99.0)
                      if test is not None else None,
        "classes": data.classes,
        "config": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
        "versions": {"torch": str(torch.__version__)},
    }
    save_plots(history, initial_state, checkpoint["state_dict"], best_epoch, test, args.output_dir)
    metrics["total_seconds"] = time.perf_counter() - started
    write_json(args.output_dir / "metrics.json", metrics)
    test_text = (f"test={test['accuracy']:.4f}% ({test['correct']}/{test['count']})"
                 if test is not None else "test=skipped")
    print(
        f"Final: train={train['accuracy']:.4f}%, val={val['accuracy']:.4f}%, "
        f"{test_text}\n"
        f"99% train/test target met: {metrics['target_met']}\n"
        f"Training: {training_seconds:.1f}s; total: {metrics['total_seconds']:.1f}s\n"
        f"Artifacts: {args.output_dir.resolve()}", flush=True,
    )


if __name__ == "__main__":
    main()

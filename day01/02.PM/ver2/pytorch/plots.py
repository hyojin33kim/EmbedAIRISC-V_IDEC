"""GUI 없는 서버에서도 PNG 그래프를 저장."""

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


def save_plots(history, initial_state, best_state, best_epoch, test, output: Path):
    plt.rcParams.update({"figure.dpi": 140, "font.size": 10})
    epochs = [row["epoch"] for row in history]

    for metric, ylabel, filename in [
        ("loss", "Cross-entropy loss", "training_loss.png"),
        ("accuracy", "Accuracy (%)", "accuracy.png"),
    ]:
        fig, ax = plt.subplots(figsize=(8, 4.5))
        ax.plot(epochs, [r[f"train_{metric}"] for r in history], label="Train (eval mode)")
        ax.plot(epochs, [r[f"val_{metric}"] for r in history], label="Validation")
        ax.axvline(best_epoch, color="gray", linestyle="--", alpha=0.7,
                   label=f"Selected epoch: {best_epoch}")
        if test is not None:
            ax.scatter([best_epoch], [test[metric]], color="black", marker="*", s=130,
                       zorder=5, label=f"Final test: {test[metric]:.4f}")
        if metric == "accuracy":
            ax.axhline(99, color="green", linestyle=":", alpha=0.7, label="99% target")
            ax.set_ylim(0, 102)
        ax.set(xlabel="Epoch", ylabel=ylabel)
        ax.grid(alpha=0.25)
        ax.legend(fontsize=8)
        fig.tight_layout()
        fig.savefig(output / filename)
        plt.close(fig)

    names = [name for name, tensor in best_state.items()
             if name.endswith("weight") and tensor.ndim > 1]
    columns = 2
    rows = (len(names) + columns - 1) // columns
    fig, axes = plt.subplots(rows, columns, figsize=(10, 3 * rows), squeeze=False)
    for ax, name in zip(axes.flat, names):
        before = initial_state[name].numpy().ravel()
        after = best_state[name].numpy().ravel()
        bins = np.linspace(min(before.min(), after.min()), max(before.max(), after.max()), 61)
        ax.hist(before, bins=bins, density=True, alpha=0.5, label="Initial")
        ax.hist(after, bins=bins, density=True, alpha=0.5, label=f"Epoch {best_epoch}")
        ax.set(title=name, xlabel="Weight (FP32)", ylabel="Density")
        ax.legend(fontsize=8)
        ax.grid(alpha=0.2)
    for ax in list(axes.flat)[len(names):]:
        ax.set_visible(False)
    fig.suptitle("Weight distribution: initial vs selected model")
    fig.tight_layout()
    fig.savefig(output / "weight_histogram.png")
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(8, 4.5))
    for name in names:
        ax.plot(epochs, [r[f"weight_delta/{name}"] for r in history], label=name)
    ax.set(xlabel="Epoch", ylabel="Mean absolute change from initial weights")
    ax.grid(alpha=0.25)
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(output / "weight_change.png")
    plt.close(fig)


def main():
    """학습을 반복하지 않고 CSV/checkpoint/metrics에서 그래프를 다시 생성."""
    import argparse
    import csv
    import json

    import torch

    from model import CNNSimpleNet
    from utils import setup_runtime

    parser = argparse.ArgumentParser(description=main.__doc__)
    parser.add_argument("--output-dir", type=Path,
                        default=Path(__file__).resolve().parent / "outputs")
    args = parser.parse_args()
    output = args.output_dir
    checkpoint = torch.load(output / "model_fp32.pth", map_location="cpu", weights_only=True)
    if checkpoint.get("format_version") != 2:
        raise ValueError("Expected a plain-CNN checkpoint (format_version=2) from the current train.py.")
    setup_runtime(checkpoint["seed"], num_threads=1)
    initial = CNNSimpleNet(**checkpoint["model_config"]).state_dict()
    with (output / "history.csv").open(newline="", encoding="utf-8") as handle:
        history = [{k: float(v) for k, v in row.items()} for row in csv.DictReader(handle)]
    metrics = json.loads((output / "metrics.json").read_text(encoding="utf-8"))
    save_plots(history, initial, checkpoint["state_dict"], checkpoint["epoch"],
               metrics.get("test"), output)
    print(f"Saved four graphs to {output.resolve()}")


if __name__ == "__main__":
    main()

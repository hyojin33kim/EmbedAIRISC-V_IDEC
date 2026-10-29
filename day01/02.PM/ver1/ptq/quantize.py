"""FP32 weight 관찰 → 수동 INT8 → calibration → 실제 static PTQ."""

import argparse
from pathlib import Path

import torch
from torch.ao import quantization as aq
from torch.utils.data import Subset

from quant_common import (
    add_arguments, balanced_indices, calibrate, finish, floating_reference, initialize, load_fp32,
    load_partitions, loader, prepare_model, sha256, weight_exercise, write_json,
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    add_arguments(parser, Path(__file__).resolve().parent / "outputs")
    parser.add_argument("--stage", choices=["weights", "all"], default="all")
    parser.add_argument("--calibration-samples", type=int, default=256)
    parser.add_argument("--layer", default="classifier.1", help="수동 weight 비교/그래프 대상")
    parser.add_argument("--print-weight", action="store_true")
    args = parser.parse_args()
    backend = initialize(args)

    print("Step 1. 기존 학습 checkpoint 로드 / FP32 weight 통계", flush=True)
    checkpoint, fp32 = load_fp32(args.checkpoint)
    weight_exercise(fp32, args.checkpoint, args.output_dir, args.layer, args.print_weight)
    if args.stage == "weights":
        return

    print("Step 2. 원본 분할에서 train 전용 calibration 이미지 선택", flush=True)
    data, indices, train_eval, validation, manifest, split_path = load_partitions(args, checkpoint)
    selected = balanced_indices([int(data.targets[i]) for i in indices], args.calibration_samples, args.seed)
    calibration = Subset(train_eval, selected)
    paths = [manifest["train"][i] for i in selected]
    assert not set(paths) & set(manifest["validation"])
    write_json(args.output_dir / "calibration.json", {
        "source_split": str(split_path.resolve()), "split_sha256": sha256(split_path),
        "seed": args.seed, "count": len(paths), "source": "original_train_only",
        "paths": paths, "validation_overlap": 0, "test_used": False,
        "class_counts": {name: sum(p.split('/')[0] == name for p in paths) for name in checkpoint["classes"]},
    })

    print(f"Step 3. Fuse + prepare (backend={backend})", flush=True)
    prepared = prepare_model(checkpoint, backend)
    (args.output_dir / "prepared_model.txt").write_text(str(prepared) + "\n", encoding="utf-8")
    print("Step 4. Calibration: forward만 실행, weight 업데이트 없음", flush=True)
    calibrate(prepared, loader(calibration, args.batch_size))
    print("Step 5. convert → 실제 CPU INT8 Conv/Linear", flush=True)
    int8 = aq.convert(prepared.eval(), inplace=False)
    reference = floating_reference(prepared, checkpoint)
    for name, param in reference.named_parameters():
        if not torch.equal(param, fp32.get_parameter(name)):
            raise AssertionError(f"PTQ unexpectedly changed {name}")
    (args.output_dir / "int8_model.txt").write_text(str(int8) + "\n", encoding="utf-8")
    print("Step 6. 저장/재로드, 전체 test 평가, 크기·CPU 시간 측정", flush=True)
    finish(int8, fp32, checkpoint, args, backend, "ptq", validation)


if __name__ == "__main__":
    main()

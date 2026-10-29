"""기존 Pillow 전처리로 test/단일 이미지를 C용 UINT8·gray8·little-endian FP32로 저장."""

import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np
import torch

from export_model import BASE
sys.path.insert(0, str(BASE.parent / "ptq"))
from quant_common import (  # noqa: E402
    DEFAULT_DATA_ROOT, CachedImages, load_int8, normalize, read_grayscale, setup_runtime,
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=BASE / "model_manifest.json")
    inputs = parser.add_mutually_exclusive_group()
    inputs.add_argument("--data-dir", type=Path)
    inputs.add_argument("--image", type=Path)
    parser.add_argument("--output-dir", type=Path, default=BASE / "outputs")
    parser.add_argument("--limit", type=int, default=0, help="0=전체 이미지")
    args = parser.parse_args()
    if args.limit < 0:
        parser.error("limit must be nonnegative")
    manifest = json.loads(args.manifest.read_text())
    setup_runtime(42, 4)
    checkpoint = Path(manifest["source_checkpoint"])
    if hashlib.sha256(checkpoint.read_bytes()).hexdigest() != manifest["source_sha256"]:
        raise ValueError("QAT checkpoint changed; run export_model.py again, then rebuild C")
    model, artifact = load_int8(checkpoint)
    mode, classes = artifact["preprocessing"]["input_mode"], artifact["classes"]
    if args.image:
        images = read_grayscale(args.image).unsqueeze(0)
        samples = [{"image": str(args.image.resolve()), "label": classes.index(args.image.parent.name)
                    if args.image.parent.name in classes else None}]
    else:
        data = CachedImages(args.data_dir or DEFAULT_DATA_ROOT / "test", expected_classes=classes)
        count = args.limit or len(data.samples)
        images = data.images[:count]
        samples = [{"image": str(Path(p).resolve()), "label": int(label)} for p, label in data.samples[:count]]
    gray = (images * 255).round().to(torch.uint8)
    reconstructed = gray.float() / 255.0
    if not torch.equal(images, reconstructed):
        raise AssertionError("gray8 round trip changed preprocessed pixels")
    normalized = normalize(images, mode)
    with torch.inference_mode():
        quantized = model.quant(normalized).int_repr().numpy()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    files = {
        "test_inputs_u8.bin": quantized.astype(np.uint8).tobytes(),
        "test_inputs_gray8.bin": gray.numpy().tobytes(),
        "example_input_u8.bin": quantized[0].tobytes(),
        "example_input_gray8.bin": gray[0].numpy().tobytes(),
        "example_input_f32le.bin": normalized[0].numpy().astype("<f4").tobytes(),
    }
    for name, blob in files.items():
        (args.output_dir / name).write_bytes(blob)
    input_manifest = {
        "source_model_sha256": manifest["source_sha256"], "classes": classes,
        "input_shape": manifest["input_shape"], "count": len(samples), "samples": samples,
        "preprocessing": artifact["preprocessing"], "input_scale": manifest["input_scale"],
        "input_zero_point": manifest["input_zero_point"], "record_bytes_u8": quantized[0].nbytes,
        "record_bytes_f32le": normalized[0].numel() * 4,
        "files_sha256": {name: hashlib.sha256(blob).hexdigest() for name, blob in files.items()},
    }
    (args.output_dir / "input_manifest.json").write_text(json.dumps(input_manifest, indent=2) + "\n")
    print(f"Prepared {len(samples)} images → {args.output_dir.resolve()}")


if __name__ == "__main__":
    main()

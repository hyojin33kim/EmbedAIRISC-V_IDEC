"""저자가 공개한 RPS 예측 예제를 추가 학습용으로 준비 (CC BY 2.0)."""

import argparse
import hashlib
import io
import re
from pathlib import Path
from urllib.request import urlopen
from zipfile import ZipFile

import torch
from PIL import Image

from data import IMAGE_SIZE, DEFAULT_DATA_ROOT, read_grayscale
from utils import write_json

BASE = Path(__file__).resolve().parent
SOURCE = "https://storage.googleapis.com/learning-datasets/rps-validation.zip"
SHA256 = "b532690f8124dd105cb919a7f99b79c30d33b5ec68c254e6f5a79ee59a9f5555"


def pixel_hash(image):
    image = image.convert("RGBA")
    return hashlib.sha256(str(image.size).encode() + image.tobytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", type=Path, default=DEFAULT_DATA_ROOT)
    parser.add_argument("--output-dir", type=Path, default=BASE / "extra_data")
    parser.add_argument("--archive", type=Path, help="선택: 이미 내려받은 ZIP")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    archive = args.archive or args.output_dir / "rps-author-examples.zip"
    if args.archive is not None and not archive.is_file():
        raise FileNotFoundError(f"Archive not found: {archive}")
    if not archive.exists():
        print(f"Downloading {SOURCE}", flush=True)
        with urlopen(SOURCE, timeout=30) as response:
            archive.write_bytes(response.read())
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise ValueError("Archive SHA256 mismatch; no images were imported.")

    print("Auditing overlap with original train/test images...", flush=True)
    existing_hashes = set()
    existing_paths = sorted(p for p in args.data_root.rglob("*.png"))
    if not existing_paths:
        raise FileNotFoundError(f"Original PNG dataset not found: {args.data_root}")
    for path in existing_paths:
        with Image.open(path) as image:
            existing_hashes.add(pixel_hash(image))
    existing_images = torch.stack([read_grayscale(path).flatten() for path in existing_paths])
    imported, excluded = [], []
    pattern = re.compile(r"^(paper|rock|scissors)(?:-hires)?\d+\.png$")
    for name in ["paper", "rock", "scissors"]:
        (args.output_dir / "train" / name).mkdir(parents=True, exist_ok=True)
    with ZipFile(archive) as handle:
        for member in sorted(handle.namelist()):
            match = pattern.fullmatch(member)
            if match is None:
                continue
            category = match.group(1)
            raw = handle.read(member)
            destination = args.output_dir / "train" / category / member
            with Image.open(io.BytesIO(raw)) as image:
                exact_duplicate = pixel_hash(image) in existing_hashes
            # ZIP 경로를 그대로 추출하지 않고 검증된 파일명만 사용.
            destination.write_bytes(raw)
            gray = read_grayscale(destination).flatten()
            distances = (existing_images - gray).abs().mean(dim=1)
            nearest = int(distances.argmin())
            nearest_mae = float(distances[nearest])
            if exact_duplicate or nearest_mae < 0.001:
                destination.unlink()
                excluded.append({"file": member, "nearest_original": str(existing_paths[nearest]),
                                 f"mae_{IMAGE_SIZE}x{IMAGE_SIZE}": nearest_mae})
            else:
                imported.append({"file": str(destination.relative_to(args.output_dir)),
                                 "class": category, "sha256": hashlib.sha256(raw).hexdigest(),
                                 "nearest_original": str(existing_paths[nearest]),
                                 f"mae_{IMAGE_SIZE}x{IMAGE_SIZE}": nearest_mae})
    write_json(args.output_dir / "provenance.json", {
        "source": SOURCE, "archive_sha256": SHA256,
        "author": "Laurence Moroney", "license": "CC BY 2.0",
        "homepage": "https://laurencemoroney.com/datasets.html",
        "original_purpose": "Author-provided prediction examples",
        "use_here": "Supplemental training images; original test split remains unchanged",
        "imported": imported, "excluded_duplicates": excluded,
    })
    (args.output_dir / "ATTRIBUTION.txt").write_text(
        "Rock Paper Scissors images by Laurence Moroney.\n"
        "Source: https://laurencemoroney.com/datasets.html\n"
        "License: Creative Commons Attribution 2.0\n"
        "https://creativecommons.org/licenses/by/2.0/\n"
        "The author's prediction examples are reused as supplemental training images.\n"
        "Original source images are retained; grayscale/resize/augmentation occurs at runtime.\n",
        encoding="utf-8",
    )
    print(f"Imported {len(imported)} images; excluded {len(excluded)} duplicates.")
    print(f"Additional train directory: {(args.output_dir / 'train').resolve()}")


if __name__ == "__main__":
    main()

"""학습과 추론이 공유하는 전처리, 메모리 캐시, 계층화 분할."""

from pathlib import Path

import numpy as np
import torch
from torch.nn import functional as F
from PIL import Image, ImageOps
from torch.utils.data import Dataset
from torchvision import datasets, transforms
from torchvision.transforms import functional as TF

from model import IMAGE_SIZE
DEFAULT_DATA_ROOT = Path(__file__).resolve().parents[2] / "dataset" / "rps"


def read_grayscale(path: Path) -> torch.Tensor:
    """투명 배경을 흰색에 합성하고 (1, 32, 32), float32 [0, 1]로 변환."""
    with Image.open(path) as image:
        rgba = ImageOps.exif_transpose(image).convert("RGBA")
        background = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
        gray = Image.alpha_composite(background, rgba).convert("L")
        gray = gray.resize((IMAGE_SIZE, IMAGE_SIZE), Image.Resampling.BILINEAR)
        array = np.array(gray, dtype=np.float32, copy=True) / 255.0
    return torch.from_numpy(array).unsqueeze(0)


def normalize(image: torch.Tensor, input_mode: str = "foreground") -> torch.Tensor:
    """foreground: 흰 배경을 0으로 반전. signed: 기존 [-1, 1] 전처리."""
    if input_mode == "foreground":
        return 1.0 - image
    if input_mode == "signed":
        return (image - 0.5) / 0.5
    raise ValueError(f"Unknown input mode: {input_mode}")


class RandomHorizontalScale:
    """손가락 벌림과 손 폭의 변화를 학습하도록 가로 비율만 0.65~1.0배로 변경."""

    def __call__(self, image: torch.Tensor) -> torch.Tensor:
        height, width = image.shape[-2:]
        new_width = max(1, round(width * torch.empty(1).uniform_(0.65, 1.0).item()))
        image = TF.resize(image, [height, new_width], antialias=True)
        left = (width - new_width) // 2
        return TF.pad(image, [left, 0, width - new_width - left, 0], fill=1.0)


class HandShapeAugment:
    """학습 전용: 좁은 손가락 틈을 채우고 일부 영상을 실루엣으로 변환."""

    def __call__(self, image: torch.Tensor) -> torch.Tensor:
        kernel = 3 if torch.rand(1).item() < 0.5 else 5
        expanded = -F.max_pool2d(-image, kernel, stride=1, padding=kernel // 2)
        closed = F.max_pool2d(expanded, kernel, stride=1, padding=kernel // 2)
        if torch.rand(1).item() < 0.5:
            threshold = torch.empty(1).uniform_(0.92, 0.98).item()
            closed = (closed >= threshold).to(image.dtype)
        return closed


class CachedImages:
    """원본 PNG를 매 epoch 다시 읽지 않도록 작은 영상만 CPU RAM에 보관."""

    def __init__(self, root: Path, expected_classes: list[str] | None = None):
        self.root = Path(root)
        folder = datasets.ImageFolder(self.root)
        self.classes = folder.classes
        self.class_to_idx = folder.class_to_idx
        if expected_classes is not None and self.classes != expected_classes:
            raise ValueError(
                f"Class mismatch in {self.root}: expected {expected_classes}, "
                f"found {self.classes}"
            )
        self.samples = folder.samples
        self.targets = np.array(folder.targets, dtype=np.int64)
        self.images = torch.stack([read_grayscale(Path(p)) for p, _ in self.samples])


class ImageSubset(Dataset):
    def __init__(self, data: CachedImages, indices, augment: bool = False,
                 input_mode: str = "foreground", shape_augment: bool = False):
        self.data = data
        self.indices = list(map(int, indices))
        self.input_mode = input_mode
        self.augmentation = None
        if augment:
            self.augmentation = transforms.Compose([
                transforms.RandomApply([RandomHorizontalScale()], p=0.5),
                *([transforms.RandomApply([HandShapeAugment()], p=0.35)]
                  if shape_augment else []),
                transforms.RandomHorizontalFlip(),
                transforms.RandomAffine(
                    degrees=30,
                    translate=(0.15, 0.15),
                    scale=(0.7, 1.25),
                    interpolation=transforms.InterpolationMode.BILINEAR,
                    fill=1.0,
                ),
                *([transforms.ColorJitter(brightness=0.3, contrast=0.5)]
                  if input_mode == "signed" else []),
                transforms.RandomAutocontrast(p=0.5),
                transforms.RandomPerspective(
                    distortion_scale=0.2, p=0.3,
                    interpolation=transforms.InterpolationMode.BILINEAR, fill=1.0,
                ),
            ])

    def __len__(self):
        return len(self.indices)

    def __getitem__(self, index):
        original_index = self.indices[index]
        image = self.data.images[original_index]
        if self.augmentation is not None:
            image = self.augmentation(image)
        return normalize(image, self.input_mode), int(self.data.targets[original_index])


def stratified_split(targets: np.ndarray, val_ratio: float, seed: int):
    """클래스 비율을 유지하며 train 폴더 내부에서만 validation을 분리."""
    if not 0 < val_ratio < 1:
        raise ValueError("--val-ratio must be between 0 and 1 (exclusive).")
    rng = np.random.default_rng(seed)
    train_indices, val_indices = [], []
    for label in np.unique(targets):
        indices = rng.permutation(np.flatnonzero(targets == label))
        n_val = round(len(indices) * val_ratio)
        if not 1 <= n_val < len(indices):
            raise ValueError("Each class needs at least one train and validation image.")
        val_indices.extend(indices[:n_val].tolist())
        train_indices.extend(indices[n_val:].tolist())
    return sorted(train_indices), sorted(val_indices)


def grouped_split(samples, val_ratio: float, seed: int):
    """같은 촬영 시퀀스(prefix-NNN.png)를 train/validation 사이에 섞지 않음.

    클래스별로 시퀀스 수에 val_ratio를 곱해 반올림하므로 실제 영상 비율은
    요청한 비율과 다를 수 있음. 동일 prefix의 영상은 항상 한 분할에만 존재.
    """
    if not 0 < val_ratio < 1:
        raise ValueError("--val-ratio must be between 0 and 1 (exclusive).")
    rng = np.random.default_rng(seed)
    train_indices, val_indices = [], []
    labels = sorted({label for _, label in samples})
    for label in labels:
        groups = {}
        for index, (path, target) in enumerate(samples):
            if target == label:
                group = Path(path).stem.rsplit("-", 1)[0]
                groups.setdefault(group, []).append(index)
        names = sorted(groups)
        if len(names) < 2:
            raise ValueError("Group split requires at least two filename prefixes per class.")
        n_val = max(1, min(len(names) - 1, round(len(names) * val_ratio)))
        val_groups = set(rng.permutation(names)[:n_val])
        for name, indices in groups.items():
            (val_indices if name in val_groups else train_indices).extend(indices)
    return sorted(train_indices), sorted(val_indices)

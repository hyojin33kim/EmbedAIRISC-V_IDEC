"""LeNet 스타일의 작은 64x64 흑백 영상 분류기."""

import torch
from torch import nn


class CNNSimpleNet(nn.Module):
    """Conv-ReLU-MaxPool 블록과 FC 2개. 출력은 softmax 이전 logits."""

    def __init__(self, num_classes: int = 3, base_channels: int = 8,
                 hidden_dim: int = 32, conv_blocks: int = 4, bias: bool = False):
        super().__init__()
        if conv_blocks not in (3, 4, 5):
            raise ValueError("conv_blocks must be 3, 4 or 5.")
        c = base_channels
        channels = [c, 2 * c] + [4 * c] * (conv_blocks - 2)
        layers = []
        in_channels = 1
        for out_channels in channels:
            layers.append(nn.Conv2d(in_channels, out_channels, kernel_size=3, padding=1, bias=bias))
            layers.extend([nn.ReLU(), nn.MaxPool2d(2)])
            in_channels = out_channels
        self.features = nn.Sequential(*layers)
        spatial_size = 64 // (2 ** conv_blocks)
        self.classifier = nn.Sequential(
            nn.Flatten(),
            nn.Linear(4 * c * spatial_size * spatial_size, hidden_dim, bias=bias),
            nn.ReLU(),
            nn.Linear(hidden_dim, num_classes, bias=bias),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.classifier(self.features(x))

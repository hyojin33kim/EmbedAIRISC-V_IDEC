"""양자화 수식, 원본 weight 보존, 실제 INT8 연산/저장, QAT gradient 회귀 검사."""

import copy
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import torch
from torch import nn
from torch.ao import quantization as aq

from quant_common import (
    CNNSimpleNet, PYTORCH, balanced_indices, calibrate, floating_reference,
    load_fp32, load_int8, load_partitions, prepare_model, quantized_layers, save_int8,
    select_backend, setup_runtime, symmetric_quantize,
)


class QuantizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        setup_runtime(42, 2)
        cls.backend = select_backend("auto")
        cls.checkpoint, cls.fp32 = load_fp32(PYTORCH / "outputs/model_fp32.pth")

    def test_manual_error_bound_and_zero_weights(self):
        for w in [torch.zeros(5), torch.linspace(-2, 3, 1001), torch.tensor([-0.1, 0.2])]:
            q, scale, dq = symmetric_quantize(w)
            self.assertEqual(q.dtype, torch.int8)
            self.assertGreater(scale, 0)
            self.assertGreaterEqual(int(q.min()), -127)
            self.assertLessEqual(int(q.max()), 127)
            self.assertLessEqual((w - dq).abs().max().item(), scale / 2 + 1e-6)

    def test_calibration_selection_balanced_reproducible(self):
        labels = [0] * 100 + [1] * 100 + [2] * 100
        a = balanced_indices(labels, 64, 42)
        self.assertEqual(a, balanced_indices(labels, 64, 42))
        self.assertNotEqual(a, balanced_indices(labels, 64, 43))
        self.assertEqual(len(set(a)), 64)
        counts = [sum(labels[i] == k for i in a) for k in range(3)]
        self.assertLessEqual(max(counts) - min(counts), 1)
        with self.assertRaises(ValueError):
            balanced_indices(labels, 301, 42)

    def test_fusion_preserves_supplied_weight_and_logits(self):
        prepared = prepare_model(self.checkpoint, self.backend)
        reference = floating_reference(prepared, self.checkpoint)
        for name, p in reference.named_parameters():
            self.assertTrue(torch.equal(p, self.fp32.get_parameter(name)))
        x = torch.rand(4, 1, 64, 64)
        with torch.no_grad():
            torch.testing.assert_close(prepared(x), self.fp32(x), rtol=0, atol=0)

    def test_saved_partition_rejects_overlap_and_missing_images(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            names = [f"{name}/{i}.png" for name in self.checkpoint["classes"] for i in range(2)]
            data = SimpleNamespace(root=root / "train", class_to_idx=self.checkpoint["class_to_idx"],
                                   samples=[(str(root / "train" / name), i // 2) for i, name in enumerate(names)])
            args = SimpleNamespace(checkpoint=root / "checkpoint.pth", split=root / "split.json", data_root=root)
            manifest = {"class_to_idx": self.checkpoint["class_to_idx"],
                        "train": names[::2], "validation": names[1::2]}
            args.split.write_text(json.dumps(manifest))
            with patch("quant_common.CachedImages", return_value=data):
                self.assertEqual(len(load_partitions(args, self.checkpoint)[1]), 3)
                for broken in [
                    {**manifest, "validation": manifest["validation"] + [names[0]]},
                    {**manifest, "train": manifest["train"][:-1]},
                    {**manifest, "train": manifest["train"] + [names[0]]},
                ]:
                    args.split.write_text(json.dumps(broken))
                    with self.assertRaises(ValueError):
                        load_partitions(args, self.checkpoint)

    def test_ptq_actual_int8_and_disk_roundtrip(self):
        prepared = prepare_model(self.checkpoint, self.backend)
        x = torch.rand(4, 1, 64, 64)
        calibrate(prepared, [(x, torch.zeros(4, dtype=torch.long))])
        model = aq.convert(prepared, inplace=False)
        layers, _ = quantized_layers(model, self.fp32)
        self.assertEqual(len(layers), 6)
        # packed weight만 바꾸고 FP32 Conv로 실행하는 구현을 탐지한다.
        self.assertFalse(any(isinstance(m, (nn.Conv2d, nn.Linear)) for m in model.modules()))
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "int8.pt"
            save_int8(model, self.checkpoint, self.backend, "ptq", path)
            restored, _ = load_int8(path)
            with torch.no_grad():
                torch.testing.assert_close(model(x), restored(x), rtol=0, atol=0)

    def test_qat_gradients_weight_update_and_observer_freeze(self):
        model = prepare_model(self.checkpoint, self.backend, qat=True)
        self.assertTrue(any(isinstance(m, aq.FakeQuantizeBase) for m in model.modules()))
        before = floating_reference(model, self.checkpoint)
        optimizer = torch.optim.SGD(model.parameters(), lr=1e-4)
        x, y = torch.rand(4, 1, 64, 64), torch.tensor([0, 1, 2, 0])
        loss = nn.CrossEntropyLoss()(model(x), y)
        loss.backward()
        self.assertTrue(all(p.grad is not None and torch.isfinite(p.grad).all() for p in model.parameters()))
        optimizer.step()
        after = floating_reference(model, self.checkpoint)
        self.assertTrue(any(not torch.equal(p, before.get_parameter(name)) for name, p in after.named_parameters()))
        model.eval().apply(aq.disable_observer)
        old = copy.deepcopy(model.state_dict())
        with torch.no_grad():
            model(x * 100)
        for name, value in model.state_dict().items():
            torch.testing.assert_close(value, old[name], rtol=0, atol=0)
        converted = aq.convert(model, inplace=False)
        with torch.no_grad():
            self.assertTrue(torch.isfinite(converted(x)).all())

    def test_nondefault_architecture_with_bias(self):
        config = {"num_classes": 3, "base_channels": 4, "hidden_dim": 16, "conv_blocks": 3, "bias": True}
        fp32 = CNNSimpleNet(**config)
        ckpt = {**self.checkpoint, "model_config": config, "state_dict": fp32.state_dict()}
        model = prepare_model(ckpt, self.backend)
        calibrate(model, [(torch.rand(2, 1, 64, 64), torch.tensor([0, 1]))])
        converted = aq.convert(model, inplace=False)
        rows, _ = quantized_layers(converted, fp32)
        self.assertEqual(len(rows), 5)
        with torch.no_grad():
            self.assertEqual(tuple(converted(torch.rand(2, 1, 64, 64)).shape), (2, 3))


if __name__ == "__main__":
    unittest.main(verbosity=2)

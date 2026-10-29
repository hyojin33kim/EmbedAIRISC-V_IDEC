"""가속기용 순수 CNN의 연산·상태·학습 경로 검사: python -m unittest test_model -v"""

import unittest

import torch
from torch import nn
from torch.fx import symbolic_trace

from model import CNNSimpleNet
from data import HandShapeAugment, normalize
from utils import describe_model, setup_runtime


class PlainCNNTests(unittest.TestCase):
    def setUp(self):
        setup_runtime(42, num_threads=2)

    def test_hardware_graph_uses_only_basic_operators(self):
        allowed = (nn.Conv2d, nn.ReLU, nn.MaxPool2d, nn.Flatten, nn.Linear)
        model = CNNSimpleNet()
        graph = symbolic_trace(model)
        for node in graph.graph.nodes:
            self.assertIn(node.op, {"placeholder", "call_module", "output"})
            if node.op == "call_module":
                self.assertIsInstance(graph.get_submodule(node.target), allowed)
        self.assertEqual(list(model.buffers()), [])
        for module in model.modules():
            if isinstance(module, (nn.Conv2d, nn.Linear)):
                self.assertIsNone(module.bias)

    def test_training_and_evaluation_are_identical(self):
        model = CNNSimpleNet()
        image = torch.rand(2, 1, 64, 64) * 2 - 1
        with torch.inference_mode():
            model.train()
            train = model(image)
            model.eval()
            evaluation = model(image)
        self.assertEqual(train.shape, (2, 3))
        torch.testing.assert_close(train, evaluation, rtol=0, atol=0)

    def test_cpu_backward_updates_weights(self):
        model = CNNSimpleNet()
        before = model.features[0].weight.detach().clone()
        optimizer = torch.optim.Adam(model.parameters(), lr=0.001)
        image = torch.rand(4, 1, 64, 64) * 2 - 1
        loss = nn.CrossEntropyLoss()(model(image), torch.tensor([0, 1, 2, 0]))
        loss.backward()
        self.assertTrue(all(p.grad is not None and p.grad.isfinite().all()
                            for p in model.parameters()))
        optimizer.step()
        self.assertFalse(torch.equal(before, model.features[0].weight))

    def test_reference_model_size_and_macs(self):
        model = CNNSimpleNet(base_channels=8, hidden_dim=32, conv_blocks=3)
        before = {k: v.clone() for k, v in model.state_dict().items()}
        report = describe_model(model)
        self.assertEqual(report["parameter_count"], 71464)
        self.assertEqual(report["macs_per_image"], 2719840)
        for name, tensor in model.state_dict().items():
            self.assertTrue(torch.equal(before[name], tensor))
        self.assertTrue(model.training)

    def test_positive_input_gain_preserves_classification(self):
        model = CNNSimpleNet().eval()
        image = torch.rand(2, 1, 64, 64)
        with torch.inference_mode():
            reference = model(image)
            scaled = model(2 * image)
        torch.testing.assert_close(scaled, 2 * reference, atol=1e-6, rtol=1e-5)

    def test_foreground_input_and_training_shape_augmentation(self):
        white = torch.ones(1, 64, 64)
        self.assertTrue(torch.equal(normalize(white), torch.zeros_like(white)))
        self.assertTrue(torch.equal(normalize(torch.zeros_like(white)), white))
        transform = HandShapeAugment()
        torch.testing.assert_close(transform(white), white, rtol=0, atol=0)
        image = white.clone()
        image[:, 12:52, 16:48] = 0.3
        for _ in range(10):
            augmented = transform(image)
            self.assertEqual(augmented.shape, image.shape)
            self.assertTrue(augmented.isfinite().all())
            self.assertGreaterEqual(float(augmented.min()), 0)
            self.assertLessEqual(float(augmented.max()), 1)

    @unittest.skipUnless(torch.cuda.is_available(), "CUDA unavailable")
    def test_cpu_gpu_logits_match(self):
        model = CNNSimpleNet().eval()
        image = torch.rand(2, 1, 64, 64) * 2 - 1
        with torch.inference_mode():
            cpu = model(image)
            gpu = model.cuda()(image.cuda()).cpu()
        torch.testing.assert_close(cpu, gpu, atol=1e-5, rtol=1e-4)


if __name__ == "__main__":
    unittest.main()

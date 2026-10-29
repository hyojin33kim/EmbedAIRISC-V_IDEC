"""Reject mixed execution conditions before reporting a speedup."""
import copy
import unittest

from compare_results import compare


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.cpu = dict(firmware="compare", backend="cpu", repeats=2,
                        firmware_sha256="elf", model_sha256="model",
                        simulation_sources_sha256="rtl", simulator="verilator",
                        simulation_executable_sha256="binary", comparison_id="fresh",
                        network=[dict(sample=124, run=i, input_sha256="input",
                                      q=[54, 87, 41], predicted_index=1,
                                      cpu_cycles=80, npu_cycles=0) for i in range(2)])
        self.npu = copy.deepcopy(self.cpu)
        self.npu["backend"] = "npu"
        for row in self.npu["network"]:
            row.update(cpu_cycles=10, npu_cycles=9)

    def test_matching_pair(self):
        self.assertEqual([r["speedup"] for r in compare(self.cpu, self.npu)], [8.0, 8.0])

    def test_mixed_execution_conditions(self):
        for key in ("firmware_sha256", "model_sha256", "simulation_sources_sha256",
                    "simulator", "simulation_executable_sha256", "comparison_id"):
            with self.subTest(key=key):
                changed = copy.deepcopy(self.npu)
                changed[key] = "different"
                with self.assertRaises(ValueError):
                    compare(self.cpu, changed)

    def test_mismatched_input_or_scores(self):
        for key, value in (("input_sha256", "different"), ("q", [0, 0, 0]),
                           ("predicted_index", 0)):
            with self.subTest(key=key):
                changed = copy.deepcopy(self.npu)
                changed["network"][0][key] = value
                with self.assertRaises(ValueError):
                    compare(self.cpu, changed)


if __name__ == "__main__":
    unittest.main()

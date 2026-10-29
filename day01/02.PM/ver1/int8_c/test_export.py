"""수치 정밀도, 지원하지 않는 입력 거부, exporter 재현성 검사."""

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

from export_model import BASE, export_model, extract_model, float_literal, quantized_multiplier


class ExportTests(unittest.TestCase):
    def test_q31_multiplier_error_bound(self):
        for real in np.geomspace(1e-8, 10, 100):
            multiplier, shift = quantized_multiplier(float(real))
            self.assertGreaterEqual(multiplier, 1 << 30)
            self.assertLess(multiplier, 1 << 31)
            self.assertLessEqual(abs(multiplier / 2**shift - real), real * 2**-30)

    def test_invalid_multiplier_and_alignment_rejected(self):
        for value in [0, -1, float('nan'), float('inf'), 1e-30, 1e30]:
            with self.assertRaises(ValueError):
                quantized_multiplier(value)
        for alignment in [0, -1, 3, 257]:
            with self.assertRaises(ValueError):
                export_model(BASE / 'does_not_exist.pt', BASE, alignment)

    def test_float32_header_round_trip(self):
        values = np.concatenate([np.geomspace(1e-10, 10, 100).astype(np.float32), np.array([0, 1, -1], np.float32)])
        for value in values:
            literal = float_literal(value)
            self.assertTrue(literal.endswith('f'))
            self.assertEqual(np.float32(literal[:-1]).tobytes(), value.tobytes())

    def test_unsupported_bias_and_preprocessing_rejected(self):
        artifact = {'model_config': {'bias': True}}
        with patch('export_model.load_int8', return_value=(None, artifact)):
            with self.assertRaisesRegex(ValueError, 'bias=False'):
                extract_model('ignored')
        artifact = {'model_config': {'bias': False}, 'preprocessing': {'channels': 3}}
        with patch('export_model.load_int8', return_value=(None, artifact)):
            with self.assertRaisesRegex(ValueError, 'preprocessing'):
                extract_model('ignored')

    def test_export_is_deterministic(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            checkpoint = BASE.parent / 'qat/outputs/model_int8.pt'
            export_model(checkpoint, root/'a')
            export_model(checkpoint, root/'b')
            for name in ['model_data.h','model_param.h','model_data.bin','model_manifest.json']:
                self.assertEqual((root/'a'/name).read_bytes(), (root/'b'/name).read_bytes())
            manifest = json.loads((root/'a/model_manifest.json').read_text())
            self.assertEqual(manifest['weight_bytes'], 31528)


if __name__ == '__main__':
    unittest.main(verbosity=2)

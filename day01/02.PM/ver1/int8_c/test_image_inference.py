"""단일 이미지 CLI의 device 옵션·실제 C 결과·checkpoint 연결 회귀 검사."""

import copy
import importlib.util
import json
import math
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from compare_inference import compare_results

BASE = Path(__file__).resolve().parent
PM = BASE.parent


class SingleImageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.output_dir = Path(cls.temp.name)
        cls.results = {}
        cls.image = PM / 'dataset/rps/test/rock/testrock01-00.png'
        for folder, model_type in [('pytorch','FP32'),('qat','QAT'),('ptq','PTQ'),('int8_c','INT8_C')]:
            output = cls.output_dir / folder
            process = subprocess.run(
                [sys.executable, 'inference.py', '--device', 'cpu', '--image',
                 '../dataset/rps/test/rock/testrock01-00.png', '--output-dir', str(output)],
                cwd=PM/folder, capture_output=True, text=True)
            if process.returncode:
                cls.temp.cleanup()
                raise AssertionError(f'{folder}: {process.stdout}\n{process.stderr}')
            cls.results[model_type] = json.loads((output/'prediction.json').read_text())

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_exact_user_command_and_unified_results(self):
        for name,result in self.results.items():
            with self.subTest(model=name):
                self.assertEqual(result['model_type'],name)
                self.assertEqual(result['device'],'cpu')
                self.assertEqual(result['predicted_label'],'rock')
                self.assertAlmostEqual(sum(result['probabilities'].values()),1.0,places=6)
                self.assertAlmostEqual(result['confidence'],result['probabilities']['rock'])
                logits=list(result['logits'].values())
                self.assertTrue(all(math.isfinite(value) for value in logits))
                exp=[math.exp(value-max(logits)) for value in logits]
                for label,value in zip(result['classes'],exp):
                    self.assertAlmostEqual(result['probabilities'][label],value/sum(exp),places=6)

    def test_c_is_actual_qat_source_and_has_identical_logits(self):
        qat,c=self.results['QAT'],self.results['INT8_C']
        self.assertEqual(qat['model_sha256'],c['model_sha256'])
        self.assertEqual(c['source_method'],'qat')
        self.assertEqual(c['runtime'],'C11 standalone')
        self.assertEqual(qat['logits'],c['logits'])
        for label in qat['classes']:
            self.assertAlmostEqual(qat['probabilities'][label],c['probabilities'][label],places=6)
        self.assertEqual(len(c['quantized_output']),3)

    def test_comparison_rejects_mismatched_c_export(self):
        report=compare_results(copy.deepcopy(self.results),self.image)
        self.assertTrue(report['all_predictions_equal'])
        self.assertEqual(report['qat_c_max_logit_abs_error'],0)
        broken=copy.deepcopy(self.results)
        broken['INT8_C']['model_sha256']='different-model'
        with self.assertRaisesRegex(ValueError,'differ'):
            compare_results(broken,self.image)

    def test_comparison_rejects_different_class_order(self):
        broken=copy.deepcopy(self.results)
        broken['PTQ']['classes']=list(reversed(broken['PTQ']['classes']))
        with self.assertRaisesRegex(ValueError,'class mapping'):
            compare_results(broken,self.image)

    def test_int8_auto_device_and_legacy_model_option(self):
        for folder in ['qat','ptq','int8_c']:
            with self.subTest(folder=folder):
                output=self.output_dir/(folder+'_auto')
                extra=['--model',str(PM/folder/'outputs/model_int8.pt')] if folder!='int8_c' else []
                process=subprocess.run([sys.executable,'inference.py','--device','auto','--image',str(self.image),
                                        '--output-dir',str(output),*extra],cwd=PM/folder,capture_output=True,text=True)
                self.assertEqual(process.returncode,0,process.stderr)
                result=json.loads((output/'prediction.json').read_text())
                self.assertEqual(result['device'],'cpu')
                self.assertEqual(result['predicted_label'],'rock')

    def test_int8_cuda_fails_with_clear_cpu_message(self):
        for folder in ['qat','ptq','int8_c']:
            with self.subTest(folder=folder):
                process=subprocess.run([sys.executable,'inference.py','--device','cuda','--image',str(self.image)],
                                       cwd=PM/folder,capture_output=True,text=True)
                self.assertEqual(process.returncode,2)
                self.assertIn('CPU only',process.stderr)
                self.assertNotIn('unrecognized arguments',process.stderr)

    def test_importing_fp32_first_does_not_redirect_qat_entrypoint(self):
        # 단순 'from inference import main'은 이미 import한 FP32 inference 모듈을 잘못 참조한다.
        previous=sys.modules.get('inference')
        sys.path.insert(0,str(PM/'pytorch'))
        try:
            fp_spec=importlib.util.spec_from_file_location('inference',PM/'pytorch/inference.py')
            fp32_inference=importlib.util.module_from_spec(fp_spec)
            sys.modules['inference']=fp32_inference
            fp_spec.loader.exec_module(fp32_inference)
            spec=importlib.util.spec_from_file_location('qat_cli_import_regression',PM/'qat/inference.py')
            module=importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            self.assertNotEqual(module.main.__module__,fp32_inference.main.__module__)
            self.assertEqual(module.main.__module__,'quant_inference')
        finally:
            if previous is None:
                sys.modules.pop('inference',None)
            else:
                sys.modules['inference']=previous


if __name__=='__main__':
    unittest.main(verbosity=2)

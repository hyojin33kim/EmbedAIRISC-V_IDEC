"""Validation only: run the standalone C process on real PNGs and compare Pillow/QAT."""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import torch
from PIL import Image

BASE = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE.parent / 'ptq'))
from quant_common import DEFAULT_DATA_ROOT, load_int8, normalize, read_grayscale, setup_runtime, write_csv, write_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', type=Path, default=BASE/'build/inference')
    parser.add_argument('--output-dir', type=Path, default=BASE/'outputs/native_c')
    parser.add_argument('--skip-dataset', action='store_true')
    args = parser.parse_args()
    setup_runtime(42, 4)
    metadata = json.loads((BASE/'model_manifest.json').read_text())
    model, artifact = load_int8(metadata['source_checkpoint'])
    samples = [] if args.skip_dataset else sorted((DEFAULT_DATA_ROOT/'test').glob('*/*.png'))
    comparisons, fixture_errors = [], []
    executable = args.executable.resolve()
    with tempfile.TemporaryDirectory() as temporary:
        temp = Path(temporary)
        empty_path = temp/'no_python_on_path'
        empty_path.mkdir()
        environment = {**os.environ, 'PATH': str(empty_path)}

        def check_image(path, fixture=False, jpeg=False):
            command = [str(executable), '--image', str(path), '--device', 'cpu',
                       '--output', str(temp/'prediction.json'), '--dump-gray', str(temp/'gray.bin'),
                       '--dump-input', str(temp/'input.bin')]
            process = subprocess.run(command, env=environment, capture_output=True, text=True)
            if process.returncode:
                raise AssertionError(f'{path}: {process.stderr}')
            gray = np.fromfile(temp/'gray.bin', dtype=np.uint8)
            expected_gray = (read_grayscale(path)*255).round().to(torch.uint8).numpy().reshape(-1)
            error = int(np.abs(gray.astype(np.int16)-expected_gray.astype(np.int16)).max())
            if not jpeg and error:
                raise AssertionError(f'C/Pillow preprocessing mismatch {path}: max={error}, count={np.count_nonzero(gray!=expected_gray)}')
            x = normalize(torch.from_numpy(expected_gray.copy()).reshape(1,*metadata['input_shape']).float()/255,
                          artifact['preprocessing']['input_mode'])
            with torch.inference_mode():
                expected_input = model.quant(x).int_repr().numpy().reshape(-1)
                expected_logits = model(x)[0].numpy()
            record = json.loads((temp/'prediction.json').read_text())
            if record['preprocessing'] != artifact['preprocessing']:
                raise AssertionError('C/PyTorch preprocessing metadata mismatch')
            actual_input = np.fromfile(temp/'input.bin',dtype=np.uint8)
            if not jpeg and not np.array_equal(actual_input,expected_input):
                raise AssertionError(f'Input quantization mismatch {path}')
            logits = np.array([record['logits'][c] for c in artifact['classes']],dtype=np.float32)
            max_logit_error = float(np.abs(logits-expected_logits).max())
            if not jpeg and max_logit_error:
                raise AssertionError(f'Final logits mismatch {path}: {max_logit_error}')
            probabilities=np.array([record['probabilities'][c] for c in artifact['classes']])
            if not np.isclose(probabilities.sum(),1,atol=2e-7):
                raise AssertionError('C softmax sum')
            if not jpeg and np.max(np.abs(probabilities-torch.from_numpy(expected_logits).softmax(0).numpy()))>2e-7:
                raise AssertionError('C/PyTorch softmax tolerance')
            row={'image':str(path),'prediction':record['predicted_label'],'max_gray_error':error,
                 'max_logit_error':max_logit_error,'confidence':record['confidence']}
            if fixture:
                fixture_errors.append(row)
            else:
                row['correct']=record['predicted_label']==path.parent.name
                comparisons.append(row)

        for i,path in enumerate(samples):
            check_image(path)
            if (i+1)%32==0: print(f'Native C PNG {i+1}/{len(samples)}',flush=True)
        rng=np.random.default_rng(42)
        for mode in ['L','RGB','RGBA','LA','1','P']:
            for width,height in [(1,1),(17,31),(32,32),(64,64),(127,99),(300,301)]:
                image=Image.fromarray(rng.integers(0,256,(height,width,4),dtype=np.uint8),'RGBA').convert(mode)
                path=temp/f'{mode}_{width}_{height}.png'
                image.save(path)
                check_image(path,fixture=True)
        rgba=np.empty((256,256,4),dtype=np.uint8)
        rgba[...,0]=np.arange(256,dtype=np.uint8)[:,None]
        rgba[...,1]=255-rgba[...,0]
        rgba[...,2]=rgba[...,0]
        rgba[...,3]=np.arange(256,dtype=np.uint8)[None,:]
        path=temp/'alpha_exhaustive.png'
        Image.fromarray(rgba,'RGBA').save(path)
        check_image(path,fixture=True)
        rgb=Image.fromarray(rng.integers(0,256,(97,123,3),dtype=np.uint8),'RGB')
        for orientation in range(1,9):
            exif=Image.Exif(); exif[274]=orientation
            path=temp/f'orientation_{orientation}.png'
            rgb.save(path,exif=exif)
            check_image(path,fixture=True)
        for orientation in [1,6,8]:
            exif=Image.Exif(); exif[274]=orientation
            path=temp/f'jpeg_{orientation}.jpg'
            rgb.save(path,quality=95,exif=exif)
            check_image(path,fixture=True,jpeg=True)
        # Errors must be returned without launching Python or accessing a model file.
        for name,blob in [('empty',b''),('truncated',b'\x89PNG\r\n\x1a\n'),('invalid',b'not an image')]:
            path=temp/name; path.write_bytes(blob)
            result=subprocess.run([str(executable),'--image',str(path)],env=environment,capture_output=True)
            if result.returncode!=2: raise AssertionError(f'{name} was not rejected: {result.returncode}')
        path=temp/'16bit.png'
        Image.fromarray(np.arange(256,dtype=np.uint16).reshape(16,16)*257).save(path)
        if subprocess.run([str(executable),'--image',str(path)],env=environment,capture_output=True).returncode!=2:
            raise AssertionError('16-bit input should be rejected explicitly')
    args.output_dir.mkdir(parents=True,exist_ok=True)
    report={'native_c_pipeline':True,'python_missing_from_runtime_path':True,
            'input_shape':metadata['input_shape'],
            'dataset_count':len(comparisons),'correct':sum(row['correct'] for row in comparisons),
            'max_dataset_gray_error':max((row['max_gray_error'] for row in comparisons),default=0),
            'max_dataset_logit_error':max((row['max_logit_error'] for row in comparisons),default=0),
            'fixtures_count':len(fixture_errors),'fixtures':fixture_errors,
            'invalid_empty_truncated_16bit_rejected':True,'source_sha256':metadata['source_sha256']}
    write_json(args.output_dir/'verification.json',report)
    if comparisons: write_csv(args.output_dir/'comparison.csv',comparisons)
    print(json.dumps({k:v for k,v in report.items() if k!='fixtures'},indent=2))


if __name__=='__main__':
    main()

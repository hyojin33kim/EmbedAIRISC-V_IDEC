# 실제 C 모델의 계층별 정답과 독립 정수 참조의 일반 형상 검증 벡터를 생성한다.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
import argparse
import csv
import ctypes as ct
import hashlib
import json
import random
import struct
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[7]
CNN = ROOT / "day01/01.AM/RV32IMAC_Wally/software/cnn"
INPUTS = ROOT / "day01/02.PM/ver2/int8_c/outputs"
SHA = "efb69dd24b01b645d35fc2c949605c9e5b3b7bea83a759af48643082a4c298a6"
P8 = ct.POINTER(ct.c_uint8)
P32 = ct.POINTER(ct.c_int32)


class Layer(ct.Structure):
    _fields_ = [("name", ct.c_char_p)] + [(name, ct.c_int) for name in (
        "is_conv", "relu", "in_c", "in_h", "in_w", "out_c", "out_h", "out_w",
        "input_zero", "output_zero")] + [
        ("weight", ct.POINTER(ct.c_int8)), ("weight_zero", P32),
        ("multiplier", P32), ("right_shift", P32),
        ("trace_offset", ct.c_size_t), ("output_elements", ct.c_size_t)]


def requant(acc, multiplier, shift, zero, relu):
    product = acc * multiplier
    quotient, remainder = divmod(abs(product), 1 << shift)
    half = 1 << (shift - 1)
    quotient += remainder > half or (remainder == half and quotient % 2)
    rounded = -quotient if product < 0 else quotient
    rounded = max(-(1 << 31), min((1 << 31) - 1, rounded))
    return min(255, max(zero if relu else 0, rounded + zero))


def reference(cfg, ifm, weights, qparams):
    c, h, w, oc_count = (cfg[k] for k in ("in_c", "in_h", "in_w", "out_c"))
    output = bytearray()
    signed_weights = [v if v < 128 else v - 256 for v in weights]
    for oc in range(oc_count):
        wz, mult, shift = qparams[oc]
        if cfg["op"] == 1:
            acc = sum((int(a) - cfg["input_zero"]) *
                      (signed_weights[oc*c*h*w+i] - wz) for i, a in enumerate(ifm))
            output.append(requant(acc, mult, shift, cfg["output_zero"], cfg["relu"]))
            continue
        for oy in range(h // 2):
            for ox in range(w // 2):
                samples = []
                for py in range(2):
                    for px in range(2):
                        acc = 0
                        for ic in range(c):
                            for ky in range(3):
                                iy = 2*oy + py + ky - 1
                                for kx in range(3):
                                    ix = 2*ox + px + kx - 1
                                    if 0 <= iy < h and 0 <= ix < w:
                                        a = ifm[(ic*h+iy)*w+ix] - cfg["input_zero"]
                                        b = signed_weights[((oc*c+ic)*3+ky)*3+kx] - wz
                                        acc += a*b
                        samples.append(acc)
                output.append(requant(max(samples), mult, shift,
                                      cfg["output_zero"], cfg["relu"]))
    return bytes(output)


def write_blob(path, blob):
    path.write_bytes(blob)
    padded = blob + bytes((-len(blob)) % 4)
    path.with_suffix(".mem").write_text("".join(
        f"{int.from_bytes(padded[i:i+4], 'little'):08x}\n" for i in range(0, len(padded), 4)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((INPUTS / "input_manifest.json").read_text())
    inputs = (INPUTS / "test_inputs_u8.bin").read_bytes()
    assert manifest["count"] == 372 and len(inputs) == 372*1024
    assert manifest["source_model_sha256"] == SHA
    assert hashlib.sha256(inputs).hexdigest() == manifest["files_sha256"]["test_inputs_u8.bin"]
    with (INPUTS / "c_predictions_u8.csv").open() as stream:
        predictions = list(csv.DictReader(stream))
    rows, cases = [], []

    def emit(kind, sample, layer_index, cfg, ifm, weights, qparams, expected, addresses):
        case_id = len(cases)
        case_dir = output / f"case_{case_id:05d}"
        case_dir.mkdir(exist_ok=True)
        qp = b"".join(struct.pack("<iiI", *record) for record in qparams)
        payloads = {"ifm": ifm, "weight": weights, "qparam": qp, "expected": expected}
        for name, blob in payloads.items():
            write_blob(case_dir / f"{name}.bin", blob)
        lengths = dict(zip(("ifm", "weight", "ofm"), map(len, (ifm, weights, expected))))
        lengths["qparam"] = len(qp)
        case = {"id": case_id, "kind": kind, "sample": sample, "layer": layer_index,
                "cfg": cfg, "addresses": addresses, "lengths": lengths,
                "guard_bytes": 64, "model_sha256": SHA if kind == 0 else None}
        (case_dir / "case.json").write_text(json.dumps(case, indent=2) + "\n")
        fields = [case_id, kind, sample, layer_index] + [cfg[k] for k in (
            "op", "relu", "in_c", "in_h", "in_w", "out_c", "input_zero", "output_zero")]
        rows.append(" ".join(map(str, fields)) + " " + " ".join(
            f"{addresses[k]:08x}" for k in ("src", "weight", "dst", "qparam")) +
            " " + " ".join(str(lengths[k]) for k in ("ifm", "weight", "ofm")))
        cases.append(case)

    with tempfile.TemporaryDirectory(prefix="tinynpu_golden_") as temp:
        library = Path(temp) / "model.so"
        subprocess.run(["gcc", "-O2", "-std=c11", "-Wall", "-Wextra", "-Werror",
                        "-DMODEL_INTEGER_ONLY", "-include", "firmware_no_float.h",
                        "-fPIC", "-shared", "model.c", "-o", str(library)], cwd=CNN, check=True)
        runtime = ct.CDLL(str(library))
        runtime.model_source_sha256.restype = ct.c_char_p
        assert runtime.model_source_sha256().decode() == SHA
        runtime.model_infer_u8_trace.argtypes = [P8, P8, ct.c_void_p, P8, ct.c_size_t]
        runtime.model_infer_u8_trace.restype = ct.c_int
        model = (Layer * 6).in_dll(runtime, "model_layers")
        workspace_raw = ct.create_string_buffer(4096 + 15)
        workspace = ct.c_void_p((ct.addressof(workspace_raw) + 15) & ~15)
        for sample in range(372):
            original = inputs[sample*1024:(sample+1)*1024]
            array = (ct.c_uint8 * 1024).from_buffer_copy(original)
            result, trace = (ct.c_uint8 * 3)(), (ct.c_uint8 * 3747)()
            assert runtime.model_infer_u8_trace(array, result, workspace, trace, 3747) == 0
            assert list(result) == [int(predictions[sample][f"q{i}"]) for i in range(3)]
            current = original
            for layer_index, layer in enumerate(model):
                cfg = {k: int(getattr(layer, k)) for k in (
                    "relu", "in_c", "in_h", "in_w", "out_c", "input_zero", "output_zero")}
                cfg["op"] = 0 if layer.is_conv else 1
                nweights = layer.out_c * (9*layer.in_c if layer.is_conv else len(current))
                weights = ct.string_at(layer.weight, nweights)
                qp = [(layer.weight_zero[oc], layer.multiplier[oc], layer.right_shift[oc])
                      for oc in range(layer.out_c)]
                expected = bytes(trace[layer.trace_offset:layer.trace_offset+layer.output_elements])
                if sample == 0:
                    assert reference(cfg, current, weights, qp) == expected, layer.name
                dst = 0x80004000 if layer_index % 2 == 0 else 0x80005000
                src = 0x80001003 if layer_index == 0 else (
                    0x80005000 if layer_index % 2 == 0 else 0x80004000)
                emit(0, sample, layer_index, cfg, current, weights, qp, expected,
                     {"src": src, "weight": 0x80008001, "dst": dst, "qparam": 0x80007000})
                current = expected

    rng = random.Random(0x544E5055)
    shapes = [(1,1,1,1,1), (1,1,4,32,3), (1,32,2,2,32),
              (0,1,2,2,1), (0,2,6,10,5), (0,32,8,8,32),
              (0,1,32,32,8), (0,8,16,16,32), (0,32,2,2,3)]
    for index, (op,c,h,w,oc) in enumerate(shapes):
        for relu in (0,1):
            cfg = dict(op=op,relu=relu,in_c=c,in_h=h,in_w=w,out_c=oc,
                       input_zero=(0,127,255)[index%3],output_zero=(0,62,255)[(index+1)%3])
            ifm = bytes(rng.randrange(256) for _ in range(c*h*w))
            weights = bytes(rng.randrange(256) for _ in range(oc*(c*h*w if op else 9*c)))
            qp = [((-128,0,127)[i%3], (1,65537,2147483647)[i%3],
                   (1,31,39,54,62)[i%5]) for i in range(oc)]
            expected = reference(cfg, ifm, weights, qp)
            emit(1,index,relu,cfg,ifm,weights,qp,expected,
                 {"src":0x800013fd+index%4,"weight":0x800083fd+index%4,
                  "dst":0x800043fd+index%4,"qparam":0x80007000})
    (output / "cases.txt").write_text(str(len(rows)) + "\n" + "\n".join(rows) + "\n")
    (output / "manifest.json").write_text(json.dumps({"model_sha256":SHA,
        "cnn_inputs":372,"cnn_layers":2232,"general_cases":len(cases)-2232,
        "python_matches_c_trace":True,"case_count":len(cases)},indent=2)+"\n")
    print(f"[PASS] golden: 372 C traces, 2232 CNN layers, {len(cases)-2232} general cases; Python/C trace match")


if __name__ == "__main__":
    main()

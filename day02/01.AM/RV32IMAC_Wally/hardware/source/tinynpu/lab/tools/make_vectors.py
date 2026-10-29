# Lab 7/8용으로 데모 프레임 한 장의 여섯 계층 입력·가중치·QPARAM·정답을 C 모델에서 만든다.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
import argparse
import ctypes as ct
import re
import struct
import subprocess
import tempfile
from pathlib import Path

CNN = Path(__file__).resolve().parents[5] / "software/cnn"
P32 = ct.POINTER(ct.c_int32)


class Layer(ct.Structure):
    _fields_ = [("name", ct.c_char_p)] + [(name, ct.c_int) for name in (
        "is_conv", "relu", "in_c", "in_h", "in_w", "out_c", "out_h", "out_w",
        "input_zero", "output_zero")] + [
        ("weight", ct.POINTER(ct.c_int8)), ("weight_zero", P32),
        ("multiplier", P32), ("right_shift", P32),
        ("trace_offset", ct.c_size_t), ("output_elements", ct.c_size_t)]


def write_hex(path, blob):
    path.write_text("".join(f"{value:02x}\n" for value in blob))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    frame = re.search(r"demo_frame\[1024\]\s*=\s*\{([^}]*)\}", (CNN / "demo_frame.h").read_text())
    gray = [int(value) for value in re.findall(r"\d+", frame.group(1))]
    assert len(gray) == 1024

    with tempfile.TemporaryDirectory(prefix="tinynpu_lab_") as temp:
        library = Path(temp) / "model.so"
        subprocess.run(["gcc", "-O2", "-std=c11", "-DMODEL_INTEGER_ONLY", "-include", "firmware_no_float.h",
                        "-fPIC", "-shared", "model.c", "-o", str(library)], cwd=CNN, check=True)
        runtime = ct.CDLL(str(library))
        quantized = (ct.c_uint8 * 1024)()
        assert runtime.model_gray_to_input((ct.c_uint8 * 1024)(*gray), quantized) == 0
        workspace_raw = ct.create_string_buffer(4096 + 15)
        workspace = ct.c_void_p((ct.addressof(workspace_raw) + 15) & ~15)
        result, trace = (ct.c_uint8 * 3)(), (ct.c_uint8 * 3747)()
        assert runtime.model_infer_u8_trace(quantized, result, workspace, trace, 3747) == 0
        model = (Layer * 6).in_dll(runtime, "model_layers")
        names = (ct.c_char_p * 3).in_dll(runtime, "model_class_names")
        weights, qparams, rows = bytearray(), bytearray(), []
        current = bytes(quantized)
        for index, layer in enumerate(model):
            count = layer.out_c * (9*layer.in_c if layer.is_conv else len(current))
            weights += ct.string_at(layer.weight, count)
            for oc in range(layer.out_c):
                qparams += struct.pack("<iiI", layer.weight_zero[oc], layer.multiplier[oc], layer.right_shift[oc])
            expected = bytes(trace[layer.trace_offset:layer.trace_offset+layer.output_elements])
            write_hex(output / f"expected_L{index}.hex", expected)
            rows.append(f"{0 if layer.is_conv else 1} {layer.relu} {layer.in_c} {layer.in_h} {layer.in_w} "
                        f"{layer.out_c} {layer.input_zero} {layer.output_zero} {count} {len(expected)}")
            current = expected
    write_hex(output / "input.hex", bytes(quantized))
    write_hex(output / "weights.hex", weights)
    write_hex(output / "qparam.hex", qparams)
    (output / "layers.txt").write_text("\n".join(rows) + "\n")
    print(f"[PASS] vectors: demo frame, 6 layers, weight {len(weights)} B, qparam {len(qparams)} B, "
          f"C score {list(result)} -> {names[max(range(3), key=lambda i: result[i])].decode()}")


if __name__ == "__main__":
    main()

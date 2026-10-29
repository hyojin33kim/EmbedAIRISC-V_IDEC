"""독립적인 NumPy INT64 참조와 ctypes C API. packed backend 연산은 사용하지 않는다."""

import ctypes as ct
import json
from pathlib import Path

import numpy as np

BASE = Path(__file__).resolve().parent


def round_shift_even(values, multipliers, shifts):
    product = values.astype(np.int64) * np.asarray(multipliers, dtype=np.int64)
    shifts = np.asarray(shifts, dtype=np.int64)
    magnitude = np.abs(product)
    quotient = magnitude >> shifts
    remainder = magnitude & ((np.int64(1) << shifts) - 1)
    half = np.int64(1) << (shifts - 1)
    rounded = quotient + ((remainder > half) | ((remainder == half) & ((quotient & 1) != 0)))
    return np.where(product < 0, -rounded, rounded)


def integer_reference(input_u8, layers):
    current, trace = np.asarray(input_u8, dtype=np.uint8), []
    for layer in layers:
        c, h, w = layer["input_shape"]
        out_c = layer["output_shape"][0]
        centered = current.reshape(c, h, w).astype(np.int64) - layer["input_zero_point"]
        weight = layer["weight"].astype(np.int64).reshape(out_c, -1)
        weight -= np.asarray(layer["weight_zero_points"], dtype=np.int64)[:, None]
        if layer["type"] == "conv_pool":
            padded = np.pad(centered, ((0, 0), (1, 1), (1, 1)), constant_values=0)
            windows = np.lib.stride_tricks.sliding_window_view(padded, (3, 3), axis=(1, 2))
            acc = np.einsum("ockl,chwkl->ohw", weight.reshape(out_c, c, 3, 3), windows, optimize=True)
            m = np.asarray(layer["multipliers"])[:, None, None]
            shifts = np.asarray(layer["right_shifts"])[:, None, None]
        else:
            acc = weight @ centered.reshape(-1)
            m, shifts = layer["multipliers"], layer["right_shifts"]
        q = round_shift_even(acc, m, shifts) + layer["output_zero_point"]
        q = np.clip(q, layer["output_zero_point"] if layer["relu"] else 0, 255).astype(np.uint8)
        if layer["type"] == "conv_pool":
            q = q.reshape(out_c, h // 2, 2, w // 2, 2).max(axis=(2, 4))
        current = q
        trace.append(q.reshape(-1).copy())
    return current.reshape(-1), trace


class CRuntime:
    def __init__(self, library=BASE / "build/libint8_model.so", manifest=BASE / "model_manifest.json", integer_only=False):
        self.manifest = json.loads(Path(manifest).read_text())
        self.lib = ct.CDLL(str(Path(library).resolve()))
        if not hasattr(self.lib, "model_source_sha256"):
            raise ValueError("C library needs rebuild: run make in int8_c")
        self.lib.model_source_sha256.restype = ct.c_char_p
        if self.lib.model_source_sha256().decode("ascii") != self.manifest["source_sha256"]:
            raise ValueError("C library/manifest source hash mismatch; rebuild after export")
        p8 = np.ctypeslib.ndpointer(dtype=np.uint8, flags="C_CONTIGUOUS")
        pf = np.ctypeslib.ndpointer(dtype=np.float32, flags="C_CONTIGUOUS")
        self.lib.model_workspace_bytes.restype = ct.c_size_t
        self.workspace_size = self.lib.model_workspace_bytes()
        if self.workspace_size != self.manifest["workspace_bytes"]:
            raise ValueError("Library/manifest workspace mismatch; rebuild after export")
        align = self.manifest["alignment"]
        self._storage = ct.create_string_buffer(self.workspace_size + align - 1)
        address = (ct.addressof(self._storage) + align - 1) // align * align
        self.workspace = ct.c_void_p(address)
        self.lib.model_infer_u8.argtypes = [p8, p8, ct.c_void_p]
        self.lib.model_infer_u8.restype = ct.c_int
        self.lib.model_infer_u8_trace.argtypes = [p8, p8, ct.c_void_p, p8, ct.c_size_t]
        self.lib.model_infer_u8_trace.restype = ct.c_int
        self.lib.model_gray_to_input.argtypes = [p8, p8]
        self.lib.model_gray_to_input.restype = ct.c_int
        if integer_only:
            for name in ["model_quantize_input", "model_infer_f32", "model_dequantize_output"]:
                if hasattr(self.lib, name):
                    raise ValueError(f"Integer firmware unexpectedly exports {name}")
        else:
            self.lib.model_quantize_input.argtypes = [pf, p8]
            self.lib.model_quantize_input.restype = ct.c_int
            self.lib.model_infer_f32.argtypes = [pf, pf, ct.c_void_p]
            self.lib.model_infer_f32.restype = ct.c_int
            self.lib.model_dequantize_output.argtypes = [p8, pf]
            self.lib.model_dequantize_output.restype = None

    @staticmethod
    def _check(status):
        if status:
            raise ValueError(f"C runtime error: {status}")

    def infer(self, quantized, trace=False):
        quantized = np.ascontiguousarray(quantized, dtype=np.uint8).reshape(-1)
        if len(quantized) != 4096:
            raise ValueError("Expected 4096 quantized input elements")
        output = np.empty(len(self.manifest["classes"]), dtype=np.uint8)
        if trace:
            values = np.empty(self.manifest["trace_elements"], dtype=np.uint8)
            self._check(self.lib.model_infer_u8_trace(quantized, output, self.workspace, values, values.size))
            traces = [values[l["trace_offset"]:l["trace_offset"] + l["output_elements"]].copy()
                      for l in self.manifest["layers"]]
            return output, traces
        self._check(self.lib.model_infer_u8(quantized, output, self.workspace))
        return output

    def quantize(self, floats):
        floats = np.ascontiguousarray(floats, dtype=np.float32).reshape(-1)
        if floats.size != 4096:
            raise ValueError("Expected 4096 FP32 input elements")
        output = np.empty(4096, dtype=np.uint8)
        self._check(self.lib.model_quantize_input(floats, output))
        return output

    def gray_to_input(self, gray):
        gray = np.ascontiguousarray(gray, dtype=np.uint8).reshape(-1)
        if gray.size != 4096:
            raise ValueError("Expected 4096 gray pixels")
        output = np.empty(4096, dtype=np.uint8)
        self._check(self.lib.model_gray_to_input(gray, output))
        return output

    def infer_f32(self, floats):
        floats = np.ascontiguousarray(floats, dtype=np.float32).reshape(-1)
        if floats.size != 4096:
            raise ValueError("Expected 4096 FP32 input elements")
        output = np.empty(len(self.manifest["classes"]), dtype=np.float32)
        self._check(self.lib.model_infer_f32(floats, output, self.workspace))
        return output

    def dequantize(self, quantized):
        quantized = np.ascontiguousarray(quantized, dtype=np.uint8).reshape(-1)
        if quantized.size != len(self.manifest["classes"]):
            raise ValueError("Expected one quantized logit per class")
        output = np.empty(quantized.size, dtype=np.float32)
        self.lib.model_dequantize_output(quantized, output)
        return output

# 전처리된 32×32 입력의 Wally CNN 결과를 ver2 기준값과 비교한다.
import csv
import ctypes as ct
import hashlib
import json
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

BASE = Path(__file__).resolve().parent
SOURCE = BASE.parents[4] / "day01/02.PM/ver2/int8_c"


class PreparedInputTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(temporary.cleanup)
        library = Path(temporary.name) / "libcnn.so"
        subprocess.run([
            "gcc", "-O2", "-std=c11", "-Wall", "-Wextra", "-Werror",
            "-DMODEL_INTEGER_ONLY", "-include", "firmware_no_float.h",
            "-DFIRMWARE_HOST_DEMO", "-Dmain=firmware_main", "-fPIC", "-shared",
            "model.c", "firmware_main.c", "-o", str(library),
        ], cwd=BASE, check=True)
        cls.runtime = ct.CDLL(str(library))
        p8 = ct.POINTER(ct.c_uint8)
        cls.runtime.firmware_main.restype = ct.c_int
        cls.runtime.model_gray_to_input.argtypes = [p8, p8]
        cls.runtime.model_gray_to_input.restype = ct.c_int
        cls.runtime.model_infer_u8.argtypes = [p8, p8, ct.c_void_p]
        cls.runtime.model_infer_u8.restype = ct.c_int
        cls.runtime.model_workspace_bytes.restype = ct.c_size_t
        cls.runtime.model_source_sha256.restype = ct.c_char_p
        cls.manifest = json.loads((SOURCE / "model_manifest.json").read_text())
        cls.inputs = json.loads((SOURCE / "outputs/input_manifest.json").read_text())
        cls.gray = (SOURCE / "outputs/test_inputs_gray8.bin").read_bytes()
        cls.quantized = (SOURCE / "outputs/test_inputs_u8.bin").read_bytes()
        with (SOURCE / "outputs/c_predictions_u8.csv").open() as stream:
            cls.expected = list(csv.DictReader(stream))

    def test_model_matches_32x32_ver2(self):
        self.assertEqual(self.manifest["input_shape"], [1, 32, 32])
        self.assertEqual(self.inputs["source_model_sha256"], self.manifest["source_sha256"])
        self.assertEqual(self.runtime.model_source_sha256().decode(), self.manifest["source_sha256"])
        self.assertEqual(self.runtime.model_workspace_bytes(), 4096)
        for name in ["model_data.h", "model_param.h"]:
            self.assertEqual((BASE / name).read_bytes(), (SOURCE / name).read_bytes())
        for name, blob in [("test_inputs_gray8.bin", self.gray), ("test_inputs_u8.bin", self.quantized)]:
            self.assertEqual(hashlib.sha256(blob).hexdigest(), self.inputs["files_sha256"][name])

    def test_demo_is_preprocessed_32x32_rock(self):
        header = (BASE / "demo_frame.h").read_text()
        self.assertRegex(header, r"#define DEMO_FRAME_WIDTH 32\b")
        self.assertRegex(header, r"#define DEMO_FRAME_HEIGHT 32\b")
        values = re.search(r"demo_frame\[1024\]\s*=\s*\{([^}]+)\}", header).group(1)
        frame = bytes(int(value) for value in re.findall(r"\d+", values))
        index = next(i for i, row in enumerate(self.inputs["samples"])
                     if row["image"].endswith("/rock/testrock01-00.png"))
        self.assertEqual(len(frame), 1024)
        self.assertEqual(frame, self.gray[index * 1024:(index + 1) * 1024])

    def test_actual_main_signature(self):
        self.assertEqual(self.runtime.firmware_main(), 0)
        result = (ct.c_uint32 * 8).in_dll(self.runtime, "firmware_result")
        self.assertEqual(list(result), [0x494E5438, 1, 54, 87, 41, 32, 32, 0])

    def test_all_372_preprocessed_inputs_match_ver2(self):
        self.assertEqual(self.manifest["input_shape"], [1, 32, 32])
        self.assertEqual(len(self.expected), 372)
        self.assertEqual(len(self.gray), 372 * 1024)
        self.assertEqual(len(self.quantized), 372 * 1024)
        storage = ct.create_string_buffer(self.runtime.model_workspace_bytes() + 15)
        workspace = ct.c_void_p((ct.addressof(storage) + 15) & ~15)
        input_type = ct.c_uint8 * 1024
        output_type = ct.c_uint8 * 3
        correct = 0
        for index, row in enumerate(self.expected):
            with self.subTest(image=index):
                gray = input_type.from_buffer_copy(self.gray[index * 1024:(index + 1) * 1024])
                quantized, output = input_type(), output_type()
                self.assertEqual(self.runtime.model_gray_to_input(gray, quantized), 0)
                self.assertEqual(bytes(quantized), self.quantized[index * 1024:(index + 1) * 1024])
                self.assertEqual(self.runtime.model_infer_u8(quantized, output, workspace), 0)
                self.assertEqual(list(output), [int(row[f"q{i}"]) for i in range(3)])
                prediction = max(range(3), key=lambda i: output[i])
                self.assertEqual(prediction, int(row["predicted_index"]))
                correct += prediction == self.inputs["samples"][index]["label"]
        self.assertEqual(correct, 360)


if __name__ == "__main__":
    unittest.main(verbosity=2)

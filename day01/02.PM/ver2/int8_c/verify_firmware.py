"""RV32IMAC 펌웨어의 전처리 소스·ELF·QEMU 결과 검증. Python 표준 라이브러리만 사용."""

import argparse
import hashlib
import json
import re
import shlex
import struct
import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parent
SOURCES = ["model.c", "image_preprocess.c", "firmware_main.c", "firmware_example.c"]
FP_TYPES = re.compile(r"\b(?:float|double|__fp16|__bf16|__float(?:80|128)|_Float\d+x?|_Decimal\d+)\b")
FP_LITERALS = re.compile(
    r"(?<![\w.])(?:0[xX](?:[0-9a-fA-F]+(?:\.[0-9a-fA-F]*)?|\.[0-9a-fA-F]+)"
    r"[pP][+-]?\d+[fFlL]?|(?:\d+\.\d*|\.\d+)(?:[eE][+-]?\d+)?[fFlL]?|"
    r"\d+[eE][+-]?\d+[fFlL]?)(?![\w.])"
)
C_STRINGS = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|/\*.*?\*/|//[^\n]*', re.S)


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def source_fp_tokens(source):
    source = C_STRINGS.sub(" ", source)
    return FP_TYPES.findall(source), FP_LITERALS.findall(source)


def run(command, **kwargs):
    return subprocess.run(command, cwd=BASE, capture_output=True, check=True, **kwargs)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default="riscv64-unknown-elf-gcc")
    parser.add_argument("--cflags", required=True, help="Makefile의 실제 컴파일 옵션")
    parser.add_argument("--qemu", default="qemu-riscv32")
    parser.add_argument("--elf", type=Path, default=BASE / "build/firmware_rv32imac_ilp32.elf")
    parser.add_argument("--output-dir", type=Path, default=BASE / "outputs/rv32imac_ilp32")
    args = parser.parse_args()
    args.elf = args.elf.resolve()
    args.output_dir = args.output_dir.resolve()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    report_path = args.output_dir / "no_float_verification.json"
    report_path.unlink(missing_ok=True)
    flags = shlex.split(args.cflags)
    require("-march=rv32imac" in flags and "-mabi=ilp32" in flags,
            "This verifier requires RV32IMAC / ILP32")
    require("-DMODEL_INTEGER_ONLY" in flags and "firmware_no_float.h" in flags,
            "Missing integer-only mode or forced type guard")
    cc = shlex.split(args.cc)

    # Prove the guard is active, even for unused declarations/sizeof expressions.
    rejected = []
    for name, code in [("float", "float forbidden;"), ("double", "double forbidden;"),
                       ("long_double", "long double forbidden;"), ("_Float32", "_Float32 forbidden;")]:
        result = subprocess.run(cc + flags + ["-x", "c", "-fsyntax-only", "-"],
                                cwd=BASE, input=code, text=True, capture_output=True)
        (args.output_dir / f"reject_{name}.log").write_text(result.stderr)
        require(result.returncode != 0 and "poisoned" in result.stderr,
                f"The compiler did not reject {name} with the no-FP type guard")
        rejected.append(name)
    for literal in ["0.5", "1e-3", "0x1.8p-2f", "1.0L"]:
        require(source_fp_tokens("int x = " + literal + ";")[1], f"Literal audit missed {literal}")
    require(not any(source_fp_tokens('const char *s = "float double 0.5"; int n = 0xdeadbeef;')),
            "Audit must ignore strings and hexadecimal integer constants")

    audits = []
    for source in SOURCES:
        code = run(cc + flags + ["-E", "-P", source], text=True).stdout
        (args.output_dir / (source + ".i")).write_text(code)
        types, literals = source_fp_tokens(code)
        require(not types and not literals, f"FP remains in {source}: {types}, {literals}")
        audits.append({"source": source, "float_type_tokens": len(types),
                       "floating_literals": len(literals), "preprocessed_sha256": hashlib.sha256(code.encode()).hexdigest()})
    # Compile the alternative SDK entry points too (the demo linker would discard them).
    run(cc + flags + ["-c", "firmware_example.c", "-o", str(args.output_dir / "firmware_example.o")])
    tool = lambda name: run(cc + ["-print-prog-name=" + name], text=True).stdout.strip()
    attributes = run([tool("readelf"), "-h", "-A", str(args.elf)], text=True).stdout
    symbols = run([tool("nm"), "-a", str(args.elf)], text=True).stdout
    undefined = run([tool("nm"), "-u", str(args.elf)], text=True).stdout
    disassembly = run([tool("objdump"), "-d", "--no-show-raw-insn", str(args.elf)], text=True).stdout
    size = run([tool("size"), str(args.elf)], text=True).stdout
    for filename, value in [("readelf.txt", attributes), ("symbols.txt", symbols),
                            ("disassembly.txt", disassembly), ("size.txt", size)]:
        (args.output_dir / filename).write_text(value)
    require("ELF32" in attributes and "little endian" in attributes and "soft-float ABI" in attributes,
            "Expected little-endian ELF32 with integer ILP32 calling convention")
    arch = re.search(r'Tag_RISCV_arch:\s*"([^"]+)"', attributes)
    require(arch is not None, "Missing RISC-V architecture attribute")
    arch = arch.group(1)
    require(arch.startswith("rv32i") and all(re.search("_" + ext + r"\d", arch) for ext in "mac"),
            f"ELF does not declare RV32IMAC: {arch}")
    require(not re.search(r"_(?:[fdq]\d|z(?:finx|dinx|hinx|fh|fa))", arch), f"FP extension present: {arch}")
    require(not undefined.strip(), "Unresolved ELF symbols: " + undefined)
    names = [line.split()[-1] for line in symbols.splitlines() if line.split()]
    fp_symbols = [name for name in names if (
        re.search(r"__[a-z0-9]*(?:sf|df|hf|tf|xf)[a-z0-9]*$", name)
        or name in {"model_infer_f32", "model_quantize_input", "model_dequantize_output"}
        or name.endswith("_weight_scale")
        or re.fullmatch(r"(?:exp|log|pow|sqrt|round|floor|ceil|sin|cos|fma)[fl]?", name)
    )]
    require(not fp_symbols, f"Floating-point helper/metadata/API symbols: {fp_symbols}")
    instructions = re.findall(r"^\s*[0-9a-f]+:\s+([a-z][a-z0-9.]*)\b", disassembly, re.M)
    require(instructions, "No disassembled instructions found")
    fp_instructions = [op for op in instructions if (op.startswith("f") and not op.startswith("fence")) or op.startswith("c.f")]
    require(not fp_instructions, f"FP instructions: {fp_instructions}")

    packet = run(shlex.split(args.qemu) + [str(args.elf)]).stdout
    (args.output_dir / "firmware_result.bin").write_bytes(packet)
    require(len(packet) == 32, f"Expected 32-byte firmware packet; received {len(packet)}")
    words = struct.unpack("<8I", packet)
    manifest = json.loads((BASE / "model_manifest.json").read_text())
    # This fixed camera frame is testrock01-00.png; QAT baseline comes from the native C test.
    baseline = json.loads((BASE / "outputs/native_c/four_model_comparison/qat/prediction.json").read_text())
    require(baseline["model_sha256"] == manifest["source_sha256"], "Stale demo QAT baseline; regenerate comparison")
    require(baseline["classes"] == manifest["classes"], "QAT baseline class order differs")
    last = manifest["layers"][-1]
    expected_codes = [round(baseline["logits"][name] / last["output_scale"]) + last["output_zero_point"]
                      for name in manifest["classes"]]
    require(words == (0x494E5438, baseline["predicted_index"], *expected_codes, 300, 300, 0),
            f"QEMU/QAT result mismatch: {words}")
    report = {
        "passed": True, "architecture": arch, "abi": "ilp32", "flags": flags,
        "compiler": run(cc + ["--version"], text=True).stdout.splitlines()[0],
        "qemu": run(shlex.split(args.qemu) + ["--version"], text=True).stdout.splitlines()[0],
        "elf": str(args.elf.relative_to(BASE)), "elf_sha256": digest(args.elf),
        "source_model_sha256": manifest["source_sha256"],
        "sources": audits, "type_guard_negative_tests": rejected,
        "floating_literal_negative_tests": 4, "fp_symbols": fp_symbols,
        "fp_instructions": fp_instructions, "undefined_symbols": [],
        "instruction_count": len(instructions), "size": size.strip(),
        "qemu_result_words": list(words), "prediction": baseline["predicted_label"],
        "qemu_matches_qat_baseline": True,
    }
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS: {arch}; no FP types/literals/instructions/helpers; QEMU={list(words)}")
    print(f"Report: {report_path}")


if __name__ == "__main__":
    main()

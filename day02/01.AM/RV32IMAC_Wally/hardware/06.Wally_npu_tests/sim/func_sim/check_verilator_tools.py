"""Check the tools needed to reproduce the CPU + tinyNPU RTL seed."""
import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--verilator", default="verilator")
parser.add_argument("--riscv-prefix", default="riscv64-unknown-elf")
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--build-flags", default="")
args = parser.parse_args()

def version(command):
    if shutil.which(command) is None:
        raise SystemExit(f"[FAIL] tool not found: {command}")
    result = subprocess.run([command, "--version"], check=True, capture_output=True, text=True)
    return result.stdout.splitlines()[0]

tools = {"verilator": version(args.verilator), "host_gcc": version("gcc"),
         "host_gxx": version("g++"), "riscv_gcc": version(args.riscv_prefix + "-gcc")}
match = re.search(r"Verilator (\d+)\.(\d+)", tools["verilator"])
if not match or tuple(map(int, match.groups())) < (5, 20):
    raise SystemExit("[FAIL] this flow supports Verilator >= 5.020; see README_verilator.md")
for suffix in ("objcopy", "objdump", "nm"):
    if shutil.which(args.riscv_prefix + "-" + suffix) is None:
        raise SystemExit(f"[FAIL] tool not found: {args.riscv_prefix}-{suffix}")
result = subprocess.run([args.riscv_prefix + "-gcc", "-march=rv32imac_zicsr_zifencei_zicbom",
                         "-mabi=ilp32", "-print-libgcc-file-name"],
                        check=True, capture_output=True, text=True)
if not Path(result.stdout.strip()).is_file():
    raise SystemExit("[FAIL] RV32 ILP32 libgcc not available; install a multilib RISC-V ELF toolchain")
tools["riscv_arch"] = "rv32imac_zicsr_zifencei_zicbom/ilp32"
tools["verilator_executable"] = str(Path(shutil.which(args.verilator)).resolve())
tools["verilator_flags"] = args.build_flags
args.output.parent.mkdir(parents=True, exist_ok=True)
payload = json.dumps(tools, indent=2) + "\n"
if not args.output.is_file() or args.output.read_text() != payload:
    args.output.write_text(payload)
for name, value in tools.items():
    print(f"[TOOL] {name}: {value}")

# Wally와 tinyNPU를 연결할 34비트 CMSDK 2x2 버스 매트릭스를 재생성한다.
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT / "output/wally_npu_matrix"

subprocess.run([
    "perl", "bin/BuildBusMatrix.pl", "--xmldir=" + str(ROOT / "xml"),
    "--cfg=wally_npu_2x2.xml", "--tgtdir=" + str(ROOT / "output"),
    "--overwrite", "--notimescales",
], cwd=ROOT, check=True)
files = sorted(OUTPUT.glob("*.v"))
assert len(files) == 8, "CMSDK generation did not produce eight modules"
for path in files:
    assert "<<" not in path.read_text(), f"Unexpanded template: {path}"
# CMSDK leaves the test-only scan output unassigned until scan insertion.
# Give the generated functional model a deterministic scan passthrough.
path = OUTPUT / "wally_npu_matrix.v"
source = path.read_text()
assert not re.search(r"assign\s+SCANOUTHCLK", source)
source = source.replace("endmodule", "  assign SCANOUTHCLK = SCANINHCLK;\n\nendmodule", 1)
path.write_text(source)
source = (OUTPUT / "wally_npu_matrix_lite.v").read_text()
assert len(re.findall(r"input\s+\[33:0\]\s+HADDRS[01]", source)) == 2
assert len(re.findall(r"output\s+\[3:0\]\s+HWUSERM[01]", source)) == 2
print("[PASS] generated CMSDK 2x2 ADDR34 DATA32 USER4 with Lite wrapper")

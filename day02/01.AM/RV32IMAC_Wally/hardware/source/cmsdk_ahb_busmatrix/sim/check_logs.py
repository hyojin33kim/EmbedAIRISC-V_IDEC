# VCS 종료 코드와 함께 오류 진단 및 실제 통합 시험 완료 표식을 검사한다.
import argparse
import collections
import json
import re
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument("log",type=Path)
parser.add_argument("--compile",action="store_true")
parser.add_argument("--lint",action="store_true")
args=parser.parse_args()
content=args.log.read_text(errors="replace")
if re.search(r"^(?:Error-|Error:|Fatal:|\[FAIL\])",content,re.M):
    raise SystemExit(f"[FAIL] VCS diagnostics in {args.log}")
if not args.compile and not args.lint and not re.search(r"^\[PASS\] tb_wally_npu_soc",content,re.M):
    raise SystemExit(f"[FAIL] no completion marker in {args.log}")
if args.lint:
    baseline=json.loads(Path(__file__).with_name("lint_baseline.json").read_text())
    allowed=collections.Counter({(d["severity"],d["tag"],d["file"],d["detail"]):d["count"]
                                 for d in baseline["diagnostics"]})
    actual=collections.Counter()
    intentional=0
    pattern=r"^(Lint|Warning)-\[([^]]+)\][^\n]*\n(.+?), (\d+)\n(.*?)(?=\n\n|\Z)"
    parsed=0
    for m in re.finditer(pattern,content,re.M|re.S):
        parsed+=1
        severity,tag,path,_,detail=m.groups()
        detail=re.sub(r"\s+"," ",detail).strip()
        for prefix in ("wally/src/","tinynpu/src/","output/"):
            if prefix in path:
                path=prefix+path.split(prefix,1)[1]
                break
        # SVA syntax notices describe active assertions, rather than RTL errors.
        sva=path.startswith("tinynpu/src/") and tag in {"SVA-CE","SVA-DIU"}
        unused=(path=="tinynpu/src/tinynpu_top.sv" and detail in {
            "Following is an unused input. Source info: s_HBURST",
            "Following is an unused input. Source info: s_HPROT",
            "Following is an unused input. Source info: s_HMASTLOCK"}) or (
            path=="output/wally_npu_matrix/wally_npu_matrix.v" and detail in {
            "Following is an unused input. Source info: REMAP",
            "Following is an unused input. Source info: SCANENABLE"})
        if severity=="Lint" and (sva or (tag=="UI" and unused)):
            intentional+=1
        else:
            actual[(severity,tag,path,detail)]+=1
    total=len(re.findall(r"^(?:Lint|Warning)-\[",content,re.M))
    if parsed!=total:
        raise SystemExit("[FAIL] unparsed lint diagnostics; inspect raw log")
    unexpected=actual-allowed
    if unexpected:
        for diagnostic,count in unexpected.items():
            print(f"[FAIL] {count} new diagnostic(s): {diagnostic}")
        raise SystemExit(1)
    print(f"[PASS] lint: {sum(actual.values())} existing Wally diagnostics, "
          f"{intentional} documented SVA/unused-input notices, zero new diagnostics")
print(f"[PASS] checked {args.log.name}")

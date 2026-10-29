# 같은 ELF와 SoC 조건에서 얻은 CPU 및 NPU의 전체 추론 사이클을 비교한다.
import csv
import argparse
import json
from pathlib import Path

BUILD=Path(__file__).resolve().parent/"build"

def compare(cpu,npu):
    for key in ("firmware_sha256","model_sha256","simulation_sources_sha256","repeats",
                "simulator","simulation_executable_sha256"):
        if cpu[key]!=npu[key]: raise ValueError(f"different comparison condition: {key}")
    if cpu.get("comparison_id")!=npu.get("comparison_id"):
        raise ValueError("different comparison invocation")
    if cpu["firmware"]!="compare" or npu["firmware"]!="compare" or cpu["backend"]!="cpu" or npu["backend"]!="npu":
        raise ValueError("both results must use compare.elf with different backends")
    cpu_rows={(r["sample"],r["run"]):r for r in cpu["network"]}
    npu_rows={(r["sample"],r["run"]):r for r in npu["network"]}
    if not cpu_rows or cpu_rows.keys()!=npu_rows.keys() or len(cpu_rows)!=len(cpu["network"]) or len(npu_rows)!=len(npu["network"]):
        raise ValueError("different samples/runs or duplicate results")
    for sample in {s for s,_ in cpu_rows}:
        if {r for s,r in cpu_rows if s==sample}!=set(range(cpu["repeats"])):
            raise ValueError("incomplete repeated inferences")
    rows=[]
    for sample,run in sorted(cpu_rows):
        c,n=cpu_rows[sample,run],npu_rows[sample,run]
        if c["input_sha256"]!=n["input_sha256"]:
            raise ValueError(f"different input: sample={sample} run={run}")
        if c["q"]!=n["q"] or c["predicted_index"]!=n["predicted_index"]:
            raise ValueError(f"score mismatch: sample={sample} run={run}")
        if c["cpu_cycles"]<=0 or n["cpu_cycles"]<=0 or c["npu_cycles"]!=0 or n["npu_cycles"]<=0:
            raise ValueError("invalid CPU/NPU counters")
        rows.append(dict(sample=sample,run=run,cpu_only_cycles=c["cpu_cycles"],
                         npu_end_to_end_cycles=n["cpu_cycles"],npu_csr_cycles=n["npu_cycles"],
                         speedup=c["cpu_cycles"]/n["cpu_cycles"]))
    return rows

if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--output-dir",type=Path,default=BUILD)
    parser.add_argument("--comparison-id")
    args=parser.parse_args()
    BUILD=args.output_dir.resolve()
    if not (BUILD/"compare_cpu_results.json").exists() or not (BUILD/"compare_npu_results.json").exists():
        raise SystemExit("[FAIL] run make compare, or both make compare-npu and make compare-cpu, first")
    cpu=json.loads((BUILD/"compare_cpu_results.json").read_text())
    npu=json.loads((BUILD/"compare_npu_results.json").read_text())
    try:
        if args.comparison_id and any(r.get("comparison_id")!=args.comparison_id for r in (cpu,npu)):
            raise ValueError("stale results: comparison ID does not match requested invocation")
        rows=compare(cpu,npu)
    except (KeyError,ValueError) as error:
        raise SystemExit(f"[FAIL] {error}; rerun both comparison backends")
    report={key:cpu[key] for key in ("firmware_sha256","model_sha256","simulation_sources_sha256","repeats",
                                    "simulator","simulation_executable_sha256")}
    report["comparison_id"]=cpu.get("comparison_id")
    report.update(rows=rows,definition="CPU-only mcycle / NPU end-to-end mcycle; DMA/cache/polling included")
    (BUILD/"comparison.json").write_text(json.dumps(report,indent=2)+"\n")
    with (BUILD/"comparison.csv").open("w",newline="") as stream:
        writer=csv.DictWriter(stream,fieldnames=rows[0].keys())
        writer.writeheader(); writer.writerows(rows)
    for row in rows:
        print(f"[PASS] sample={row['sample']} run={row['run']} CPU-only={row['cpu_only_cycles']} "
              f"NPU end-to-end={row['npu_end_to_end_cycles']} speedup={row['speedup']:.3f}x")

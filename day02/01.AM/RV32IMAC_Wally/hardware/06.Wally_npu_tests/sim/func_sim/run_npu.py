# 실제 RTL 펌웨어 실행의 계층별 결과와 UART 완료 및 사이클 측정값을 수집한다.
import argparse
import csv
import hashlib
import json
import re
import subprocess
from pathlib import Path

HERE=Path(__file__).resolve().parent
BUILD=HERE/"build"
SW=HERE.parents[3]/"software/npu"
parser=argparse.ArgumentParser()
parser.add_argument("--samples",type=int,nargs="+",default=[124])
parser.add_argument("--firmware",choices=("npu","compare"),default="npu")
parser.add_argument("--backend",choices=("npu","cpu"),default="npu")
parser.add_argument("--simulator",choices=("vcs","verilator"),default="vcs")
parser.add_argument("--sim",type=Path,help="RTL simulator executable")
parser.add_argument("--output-dir",type=Path,help="Run logs/results (golden vectors stay in build/golden)")
parser.add_argument("--waveform",action="store_true",help="Capture native first-layer FST (make wave)")
args=parser.parse_args()
sim=(args.sim or HERE/"simv").resolve()
output_dir=(args.output_dir or BUILD).resolve()
output_dir.mkdir(parents=True,exist_ok=True)
if not sim.is_file():
    raise SystemExit(f"[FAIL] simulator executable not found: {sim}")
if args.backend=="cpu" and args.firmware!="compare":
    parser.error("CPU-only requires --firmware compare")
if args.waveform and (args.simulator!="verilator" or args.backend!="npu"):
    parser.error("Waveform capture requires the Verilator NPU path")
manifest_name="manifest.json" if args.firmware=="npu" else "manifest_compare.json"
manifest=json.loads((BUILD/"golden"/manifest_name).read_text())
symbols=manifest["symbols"]
elf=SW/f"{args.firmware}.elf"
if hashlib.sha256(elf.read_bytes()).hexdigest()!=manifest["firmware_sha256"]:
    raise SystemExit("[FAIL] ELF changed; regenerate vectors before simulation")
source_files={(HERE/line).resolve() for line in (HERE/"run.f").read_text().splitlines() if line.startswith(".")}
source_files.update((HERE/"run.f",HERE/"Makefile",HERE/"run_npu.py",HERE/"prepare_vectors.py"))
if args.simulator=="verilator":
    source_files.update((HERE/"Makefile.verilator",HERE/"verilator_env.cpp",HERE/"testbench_verilator.sv",HERE/"story_signals.svh",HERE/"story_main.cpp"))
source_files.update((HERE/"../../testbench").glob("*.svh"))
source_files.update((HERE/"../../testbench").glob("*.vh"))
for folder in ("rv32imac_cache","shared"):
    source_files.update((HERE/f"../../../source/wally/config/{folder}").glob("*.vh"))
fingerprint=hashlib.sha256()
for path in sorted({p.resolve() for p in source_files}):
    fingerprint.update(str(path.relative_to(HERE.parents[3])).encode()+b"\0"+path.read_bytes())
prefix="" if args.firmware=="npu" else f"compare_{args.backend}_"
backend_label="CPU" if args.backend=="cpu" else "NPU"
records=[]
metrics=[]
waveforms=[]
for index in args.samples:
    case=next((s for s in manifest["samples"] if s["index"]==index),None)
    if case is None: raise SystemExit(f"Unsupported sample {index}; choose 0, 124 or 248")
    for filename,key in (("gray.hex","input_sha256"),("trace.hex","trace_sha256")):
        data=bytes(int(v,16) for v in (Path(case["directory"])/filename).read_text().split())
        if hashlib.sha256(data).hexdigest()!=case[key]:
            raise SystemExit(f"[FAIL] golden vector changed: {filename}; regenerate vectors")
    log=output_dir/f"{prefix}sample_{index}.log"
    uart=output_dir/f"{prefix}uart_{index}.log"
    command=[str(sim)]
    if args.simulator=="vcs": command.extend(["-no_save","+vcs+lic+wait"])
    command.extend(["+TEST=npu",
             "+ElfFile="+str(elf),"+UART_LOG=1","+UART_LOG_FILE="+str(uart),
             "+sim_log_prefix="+str(output_dir/f"{prefix}sample_{index}_"),
             f"+NPU_SAMPLE={index}","+NPU_VECTORS="+case["directory"]])
    for name,key in (("FRAME","demo_frame"),("RESULT","firmware_result"),
                     ("CYCLES","firmware_cycles"),("STATS","firmware_layer_stats")):
        command.append(f"+NPU_{name}_ADDR={symbols[key]:08x}")
    if args.firmware=="compare":
        command.extend([f"+COMPARE_MODE_ADDR={symbols['firmware_backend']:08x}",
                        f"+COMPARE_RESULTS_ADDR={symbols['firmware_run_results']:08x}"])
    if args.backend=="cpu": command.append("+CPU_ONLY")
    if args.waveform:
        wave=output_dir/f"sample_{index}_first_layer.fst"
        command.append("+STORY_FILE="+str(wave))
    print(f"[RUN] {args.simulator} {args.firmware}/{args.backend} sample={index}, two complete CNN inferences",flush=True)
    with log.open("w") as stream:
        try:
            result=subprocess.run(command,cwd=HERE,stdout=stream,stderr=subprocess.STDOUT,
                                  timeout=None if args.backend=="cpu" else 900)
        except subprocess.TimeoutExpired:
            raise SystemExit(f"[FAIL] simulation exceeded 900 seconds; see {log}")
    content=log.read_text(errors="replace")
    if result.returncode or re.search(r"^(?:Error[-:]|Fatal:|FAILURE:|\[FAIL\])",content,re.M):
        raise SystemExit(f"[FAIL] {args.simulator} sample {index}, exit={result.returncode}; see {log}")
    if args.waveform:
        if not wave.is_file() or wave.stat().st_size==0:
            raise SystemExit("[FAIL] missing FST; build with make -f Makefile.verilator wave")
        waveforms.append({"sample":index,"file":wave.name,
                          "sha256":hashlib.sha256(wave.read_bytes()).hexdigest()})
    commands=0 if args.backend=="cpu" else 12
    if not re.search(rf"^\[PASS\] {backend_label} firmware sample={index} commands={commands}\b",content,re.M):
        raise SystemExit(f"[FAIL] missing full NPU verification marker; see {log}")
    uart_text=uart.read_text(errors="replace") if uart.exists() else ""
    if "[PASS]" not in uart_text or "[FAIL]" in uart_text:
        raise SystemExit(f"[FAIL] firmware UART did not report success; see {uart}")
    network=re.findall(rf"\[{backend_label}_NETWORK\] sample=(\d+) run=(\d+) cpu_cycles=(\d+) npu_cycles=(\d+)",content)
    layers=re.findall(r"\[NPU_METRIC\] sample=(\d+) run=(\d+) layer=(\d+) cpu_cycles=(\d+) npu_cycles=(\d+) polls=(\d+)",content)
    if len(network)!=2 or len(layers)!=(0 if args.backend=="cpu" else 12):
        raise SystemExit("[FAIL] incomplete cycle report")
    for sample,run,cpu,npu in network:
        records.append(dict(sample=int(sample),run=int(run),cpu_cycles=int(cpu),npu_cycles=int(npu),
                            predicted_index=case["predicted_index"],q=case["q"],input_sha256=case["input_sha256"]))
        print(f"[PASS] sample={sample} run={run} CPU={cpu} NPU={npu} q={case['q']}",flush=True)
    for values in layers:
        metrics.append(dict(zip(("sample","run","layer","cpu_cycles","npu_cycles","polls"),map(int,values))))
report={"firmware":args.firmware,"backend":args.backend,"simulator":args.simulator,
        "simulation_executable_sha256":hashlib.sha256(sim.read_bytes()).hexdigest(),
        "firmware_sha256":manifest["firmware_sha256"],"model_sha256":manifest["model_sha256"],
        "simulation_sources_sha256":fingerprint.hexdigest(),"repeats":2,
        "network":records,"layers":metrics,"waveforms":waveforms,"verified_layer_bytes":0 if args.backend=="cpu" else len(records)*3747,
        "cycle_scope":"Inference-call CPU mcycle; excludes LUT, UART and validation; NPU path includes cache/DMA/wait."}
tool_file=sim.parent/"tool_versions.json"
if args.simulator=="verilator" and tool_file.is_file():
    report["tools"]=json.loads(tool_file.read_text())
(output_dir/f"{prefix}results.json").write_text(json.dumps(report,indent=2)+"\n")
with (output_dir/f"{prefix}cycles.csv").open("w",newline="") as stream:
    writer=csv.DictWriter(stream,fieldnames=("sample","run","cpu_cycles","npu_cycles"))
    writer.writeheader()
    for row in records: writer.writerow({k:row[k] for k in writer.fieldnames})
print(f"[PASS] {len(records)} CNN inferences, {len(metrics)} layers, {report['verified_layer_bytes']} output bytes")

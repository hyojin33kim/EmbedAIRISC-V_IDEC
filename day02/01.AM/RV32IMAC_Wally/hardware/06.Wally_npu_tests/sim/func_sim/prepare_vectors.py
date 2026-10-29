# 기존 C CNN 모델로 대표 입력의 계층별 정답과 펌웨어 심볼 정보를 생성한다.
import argparse
import csv
import ctypes as ct
import hashlib
import json
import re
import subprocess
from pathlib import Path

HERE=Path(__file__).resolve().parent
BASE=HERE.parents[2].parent
SW=BASE/"software/npu"
REPO=BASE.parents[2]
SOURCE=REPO/"day01/02.PM/ver2/int8_c"
OUT=HERE/"build/golden"
parser=argparse.ArgumentParser()
parser.add_argument("--firmware",choices=("npu","compare"),default="npu")
args=parser.parse_args()
target=args.firmware
OUT.mkdir(parents=True,exist_ok=True)
subprocess.run(["gcc","-O2","-std=c11","-Wall","-Wextra","-Werror",
                "-DMODEL_INTEGER_ONLY","-include","firmware_no_float.h",
                "-fPIC","-shared","model.c","-o",str(OUT/"reference.so")],cwd=SW,check=True)
model=ct.CDLL(str(OUT/"reference.so"))
p8=ct.POINTER(ct.c_uint8)
model.model_infer_u8_trace.argtypes=[p8,p8,ct.c_void_p,p8,ct.c_size_t]
model.model_source_sha256.restype=ct.c_char_p
inputs=json.loads((SOURCE/"outputs/input_manifest.json").read_text())
gray=(SOURCE/"outputs/test_inputs_gray8.bin").read_bytes()
quantized=(SOURCE/"outputs/test_inputs_u8.bin").read_bytes()
assert model.model_source_sha256().decode()==inputs["source_model_sha256"]
for name,data in (("test_inputs_gray8.bin",gray),("test_inputs_u8.bin",quantized)):
    assert hashlib.sha256(data).hexdigest()==inputs["files_sha256"][name]
with (SOURCE/"outputs/c_predictions_u8.csv").open() as stream:
    expected=list(csv.DictReader(stream))
addresses=(SW/f"{target}.elf.objdump.addr").read_text().splitlines()
names=(SW/f"{target}.elf.objdump.lab").read_text().splitlines()
symbols=dict(zip(names,(int(a,16) for a in addresses)))
for name in ("demo_frame","firmware_result","firmware_cycles","firmware_layer_stats"):
    assert 0x80000000<=symbols[name]<0x88000000,name
if target=="npu":
    for name in ("model_infer_u8","model_infer_u8_trace","convolution_at","linear"):
        assert name not in symbols,f"Software CNN remains in target ELF: {name}"
else:
    for name in ("model_infer_u8","npu_model_infer_u8","firmware_backend","firmware_run_results"):
        assert name in symbols,name
    for name in ("model.c","model_data.h","model_param.h","demo_frame.h"):
        assert (SW/name).read_bytes()==(REPO/"day01/01.AM/RV32IMAC_Wally/software/cnn"/name).read_bytes()
elf=(SW/f"{target}.elf").read_bytes()
binary=(SW/f"{target}.bin").read_bytes()
words=bytes().join(int(s,16).to_bytes(4,"little") for s in (SW/f"{target}.elf.memfile").read_text().split())
assert words==binary and symbols["_start"]==0x80000000
if target=="compare":
    offset=symbols["firmware_backend"]-0x80000000
    assert binary[offset:offset+4]==bytes.fromhex("0055504e"),"Selector must be initialized .data"
manifest={"model_sha256":inputs["source_model_sha256"],"firmware_sha256":hashlib.sha256(elf).hexdigest(),
          "firmware":target,"symbols":symbols,"repeats":2,"samples":[]}
for index in (0,124,248):
    case=OUT/f"sample_{index}"
    case.mkdir(exist_ok=True)
    frame=gray[index*1024:(index+1)*1024]
    original=quantized[index*1024:(index+1)*1024]
    source=(ct.c_uint8*1024).from_buffer_copy(original)
    output=(ct.c_uint8*3)(); trace=(ct.c_uint8*3747)()
    storage=ct.create_string_buffer(4096+63)
    workspace=ct.c_void_p((ct.addressof(storage)+63)&~63)
    assert model.model_infer_u8_trace(source,output,workspace,trace,3747)==0
    assert list(output)==[int(expected[index][f"q{i}"]) for i in range(3)]
    if index==124:
        values=re.search(r"demo_frame\[1024\]\s*=\s*\{([^}]+)\}",(SW/"demo_frame.h").read_text()).group(1)
        assert frame==bytes(map(int,re.findall(r"\d+",values))),"Default demo_frame changed"
    for name,data in (("gray",frame),("trace",bytes(trace))):
        (case/f"{name}.hex").write_text("".join(f"{v:02x}\n" for v in data))
    row={"index":index,"label":inputs["samples"][index]["label"],"q":list(output),
         "predicted_index":max(range(3),key=lambda i:output[i]),"directory":str(case),
         "input_sha256":hashlib.sha256(frame).hexdigest(),"trace_sha256":hashlib.sha256(bytes(trace)).hexdigest()}
    manifest["samples"].append(row)
manifest_name="manifest.json" if target=="npu" else "manifest_compare.json"
(OUT/manifest_name).write_text(json.dumps(manifest,indent=2)+"\n")
print(f"[PASS] {target} ELF/preload and independent C traces for samples 0/124/248")

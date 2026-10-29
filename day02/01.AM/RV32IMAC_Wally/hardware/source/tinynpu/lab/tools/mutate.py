# Lab 9: RTL 복사본에 버그 하나를 주입하고 기존 단위 TB와 6계층 top 실습 중 어느 것이 잡는지 확인한다.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
import argparse
import re
import shutil
import subprocess
from pathlib import Path

LAB = Path(__file__).resolve().parents[1]
ROOT = LAB.parent
MUTANTS = {
    "M1": ("tinynpu_requant.sv", "increment = remainder > half || (remainder == half && quotient[0]);",
           "increment = remainder >= half;", "반올림: ties-to-even 대신 half-up"),
    "M2": ("tinynpu_mac.sv", "acc_o <= acc_o + {{14{product[17]}}, product};",
           "acc_o <= acc_o + {14'b0, product};", "MAC: 18 bit 곱을 부호 확장하지 않음"),
    "M3": ("tinynpu_pool.sv", "if (count == 3'd3) max_valid_o <= 1'b1;",
           "if (count == 3'd2) max_valid_o <= 1'b1;", "pool: 3번째 sample에서 max_valid"),
    "M4": ("tinynpu_addrgen.sv", "padding_o = iy < 0 || ix < 0 ||",
           "padding_o = ix < 0 ||", "addrgen: 위쪽(iy < 0) padding 판정 누락"),
    "M5": ("tinynpu_compute.sv", "assign mac_a = $signed({1'b0, ifm_byte}) - $signed({1'b0, cfg.input_zero});",
           "assign mac_a = $signed({1'b0, ifm_byte});", "compute: INPUT_ZERO 보정 누락"),
    "M6": ("tinynpu_cfg_check.sv", "end else if (({1'b0, cfg_i.dst_addr} < src_end",
           "end else if (1'b0 && ({1'b0, cfg_i.dst_addr} < src_end", "cfg_check: DST-SRC 겹침 검사 누락"),
    "M7": ("tinynpu_ahb_slave.sv", "assign s_HREADYOUT = !rst_n || !data_valid || error_second || !access_error;",
           "assign s_HREADYOUT = 1'b1;", "ahb_slave: ERROR 첫 cycle에도 HREADYOUT=1"),
    "M8": ("tinynpu_csr.sv", "if (reg_wdata_i[1]) done_flag <= 1'b0;",
           "if (1'b0) done_flag <= 1'b0;", "csr: STATUS.DONE W1C 미동작"),
    "M9": ("tinynpu_controller.sv", "assign weight_addr = cfg.weight_addr + {24'b0, oc} * {16'b0, shape.wgt_per_oc};",
           "assign weight_addr = cfg.weight_addr;", "controller: 채널별 weight 주소 증가 누락"),
    "M10": ("tinynpu_dma_plan.sv", "if (words > boundary_words) words = boundary_words;",
            "words = words;", "dma_plan: 1 KiB 경계 제한 누락"),
    "M11": ("tinynpu_ahb_master.sv", "(a_index_q == 0 ? 2'b10 : 2'b11)",
            "(2'b10)", "ahb_master: burst 안의 beat도 NONSEQ"),
    "M12": ("tinynpu_local_mem.sv", "assign ifm_read = rst_n && phase_i == MEM_COMPUTE && ifm_rd_en_i",
            "assign ifm_read = rst_n && ifm_rd_en_i", "local_mem: IFM read의 phase 검사 누락"),
}
TESTS = ["tb_tinynpu_arithmetic", "tb_tinynpu_memory", "tb_tinynpu_compute", "tb_tinynpu_control",
         "tb_tinynpu_controller", "tb_tinynpu_ahb_master", "tb_tinynpu_dma", "lab7_top_layer"]
FLAGS = ["-full64", "-sverilog", "-timescale=1ns/1ps", "+vcs+lic+wait"]


def run_test(work, sources, test, vectors):
    bench = LAB / "solution" / f"{test}.sv" if test.startswith("lab") else ROOT / "testbench" / f"{test}.sv"
    models = [ROOT / "testbench" / "ahb_sram_model.sv", ROOT / "testbench" / "ahb_master_bfm.sv"]
    compile_log = work / f"compile_{test}.log"
    result = subprocess.run(["vcs", *FLAGS, *map(str, sources + models + [bench]), "-top", test,
                             f"-Mdir=csrc_{test}", "-o", f"simv_{test}", "-l", compile_log.name],
                            cwd=work, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    if result.returncode:
        return "COMPILE", compile_log.read_text(errors="replace")[-300:]
    log = work / f"{test}.log"
    subprocess.run([f"./simv_{test}", "-q", "-no_save", "+vcs+lic+wait", f"+VECTORS={vectors}", "+ALL",
                    "-l", log.name], cwd=work, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    content = log.read_text(errors="replace")
    failure = re.search(r"^.*(?:Fatal|Error).*$", content, re.M)
    if failure or not re.search(r"^\[PASS\] (?:tb_tinynpu|lab8)", content, re.M):
        lines = content.strip().splitlines()
        message = failure.group(0) if failure else next(
            (line for line in reversed(lines) if line.startswith(("[TODO]", "[LAB7] L"))), lines[-1])
        following = content[failure.end():].strip().splitlines()[:1] if failure else []
        detail = " ".join([message.strip()] + [line.strip() for line in following])
        return "FAIL", re.sub(r'"[^"]*/([^/"]+)"', r"\1", detail)[:120]
    return "PASS", ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mutant", help="list | all | M1..M12")
    parser.add_argument("--build", type=Path, default=LAB / "build" / "mutants")
    args = parser.parse_args()
    if args.mutant == "list":
        for key, (file, _, _, text) in MUTANTS.items():
            print(f"{key:4} {file:24} {text}")
        return
    selected = list(MUTANTS) if args.mutant == "all" else [args.mutant]
    vectors = args.build.parent / "vectors"
    if not (vectors / "layers.txt").exists():
        subprocess.run(["python3", str(LAB / "tools" / "make_vectors.py"), "--output", str(vectors)], check=True)
    order = [Path(line.strip()).name for line in (ROOT / "sim" / "run.f").read_text().split() if line.strip()]
    summary = []
    for key in selected:
        file, original, mutated, text = MUTANTS[key]
        work = args.build / key
        shutil.rmtree(work, ignore_errors=True)
        shutil.copytree(ROOT / "src", work / "src")
        target = work / "src" / file
        content = target.read_text()
        assert content.count(original) == 1, f"{key}: 원본 문장을 찾지 못함"
        target.write_text(content.replace(original, mutated))
        print(f"[LAB9] {key} {file}: {text}")
        caught = []
        for test in TESTS:
            status, detail = run_test(work, [work / "src" / name for name in order], test, vectors.resolve())
            print(f"[LAB9]   {test:24} {status:7} {detail}")
            if status != "PASS":
                caught.append(test.replace("tb_tinynpu_", "").replace("lab7_top_layer", "top6"))
        summary.append((key, text, caught))
    print("[LAB9] 요약 — 버그를 잡은 테스트")
    for key, text, caught in summary:
        print(f"[LAB9] {key:4} {text:38} -> {', '.join(caught) if caught else '잡지 못함'}")


if __name__ == "__main__":
    main()

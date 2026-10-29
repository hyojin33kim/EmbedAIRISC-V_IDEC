# CMSDK와 Wally 및 tinyNPU 통합의 VCS 컴파일과 버스 및 CPU 실행을 검증한다.
SHELL := /bin/bash
VCS ?= vcs
CROSS ?= /opt/riscv/bin/riscv64-unknown-elf-
BUILD := $(CURDIR)/build
RTL := $(abspath $(addprefix $(BUILD)/,$(shell sed -n '/^[^+]/p' run.f)))
CONFIG := $(wildcard ../../wally/config/rv32imac_cache/*.vh ../../wally/config/shared/*.vh)
VFLAGS := -full64 -sverilog -timescale=1ns/1ps +vcs+lic+wait +lint=all
CFLAGS := -march=rv32imac_zicsr_zifencei_zicbom -mabi=ilp32 -O2 -Wall -Wextra -Werror -ffreestanding -fno-builtin -msmall-data-limit=0 -nostdlib -nostartfiles -Wl,--gc-sections -T ../testbench/cpu.ld
TB := ../../testbench/tb_wally_npu_soc.sv
BFM := ../../../tinynpu/testbench/ahb_master_bfm.sv ../../../tinynpu/testbench/ahb_sram_model.sv
BFM_SRC := $(abspath $(addprefix $(BUILD)/,$(BFM)))

.PHONY: all generate bus cpu bypass lint
all: bus cpu bypass lint
generate:
	python3 ../generate.py
$(BUILD):
	mkdir -p $@
$(BUILD)/cpu.elf: ../testbench/cpu_test.c ../testbench/cpu_start.S ../testbench/cpu.ld | $(BUILD)
	$(CROSS)gcc $(CFLAGS) ../testbench/cpu_start.S ../testbench/cpu_test.c -o $@
$(BUILD)/plain.elf: ../testbench/cpu_test.c ../testbench/cpu_start.S ../testbench/cpu.ld | $(BUILD)
	$(CROSS)gcc $(CFLAGS) -DCPU_ONLY ../testbench/cpu_start.S ../testbench/cpu_test.c -o $@
$(BUILD)/%.bin: $(BUILD)/%.elf
	$(CROSS)objcopy -O binary $< $@
	truncate -s %4 $@
$(BUILD)/%.mem: $(BUILD)/%.bin
	od -An -v -tx4 -w4 $< | tr -d ' ' > $@

$(BUILD)/simv_%: run.f $(RTL) $(CONFIG) $(BFM_SRC) ../testbench/tb_wally_npu_soc.sv | $(BUILD)
	cd $(BUILD) && $(VCS) $(VFLAGS) -f ../run.f $(BFM) $(TB) -top tb_wally_npu_soc $(if $(filter cpu,$*),-pvalue+tb_wally_npu_soc.BUS_TEST=0,$(if $(filter bypass,$*),-pvalue+tb_wally_npu_soc.BUS_TEST=0 -pvalue+tb_wally_npu_soc.NPU_ENABLE=0,)) -Mdir=csrc_$* -o simv_$* -l compile_$*.log > compile_$*.stdout 2>&1
	python3 check_logs.py --compile $(BUILD)/compile_$*.log
bus: $(BUILD)/simv_bus
	cd $(BUILD) && ./simv_bus -no_save +vcs+lic+wait -l bus.log
	python3 check_logs.py $(BUILD)/bus.log
cpu: $(BUILD)/simv_cpu $(BUILD)/cpu.mem
	cd $(BUILD) && ./simv_cpu -no_save +vcs+lic+wait +FW=cpu.mem -l cpu.log
	python3 check_logs.py $(BUILD)/cpu.log
bypass: $(BUILD)/simv_bypass $(BUILD)/plain.mem
	cd $(BUILD) && ./simv_bypass -no_save +vcs+lic+wait +FW=plain.mem -l bypass.log
	python3 check_logs.py $(BUILD)/bypass.log
$(BUILD)/simv_lint: run.f $(RTL) $(CONFIG) ../testbench/tb_wally_npu_lint.sv | $(BUILD)
	cd $(BUILD) && $(VCS) $(VFLAGS) -f ../run.f ../../testbench/tb_wally_npu_lint.sv -top tb_wally_npu_lint -Mdir=csrc_lint -o simv_lint -l compile_lint.log > compile_lint.stdout 2>&1
lint: $(BUILD)/simv_lint
	python3 check_logs.py --lint $(BUILD)/compile_lint.log

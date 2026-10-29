# tinyNPU의 VCS 단위 검증과 실제 C 모델 전체 회귀를 실행한다.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
SHELL := /bin/bash
VCS ?= vcs
VCS_FLAGS := -full64 -sverilog -timescale=1ns/1ps +lint=all +vcs+lic+wait
SIM_FLAGS ?= -no_save +vcs+lic+wait
BUILD := $(CURDIR)/build
GOLDEN := $(CURDIR)/golden
SRC := $(wildcard ../src/*.sv)
TESTBENCH := $(wildcard ../testbench/*.sv)
JOBS ?= 2
MODEL := ../../../../software/cnn
INPUTS := ../../../../../../02.PM/ver2/int8_c/outputs

.PHONY: all golden lint unit dma layer cnn clean
all: lint unit dma layer cnn

golden: $(GOLDEN)/manifest.json
$(GOLDEN)/manifest.json: ../tools/export_golden.py $(MODEL)/model.c $(wildcard $(MODEL)/model*.h) $(MODEL)/firmware_no_float.h $(INPUTS)/test_inputs_u8.bin $(INPUTS)/input_manifest.json $(INPUTS)/c_predictions_u8.csv
	python3 ../tools/export_golden.py --output $(GOLDEN)

$(BUILD):
	mkdir -p $@

$(BUILD)/simv_%: $(SRC) $(TESTBENCH) run.f | $(BUILD)
	cd $(BUILD) && $(VCS) $(VCS_FLAGS) -f ../run.f ../../testbench/ahb_sram_model.sv ../../testbench/ahb_master_bfm.sv ../../testbench/$*.sv -top $* -Mdir=csrc_$* -o simv_$* -l compile_$*.log
	python3 ../tools/check_vcs_log.py --compile $(BUILD)/compile_$*.log

lint: $(SRC) run.f | $(BUILD)
	cd $(BUILD) && $(VCS) $(VCS_FLAGS) -f ../run.f -top tinynpu_top -Mdir=csrc_lint -o simv_lint -l lint.log
	python3 ../tools/check_vcs_log.py --lint $(BUILD)/lint.log

unit: $(BUILD)/simv_tb_tinynpu_arithmetic $(BUILD)/simv_tb_tinynpu_memory $(BUILD)/simv_tb_tinynpu_compute $(BUILD)/simv_tb_tinynpu_control $(BUILD)/simv_tb_tinynpu_controller
	cd $(BUILD) && ./simv_tb_tinynpu_arithmetic $(SIM_FLAGS) -l arithmetic.log
	python3 ../tools/check_vcs_log.py $(BUILD)/arithmetic.log
	cd $(BUILD) && ./simv_tb_tinynpu_memory $(SIM_FLAGS) -l memory.log
	python3 ../tools/check_vcs_log.py $(BUILD)/memory.log
	cd $(BUILD) && ./simv_tb_tinynpu_compute $(SIM_FLAGS) -l compute.log
	python3 ../tools/check_vcs_log.py $(BUILD)/compute.log
	cd $(BUILD) && ./simv_tb_tinynpu_control $(SIM_FLAGS) -l control.log
	python3 ../tools/check_vcs_log.py $(BUILD)/control.log
	cd $(BUILD) && ./simv_tb_tinynpu_controller $(SIM_FLAGS) -l controller.log
	python3 ../tools/check_vcs_log.py $(BUILD)/controller.log

dma: $(BUILD)/simv_tb_tinynpu_ahb_master $(BUILD)/simv_tb_tinynpu_dma
	cd $(BUILD) && ./simv_tb_tinynpu_ahb_master $(SIM_FLAGS) -l ahb_master.log
	python3 ../tools/check_vcs_log.py $(BUILD)/ahb_master.log
	cd $(BUILD) && ./simv_tb_tinynpu_dma $(SIM_FLAGS) -l dma.log
	python3 ../tools/check_vcs_log.py $(BUILD)/dma.log

layer: golden $(BUILD)/simv_tb_tinynpu_top
	cd $(BUILD) && ./simv_tb_tinynpu_top $(SIM_FLAGS) +GOLDEN=$(GOLDEN) +CASE_COUNT=6 -l layer.log
	python3 ../tools/check_vcs_log.py $(BUILD)/layer.log
	cd $(BUILD) && ./simv_tb_tinynpu_top $(SIM_FLAGS) +GOLDEN=$(GOLDEN) +CASE_START=2232 +CASE_COUNT=18 -l general.log
	python3 ../tools/check_vcs_log.py $(BUILD)/general.log

cnn: golden $(BUILD)/simv_tb_tinynpu_top
	python3 ../tools/run_cnn.py --sim $(BUILD)/simv_tb_tinynpu_top --golden $(GOLDEN) --jobs $(JOBS) --logs $(BUILD)

clean:
	rm -rf $(BUILD) $(GOLDEN)

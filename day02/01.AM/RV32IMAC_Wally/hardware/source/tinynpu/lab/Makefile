# tinyNPU 설계 실습(Lab 0~9)을 VCS로 실행하고 FSDB 파형과 로그를 build/에 남긴다.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
SHELL := /bin/bash
VCS ?= vcs
VERDI ?= verdi
BUILD := $(CURDIR)/build
TB_DIR := $(if $(filter 1,$(SOL)),$(CURDIR)/solution,$(CURDIR)/tb)
RTL := $(addprefix $(CURDIR)/../src/,$(notdir $(shell cat $(CURDIR)/../sim/run.f)))
MODELS := $(CURDIR)/../testbench/ahb_master_bfm.sv $(CURDIR)/../testbench/ahb_sram_model.sv
VCS_FLAGS := -full64 -sverilog -timescale=1ns/1ps +vcs+lic+wait -kdb -debug_access+all +define+FSDB
SIM_FLAGS := -q -no_save +vcs+lic+wait
LAB ?= lab3
MUT ?= list

TB_lab1 := lab1_requant
TB_lab2 := lab2_cfg_check
TB_lab3 := lab3_csr_wave
TB_lab4 := lab4_compute
TB_lab5 := lab5_dma_plan
TB_lab6 := lab6_dma_wave
TB_lab7 := lab7_top_layer
TB_lab8 := lab7_top_layer
ARGS_lab7 := +VECTORS=$(BUILD)/vectors
ARGS_lab8 := +VECTORS=$(BUILD)/vectors +ALL
LABS := lab1 lab2 lab3 lab4 lab5 lab6 lab7 lab8

.PHONY: help lab0 $(LABS) lab9 vectors wave solutions clean
help:
	@echo "make lab0            기존 회귀 (lint, unit, dma)"
	@echo "make lab1 ... lab8   실습 실행 (tb/의 TODO를 채운 뒤), SOL=1 이면 solution/ 사용"
	@echo "make lab9 MUT=M1     버그 주입 후 단위 TB 실행 (MUT=list | M1..M12 | all)"
	@echo "make wave LAB=lab3   Verdi로 build/lab3.fsdb 열기"

$(BUILD):
	mkdir -p $@

lab0:
	$(MAKE) -C ../sim lint unit dma

vectors: $(BUILD)/vectors/layers.txt
$(BUILD)/vectors/layers.txt: tools/make_vectors.py | $(BUILD)
	python3 tools/make_vectors.py --output $(BUILD)/vectors

lab7 lab8: vectors
$(LABS): | $(BUILD)
	@cd $(BUILD) && $(VCS) $(VCS_FLAGS) $(RTL) $(MODELS) $(TB_DIR)/$(TB_$@).sv -top $(TB_$@) \
	  -Mdir=csrc_$@ -o simv_$@ -l compile_$@.log > /dev/null || { tail -n 30 compile_$@.log; exit 1; }
	@cd $(BUILD) && ./simv_$@ $(SIM_FLAGS) $(ARGS_$@) +FSDB_FILE=$@.fsdb -l $@.log > /dev/null; \
	  grep -E '^\[(LAB|PASS|TODO)|Error|Fatal' $@.log

lab9: | $(BUILD)
	python3 tools/mutate.py $(MUT) --build $(BUILD)/mutants

wave:
	cd $(BUILD) && $(VERDI) -dbdir simv_$(LAB).daidir -ssf $(LAB).fsdb &

solutions:
	@for lab in $(LABS); do $(MAKE) --no-print-directory $$lab SOL=1 | grep -E '^\[(PASS|TODO)\]|Error|Fatal'; done

clean:
	rm -rf $(BUILD)

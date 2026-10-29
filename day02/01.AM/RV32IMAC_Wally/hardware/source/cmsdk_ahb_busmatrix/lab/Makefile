# AHB 실습(Lab 1~4)을 VCS로 컴파일·실행하고 FSDB 파형과 로그를 build/에 남긴다.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
SHELL := /bin/bash
VCS ?= vcs
VERDI ?= verdi
BUILD := $(CURDIR)/build
RTL_DIR := $(if $(filter 1,$(SOL)),$(CURDIR)/solution,$(CURDIR)/rtl)
TB4 := $(if $(filter 1,$(SOL)),$(CURDIR)/solution,$(CURDIR)/tb)/tb_lab4_matrix.sv
REF := $(CURDIR)/solution
MATRIX := $(wildcard $(CURDIR)/../output/wally_npu_matrix/*.v)
VCS_FLAGS := -full64 -sverilog -timescale=1ns/1ps +vcs+lic+wait -kdb -debug_access+all +define+FSDB
SIM_FLAGS := -q -no_save +vcs+lic+wait
LAB ?= lab1

SRC_lab1 := $(RTL_DIR)/ahb_lab_slave.sv $(CURDIR)/tb/ahb_checker.sv $(CURDIR)/tb/tb_lab1_slave.sv
SRC_lab2 := $(RTL_DIR)/ahb_lab_master.sv $(REF)/ahb_lab_slave.sv $(CURDIR)/tb/ahb_checker.sv $(CURDIR)/tb/tb_lab2_master.sv
SRC_lab3 := $(RTL_DIR)/ahb_lab_burst_master.sv $(REF)/ahb_lab_slave.sv $(CURDIR)/tb/ahb_checker.sv $(CURDIR)/tb/tb_lab3_burst.sv
SRC_lab4 := $(MATRIX) $(REF)/ahb_lab_burst_master.sv $(REF)/ahb_lab_slave.sv $(CURDIR)/tb/ahb_checker.sv $(TB4)
TOP_lab1 := tb_lab1_slave
TOP_lab2 := tb_lab2_master
TOP_lab3 := tb_lab3_burst
TOP_lab4 := tb_lab4_matrix
LABS := lab1 lab2 lab3 lab4

.PHONY: help $(LABS) wave solutions clean
help:
	@echo "make lab1   AHB slave        (rtl/ahb_lab_slave.sv의 TODO 작성)"
	@echo "make lab2   AHB master       (rtl/ahb_lab_master.sv의 TODO 작성)"
	@echo "make lab3   AHB burst master (rtl/ahb_lab_burst_master.sv의 TODO 작성)"
	@echo "make lab4   CMSDK bus matrix (tb/tb_lab4_matrix.sv의 예측값 작성)"
	@echo "SOL=1       solution/ 정답으로 실행 · make wave LAB=lab3 · make solutions · make clean"

$(BUILD):
	mkdir -p $@

$(LABS): | $(BUILD)
	@cd $(BUILD) && $(VCS) $(VCS_FLAGS) $(SRC_$@) -top $(TOP_$@) -Mdir=csrc_$@ -o simv_$@ \
	  -l compile_$@.log > /dev/null || { grep -E "Error|error" -A4 compile_$@.log | head -n 30; exit 1; }
	@cd $(BUILD) && ./simv_$@ $(SIM_FLAGS) +FSDB_FILE=$@.fsdb -l $@.log > /dev/null; \
	  grep -E '^\[(LAB[0-9]|PASS|FAIL|TODO)' $@.log

wave:
	cd $(BUILD) && $(VERDI) -dbdir simv_$(LAB).daidir -ssf $(LAB).fsdb &

solutions:
	@for lab in $(LABS); do $(MAKE) --no-print-directory $$lab SOL=1 | grep -E '^\[(PASS|FAIL|TODO)\]'; done

clean:
	rm -rf $(BUILD)

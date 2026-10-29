#------------------------------------------------------------------
# Copyright (c) 2013 by Ando Ki.
# All right reserved.
#
# This code is distributed in the hope that it will
# be useful to understand Ando Ki's work,
# but WITHOUT ANY WARRANTY.
#------------------------------------------------------------------
SHELL		= /bin/sh
MAKEFILE	= Makefile
#------------------------------------------------------------------
ARCH	= $(shell uname)
ifeq ($(ARCH), CYGWIN_NT-5.1)
else
ifeq ($(ARCH), MINGW32_NT-5.1)
else
endif
endif

VLIB	= $(shell which vlib)
VLOG	= $(shell which vlog)
VSIM	= $(shell which vsim)
WORK	= simv

TOP	= testbench

VCS ?= vcs
VERILATOR ?= verilator
JOBS ?= 2
VCS_OPTS = +vcs+lic+wait +lint=all
SW := ../../../../software/npu
SAMPLES ?= 124
RTL := $(shell sed -n '/^\./p' run.f)
HEADERS := $(wildcard ../../testbench/*.vh ../../testbench/*.svh ../../../source/wally/config/rv32imac_cache/*.vh ../../../source/wally/config/shared/*.vh)

.PHONY: all firmware vectors vcs run regression compare-build compare compare-npu compare-cpu compare-report
all: firmware vectors vcs

build:
	mkdir -p $@

firmware:
	$(MAKE) -C $(SW)

vectors: firmware | build
	python3 prepare_vectors.py

irun:
	irun

vcs: $(WORK)

$(WORK): run.f $(RTL) $(HEADERS) Makefile | build
	$(VCS) -full64 -sverilog -timescale=1ns/1ps $(VCS_OPTS) -f run.f -Mdir=build/csrc -o $(WORK) -l build/compile.log > build/compile.stdout 2>&1
	python3 ../../../source/cmsdk_ahb_busmatrix/sim/check_logs.py --compile build/compile.log

run: all
	python3 run_npu.py --samples $(SAMPLES)

.PHONY: verilator run-verilator regression-verilator
verilator: build/verilator/simv_verilator

build/verilator/simv_verilator: run.f $(RTL) $(HEADERS) Makefile verilator_env.cpp | build
	$(VERILATOR) --binary --timing -Wno-fatal --timescale 1ns/1ps +incdir+. -f run.f $(abspath verilator_env.cpp) --Mdir build/verilator -o simv_verilator -j $(JOBS) > build/verilator_compile.log 2>&1

run-verilator: firmware vectors verilator
	python3 run_npu.py --simulator verilator --samples $(SAMPLES)

regression-verilator: firmware vectors verilator
	python3 run_npu.py --simulator verilator --samples 0 124 248

regression: all
	python3 run_npu.py --samples 0 124 248

compare-build: | build
	$(MAKE) -C $(SW) compare
	python3 prepare_vectors.py --firmware compare

compare: compare-build vcs
	python3 run_npu.py --firmware compare --backend npu --samples $(SAMPLES)
	python3 run_npu.py --firmware compare --backend cpu --samples $(SAMPLES)
	python3 compare_results.py

.PHONY: compare-verilator
compare-verilator: compare-build verilator
	python3 run_npu.py --simulator verilator --firmware compare --backend npu --samples $(SAMPLES)
	python3 run_npu.py --simulator verilator --firmware compare --backend cpu --samples $(SAMPLES)
	python3 compare_results.py

compare-npu: compare-build vcs
	python3 run_npu.py --firmware compare --backend npu --samples $(SAMPLES)

compare-cpu: compare-build vcs
	python3 run_npu.py --firmware compare --backend cpu --samples $(SAMPLES)

compare-report:
	python3 compare_results.py

xrun:
	if [ -d $(WORK) ]; then /bin/rm -rf $(WORK); fi
	xrun -64bit -access +rwc -f run.f

verdi:
	Verdi -f run.f &

vlib:
	if [ -d $(WORK) ]; then /bin/rm -rf $(WORK); fi
	($(VLIB) $(WORK) || exit -1) 2>&1 | tee compile.log

compile:
	($(VLOG) -lint -work $(WORK)\
		-f run.f || exit -1) 2>&1 | tee compile.log

simulate: compile
	$(VSIM) -novopt -c -do "add wave *; run -all; quit"\
		$(WORK).$(TOP)

#--------------------------------------------------------
clean:
	-@/bin/rm -rf build
	-@/bin/rm -rf $(WORK)
	-@/bin/rm -f  transcript
	-@/bin/rm -f  wave.vcd dump.vcd
	-@/bin/rm -f  vsim.wlf
	-@/bin/rm -f  vish_stacktrace.vstf
	-@/bin/rm -f  wlft*
	-@/bin/rm -f  compile.log
	-@/bin/rm -f  xrun.history
	-@/bin/rm -f  xrun.log
	-@/bin/rm -f  novas_dump.log
	-@/bin/rm -f  wave.fsdb
	-@/bin/rm -rf  VerdiLog *.vpd
	-@/bin/rm -rf  simv csrc simv.daidir ucli.key
	-@/bin/rm -rf  logs vc_hdrs.h novas.conf novas.rc *.log sim.tmp

cleanup: clean

clobber: cleanup
#--------------------------------------------------------

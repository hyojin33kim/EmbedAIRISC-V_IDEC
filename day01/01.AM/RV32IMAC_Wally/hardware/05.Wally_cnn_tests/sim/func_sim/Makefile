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

VCS_OPTS = -lca -ntb_opts sensitive_dyn -suppress +warn \
	+lint=all,noGCWM,noUI,noSVA-UA,noIDTS,noNS,noULCO,noCAWM-L,noWMIA-L,noSV-PIU,noSTASKW_CO,noSTASKW_CO1,noSTASKW_RMCOF
TESTS	= cnn

ELF_cnn	= cnn/cnn.elf

all: vcs

irun:
	irun 

vcs:
	if [ -d $(WORK) ]; then /bin/rm -rf $(WORK); fi
	vcs -full64 -debug_acc+all -sverilog -timescale=1ns/1ns $(VCS_OPTS) -f run.f

test	?= all
run:
	@[ -x simv ] || $(MAKE) vcs
ifeq ($(test),all)
	@rm -f output.log
	@$(foreach t,$(TESTS),printf "%-16s : " $(t); \
		./simv +TEST=$(t) +ElfFile=$(ELF_$(t)) -no_save > sim.tmp 2>&1; \
		cat sim.tmp >> output.log; \
		grep -hE "\[PASS\]|\[FAIL\]" sim.tmp || echo "NO RESULT (see output.log)";)
	@rm -f sim.tmp
	@printf "\n PASS %s / %s\n" $$(grep -c "\[PASS\]" output.log) $(words $(TESTS))
else
	./simv +TEST=$(test) +ElfFile=$(ELF_$(test)) -no_save
endif

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

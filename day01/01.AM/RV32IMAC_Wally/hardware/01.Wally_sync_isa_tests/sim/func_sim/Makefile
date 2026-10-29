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
#--------------------------------------------------------
VLIB	= $(shell which vlib)
VLOG	= $(shell which vlog)
VSIM	= $(shell which vsim)
WORK	= simv
#--------------------------------------------------------
TOP	= testbench
#--------------------------------------------------------
VCS_OPTS = -lca -ntb_opts sensitive_dyn -suppress +warn \
	+lint=all,noGCWM,noUI,noSVA-UA,noIDTS,noNS,noULCO,noCAWM-L,noWMIA-L,noSV-PIU,noSTASKW_CO,noSTASKW_CO1,noSTASKW_RMCOF

TESTS	= add addi and andi auipc beq bge bgeu blt bltu bne fence_i jal jalr lb lbu lh lhu lui lw or ori sb sh simple sll slli slt slti sltiu sltu sra srai srl srli sub sw xor xori div divu mul mulh mulhsu mulhu rem remu amoadd_w amoand_w amomax_w amomaxu_w amomin_w amominu_w amoor_w amoswap_w amoxor_w lrsc rvc

ELF_add	= riscv-isa-tests/add.elf
ELF_addi	= riscv-isa-tests/addi.elf
ELF_and	= riscv-isa-tests/and.elf
ELF_andi	= riscv-isa-tests/andi.elf
ELF_auipc	= riscv-isa-tests/auipc.elf
ELF_beq	= riscv-isa-tests/beq.elf
ELF_bge	= riscv-isa-tests/bge.elf
ELF_bgeu	= riscv-isa-tests/bgeu.elf
ELF_blt	= riscv-isa-tests/blt.elf
ELF_bltu	= riscv-isa-tests/bltu.elf
ELF_bne	= riscv-isa-tests/bne.elf
ELF_fence_i	= riscv-isa-tests/fence_i.elf
ELF_jal	= riscv-isa-tests/jal.elf
ELF_jalr	= riscv-isa-tests/jalr.elf
ELF_lb	= riscv-isa-tests/lb.elf
ELF_lbu	= riscv-isa-tests/lbu.elf
ELF_lh	= riscv-isa-tests/lh.elf
ELF_lhu	= riscv-isa-tests/lhu.elf
ELF_lui	= riscv-isa-tests/lui.elf
ELF_lw	= riscv-isa-tests/lw.elf
ELF_or	= riscv-isa-tests/or.elf
ELF_ori	= riscv-isa-tests/ori.elf
ELF_sb	= riscv-isa-tests/sb.elf
ELF_sh	= riscv-isa-tests/sh.elf
ELF_simple	= riscv-isa-tests/simple.elf
ELF_sll	= riscv-isa-tests/sll.elf
ELF_slli	= riscv-isa-tests/slli.elf
ELF_slt	= riscv-isa-tests/slt.elf
ELF_slti	= riscv-isa-tests/slti.elf
ELF_sltiu	= riscv-isa-tests/sltiu.elf
ELF_sltu	= riscv-isa-tests/sltu.elf
ELF_sra	= riscv-isa-tests/sra.elf
ELF_srai	= riscv-isa-tests/srai.elf
ELF_srl	= riscv-isa-tests/srl.elf
ELF_srli	= riscv-isa-tests/srli.elf
ELF_sub	= riscv-isa-tests/sub.elf
ELF_sw	= riscv-isa-tests/sw.elf
ELF_xor	= riscv-isa-tests/xor.elf
ELF_xori	= riscv-isa-tests/xori.elf
ELF_div	= riscv-isa-tests/div.elf
ELF_divu	= riscv-isa-tests/divu.elf
ELF_mul	= riscv-isa-tests/mul.elf
ELF_mulh	= riscv-isa-tests/mulh.elf
ELF_mulhsu	= riscv-isa-tests/mulhsu.elf
ELF_mulhu	= riscv-isa-tests/mulhu.elf
ELF_rem	= riscv-isa-tests/rem.elf
ELF_remu	= riscv-isa-tests/remu.elf
ELF_amoadd_w	= riscv-isa-tests/amoadd_w.elf
ELF_amoand_w	= riscv-isa-tests/amoand_w.elf
ELF_amomax_w	= riscv-isa-tests/amomax_w.elf
ELF_amomaxu_w	= riscv-isa-tests/amomaxu_w.elf
ELF_amomin_w	= riscv-isa-tests/amomin_w.elf
ELF_amominu_w	= riscv-isa-tests/amominu_w.elf
ELF_amoor_w	= riscv-isa-tests/amoor_w.elf
ELF_amoswap_w	= riscv-isa-tests/amoswap_w.elf
ELF_amoxor_w	= riscv-isa-tests/amoxor_w.elf
ELF_lrsc	= riscv-isa-tests/lrsc.elf
ELF_rvc	= riscv-isa-tests/rvc.elf
#--------------------------------------------------------
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
	Verdi-Ultra -sv -f run.f &

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
	-@/bin/rm -rf  Verdi-UltraLog *.vpd
	-@/bin/rm -rf  simv csrc simv.daidir ucli.key
	-@/bin/rm -rf  logs vc_hdrs.h novas.conf novas.rc *.log sim.tmp

cleanup: clean

clobber: cleanup
#--------------------------------------------------------

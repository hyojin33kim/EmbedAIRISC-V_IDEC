SHELL := $(shell which bash) -o pipefail

RISCV   := riscv64-unknown-elf
LIB     := ../151_library
LIBSRC  := $(LIB)/wally_sys.c $(LIB)/uart.c

SUITES_NOC := rv32ui rv32um rv32ua rv32uf
SUITES_C   := rv32uc
tests_of    = $(basename $(notdir $(wildcard $(addsuffix /*.S,$(addprefix riscv-tests/isa/,$(1))))))
TESTS_NOC  := $(call tests_of,$(SUITES_NOC))
TESTS_C    := $(call tests_of,$(SUITES_C))
TESTS      := $(TESTS_NOC) $(TESTS_C)

MARCH       = rv32imaf_zicsr_zifencei
$(addsuffix .elf,$(TESTS_C)): MARCH = rv32imafc_zicsr_zifencei

GCC_OPTS := -mabi=ilp32f -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
            -O2 -T env_wally/link.ld -Wl,--build-id=none -Wl,--no-warn-rwx-segments
INCS     := -Ienv_wally -Iriscv-tests/env -Iriscv-tests/isa/macros/scalar -I$(LIB)

VPATH := $(addprefix riscv-tests/isa/,$(SUITES_NOC) $(SUITES_C))

all: $(addsuffix .elf,$(TESTS))

list:
	@echo $(TESTS)

%.elf: %.S $(LIBSRC) env_wally/riscv_test.h env_wally/link.ld
	$(RISCV)-gcc -march=$(MARCH) $(GCC_OPTS) $(INCS) $< $(LIBSRC) -lgcc -o $@
	$(RISCV)-objdump -D -Mnumeric $@ > $*.dump
	$(RISCV)-objcopy -O binary $@ $*.bin
	truncate -s %4 $*.bin
	od -An -v -tx4 -w4 $*.bin | tr -d ' ' > $@.memfile
	$(RISCV)-objdump -S -D $@ > $@.objdump
	grep -E '^[0-9a-f]{8} <[0-9a-zA-Z_]+>' $@.objdump | awk '{print $$1}'               > $@.objdump.addr
	grep -E '^[0-9a-f]{8} <[0-9a-zA-Z_]+>' $@.objdump | awk '{print $$2}' | tr -d '<>:' > $@.objdump.lab

clean:
	rm -f *.elf *.bin *.mif *.dump *.memfile *.objdump*

.PHONY: all list clean

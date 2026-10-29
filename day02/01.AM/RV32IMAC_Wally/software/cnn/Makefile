# Wally RTL용 정수 CNN 펌웨어와 메모리 이미지를 빌드한다.
TARGET := cnn
RISCV ?= riscv64-unknown-elf
CC := $(RISCV)-gcc
OBJCOPY := $(RISCV)-objcopy
OBJDUMP := $(RISCV)-objdump
NM := $(RISCV)-nm

ARCH_FLAGS := -march=rv32imac_zicsr_zifencei -mabi=ilp32 -mcmodel=medany
CPPFLAGS := -DMODEL_INTEGER_ONLY -include firmware_no_float.h
CFLAGS := -O2 -std=c11 -Wall -Wextra -Werror -ffreestanding -fno-builtin \
          -fno-stack-protector -fno-tree-loop-distribute-patterns \
          -msmall-data-limit=0 -ffunction-sections -fdata-sections -fstack-usage
LDFLAGS := $(ARCH_FLAGS) -nostdlib -nostartfiles -static -T $(TARGET).ld \
           -Wl,--gc-sections,--no-warn-rwx-segments,-Map,$(TARGET).map
SOURCES := model.c firmware_main.c uprintf.c uart.c wally_sys.c
OBJECTS := $(SOURCES:%.c=build/%.o) build/start.o
OUTPUTS := $(TARGET).elf $(TARGET).bin $(TARGET).elf.memfile $(TARGET).dump \
           $(TARGET).elf.objdump $(TARGET).elf.objdump.addr $(TARGET).elf.objdump.lab

.PHONY: all clean
.DELETE_ON_ERROR:
all: $(OUTPUTS)

build:
	mkdir -p $@

build/%.o: %.c Makefile | build
	$(CC) $(ARCH_FLAGS) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@

build/start.o: start.s Makefile | build
	$(CC) $(ARCH_FLAGS) -c $< -o $@

$(TARGET).elf: $(OBJECTS) $(TARGET).ld Makefile
	$(CC) $(LDFLAGS) $(OBJECTS) -lgcc -o $@

$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@
	truncate -s %4 $@

$(TARGET).elf.memfile: $(TARGET).bin
	od -An -v -tx4 -w4 $< | tr -d ' ' > $@

$(TARGET).dump: $(TARGET).elf
	$(OBJDUMP) -d -Mnumeric $< > $@

$(TARGET).elf.objdump: $(TARGET).elf
	$(OBJDUMP) -S -D $< > $@

$(TARGET).elf.objdump.addr: $(TARGET).elf
	$(NM) -n --defined-only $< | awk 'NF == 3 {print $$1}' > $@

$(TARGET).elf.objdump.lab: $(TARGET).elf
	$(NM) -n --defined-only $< | awk 'NF == 3 {print $$3}' > $@

clean:
	rm -rf build
	rm -f $(OUTPUTS) $(TARGET).map

-include $(OBJECTS:.o=.d)

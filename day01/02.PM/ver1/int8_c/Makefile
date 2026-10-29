CC ?= cc
PYTHON ?= python
CFLAGS ?= -O3 -std=c11 -Wall -Wextra -Wpedantic -Werror -fno-fast-math -ffp-contract=off
LDLIBS ?= -lm
CHECKPOINT ?= ../qat/outputs/model_int8.pt
HEADERS = model.h model_data.h model_param.h model_types.h
IMAGE_SOURCES = image_decode.c image_preprocess.c
IMAGE_HEADERS = image_decode.h image_preprocess.h third_party/stb/stb_image.h
FIRMWARE_CPPFLAGS = -DMODEL_INTEGER_ONLY -include firmware_no_float.h

.PHONY: all export check sanitize clean
all: build/inference build/libint8_model.so build/kernel_tests build/firmware_example.o build/firmware_demo

export:
	$(PYTHON) export_model.py --checkpoint "$(CHECKPOINT)"

build:
	mkdir -p build

build/inference: model.c main.c $(IMAGE_SOURCES) $(HEADERS) $(IMAGE_HEADERS) | build
	$(CC) $(CPPFLAGS) $(CFLAGS) model.c $(IMAGE_SOURCES) main.c -o $@ $(LDFLAGS) $(LDLIBS)

build/libint8_model.so: model.c $(HEADERS) | build
	$(CC) $(CPPFLAGS) $(CFLAGS) -fPIC -shared model.c -o $@ $(LDFLAGS) $(LDLIBS)

build/kernel_tests: model.c kernel_tests.c $(HEADERS) | build
	$(CC) $(CPPFLAGS) $(CFLAGS) model.c kernel_tests.c -o $@ $(LDFLAGS) $(LDLIBS)

build/firmware_example.o: firmware_example.c $(HEADERS) firmware_no_float.h Makefile | build
	$(CC) $(CPPFLAGS) $(CFLAGS) $(FIRMWARE_CPPFLAGS) -c firmware_example.c -o $@

build/firmware_demo: model.c image_preprocess.c firmware_main.c demo_frame.h $(HEADERS) image_preprocess.h firmware_no_float.h Makefile | build
	$(CC) $(CPPFLAGS) $(CFLAGS) $(FIRMWARE_CPPFLAGS) -DFIRMWARE_HOST_DEMO model.c image_preprocess.c firmware_main.c -o $@

build/libint8_integer.so: model.c $(HEADERS) firmware_no_float.h Makefile | build
	$(CC) $(CPPFLAGS) $(CFLAGS) $(FIRMWARE_CPPFLAGS) -fPIC -shared model.c -o $@ $(LDFLAGS)

RISCV_CC ?= riscv64-unknown-elf-gcc
QEMU_RISCV32 ?= qemu-riscv32
RISCV_ARCH ?= rv32imac
RISCV_ABI ?= ilp32
RISCV_FLAGS = -march=$(RISCV_ARCH) -mabi=$(RISCV_ABI) -O2 -std=c11 -Wall -Wextra -Werror -ffreestanding -fno-builtin -fno-stack-protector -msmall-data-limit=0 -ffunction-sections -fdata-sections $(FIRMWARE_CPPFLAGS)
RISCV_ELF = build/firmware_$(RISCV_ARCH)_$(RISCV_ABI).elf

$(RISCV_ELF): model.c image_preprocess.c firmware_main.c riscv_qemu_start.S demo_frame.h $(HEADERS) image_preprocess.h firmware_no_float.h Makefile | build
	$(RISCV_CC) $(RISCV_FLAGS) -nostdlib -nostartfiles -Wl,--gc-sections,-e,_start model.c image_preprocess.c firmware_main.c riscv_qemu_start.S -o $@ -lgcc

.PHONY: firmware-demo riscv-smoke riscv-verify
firmware-demo: build/firmware_demo
	./build/firmware_demo

riscv-smoke: $(RISCV_ELF)
	$(QEMU_RISCV32) ./$(RISCV_ELF) > build/firmware_$(RISCV_ARCH)_$(RISCV_ABI)_result.bin

riscv-verify: $(RISCV_ELF)
	$(PYTHON) verify_firmware.py --cc "$(RISCV_CC)" --cflags "$(RISCV_FLAGS)" --qemu "$(QEMU_RISCV32)" --elf $(RISCV_ELF) --output-dir outputs/$(RISCV_ARCH)_$(RISCV_ABI)

check: all
	./build/kernel_tests

build/kernel_tests_sanitize: model.c kernel_tests.c $(HEADERS) | build
	$(CC) -std=c11 -O1 -g -Wall -Wextra -Wpedantic -Werror -fno-omit-frame-pointer -fno-fast-math -ffp-contract=off -fsanitize=address,undefined model.c kernel_tests.c -o $@ -lm

build/inference_sanitize: model.c main.c $(IMAGE_SOURCES) $(HEADERS) $(IMAGE_HEADERS) | build
	$(CC) -std=c11 -O1 -g -Wall -Wextra -Wpedantic -Werror -fno-omit-frame-pointer -fno-fast-math -ffp-contract=off -fsanitize=address,undefined model.c $(IMAGE_SOURCES) main.c -o $@ -lm

sanitize: build/kernel_tests_sanitize build/inference_sanitize
	./build/kernel_tests_sanitize

clean:
	rm -rf build

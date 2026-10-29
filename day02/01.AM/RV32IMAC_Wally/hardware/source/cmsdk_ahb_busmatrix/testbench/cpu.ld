/* SoC 연결 검증 프로그램과 스택을 공유 SRAM에 배치한다. */
OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M }
SECTIONS {
  .text : { KEEP(*(.text.start)) *(.text*) } > RAM
  .rodata : { *(.rodata*) } > RAM
  .data : { *(.data*) *(.sdata*) } > RAM
  .bss : { *(.bss*) *(.sbss*) *(COMMON) } > RAM
  _stack_top = ORIGIN(RAM) + 0x100000;
}

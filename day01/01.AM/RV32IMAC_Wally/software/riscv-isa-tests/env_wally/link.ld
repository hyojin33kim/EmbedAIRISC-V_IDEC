OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  . = ALIGN(0x1000);
  .text : { *(.text .text.*) }
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
  . = ALIGN(0x1000);
  .data : { *(.data .data.* .sdata .sdata.*) }
  .bss : { *(.sbss .sbss.* .bss .bss.* COMMON) }
  _end = .;
  . = ALIGN(16);
  . = . + 0x4000;
  _stack_top = .;
}

/* Wally RAM에 CNN 코드와 데이터, BSS와 64 KiB 스택을 배치한다. */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M
}

SECTIONS
{
    .text : {
        KEEP(*(.start))
        *(.text .text.*)
    } > RAM
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
    .data : {
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.data .data.* .sdata .sdata.*)
    } > RAM
    .bss (NOLOAD) : {
        . = ALIGN(16);
        __bss_start = .;
        *(.sbss .sbss.* .bss .bss.* COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > RAM
    begin_signature = firmware_result;
    sig_end_canary = firmware_result + 32;
    .stack (NOLOAD) : {
        . = ALIGN(16);
        _stack_bottom = .;
        . = . + 0x10000;
        _stack_top = .;
    } > RAM
}

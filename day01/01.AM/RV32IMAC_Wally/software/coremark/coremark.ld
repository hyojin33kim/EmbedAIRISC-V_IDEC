OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
    . = 0x80000000;
    .text : {
        * (.start);
        * (.text .text.*);
    }
    .rodata : { * (.rodata .rodata.* .srodata .srodata.*) }
    .data   : { * (.data .data.* .sdata .sdata.*) }
    . = ALIGN(4);
    .bss    : {
        __bss_start = .;
        * (.sbss .sbss.* .bss .bss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    }
    . = ALIGN(16);
    . = . + 0x10000;
    _stack_top = .;
}

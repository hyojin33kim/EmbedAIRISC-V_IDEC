/* RV32 Linux-user smoke-test adapter only, not board startup code.
 * Board projects supply reset/vector setup, linker script, clock and UART drivers. */
.section .text.start,"ax",@progbits
.globl _start
_start:
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, __stack_top
    call main
    mv s0, a0
    li a0, 1
    la a1, firmware_result
    li a2, 32
    li a7, 64
    ecall
    mv a0, s0
    li a7, 93
    ecall
1:  j 1b

.section .bss.stack,"aw",@nobits
.balign 16
    .space 8192
__stack_top:

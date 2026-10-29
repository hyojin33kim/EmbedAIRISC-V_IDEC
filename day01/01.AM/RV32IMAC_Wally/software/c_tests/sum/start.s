    .section    .start
    .global     _start

_start:
    .option push
    .option norelax
    la      sp, _stack_top
    .option pop

    la      t0, trap_loop
    csrw    mtvec, t0


    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:
    jal     uart_init
    jal     main

    .option push
    .option norvc
    .balign 4
end_loop:
    j       end_loop
    .balign 4
trap_loop:
    j       trap_loop
    .option pop

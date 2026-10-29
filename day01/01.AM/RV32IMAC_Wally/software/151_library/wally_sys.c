#include "types.h"
#include "uart.h"
#include "memory_map.h"

static void uwrite_dec(uint32_t v) {
    int8_t buf[11];
    int i = 10;
    buf[i] = '\0';
    do { buf[--i] = '0' + (v % 10); v /= 10; } while (v && i > 0);
    uwrite_int8s(&buf[i]);
}

void wally_tohost(uint32_t val) {
    if (val == 0) return;

    uint32_t cyc  = rd_mcycle();
    uint32_t inst = rd_minstret();

    uwrite_int8s((const int8_t*)(val == 1 ? "[PASS] " : "[FAIL] "));
    uwrite_dec(cyc);
    uwrite_int8s((const int8_t*)" cycles, ");
    uwrite_dec(inst);
    uwrite_int8s((const int8_t*)" instrs");
    if (val != 1) {
        uwrite_int8s((const int8_t*)" (test ");
        uwrite_dec(val >> 1);
        uwrite_int8s((const int8_t*)")");
    }
    uwrite_int8s((const int8_t*)"\r\n");

    asm volatile (
        ".option push      \n"
        ".option norvc     \n"
        "1: j 1b           \n"                      // jal x0, 0  (0x0000006f)
        ".option pop       \n");
    __builtin_unreachable();
}

#ifndef _TB_CXXRTL_IO_H
#define _TB_CXXRTL_IO_H

#include <stdint.h>

void uwrite_int8(char c);                    // 151_library/uart.c
void wally_tohost(uint32_t val);             // 151_library/wally_sys.c

static inline void tb_putc(char c) {
	uwrite_int8(c);
}

static inline void tb_puts(const char *s) {
	while (*s)
		tb_putc(*s++);
}

static inline void tb_exit(uint32_t ret) {
	wally_tohost(ret == 0 ? 1 : 2);
}

#endif

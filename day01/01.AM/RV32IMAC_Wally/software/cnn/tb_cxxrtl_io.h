// UART 출력과 테스트벤치 종료를 위한 Dhrystone 호환 함수를 제공한다.
#ifndef _TB_CXXRTL_IO_H
#define _TB_CXXRTL_IO_H

#include "uart.h"
#include "memory_map.h"

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

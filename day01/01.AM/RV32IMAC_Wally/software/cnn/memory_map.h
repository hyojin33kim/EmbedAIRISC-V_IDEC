// Wally 성능 카운터와 시뮬레이션 종료 인터페이스를 정의한다.
#ifndef MEMORY_MAP_H_
#define MEMORY_MAP_H_

#include <stdint.h>

void wally_tohost(uint32_t val);
#define csr_tohost(csr_val) wally_tohost(csr_val)

static inline uint32_t rd_mcycle(void)   { uint32_t v; __asm__ volatile ("csrr %0, mcycle"   : "=r"(v)); return v; }
static inline uint32_t rd_minstret(void) { uint32_t v; __asm__ volatile ("csrr %0, minstret" : "=r"(v)); return v; }
#define CYCLE_COUNTER        rd_mcycle()
#define INSTRUCTION_COUNTER  rd_minstret()

#endif

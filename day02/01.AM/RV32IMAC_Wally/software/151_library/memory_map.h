#ifndef MEMORY_MAP_H_
#define MEMORY_MAP_H_

#include "types.h"

void wally_tohost(uint32_t val);
#define csr_tohost(csr_val) wally_tohost(csr_val)

static inline uint32_t rd_mcycle(void)   { uint32_t v; asm volatile ("csrr %0, mcycle"   : "=r"(v)); return v; }
static inline uint32_t rd_minstret(void) { uint32_t v; asm volatile ("csrr %0, minstret" : "=r"(v)); return v; }
#define CYCLE_COUNTER        rd_mcycle()
#define INSTRUCTION_COUNTER  rd_minstret()

#endif

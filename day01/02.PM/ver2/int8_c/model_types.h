#ifndef INT8_C_MODEL_TYPES_H
#define INT8_C_MODEL_TYPES_H

#include <stdint.h>
#ifdef MODEL_INTEGER_ONLY
/* GCC/Clang stddef.h also declares max_align_t using long double. Firmware
 * only needs the compiler's integer size type and a null pointer constant. */
#ifndef __SIZE_TYPE__
#error "Integer-only firmware needs the GCC/Clang __SIZE_TYPE__ builtin"
#endif
typedef __SIZE_TYPE__ size_t;
#ifndef NULL
#define NULL ((void *)0)
#endif
#else
#include <stddef.h>
#endif

#endif

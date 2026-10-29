TARGET      := coremark
INCLUDE_LIB := false
ITERATIONS  ?= 35

CORE_SRCS   = dist/core_list_join.c dist/core_main.c dist/core_matrix.c dist/core_state.c dist/core_util.c
PORT_SRCS   = dist/barebones/core_portme.c dist/barebones/ee_printf.c
EXTRA_SRCS  = $(CORE_SRCS) $(PORT_SRCS) $(LIB_PATH)/uart.c $(LIB_PATH)/wally_sys.c

PORT_CFLAGS = -O2 -fno-common -funroll-loops -finline-functions -fno-builtin-printf \
              --param max-inline-insns-auto=20 -falign-functions=4 -falign-jumps=4 -falign-loops=4
GCC_OPTS += $(PORT_CFLAGS) -flto -Idist -Idist/barebones \
            -DPERFORMANCE_RUN=1 -DITERATIONS=$(ITERATIONS) -DFLAGS_STR='"-O2 -funroll-loops -finline-functions -flto"'

include ../Makefrag

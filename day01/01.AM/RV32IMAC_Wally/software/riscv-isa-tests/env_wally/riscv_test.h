// See LICENSE for license details.
//=======================================================================
//       PASS : wally_tohost(1)                 → "[PASS] N cycles, M instrs"
//       FAIL : wally_tohost((TESTNUM<<1)|1)    → "[FAIL] ... test=TESTNUM"
//=======================================================================

#ifndef _ENV_PHYSICAL_SINGLE_CORE_H
#define _ENV_PHYSICAL_SINGLE_CORE_H

#include "encoding.h"

//-----------------------------------------------------------------------
// Begin Macro
//-----------------------------------------------------------------------

#define RVTEST_RV64U                                                    \
  .macro init;                                                          \
  .endm

#define RVTEST_RV64UF                                                   \
  .macro init;                                                          \
  .endm

#define RVTEST_RV32U                                                    \
  .macro init;                                                          \
  .endm

#define RVTEST_RV32UF                                                   \
  .macro init;                                                          \
  .endm

#define RVTEST_RV64M                                                    \
  .macro init;                                                          \
  .endm

#define RVTEST_RV64S                                                    \
  .macro init;                                                          \
  .endm

#define RVTEST_RV32M                                                    \
  .macro init;                                                          \
  .endm

#define RVTEST_RV32S                                                    \
  .macro init;                                                          \
  .endm

#define TESTNUM gp

#define WALLY_SET_SP                                                    \
        .option push;                                                   \
        .option norelax;                                                \
        la sp, _stack_top;                                              \
        .option pop

#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .globl _start;                                                  \
_start:                                                                 \
        /* reset vector */                                              \
        j reset_vector;                                                 \
        .align 2;                                                       \
trap_vector:                                                            \
        WALLY_SET_SP;                                                   \
        slli a0, TESTNUM, 1;                                            \
        ori  a0, a0, 1;                                                 \
        call wally_tohost;                                              \
        .align 2;                                                       \
reset_vector:                                                           \
        WALLY_SET_SP;                                                   \
        la t0, trap_vector;                                             \
        csrw mtvec, t0;                                                 \
        li t0, MSTATUS_FS & (MSTATUS_FS >> 1);                          \
        csrs mstatus, t0;                                               \
        csrwi fcsr, 0;                                                  \
        call uart_init;                                                 \
        li TESTNUM, 0;                                                  \
        init

//-----------------------------------------------------------------------
// End Macro
//-----------------------------------------------------------------------

#define RVTEST_CODE_END                                                 \
        unimp

//-----------------------------------------------------------------------
// Pass/Fail Macro
//-----------------------------------------------------------------------

#define RVTEST_PASS                                                     \
        fence;                                                          \
        WALLY_SET_SP;                                                   \
        li a0, 1;                                                       \
        call wally_tohost

#define RVTEST_FAIL                                                     \
        fence;                                                          \
        WALLY_SET_SP;                                                   \
        slli a0, TESTNUM, 1;                                            \
        ori  a0, a0, 1;                                                 \
        call wally_tohost

//-----------------------------------------------------------------------
// Data Section Macro
//-----------------------------------------------------------------------

#define EXTRA_DATA

#define RVTEST_DATA_BEGIN                                               \
        EXTRA_DATA                                                      \
        .align 4; .global begin_signature; begin_signature:

#define RVTEST_DATA_END .align 4; .global end_signature; end_signature:

#endif

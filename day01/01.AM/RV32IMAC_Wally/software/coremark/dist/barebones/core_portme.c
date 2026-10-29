/*
Copyright 2018 Embedded Microprocessor Benchmark Consortium (EEMBC)

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Original Author: Shay Gal-on
*/
#include "coremark.h"
#include "core_portme.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
/* Porting : Timing functions
        How to capture time and convert to seconds must be ported to whatever is
   supported by the platform. e.g. Read value from on board RTC, read value from
   cpu clock cycles performance counter etc. Sample implementation for standard
   time.h and windows.h definitions included.
*/

#define read_csr(csrname) ({ \
  uint32_t __csr_tmp_u32; \
  __asm__ volatile ("csrr %0, " #csrname : "=r" (__csr_tmp_u32)); \
  __csr_tmp_u32; \
})

CORETIMETYPE
barebones_clock()
{

    return read_csr(mcycle);
    //return *(volatile unsigned int *)(0x80001100);
// #error \
//     "You must implement a method to measure time in barebones_clock()! This function should return current time.\n"
}
/* Define : TIMER_RES_DIVIDER
        Divider to trade off timer resolution and total time that can be
   measured.

        Use lower values to increase resolution, but make sure that overflow
   does not occur. If there are issues with the return value overflowing,
   increase this value.
        */
#define GETMYTIME(_t)              (*_t = barebones_clock())
#define MYTIMEDIFF(fin, ini)       ((fin) - (ini))
#define TIMER_RES_DIVIDER          1
#define CLOCKS_PER_SEC             50000000
#define SAMPLE_TIME_IMPLEMENTATION 1
// #define EE_TICKS_PER_SEC           (CLOCKS_PER_SEC / TIMER_RES_DIVIDER)
#define EE_TICKS_PER_SEC           (1000 * 1000)

/** Define Host specific (POSIX), or target specific global time variables. */
static CORETIMETYPE start_time_val, stop_time_val;

/* Function : start_time
        This function will be called right before starting the timed portion of
   the benchmark.

        Implementation may be capturing a system timer (as implemented in the
   example code) or zeroing some system parameters - e.g. setting the cpu clocks
   cycles to 0.
*/
void
start_time(void)
{
    GETMYTIME(&start_time_val);
}
/* Function : stop_time
        This function will be called right after ending the timed portion of the
   benchmark.

        Implementation may be capturing a system timer (as implemented in the
   example code) or other system parameters - e.g. reading the current value of
   cpu cycles counter.
*/
void
stop_time(void)
{
    GETMYTIME(&stop_time_val);
}
/* Function : get_time
        Return an abstract "ticks" number that signifies time on the system.

        Actual value returned may be cpu cycles, milliseconds or any other
   value, as long as it can be converted to seconds by <time_in_secs>. This
   methodology is taken to accomodate any hardware or simulated platform. The
   sample implementation returns millisecs by default, and the resolution is
   controlled by <TIMER_RES_DIVIDER>
*/
CORE_TICKS
get_time(void)
{
    CORE_TICKS elapsed
        = (CORE_TICKS)(MYTIMEDIFF(stop_time_val, start_time_val));
    return elapsed;
}
/* Function : time_in_secs
        Convert the value returned by get_time to seconds.

        The <secs_ret> type is used to accomodate systems with no support for
   floating point. Default implementation implemented by the EE_TICKS_PER_SEC
   macro above.
*/
secs_ret
time_in_secs(CORE_TICKS ticks)
{
    secs_ret retval = ((secs_ret)ticks) / (secs_ret)EE_TICKS_PER_SEC;
    return retval;
}

ee_u32 default_num_contexts = 1;

/* Function : portable_init
        Target specific initialization code
        Test for some common mistakes.
*/
void
portable_init(core_portable *p, int *argc, char *argv[])
{
    ee_printf("IO setup.\n");
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
    {
        ee_printf(
            "ERROR! Please define ee_ptr_int to a type that holds a "
            "pointer!\n");
    }
    if (sizeof(ee_u32) != 4)
    {
        ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
    }
    p->portable_id = 1;
}
/* Function : portable_fini
        Target specific final code
*/

void wally_coremark_report(void);

void
portable_fini(core_portable *p)
{
    p->portable_id = 0;
    wally_coremark_report();
}

void uwrite_int8(char c);
void wally_tohost(unsigned int val);

static char     line_buf[160];
static int      line_len;
static int      seen_crcfinal, crc_error;
static unsigned rep_iterations, rep_ticks;

static unsigned parse_after_colon(const char *s) {
    unsigned v = 0;
    while (*s && *s != ':') s++;
    if (*s) s++;
    while (*s == ' ') s++;
    while (*s >= '0' && *s <= '9') v = v * 10 + (unsigned)(*s++ - '0');
    return v;
}

static int starts_with(const char *s, const char *p) {
    while (*p) if (*s++ != *p++) return 0;
    return 1;
}

static int contains(const char *s, const char *p) {
    for (; *s; s++) if (starts_with(s, p)) return 1;
    return 0;
}

static void check_line(void) {
    line_buf[line_len] = '\0';
    if (starts_with(line_buf, "Iterations       :")) rep_iterations = parse_after_colon(line_buf);
    if (starts_with(line_buf, "Total ticks      :")) rep_ticks      = parse_after_colon(line_buf);
    if (contains(line_buf, "crcfinal"))               seen_crcfinal  = 1;
    if (contains(line_buf, "ERROR!") && !contains(line_buf, "at least 10 secs")) crc_error = 1;
    line_len = 0;
}

void wally_coremark_putc(char c) {
    if (c == '\n') { uwrite_int8('\r'); check_line(); }
    else if (line_len < (int)sizeof(line_buf) - 1) line_buf[line_len++] = c;
    uwrite_int8(c);
}

static void put_str(const char *s) { while (*s) wally_coremark_putc(*s++); }
static void put_dec(unsigned v) {
    char b[11]; int i = 10; b[i] = 0;
    do { b[--i] = '0' + v % 10; v /= 10; } while (v);
    put_str(&b[i]);
}

void wally_coremark_report(void) {
    put_str("\n[Wally] CoreMark summary\n");
    put_str("  iterations        : "); put_dec(rep_iterations); put_str("\n");
    put_str("  ticks (= cycles)  : "); put_dec(rep_ticks);      put_str("\n");
    if (rep_iterations && rep_ticks) {
        unsigned long long x = (unsigned long long)rep_iterations * 1000000ULL * 1000ULL / rep_ticks;
        put_str("  cycles/iteration  : "); put_dec(rep_ticks / rep_iterations); put_str("\n");
        put_str("  CoreMark/MHz x1000: "); put_dec((unsigned)x); put_str("\n");
    }
    wally_tohost((seen_crcfinal && !crc_error) ? 1 : 2);
}

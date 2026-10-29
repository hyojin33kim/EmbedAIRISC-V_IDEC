#include "types.h"
#include "memory_map.h"

#define N 16

static float a[N], b[N];

void main() {
    csr_tohost(0);

    for (int i = 0; i < N; i++) {
        a[i] = (float)i * 0.5f;             // fcvt.s.w, fmul.s
        b[i] = (float)(N - i) * 0.25f;
    }

    float dot = 0.0f;
    for (int i = 0; i < N; i++)
        dot += a[i] * b[i];                 // fmadd.s / fmul.s + fadd.s

    volatile float five = 5.0f;
    float q = dot / five;                   // fdiv.s
    int   r = (int)q;                       // fcvt.w.s

    if (r == 17 && dot == 85.0f)            // feq.s
        csr_tohost(1);
    else
        csr_tohost(2);

    // spin
    for( ; ; ) {
        asm volatile ("nop");
    }
}

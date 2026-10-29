// CSR 설정과 cache 동기화를 수행해 여섯 CNN 계층을 실제 tinyNPU로 실행한다.
#include "npu_driver.h"
#include "memory_map.h"

#define NPU_CSR(offset) (*(volatile uint32_t *)(uintptr_t)(0x10080000u + (offset)))
#define CACHE_LINE 64u
#define TIMEOUT_CYCLES 100000000u
enum {
    ID=0x00, VERSION=0x04, START=0x08, STATUS=0x0c, IRQ_ENABLE=0x10,
    ERROR_CODE=0x14, ERROR_ADDR=0x18, CYCLES=0x1c, OP=0x20,
    SRC=0x24, WEIGHT=0x28, DST=0x2c, QPARAM=0x30, IN_SHAPE=0x34,
    OUT_CHANNELS=0x38, ZERO_POINTS=0x3c
};
typedef struct { int32_t weight_zero, multiplier, right_shift; } QParam;
_Static_assert(sizeof(QParam) == 12, "OC QPARAM must have three 32-bit words");
static _Alignas(CACHE_LINE) QParam qparam[32];
uint32_t npu_last_error, npu_last_error_addr;

static void barrier(void) { __asm__ volatile("fence iorw,iorw" ::: "memory"); }

uint64_t npu_cpu_cycles(void) {
    uint32_t hi, lo, after;
    do {
        __asm__ volatile("csrr %0,mcycleh" : "=r"(hi) :: "memory");
        __asm__ volatile("csrr %0,mcycle" : "=r"(lo) :: "memory");
        __asm__ volatile("csrr %0,mcycleh" : "=r"(after) :: "memory");
    } while (hi != after);
    return ((uint64_t)hi << 32) | lo;
}

void npu_cache_flush(const void *buffer, size_t length) {
    uintptr_t end=(uintptr_t)buffer + length;
    barrier();
    for (uintptr_t p=(uintptr_t)buffer & ~(CACHE_LINE-1u); p<end; p+=CACHE_LINE)
        __asm__ volatile("cbo.flush 0(%0)" :: "r"(p) : "memory");
    barrier();
}

static void invalidate(const void *buffer, size_t length) {
    uintptr_t end=(uintptr_t)buffer + length;
    barrier();
    for (uintptr_t p=(uintptr_t)buffer & ~(CACHE_LINE-1u); p<end; p+=CACHE_LINE)
        __asm__ volatile("cbo.inval 0(%0)" :: "r"(p) : "memory");
    barrier();
}

int npu_init(void) {
    npu_last_error=0; npu_last_error_addr=0;
    if (NPU_CSR(ID)!=0x544e5055u || NPU_CSR(VERSION)!=0x00010000u) return NPU_BAD_ID;
    if (NPU_CSR(STATUS)&1u) return NPU_BAD_STATUS;
    NPU_CSR(IRQ_ENABLE)=0; /* This driver polls; no interrupt handler is needed. */
    NPU_CSR(STATUS)=6; /* DONE and ERROR are W1C. */
    barrier();
    return NPU_CSR(STATUS)==0 ? MODEL_OK : NPU_BAD_STATUS;
}

int npu_model_infer_u8(const uint8_t *input, uint8_t *output, ModelWorkspace *workspace,
                       NpuLayerStats stats[MODEL_LAYER_COUNT]) {
    if (!input || !output || !workspace || !stats) return MODEL_BAD_ARGUMENT;
    const uint8_t *current=input;
    uint8_t *next=workspace->a;
    for (int i=0;i<MODEL_LAYER_COUNT;i++) {
        const ModelLayer *l=&model_layers[i];
        uint64_t begin=npu_cpu_cycles();
        size_t input_bytes=(size_t)l->in_c*l->in_h*l->in_w;
        size_t weight_bytes=(size_t)l->out_c*(l->is_conv ? 9u*l->in_c : input_bytes);
        for (int oc=0;oc<l->out_c;oc++) {
            qparam[oc].weight_zero=l->weight_zero[oc];
            qparam[oc].multiplier=l->multiplier[oc];
            qparam[oc].right_shift=l->right_shift[oc];
        }
        npu_cache_flush(current,input_bytes);
        npu_cache_flush(l->weight,weight_bytes);
        npu_cache_flush(qparam,(size_t)l->out_c*sizeof(QParam));
        /* Dirty output lines must not overwrite DMA writes on a later eviction. */
        npu_cache_flush(next,l->output_elements);
        NPU_CSR(STATUS)=6;
        NPU_CSR(OP)=(l->is_conv ? 0u : 1u) | ((uint32_t)l->relu << 8);
        NPU_CSR(SRC)=(uintptr_t)current; NPU_CSR(WEIGHT)=(uintptr_t)l->weight;
        NPU_CSR(DST)=(uintptr_t)next; NPU_CSR(QPARAM)=(uintptr_t)qparam;
        NPU_CSR(IN_SHAPE)=((uint32_t)l->in_c<<16) | ((uint32_t)l->in_w<<8) | (uint32_t)l->in_h;
        NPU_CSR(OUT_CHANNELS)=(uint32_t)l->out_c;
        NPU_CSR(ZERO_POINTS)=((uint32_t)l->output_zero<<8) | (uint32_t)l->input_zero;
        barrier();
        uint32_t started=rd_mcycle(), state;
        stats[i].polls=0;
        NPU_CSR(START)=1;
        do {
            state=NPU_CSR(STATUS);
            stats[i].polls++;
            if ((uint32_t)(rd_mcycle()-started)>TIMEOUT_CYCLES) return NPU_TIMEOUT;
        } while (state&1u);
        stats[i].npu_cycles=NPU_CSR(CYCLES);
        npu_last_error=NPU_CSR(ERROR_CODE); npu_last_error_addr=NPU_CSR(ERROR_ADDR);
        if (state&4u) return NPU_HW_ERROR;
        if (state!=2u || npu_last_error!=0 || stats[i].npu_cycles==0) return NPU_BAD_STATUS;
        invalidate(next,l->output_elements);
        NPU_CSR(STATUS)=2;
        barrier();
        stats[i].cpu_cycles=npu_cpu_cycles()-begin;
        current=next;
        next=next==workspace->a ? workspace->b : workspace->a;
    }
    for (int i=0;i<MODEL_CLASS_COUNT;i++) output[i]=current[i];
    return MODEL_OK;
}

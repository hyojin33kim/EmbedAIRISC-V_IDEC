// tinyNPU의 CNN 실행과 CPU 및 가속기 사이클 측정 인터페이스를 선언한다.
#ifndef TINYNPU_DRIVER_H
#define TINYNPU_DRIVER_H
#include "model.h"

#define NPU_REPEAT_COUNT 2
typedef struct {
    uint64_t cpu_cycles;
    uint32_t npu_cycles;
    uint32_t polls;
} NpuLayerStats;
_Static_assert(sizeof(NpuLayerStats) == 16, "NPU statistics ABI");

enum { NPU_TIMEOUT = -3, NPU_HW_ERROR = -4, NPU_BAD_ID = -5, NPU_BAD_STATUS = -6 };
extern uint32_t npu_last_error, npu_last_error_addr;
int npu_init(void);
int npu_model_infer_u8(const uint8_t *input, uint8_t *output, ModelWorkspace *workspace,
                       NpuLayerStats stats[MODEL_LAYER_COUNT]);
uint64_t npu_cpu_cycles(void);
void npu_cache_flush(const void *buffer, size_t length);
#endif

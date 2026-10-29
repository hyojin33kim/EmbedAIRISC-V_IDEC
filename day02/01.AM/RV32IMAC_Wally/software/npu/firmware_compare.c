// 동일 실행 이미지와 입력으로 CPU 전용 CNN과 NPU CNN의 전체 지연을 비교한다.
#include "model.h"
#include "demo_frame.h"
#include "npu_driver.h"
#include "uprintf.h"
#include "tb_cxxrtl_io.h"

/* Nonzero .data survives startup's BSS clear; bit 0 selects CPU-only. */
volatile uint32_t firmware_backend=0x4e505500u;
_Alignas(64) uint64_t firmware_cycles[NPU_REPEAT_COUNT];
_Alignas(64) NpuLayerStats firmware_layer_stats[NPU_REPEAT_COUNT][MODEL_LAYER_COUNT];
_Alignas(64) volatile uint32_t firmware_run_results[NPU_REPEAT_COUNT][8];
volatile uint32_t firmware_result[8];
static _Alignas(64) ModelWorkspace workspace;
static _Alignas(64) uint8_t input_u8[MODEL_INPUT_ELEMENTS];
static uint8_t output[MODEL_CLASS_COUNT];

static int cpu_infer(const uint8_t *input, uint8_t *result, ModelWorkspace *work,
                      NpuLayerStats *stats) {
    (void)stats;
    return model_infer_u8(input,result,work);
}

static void print_cycles(uint64_t value) {
    char buffer[21];
    int i=20;
    buffer[i]='\0';
    do { buffer[--i]=(char)('0'+value%10u); value/=10u; } while (value);
    uprintf("%s",buffer+i);
}

static void save_result(volatile uint32_t *result, int status) {
    result[0]=0x494e5438u;
    result[1]=(uint32_t)model_argmax(output);
    for (int i=0;i<MODEL_CLASS_COUNT;i++) result[2+i]=output[i];
    result[5]=DEMO_FRAME_WIDTH; result[6]=DEMO_FRAME_HEIGHT;
    result[7]=(uint32_t)status;
}

int main(void) {
    int cpu_only=(firmware_backend&1u)!=0;
    const char *name=cpu_only ? "CPU-only" : "NPU";
    int (*infer)(const uint8_t *,uint8_t *,ModelWorkspace *,NpuLayerStats *)=
        cpu_only ? cpu_infer : npu_model_infer_u8;
    uprintf("CNN comparison backend=%s repeats=%u\n",name,(unsigned)NPU_REPEAT_COUNT);
    int status=model_gray_to_input(demo_frame,input_u8);
    if (!status && !cpu_only) status=npu_init();
    for (int run=0;run<NPU_REPEAT_COUNT && !status;run++) {
        uint64_t begin=npu_cpu_cycles();
        status=infer(input_u8,output,&workspace,firmware_layer_stats[run]);
        firmware_cycles[run]=npu_cpu_cycles()-begin;
        /* Identical result bookkeeping stays outside the timed interval. */
        save_result(firmware_run_results[run],status);
    }
    save_result(firmware_result,status);
    for (int run=0;run<NPU_REPEAT_COUNT && !status;run++) {
        uprintf("%s CNN run %u CPU cycles: ",name,(unsigned)run);
        print_cycles(firmware_cycles[run]); uprintf("\n");
    }
    uprintf("CNN comparison %s q=%u,%u,%u class=%u status=%d\n",name,
            (unsigned)output[0],(unsigned)output[1],(unsigned)output[2],
            (unsigned)firmware_result[1],status);
    npu_cache_flush((const void *)firmware_result,sizeof(firmware_result));
    npu_cache_flush((const void *)firmware_run_results,sizeof(firmware_run_results));
    npu_cache_flush(firmware_cycles,sizeof(firmware_cycles));
    npu_cache_flush(firmware_layer_stats,sizeof(firmware_layer_stats));
    tb_exit(status ? 2u : 0u);
    return status;
}

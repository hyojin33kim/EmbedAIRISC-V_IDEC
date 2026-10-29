// 기존 demo frame을 양자화하고 실제 NPU CNN 결과와 사이클을 기록한다.
/* Input is already resized 32x32 gray8. Replace demo_frame with that buffer.
 * No files, heap, Python, decoder, libm or floating-point operations in this path. */
#ifndef MODEL_INTEGER_ONLY
#error "Compile all firmware sources with -DMODEL_INTEGER_ONLY"
#endif
#include "model.h"
#include "demo_frame.h"

#ifdef FIRMWARE_HOST_DEMO
/* Keep the host demo free of target UART accesses and privileged instructions. */
extern int printf(const char *restrict format, ...);
#define uprintf printf
#else
#include "uprintf.h"
#include "memory_map.h"
#include "tb_cxxrtl_io.h"
#include "npu_driver.h"
_Alignas(64) NpuLayerStats firmware_layer_stats[NPU_REPEAT_COUNT][MODEL_LAYER_COUNT];
_Alignas(64) uint64_t firmware_cycles[NPU_REPEAT_COUNT];

static void print_cycles(uint64_t value) {
    char buffer[21];
    int i=20;
    buffer[i]='\0';
    do { buffer[--i]=(char)('0'+value%10u); value/=10u; } while (value);
    uprintf("%s",buffer+i);
}
#endif

static _Alignas(64) ModelWorkspace workspace;
static _Alignas(64) uint8_t input_u8[MODEL_INPUT_ELEMENTS];
static uint8_t output[MODEL_CLASS_COUNT];

/* Board code can send this result via UART/SPI or inspect it in a debugger.
 * RV32 Linux-user smoke harness writes these 32 bytes to stdout. */
volatile uint32_t firmware_result[8];

int main(void) {
#ifndef FIRMWARE_HOST_DEMO
    csr_tohost(0);
#endif

    const uint8_t *gray_frame = demo_frame;
    int width = DEMO_FRAME_WIDTH, height = DEMO_FRAME_HEIGHT;
    uprintf("Firmware C main start\n");
    firmware_result[0] = UINT32_C(0x494e5438);
    int status = model_gray_to_input(gray_frame, input_u8);
#ifndef FIRMWARE_HOST_DEMO
    if (!status) status=npu_init();
#endif
    uprintf("status: %d\n", status);
    if (!status) {
#ifdef FIRMWARE_HOST_DEMO
        status = model_infer_u8(input_u8, output, &workspace);
#else
        for (int run=0;run<NPU_REPEAT_COUNT && !status;run++) {
            uint64_t begin=npu_cpu_cycles();
            status=npu_model_infer_u8(input_u8,output,&workspace,firmware_layer_stats[run]);
            firmware_cycles[run]=npu_cpu_cycles()-begin;
        }
        /* UART output is outside both timed inference intervals. */
        for (int run=0;run<NPU_REPEAT_COUNT && !status;run++) {
            uprintf("NPU CNN run %u CPU cycles: ",(unsigned)run);
            print_cycles(firmware_cycles[run]); uprintf("\n");
            for (int layer=0;layer<MODEL_LAYER_COUNT;layer++) {
                NpuLayerStats *s=&firmware_layer_stats[run][layer];
                uprintf("  layer %u %s CPU=",(unsigned)layer,model_layers[layer].name);
                print_cycles(s->cpu_cycles);
                uprintf(" NPU=%u polls=%u\n",(unsigned)s->npu_cycles,(unsigned)s->polls);
            }
        }
#endif
    }
    firmware_result[7] = (uint32_t)status;
    if (status) {
#ifndef FIRMWARE_HOST_DEMO
        uprintf("NPU failure status=%d error=%u address=%x\n",status,
                (unsigned)npu_last_error,(unsigned)npu_last_error_addr);
        npu_cache_flush((const void *)firmware_result,sizeof(firmware_result));
        tb_exit(2);
#endif
        return 2;
    }
    int predicted = model_argmax(output);
    firmware_result[1] = (uint32_t)predicted;
    for (int i = 0; i < MODEL_CLASS_COUNT && i < 3; ++i) firmware_result[2 + i] = output[i];
    firmware_result[5] = (uint32_t)width;
    firmware_result[6] = (uint32_t)height;
    uprintf("Firmware C main: %s; q=", model_class_names[predicted]);
    for (int i = 0; i < MODEL_CLASS_COUNT; ++i) uprintf("%s%u", i ? "," : "", (unsigned)output[i]);
    uprintf("; source=%dx%d; workspace=%u\n", width, height, (unsigned)sizeof(workspace));

#ifndef FIRMWARE_HOST_DEMO
    npu_cache_flush((const void *)firmware_result,sizeof(firmware_result));
    npu_cache_flush(firmware_cycles,sizeof(firmware_cycles));
    npu_cache_flush(firmware_layer_stats,sizeof(firmware_layer_stats));
    csr_tohost(1);
#endif
    return 0;
}

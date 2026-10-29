// 전처리된 32×32 gray8 입력을 양자화하고 CNN 추론 결과를 메모리에 기록한다.
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
#endif

static ModelWorkspace workspace;
static uint8_t input_u8[MODEL_INPUT_ELEMENTS];
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
    uprintf("status: %d\n", status);
    if (!status) {
#ifndef FIRMWARE_HOST_DEMO
        uprintf("CNN inference cycles start\n");
        uint32_t cycle_start = rd_mcycle();
#endif
        status = model_infer_u8(input_u8, output, &workspace);
#ifndef FIRMWARE_HOST_DEMO
        uint32_t cycle_end = rd_mcycle();
        uprintf("CNN inference cycles: %u\n", (unsigned)(cycle_end - cycle_start));
#endif
    }
    firmware_result[7] = (uint32_t)status;
    if (status) return 2;
    int predicted = model_argmax(output);
    firmware_result[1] = (uint32_t)predicted;
    for (int i = 0; i < MODEL_CLASS_COUNT && i < 3; ++i) firmware_result[2 + i] = output[i];
    firmware_result[5] = (uint32_t)width;
    firmware_result[6] = (uint32_t)height;
    uprintf("Firmware C main: %s; q=", model_class_names[predicted]);
    for (int i = 0; i < MODEL_CLASS_COUNT; ++i) uprintf("%s%u", i ? "," : "", (unsigned)output[i]);
    uprintf("; source=%dx%d; workspace=%u\n", width, height, (unsigned)sizeof(workspace));

#ifndef FIRMWARE_HOST_DEMO
    csr_tohost(1);
    tb_exit(123);
#endif
    return 0;
}

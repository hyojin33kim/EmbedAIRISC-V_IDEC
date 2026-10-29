/* Complete firmware-style main. Replace demo_frame with the camera's gray8 buffer.
 * No files, heap, Python, decoder, libm or floating-point operations in this path. */
#ifndef MODEL_INTEGER_ONLY
#error "Compile all firmware sources with -DMODEL_INTEGER_ONLY"
#endif
#include "model.h"
#include "image_preprocess.h"
#include "demo_frame.h"

#ifdef FIRMWARE_HOST_DEMO
/* Host-only integer diagnostic. Avoid stdio.h's unrelated FP typedefs/macros;
 * the board build has no printf reference and exposes firmware_result instead. */
extern int printf(const char *restrict format, ...);
#endif

static ModelWorkspace workspace;
static uint8_t gray_input[MODEL_INPUT_ELEMENTS]; /* reused in-place for quantized input */
static uint8_t output[MODEL_CLASS_COUNT];

/* Board code can send this result via UART/SPI or inspect it in a debugger.
 * RV32 Linux-user smoke harness writes these 32 bytes to stdout. */
volatile uint32_t firmware_result[8];

int main(void) {
    const uint8_t *camera_frame = demo_frame;
    int width = DEMO_FRAME_WIDTH, height = DEMO_FRAME_HEIGHT;
    firmware_result[0] = UINT32_C(0x494e5438);
    int status = image_preprocess_gray8(camera_frame, width, height, (size_t)width, 1, gray_input);
    if (!status) status = model_gray_to_input(gray_input, gray_input);
    if (!status) status = model_infer_u8(gray_input, output, &workspace);
    firmware_result[7] = (uint32_t)status;
    if (status) return 2;
    int predicted = model_argmax(output);
    firmware_result[1] = (uint32_t)predicted;
    for (int i = 0; i < MODEL_CLASS_COUNT && i < 3; ++i) firmware_result[2 + i] = output[i];
    firmware_result[5] = (uint32_t)width;
    firmware_result[6] = (uint32_t)height;
#ifdef FIRMWARE_HOST_DEMO
    printf("Firmware C main: %s; q=", model_class_names[predicted]);
    for (int i = 0; i < MODEL_CLASS_COUNT; ++i) printf("%s%u", i ? "," : "", (unsigned)output[i]);
    printf("; source=%dx%d; workspace=%zu\n", width, height, sizeof(workspace));
#endif
    return 0;
}

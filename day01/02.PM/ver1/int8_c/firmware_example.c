/* Link this with model.c in a board firmware project. No camera/UART SDK needed here. */
#ifndef MODEL_INTEGER_ONLY
#error "Compile all firmware sources with -DMODEL_INTEGER_ONLY"
#endif
#include "model.h"

/* One workspace per concurrent caller. These two examples share state and are not reentrant. */
static ModelWorkspace firmware_workspace;
static uint8_t camera_quantized[MODEL_INPUT_ELEMENTS];

/* Already quantized CHW frame. Negative result = error; >=0 = class index. */
int firmware_predict_quantized(const uint8_t frame[MODEL_INPUT_ELEMENTS],
                              uint8_t scores[MODEL_CLASS_COUNT]) {
    int status = model_infer_u8(frame, scores, &firmware_workspace);
    return status == MODEL_OK ? model_argmax(scores) : status;
}

/* Gray pixels must already be 64x64, bilinear resized, white alpha background, EXIF corrected.
 * Input quantization uses an exported UINT8 lookup table, without float arithmetic.
 * For arbitrary frame dimensions see firmware_main.c + image_preprocess.c. */
int firmware_predict_gray64(const uint8_t gray[MODEL_INPUT_ELEMENTS],
                           uint8_t scores[MODEL_CLASS_COUNT]) {
    int status = model_gray_to_input(gray, camera_quantized);
    return status == MODEL_OK ? firmware_predict_quantized(camera_quantized, scores) : status;
}

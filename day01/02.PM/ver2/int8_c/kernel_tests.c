#include "model.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static ModelWorkspace workspace;
static uint8_t input[MODEL_INPUT_ELEMENTS], q_input[MODEL_INPUT_ELEMENTS], output[MODEL_CLASS_COUNT];
static float floats[MODEL_INPUT_ELEMENTS], logits[MODEL_CLASS_COUNT];

int main(void) {
    const int64_t values[] = {1, 3, 5, 7, -1, -3, -5, -7};
    const int32_t expected[] = {0, 2, 2, 4, 0, -2, -2, -4};
    for (size_t i = 0; i < sizeof(values) / sizeof(values[0]); ++i)
        assert(model_round_shift_even(values[i], 1) == expected[i]);
    assert(model_round_shift_even(INT64_C(3) << 40, 40) == 3);
    assert(model_infer_u8(NULL, output, &workspace) == MODEL_BAD_ARGUMENT);
    assert(model_infer_u8(input, NULL, &workspace) == MODEL_BAD_ARGUMENT);
    assert(model_infer_u8(input, output, NULL) == MODEL_BAD_ARGUMENT);
    assert(model_infer_u8_trace(input, output, &workspace, input, 1) == MODEL_BAD_ARGUMENT);
    memset(input, MODEL_INPUT_ZERO_POINT, sizeof(input));
    assert(model_infer_u8(input, output, &workspace) == MODEL_OK);
    for (int i = 0; i < MODEL_CLASS_COUNT; ++i) assert(output[i] == MODEL_OUTPUT_ZERO_POINT);
    assert(model_argmax(output) == 0); /* tie => first class */
    assert(model_infer_f32(floats, logits, &workspace) == MODEL_OK);
    for (int i = 0; i < MODEL_CLASS_COUNT; ++i) assert(logits[i] == 0.0f);
    for (int i = 0; i < MODEL_INPUT_ELEMENTS; ++i) floats[i] = i % 2 ? -100.0f : 100.0f;
    assert(model_quantize_input(floats, q_input) == MODEL_OK);
    for (int i = 0; i < MODEL_INPUT_ELEMENTS; ++i) assert(q_input[i] == (i % 2 ? 0 : 255));
    floats[0] = NAN;
    assert(model_quantize_input(floats, q_input) == MODEL_NONFINITE_INPUT);
    floats[0] = INFINITY;
    assert(model_quantize_input(floats, q_input) == MODEL_NONFINITE_INPUT);
    assert((uintptr_t)model_layers[0].weight % MODEL_ALIGNMENT == 0);
    assert((uintptr_t)workspace.a % MODEL_ALIGNMENT == 0);
    assert(model_workspace_bytes() == sizeof(ModelWorkspace));
    for (int i = 0; i < MODEL_INPUT_ELEMENTS; ++i) input[i] = (uint8_t)(i % 256);
    assert(model_gray_to_input(input, q_input) == MODEL_OK);
    assert(model_gray_to_input(input, input) == MODEL_OK);
    assert(!memcmp(input, q_input, sizeof(input)));
    puts("C kernel tests PASSED: signed ties, zero/padding, saturation, invalid input, alignment, workspace");
    return 0;
}

#ifndef INT8_C_MODEL_H
#define INT8_C_MODEL_H

#include "model_types.h"
#include "model_param.h"

typedef struct {
    _Alignas(MODEL_ALIGNMENT) uint8_t a[MODEL_MAX_ACTIVATIONS];
    _Alignas(MODEL_ALIGNMENT) uint8_t b[MODEL_MAX_ACTIVATIONS];
} ModelWorkspace;

enum { MODEL_OK = 0, MODEL_BAD_ARGUMENT = -1, MODEL_NONFINITE_INPUT = -2 };

/* Caller owns workspace; input/output must not overlap workspace or each other.
 * model_infer_f32 internally quantizes to workspace.b before running the core.
 * uint8 input is already quantized CHW (1,64,64), not gray pixels. */
int model_infer_u8(const uint8_t *input, uint8_t *output, ModelWorkspace *workspace);
int model_infer_u8_trace(const uint8_t *input, uint8_t *output, ModelWorkspace *workspace,
                         uint8_t *trace, size_t trace_size);
/* Gray8 LUT is integer-only and also supports gray64 == quantized. */
int model_gray_to_input(const uint8_t *gray64, uint8_t *quantized);
#ifndef MODEL_INTEGER_ONLY
int model_infer_f32(const float *input, float *logits, ModelWorkspace *workspace);
int model_quantize_input(const float *input, uint8_t *quantized);
void model_dequantize_output(const uint8_t *quantized, float *logits);
#endif
int model_argmax(const uint8_t *quantized);
size_t model_workspace_bytes(void);
const char *model_source_sha256(void);

/* Signed product, shift in [1,62], one rounding step, ties to even; no signed shifts. */
int32_t model_round_shift_even(int64_t value, int right_shift);

#endif

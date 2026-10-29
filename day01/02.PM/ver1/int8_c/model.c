/* Portable teaching kernel. INT8 weights, UINT8 activations, INT32 accumulators.
 * No allocation, platform intrinsics, BLAS or floating point inside MAC/requant. */
#define MODEL_DATA_IMPLEMENTATION
#include "model.h"

#include <limits.h>
#ifndef MODEL_INTEGER_ONLY
#include <float.h>
#include <math.h>
#endif

_Static_assert(CHAR_BIT == 8, "8-bit bytes required");
#ifndef MODEL_INTEGER_ONLY
_Static_assert(sizeof(float) == 4 && FLT_RADIX == 2 && FLT_MANT_DIG == 24,
               "IEEE-754 binary32 input/output required");
#endif
_Static_assert(sizeof(ModelWorkspace) == 2 * MODEL_MAX_ACTIVATIONS,
               "workspace geometry/alignment mismatch");

int32_t model_round_shift_even(int64_t value, int shift) {
    /* Exporter's proven accumulator bound ensures |value| < 2^62. */
    uint64_t magnitude = value < 0 ? (uint64_t)(-(value + 1)) + 1u : (uint64_t)value;
    uint64_t quotient = magnitude >> shift;
    uint64_t remainder = magnitude & ((UINT64_C(1) << shift) - 1u);
    uint64_t half = UINT64_C(1) << (shift - 1);
    if (remainder > half || (remainder == half && (quotient & 1u))) ++quotient;
    int64_t result = value < 0 ? -(int64_t)quotient : (int64_t)quotient;
    if (result > INT32_MAX) return INT32_MAX;
    if (result < INT32_MIN) return INT32_MIN;
    return (int32_t)result;
}

static uint8_t requantize(int32_t acc, const ModelLayer *layer, int oc) {
    int64_t product = (int64_t)acc * layer->multiplier[oc];
    int64_t q = (int64_t)model_round_shift_even(product, layer->right_shift[oc]) + layer->output_zero;
    int32_t minimum = layer->relu ? layer->output_zero : 0;
    if (q < minimum) q = minimum;
    if (q > 255) q = 255;
    return (uint8_t)q;
}

static int32_t convolution_at(const uint8_t *input, const ModelLayer *l, int oc, int y, int x) {
    int32_t acc = 0;
    for (int ic = 0; ic < l->in_c; ++ic) {
        for (int ky = 0; ky < 3; ++ky) {
            int iy = y + ky - 1;
            if (iy < 0 || iy >= l->in_h) continue; /* real zero = input_zero */
            for (int kx = 0; kx < 3; ++kx) {
                int ix = x + kx - 1;
                if (ix < 0 || ix >= l->in_w) continue;
                size_t input_index = ((size_t)ic * l->in_h + iy) * l->in_w + ix;
                size_t weight_index = (((size_t)oc * l->in_c + ic) * 3 + ky) * 3 + kx;
                int32_t a = (int32_t)input[input_index] - l->input_zero;
                int32_t b = (int32_t)l->weight[weight_index] - l->weight_zero[oc];
                acc += a * b;
            }
        }
    }
    return acc;
}

static void conv_relu_pool(const uint8_t *input, uint8_t *output, const ModelLayer *l) {
    for (int oc = 0; oc < l->out_c; ++oc) {
        for (int oy = 0; oy < l->out_h; ++oy) {
            for (int ox = 0; ox < l->out_w; ++ox) {
                int32_t maximum = INT32_MIN;
                for (int py = 0; py < 2; ++py) {
                    for (int px = 0; px < 2; ++px) {
                        int32_t acc = convolution_at(input, l, oc, oy * 2 + py, ox * 2 + px);
                        if (acc > maximum) maximum = acc;
                    }
                }
                /* Positive scale => requant/ReLU monotone, so max-before-requant is equivalent. */
                output[((size_t)oc * l->out_h + oy) * l->out_w + ox] = requantize(maximum, l, oc);
            }
        }
    }
}

static void linear(const uint8_t *input, uint8_t *output, const ModelLayer *l) {
    int count = l->in_c * l->in_h * l->in_w;
    for (int oc = 0; oc < l->out_c; ++oc) {
        int32_t acc = 0;
        for (int i = 0; i < count; ++i) {
            int32_t a = (int32_t)input[i] - l->input_zero;
            int32_t b = (int32_t)l->weight[(size_t)oc * count + i] - l->weight_zero[oc];
            acc += a * b;
        }
        output[oc] = requantize(acc, l, oc);
    }
}

static void copy_bytes(uint8_t *destination, const uint8_t *source, size_t count) {
    for (size_t i = 0; i < count; ++i) destination[i] = source[i];
}

int model_infer_u8_trace(const uint8_t *input, uint8_t *output, ModelWorkspace *workspace,
                         uint8_t *trace, size_t trace_size) {
    if (!input || !output || !workspace || (trace && trace_size < MODEL_TRACE_ELEMENTS))
        return MODEL_BAD_ARGUMENT;
    const uint8_t *current = input;
    uint8_t *next = workspace->a;
    for (int i = 0; i < MODEL_LAYER_COUNT; ++i) {
        const ModelLayer *l = &model_layers[i];
        if (l->is_conv) conv_relu_pool(current, next, l);
        else linear(current, next, l);
        if (trace) copy_bytes(trace + l->trace_offset, next, l->output_elements);
        current = next;
        next = next == workspace->a ? workspace->b : workspace->a;
    }
    copy_bytes(output, current, MODEL_CLASS_COUNT);
    return MODEL_OK;
}

int model_infer_u8(const uint8_t *input, uint8_t *output, ModelWorkspace *workspace) {
    return model_infer_u8_trace(input, output, workspace, NULL, 0);
}

int model_gray_to_input(const uint8_t *gray, uint8_t *quantized) {
    if (!gray || !quantized) return MODEL_BAD_ARGUMENT;
    for (size_t i = 0; i < MODEL_INPUT_ELEMENTS; ++i)
        quantized[i] = model_gray8_to_input[gray[i]];
    return MODEL_OK;
}

#ifndef MODEL_INTEGER_ONLY
static uint8_t quantize_one(float value) {
    /* Same float32 reciprocal/multiply ordering as PyTorch quantize_per_tensor. */
    float scaled = value * (1.0f / MODEL_INPUT_SCALE);
    if (scaled <= -MODEL_INPUT_ZERO_POINT) return 0;
    if (scaled >= 255 - MODEL_INPUT_ZERO_POINT) return 255;
    float lower = floorf(scaled);
    float fraction = scaled - lower;
    int32_t rounded = (int32_t)lower;
    if (fraction > 0.5f || (fraction == 0.5f && (rounded % 2 != 0))) ++rounded;
    return (uint8_t)(rounded + MODEL_INPUT_ZERO_POINT);
}

int model_quantize_input(const float *input, uint8_t *quantized) {
    if (!input || !quantized) return MODEL_BAD_ARGUMENT;
    for (size_t i = 0; i < MODEL_INPUT_ELEMENTS; ++i) {
        if (!isfinite(input[i])) return MODEL_NONFINITE_INPUT;
        quantized[i] = quantize_one(input[i]);
    }
    return MODEL_OK;
}

void model_dequantize_output(const uint8_t *q, float *logits) {
    for (size_t i = 0; i < MODEL_CLASS_COUNT; ++i)
        logits[i] = ((int32_t)q[i] - MODEL_OUTPUT_ZERO_POINT) * MODEL_OUTPUT_SCALE;
}

int model_infer_f32(const float *input, float *logits, ModelWorkspace *workspace) {
    if (!input || !logits || !workspace) return MODEL_BAD_ARGUMENT;
    int status = model_quantize_input(input, workspace->b);
    if (status != MODEL_OK) return status;
    uint8_t output[MODEL_CLASS_COUNT];
    status = model_infer_u8(workspace->b, output, workspace);
    if (status == MODEL_OK) model_dequantize_output(output, logits);
    return status;
}
#endif

int model_argmax(const uint8_t *q) {
    int best = 0;
    for (int i = 1; i < MODEL_CLASS_COUNT; ++i) if (q[i] > q[best]) best = i;
    return best;
}

size_t model_workspace_bytes(void) { return sizeof(ModelWorkspace); }

const char *model_source_sha256(void) { return MODEL_SOURCE_SHA256; }

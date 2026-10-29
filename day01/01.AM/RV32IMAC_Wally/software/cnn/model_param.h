/* Generated model geometry and quantization parameters. */
#ifndef INT8_C_MODEL_PARAM_H
#define INT8_C_MODEL_PARAM_H
#include "model_data.h"
#include "model_types.h"
#define MODEL_INPUT_CHANNELS 1
#define MODEL_INPUT_HEIGHT 32
#define MODEL_INPUT_WIDTH 32
#define MODEL_INPUT_ELEMENTS 1024
#define MODEL_CLASS_COUNT 3
#define MODEL_LAYER_COUNT 6
#define MODEL_MAX_ACTIVATIONS 2048
#define MODEL_TRACE_ELEMENTS 3747
#define MODEL_WEIGHT_BYTES 19240
#ifndef MODEL_INTEGER_ONLY
#define MODEL_INPUT_SCALE 0.00787401665f
#define MODEL_OUTPUT_SCALE 0.142450556f
#endif
#define MODEL_INPUT_ZERO_POINT 0
#define MODEL_OUTPUT_ZERO_POINT 62
#define MODEL_INPUT_FOREGROUND 1
#define MODEL_SOURCE_SHA256 "efb69dd24b01b645d35fc2c949605c9e5b3b7bea83a759af48643082a4c298a6"
#define MODEL_SOURCE_CHECKPOINT "/home/user/lectures/B/EmbedAIRISC-V/day01/02.PM/ver2/qat/outputs/model_int8.pt"
#define MODEL_SOURCE_METHOD "qat"
typedef struct {
    const char *name;
    int is_conv, relu;
    int in_c, in_h, in_w, out_c, out_h, out_w;
    int32_t input_zero, output_zero;
#ifndef MODEL_INTEGER_ONLY
    float input_scale, output_scale;
#endif
    const int8_t *weight;
#ifndef MODEL_INTEGER_ONLY
    const float *weight_scale;
#endif
    const int32_t *weight_zero, *multiplier, *right_shift;
    size_t trace_offset, output_elements;
} ModelLayer;
extern const ModelLayer model_layers[MODEL_LAYER_COUNT];
extern const char *const model_class_names[MODEL_CLASS_COUNT];
extern const uint8_t model_gray8_to_input[256];
#ifdef MODEL_DATA_IMPLEMENTATION
const uint8_t model_gray8_to_input[256] = {
    127, 127, 126, 126, 125, 125, 124, 124, 123, 123, 122, 122, 121, 121, 120, 120, 119, 119, 118, 118, 117, 117, 116, 116, 115, 115, 114, 114, 113, 113, 112, 112, 111, 111, 110, 110, 109, 109, 108, 108, 107, 107, 106, 106, 105, 105, 104, 104, 103, 103, 102, 102, 101, 101, 100, 100, 99, 99, 98, 98, 97, 97, 96, 96, 95, 95, 94, 94, 93, 93, 92, 92, 91, 91, 90, 90, 89, 89, 88, 88, 87, 87, 86, 86, 85, 85, 84, 84, 83, 83, 82, 82, 81, 81, 80, 80, 79, 79, 78, 78, 77, 77, 76, 76, 75, 75, 74, 74, 73, 73, 72, 72, 71, 71, 70, 70, 69, 69, 68, 68, 67, 67, 66, 66, 65, 65, 64, 64, 63, 63, 62, 62, 61, 61, 60, 60, 59, 59, 58, 58, 57, 57, 56, 56, 55, 55, 54, 54, 53, 53, 52, 52, 51, 51, 50, 50, 49, 49, 48, 48, 47, 47, 46, 46, 45, 45, 44, 44, 43, 43, 42, 42, 41, 41, 40, 40, 39, 39, 38, 38, 37, 37, 36, 36, 35, 35, 34, 34, 33, 33, 32, 32, 31, 31, 30, 30, 29, 29, 28, 28, 27, 27, 26, 26, 25, 25, 24, 24, 23, 23, 22, 22, 21, 21, 20, 20, 19, 19, 18, 18, 17, 17, 16, 16, 15, 15, 14, 14, 13, 13, 12, 12, 11, 11, 10, 10, 9, 9, 8, 8, 7, 7, 6, 6, 5, 5, 4, 4, 3, 3, 2, 2, 1, 1, 0, 0
};
const ModelLayer model_layers[MODEL_LAYER_COUNT] = {
    {
        "features.0", 1, 1, 1, 32, 32, 8, 16, 16, 0, 0,
#ifndef MODEL_INTEGER_ONLY
        0.00787401665f, 0.0203343071f,
#endif
        model_conv1_weight,
#ifndef MODEL_INTEGER_ONLY
        model_conv1_weight_scale,
#endif
        model_conv1_weight_zero, model_conv1_multiplier, model_conv1_right_shift,
        0, 2048
    },
    {
        "features.3", 1, 1, 8, 16, 16, 16, 8, 8, 0, 0,
#ifndef MODEL_INTEGER_ONLY
        0.0203343071f, 0.0359366424f,
#endif
        model_conv2_weight,
#ifndef MODEL_INTEGER_ONLY
        model_conv2_weight_scale,
#endif
        model_conv2_weight_zero, model_conv2_multiplier, model_conv2_right_shift,
        2048, 1024
    },
    {
        "features.6", 1, 1, 16, 8, 8, 32, 4, 4, 0, 0,
#ifndef MODEL_INTEGER_ONLY
        0.0359366424f, 0.0539493971f,
#endif
        model_conv3_weight,
#ifndef MODEL_INTEGER_ONLY
        model_conv3_weight_scale,
#endif
        model_conv3_weight_zero, model_conv3_multiplier, model_conv3_right_shift,
        3072, 512
    },
    {
        "features.9", 1, 1, 32, 4, 4, 32, 2, 2, 0, 0,
#ifndef MODEL_INTEGER_ONLY
        0.0539493971f, 0.146816865f,
#endif
        model_conv4_weight,
#ifndef MODEL_INTEGER_ONLY
        model_conv4_weight_scale,
#endif
        model_conv4_weight_zero, model_conv4_multiplier, model_conv4_right_shift,
        3584, 128
    },
    {
        "classifier.1", 0, 1, 32, 2, 2, 32, 1, 1, 0, 0,
#ifndef MODEL_INTEGER_ONLY
        0.146816865f, 0.147649124f,
#endif
        model_fc1_weight,
#ifndef MODEL_INTEGER_ONLY
        model_fc1_weight_scale,
#endif
        model_fc1_weight_zero, model_fc1_multiplier, model_fc1_right_shift,
        3712, 32
    },
    {
        "classifier.3", 0, 0, 32, 1, 1, 3, 1, 1, 0, 62,
#ifndef MODEL_INTEGER_ONLY
        0.147649124f, 0.142450556f,
#endif
        model_fc2_weight,
#ifndef MODEL_INTEGER_ONLY
        model_fc2_weight_scale,
#endif
        model_fc2_weight_zero, model_fc2_multiplier, model_fc2_right_shift,
        3744, 3
    },
};
const char *const model_class_names[MODEL_CLASS_COUNT] = {
    "paper", "rock", "scissors"
};
#endif
#endif

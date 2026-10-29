       
typedef signed char int8_t;
typedef short int int16_t;
typedef long int int32_t;
typedef long long int int64_t;
typedef unsigned char uint8_t;
typedef short unsigned int uint16_t;
typedef long unsigned int uint32_t;
typedef long long unsigned int uint64_t;
typedef signed char int_least8_t;
typedef short int int_least16_t;
typedef long int int_least32_t;
typedef long long int int_least64_t;
typedef unsigned char uint_least8_t;
typedef short unsigned int uint_least16_t;
typedef long unsigned int uint_least32_t;
typedef long long unsigned int uint_least64_t;
typedef int int_fast8_t;
typedef int int_fast16_t;
typedef int int_fast32_t;
typedef long long int int_fast64_t;
typedef unsigned int uint_fast8_t;
typedef unsigned int uint_fast16_t;
typedef unsigned int uint_fast32_t;
typedef long long unsigned int uint_fast64_t;
typedef int intptr_t;
typedef unsigned int uintptr_t;
typedef long long int intmax_t;
typedef long long unsigned int uintmax_t;
typedef unsigned int size_t;
extern const int8_t model_conv1_weight[72];
extern const int32_t model_conv1_weight_zero[8];
extern const int32_t model_conv1_multiplier[8];
extern const int32_t model_conv1_right_shift[8];
extern const int8_t model_conv2_weight[1152];
extern const int32_t model_conv2_weight_zero[16];
extern const int32_t model_conv2_multiplier[16];
extern const int32_t model_conv2_right_shift[16];
extern const int8_t model_conv3_weight[4608];
extern const int32_t model_conv3_weight_zero[32];
extern const int32_t model_conv3_multiplier[32];
extern const int32_t model_conv3_right_shift[32];
extern const int8_t model_conv4_weight[9216];
extern const int32_t model_conv4_weight_zero[32];
extern const int32_t model_conv4_multiplier[32];
extern const int32_t model_conv4_right_shift[32];
extern const int8_t model_fc1_weight[4096];
extern const int32_t model_fc1_weight_zero[32];
extern const int32_t model_fc1_multiplier[32];
extern const int32_t model_fc1_right_shift[32];
extern const int8_t model_fc2_weight[96];
extern const int32_t model_fc2_weight_zero[3];
extern const int32_t model_fc2_multiplier[3];
extern const int32_t model_fc2_right_shift[3];
typedef struct {
    const char *name;
    int is_conv, relu;
    int in_c, in_h, in_w, out_c, out_h, out_w;
    int32_t input_zero, output_zero;
    const int8_t *weight;
    const int32_t *weight_zero, *multiplier, *right_shift;
    size_t trace_offset, output_elements;
} ModelLayer;
extern const ModelLayer model_layers[6];
extern const char *const model_class_names[3];
extern const uint8_t model_gray8_to_input[256];
typedef struct {
    _Alignas(16) uint8_t a[2048];
    _Alignas(16) uint8_t b[2048];
} ModelWorkspace;
enum { MODEL_OK = 0, MODEL_BAD_ARGUMENT = -1, MODEL_NONFINITE_INPUT = -2 };
int model_infer_u8(const uint8_t *input, uint8_t *output, ModelWorkspace *workspace);
int model_infer_u8_trace(const uint8_t *input, uint8_t *output, ModelWorkspace *workspace,
                         uint8_t *trace, size_t trace_size);
int model_gray_to_input(const uint8_t *gray, uint8_t *quantized);
int model_argmax(const uint8_t *quantized);
size_t model_workspace_bytes(void);
const char *model_source_sha256(void);
int32_t model_round_shift_even(int64_t value, int right_shift);
static ModelWorkspace firmware_workspace;
static uint8_t camera_quantized[1024];
int firmware_predict_quantized(const uint8_t frame[1024],
                              uint8_t scores[3]) {
    int status = model_infer_u8(frame, scores, &firmware_workspace);
    return status == MODEL_OK ? model_argmax(scores) : status;
}
int firmware_predict_gray8(const uint8_t gray[1024],
                           uint8_t scores[3]) {
    int status = model_gray_to_input(gray, camera_quantized);
    return status == MODEL_OK ? firmware_predict_quantized(camera_quantized, scores) : status;
}

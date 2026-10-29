       
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
typedef unsigned int size_t;
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
int image_preprocess_gray8(const uint8_t *pixels, int width, int height, size_t stride,
                           int orientation, uint8_t gray_resized[1024]);
int image_preprocess_rgba8(const uint8_t *pixels, int width, int height, size_t stride,
                           int orientation, uint8_t gray_resized[1024]);
typedef struct { int start, end; int64_t sum, center, radius; } Support;
static int64_t triangle_weight(const Support *support, int source) {
    int64_t distance = (int64_t)(2 * source + 1) * 32 - support->center;
    if (distance < 0) distance = -distance;
    return distance < support->radius ? support->radius - distance : 0;
}
static Support make_support(int input_size, int destination) {
    Support s;
    s.center = (int64_t)(2 * destination + 1) * input_size;
    s.radius = 2 * (input_size > 32 ? input_size : 32);
    s.start = (int)((s.center - s.radius) / (2 * 32)) - 1;
    s.end = (int)((s.center + s.radius) / (2 * 32)) + 2;
    if (s.start < 0) s.start = 0;
    if (s.end > input_size) s.end = input_size;
    s.sum = 0;
    for (int i = s.start; i < s.end; ++i) s.sum += triangle_weight(&s, i);
    return s;
}
static int32_t coefficient(const Support *s, int source) {
    int64_t numerator = triangle_weight(s, source) * (1LL << 22);
    return (int32_t)((numerator + s->sum / 2) / s->sum);
}
static uint8_t clip_pixel(int64_t value) {
    value >>= 22;
    return (uint8_t)(value > 255 ? 255 : value);
}
static uint8_t white_composite(uint8_t value, uint8_t alpha) {
    return (uint8_t)(((unsigned)value * alpha + 255u * (255u - alpha) + 127u) / 255u);
}
static uint8_t read_gray(const uint8_t *pixels, int w, int h, size_t stride,
                          int orientation, int x, int y, int channels) {
    int sx = x, sy = y;
    switch (orientation) {
        case 2: sx = w - 1 - x; break;
        case 3: sx = w - 1 - x; sy = h - 1 - y; break;
        case 4: sy = h - 1 - y; break;
        case 5: sx = y; sy = x; break;
        case 6: sx = y; sy = h - 1 - x; break;
        case 7: sx = w - 1 - y; sy = h - 1 - x; break;
        case 8: sx = w - 1 - y; sy = x; break;
        default: break;
    }
    const uint8_t *p = pixels + (size_t)sy * stride + (size_t)sx * channels;
    if (channels == 1) return p[0];
    unsigned r = white_composite(p[0], p[3]);
    unsigned g = white_composite(p[1], p[3]);
    unsigned b = white_composite(p[2], p[3]);
    return (uint8_t)((r * 19595u + g * 38470u + b * 7471u + 32768u) >> 16);
}
static int preprocess(const uint8_t *pixels, int w, int h, size_t stride,
                         int orientation, int channels, uint8_t *output) {
    if (!pixels || !output || w < 1 || h < 1 || w > 4096 || h > 4096
            || stride < (size_t)w * channels || stride > 0xffffffffU / (size_t)h
            || orientation < 1 || orientation > 8) return -1;
    int oriented_w = orientation >= 5 ? h : w;
    int oriented_h = orientation >= 5 ? w : h;
    Support horizontal[32];
    for (int x = 0; x < 32; ++x) horizontal[x] = make_support(oriented_w, x);
    for (int y = 0; y < 32; ++y) {
        Support vertical = make_support(oriented_h, y);
        int64_t sums[32];
        for (int x = 0; x < 32; ++x) sums[x] = 1LL << (22 - 1);
        for (int sy = vertical.start; sy < vertical.end; ++sy) {
            int32_t cy = coefficient(&vertical, sy);
            if (!cy) continue;
            for (int x = 0; x < 32; ++x) {
                const Support *s = &horizontal[x];
                int64_t sum = 1LL << (22 - 1);
                for (int sx = s->start; sx < s->end; ++sx) {
                    int32_t cx = coefficient(s, sx);
                    if (cx) sum += (int64_t)cx * read_gray(pixels, w, h, stride, orientation, sx, sy, channels);
                }
                sums[x] += (int64_t)cy * clip_pixel(sum);
            }
        }
        for (int x = 0; x < 32; ++x) output[y * 32 + x] = clip_pixel(sums[x]);
    }
    return 0;
}
int image_preprocess_gray8(const uint8_t *pixels, int w, int h, size_t stride,
                           int orientation, uint8_t gray_resized[1024]) {
    return preprocess(pixels, w, h, stride, orientation, 1, gray_resized);
}
int image_preprocess_rgba8(const uint8_t *pixels, int w, int h, size_t stride,
                           int orientation, uint8_t gray_resized[1024]) {
    return preprocess(pixels, w, h, stride, orientation, 4, gray_resized);
}

/* Integer separable triangle filtering. Each axis rounds to 8-bit at Q22.
 * Triangle weights are computed as exact rational pixel-center distances.
 * Scratch: MODEL_INPUT_WIDTH column sums and horizontal support descriptions. */
#include "image_preprocess.h"

#define OUTPUT_SIDE MODEL_INPUT_WIDTH
#define COEFFICIENT_BITS 22

typedef struct { int start, end; int64_t sum, center, radius; } Support;

static int64_t triangle_weight(const Support *support, int source) {
    int64_t distance = (int64_t)(2 * source + 1) * OUTPUT_SIDE - support->center;
    if (distance < 0) distance = -distance;
    return distance < support->radius ? support->radius - distance : 0;
}

static Support make_support(int input_size, int destination) {
    Support s;
    s.center = (int64_t)(2 * destination + 1) * input_size;
    s.radius = 2 * (input_size > OUTPUT_SIDE ? input_size : OUTPUT_SIDE);
    s.start = (int)((s.center - s.radius) / (2 * OUTPUT_SIDE)) - 1;
    s.end = (int)((s.center + s.radius) / (2 * OUTPUT_SIDE)) + 2;
    if (s.start < 0) s.start = 0;
    if (s.end > input_size) s.end = input_size;
    s.sum = 0;
    for (int i = s.start; i < s.end; ++i) s.sum += triangle_weight(&s, i);
    return s;
}

static int32_t coefficient(const Support *s, int source) {
    int64_t numerator = triangle_weight(s, source) * (INT64_C(1) << COEFFICIENT_BITS);
    return (int32_t)((numerator + s->sum / 2) / s->sum);
}

static uint8_t clip_pixel(int64_t value) {
    value >>= COEFFICIENT_BITS; /* sum is nonnegative */
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
    if (!pixels || !output || w < 1 || h < 1 || w > IMAGE_MAX_SIDE || h > IMAGE_MAX_SIDE
            || stride < (size_t)w * channels || stride > SIZE_MAX / (size_t)h
            || orientation < 1 || orientation > 8) return -1;
    int oriented_w = orientation >= 5 ? h : w;
    int oriented_h = orientation >= 5 ? w : h;
    Support horizontal[OUTPUT_SIDE];
    for (int x = 0; x < OUTPUT_SIDE; ++x) horizontal[x] = make_support(oriented_w, x);
    for (int y = 0; y < OUTPUT_SIDE; ++y) {
        Support vertical = make_support(oriented_h, y);
        int64_t sums[OUTPUT_SIDE];
        for (int x = 0; x < OUTPUT_SIDE; ++x) sums[x] = INT64_C(1) << (COEFFICIENT_BITS - 1);
        for (int sy = vertical.start; sy < vertical.end; ++sy) {
            int32_t cy = coefficient(&vertical, sy);
            if (!cy) continue;
            for (int x = 0; x < OUTPUT_SIDE; ++x) {
                const Support *s = &horizontal[x];
                int64_t sum = INT64_C(1) << (COEFFICIENT_BITS - 1);
                for (int sx = s->start; sx < s->end; ++sx) {
                    int32_t cx = coefficient(s, sx);
                    if (cx) sum += (int64_t)cx * read_gray(pixels, w, h, stride, orientation, sx, sy, channels);
                }
                sums[x] += (int64_t)cy * clip_pixel(sum);
            }
        }
        for (int x = 0; x < OUTPUT_SIDE; ++x) output[y * OUTPUT_SIDE + x] = clip_pixel(sums[x]);
    }
    return 0;
}

int image_preprocess_gray8(const uint8_t *pixels, int w, int h, size_t stride,
                           int orientation, uint8_t gray_resized[MODEL_INPUT_ELEMENTS]) {
    return preprocess(pixels, w, h, stride, orientation, 1, gray_resized);
}

int image_preprocess_rgba8(const uint8_t *pixels, int w, int h, size_t stride,
                           int orientation, uint8_t gray_resized[MODEL_INPUT_ELEMENTS]) {
    return preprocess(pixels, w, h, stride, orientation, 4, gray_resized);
}

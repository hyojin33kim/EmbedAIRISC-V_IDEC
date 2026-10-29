#ifndef INT8_C_IMAGE_PREPROCESS_H
#define INT8_C_IMAGE_PREPROCESS_H

#include "model_types.h"

#ifndef IMAGE_MAX_SIDE
#define IMAGE_MAX_SIDE 4096
#endif

/* No heap or floating point: decode is separate. Caller keeps source pixels alive.
 * Supports gray8 or RGBA8, EXIF orientations 1..8, white alpha background,
 * Pillow-style luma and separable antialiased bilinear resize to 64x64. */
int image_preprocess_gray8(const uint8_t *pixels, int width, int height, size_t stride,
                           int orientation, uint8_t gray64[4096]);
int image_preprocess_rgba8(const uint8_t *pixels, int width, int height, size_t stride,
                           int orientation, uint8_t gray64[4096]);

#endif

#ifndef INT8_C_IMAGE_DECODE_H
#define INT8_C_IMAGE_DECODE_H

#include <stddef.h>
#include <stdint.h>

typedef struct { uint8_t *rgba; int width, height, orientation; } DecodedImage;
int image_decode_file(const char *path, DecodedImage *image, char *error, size_t error_size);
void image_decode_free(DecodedImage *image);

#endif

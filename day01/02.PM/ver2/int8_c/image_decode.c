/* Portable file adapter; firmware camera frames bypass this decoder. */
#include "image_decode.h"
#include "image_preprocess.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNM
#define STBI_NO_SIMD
#define STBI_NO_THREAD_LOCALS
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#define STBI_MAX_DIMENSIONS IMAGE_MAX_SIDE
#define STB_IMAGE_IMPLEMENTATION
#include "third_party/stb/stb_image.h"

static uint16_t read16(const uint8_t *p, int little) {
    return little ? (uint16_t)(p[0] | ((uint16_t)p[1] << 8)) : (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static uint32_t read32(const uint8_t *p, int little) {
    return little ? (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24)
                  : ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static int tiff_orientation(const uint8_t *p, size_t size) {
    if (size < 8) return 1;
    int little = p[0] == 'I' && p[1] == 'I';
    if (!little && !(p[0] == 'M' && p[1] == 'M')) return 1;
    if (read16(p + 2, little) != 42) return 1;
    size_t offset = read32(p + 4, little);
    if (offset > size - 2) return 1;
    unsigned count = read16(p + offset, little);
    offset += 2;
    for (unsigned i = 0; i < count && offset <= size && size - offset >= 12; ++i, offset += 12) {
        if (read16(p + offset, little) == 0x112 && read16(p + offset + 2, little) == 3
                && read32(p + offset + 4, little) == 1) {
            int value = read16(p + offset + 8, little);
            return value >= 1 && value <= 8 ? value : 1;
        }
    }
    return 1;
}

static int orientation(const uint8_t *p, size_t size) {
    if (size >= 8 && !memcmp(p, "\x89PNG\r\n\x1a\n", 8)) {
        size_t offset = 8;
        while (offset <= size && size - offset >= 12) {
            size_t length = read32(p + offset, 0);
            if (length > size - offset - 12) break;
            if (!memcmp(p + offset + 4, "eXIf", 4)) return tiff_orientation(p + offset + 8, length);
            offset += length + 12;
        }
    } else if (size >= 2 && p[0] == 0xff && p[1] == 0xd8) {
        size_t offset = 2;
        while (offset < size) {
            if (p[offset++] != 0xff) break;
            while (offset < size && p[offset] == 0xff) ++offset;
            if (offset >= size) break;
            unsigned marker = p[offset++];
            if (marker == 0xda || marker == 0xd9) break;
            if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
            if (size - offset < 2) break;
            size_t length = read16(p + offset, 0);
            if (length < 2 || length > size - offset) break;
            if (marker == 0xe1 && length >= 8 && !memcmp(p + offset + 2, "Exif\0\0", 6))
                return tiff_orientation(p + offset + 8, length - 8);
            offset += length;
        }
    }
    return 1;
}

int image_decode_file(const char *path, DecodedImage *image, char *error, size_t error_size) {
    if (!path || !image || !error || !error_size) return -1;
    memset(image, 0, sizeof(*image));
    FILE *file = fopen(path, "rb");
    if (!file) { snprintf(error, error_size, "Cannot open image: %s", path); return -1; }
    if (fseek(file, 0, SEEK_END) || ftell(file) < 1) {
        fclose(file); snprintf(error, error_size, "Empty/unseekable image"); return -1;
    }
    long length = ftell(file);
    if (length > 32 * 1024 * 1024 || length > INT_MAX || fseek(file, 0, SEEK_SET)) {
        fclose(file); snprintf(error, error_size, "Image file exceeds 32 MiB limit"); return -1;
    }
    uint8_t *bytes = malloc((size_t)length);
    if (!bytes) { fclose(file); snprintf(error, error_size, "Image allocation failed"); return -1; }
    size_t received = fread(bytes, 1, (size_t)length, file);
    fclose(file);
    if (received != (size_t)length) {
        free(bytes); snprintf(error, error_size, "Truncated image read"); return -1;
    }
    if (stbi_is_16_bit_from_memory(bytes, (int)length)) {
        free(bytes); snprintf(error, error_size, "Use an 8-bit PNG/PGM/JPEG image"); return -1;
    }
    image->orientation = orientation(bytes, (size_t)length);
    int channels;
    image->rgba = stbi_load_from_memory(bytes, (int)length, &image->width, &image->height, &channels, 4);
    free(bytes);
    if (!image->rgba) {
        snprintf(error, error_size, "Image decode failed: %s", stbi_failure_reason()); return -1;
    }
    return 0;
}

void image_decode_free(DecodedImage *image) {
    if (image) { stbi_image_free(image->rgba); image->rgba = NULL; }
}

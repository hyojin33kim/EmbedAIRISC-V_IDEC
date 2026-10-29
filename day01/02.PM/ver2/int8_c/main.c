/* Native C entry point: image file -> decode/preprocess -> INT8 CNN -> results.
 * The binary record interface is kept for firmware transport/golden tests. */
#include "model.h"
#include "image_decode.h"
#include "image_preprocess.h"

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static ModelWorkspace workspace;
static unsigned char record[MODEL_INPUT_ELEMENTS * 4];
static float input_f32[MODEL_INPUT_ELEMENTS];
static uint8_t input_u8[MODEL_INPUT_ELEMENTS];
static uint8_t gray_resized[MODEL_INPUT_ELEMENTS];

static void usage(const char *name) {
    fprintf(stderr, "Usage: %s --image PNG/JPEG/PGM [--device cpu|auto] [--output-dir DIR | --output JSON]\n"
                    "       %s --input FILE [--input-type u8|gray8|f32le] [--output CSV]\n"
                    "Image options: --dump-gray FILE --dump-input FILE\n", name, name);
}

static int run_binary(int argc, char **argv) {
    const char *input_path = NULL, *output_path = NULL, *type = "u8";
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--help")) { usage(argv[0]); return 0; }
        if (i + 1 >= argc) { usage(argv[0]); return 2; }
        if (!strcmp(argv[i], "--input")) input_path = argv[++i];
        else if (!strcmp(argv[i], "--output")) output_path = argv[++i];
        else if (!strcmp(argv[i], "--input-type")) type = argv[++i];
        else { usage(argv[0]); return 2; }
    }
    if (!input_path || (strcmp(type, "u8") && strcmp(type, "gray8") && strcmp(type, "f32le"))) {
        usage(argv[0]); return 2;
    }
    if (output_path && !strcmp(input_path, output_path)) {
        fprintf(stderr, "Input and output paths must differ.\n"); return 2;
    }
    FILE *input = fopen(input_path, "rb");
    if (!input) { perror(input_path); return 2; }
    FILE *output = output_path ? fopen(output_path, "w") : stdout;
    if (!output) { perror(output_path); fclose(input); return 2; }
    fprintf(output, "sample_index,predicted_index");
    for (int i = 0; i < MODEL_CLASS_COUNT; ++i) fprintf(output, ",q%d", i);
    for (int i = 0; i < MODEL_CLASS_COUNT; ++i) fprintf(output, ",logit%d", i);
    fprintf(output, "\n");
    const size_t record_size = MODEL_INPUT_ELEMENTS * (!strcmp(type, "f32le") ? 4u : 1u);
    size_t count = 0;
    int error = 0;
    for (;;) {
        size_t received = fread(record, 1, record_size, input);
        if (!received) break;
        if (received != record_size) {
            fprintf(stderr, "Truncated input record %zu: expected %zu bytes, got %zu\n", count, record_size, received);
            error = 2; break;
        }
        int status = MODEL_OK;
        if (!strcmp(type, "f32le")) {
            for (size_t i = 0; i < MODEL_INPUT_ELEMENTS; ++i) {
                uint32_t bits = (uint32_t)record[4 * i] | ((uint32_t)record[4 * i + 1] << 8)
                              | ((uint32_t)record[4 * i + 2] << 16) | ((uint32_t)record[4 * i + 3] << 24);
                memcpy(&input_f32[i], &bits, 4);
            }
            status = model_quantize_input(input_f32, input_u8);
        } else if (!strcmp(type, "gray8")) {
            status = model_gray_to_input(record, input_u8);
        } else {
            memcpy(input_u8, record, MODEL_INPUT_ELEMENTS);
        }
        uint8_t q[MODEL_CLASS_COUNT];
        float logits[MODEL_CLASS_COUNT];
        if (status == MODEL_OK) status = model_infer_u8(input_u8, q, &workspace);
        if (status != MODEL_OK) {
            fprintf(stderr, "Inference failed at record %zu: status=%d\n", count, status);
            error = 2; break;
        }
        model_dequantize_output(q, logits);
        fprintf(output, "%zu,%d", count, model_argmax(q));
        for (int i = 0; i < MODEL_CLASS_COUNT; ++i) fprintf(output, ",%u", (unsigned)q[i]);
        for (int i = 0; i < MODEL_CLASS_COUNT; ++i) fprintf(output, ",%.9g", (double)logits[i]);
        fprintf(output, "\n");
        ++count;
    }
    if (ferror(input)) { perror("input read"); error = 2; }
    if (!count) { fprintf(stderr, "Input contains no complete records.\n"); error = 2; }
    fclose(input);
    if (ferror(output)) error = 2;
    if (output_path && fclose(output)) error = 2;
    fprintf(stderr, "Processed %zu images; weight=%d bytes; workspace=%zu bytes\n",
            count, MODEL_WEIGHT_BYTES, sizeof(ModelWorkspace));
    return error;
}

static void json_string(FILE *file, const char *value) {
    fputc('"', file);
    for (const unsigned char *p = (const unsigned char *)value; *p; ++p) {
        if (*p == '"' || *p == '\\') { fputc('\\', file); fputc(*p, file); }
        else if (*p < 32) fprintf(file, "\\u%04x", (unsigned)*p);
        else fputc(*p, file);
    }
    fputc('"', file);
}

static void write_prediction(FILE *file, const char *path, int predicted,
                               const uint8_t *q, const float *logits, const float *probabilities) {
    fputs("{\n  \"image\": ", file); json_string(file, path);
    fputs(",\n  \"device\": \"cpu\", \"model_type\": \"INT8_C\", \"runtime\": \"C11 standalone\",\n  \"checkpoint\": ", file);
    json_string(file, MODEL_SOURCE_CHECKPOINT);
    fputs(",\n  \"model_sha256\": ", file); json_string(file, MODEL_SOURCE_SHA256);
    fputs(",\n  \"source_method\": ", file); json_string(file, MODEL_SOURCE_METHOD);
    fputs(",\n  \"classes\": [", file);
    for (int i = 0; i < MODEL_CLASS_COUNT; ++i) { if (i) fputs(", ", file); json_string(file, model_class_names[i]); }
    fprintf(file, "],\n  \"preprocessing\": {\"image_size\": %d, \"channels\": 1, \"alpha_background\": \"white\", "
            "\"resize\": \"bilinear\", \"input_mode\": ", MODEL_INPUT_WIDTH);
    json_string(file, MODEL_INPUT_FOREGROUND ? "foreground" : "signed");
    fprintf(file, "},\n  \"predicted_index\": %d, \"predicted_label\": ", predicted);
    json_string(file, model_class_names[predicted]);
    fprintf(file, ",\n  \"confidence\": %.17g,\n  \"probabilities\": {", (double)probabilities[predicted]);
    for (int i = 0; i < MODEL_CLASS_COUNT; ++i) {
        if (i) fputs(", ", file);
        json_string(file, model_class_names[i]); fprintf(file, ": %.17g", (double)probabilities[i]);
    }
    fputs("},\n  \"logits\": {", file);
    for (int i = 0; i < MODEL_CLASS_COUNT; ++i) {
        if (i) fputs(", ", file);
        json_string(file, model_class_names[i]); fprintf(file, ": %.17g", (double)logits[i]);
    }
    fputs("},\n  \"quantized_output\": [", file);
    for (int i = 0; i < MODEL_CLASS_COUNT; ++i) fprintf(file, "%s%u", i ? ", " : "", (unsigned)q[i]);
    fputs("]\n}\n", file);
}

static int make_directory(const char *path) {
    char buffer[4096];
    if (snprintf(buffer, sizeof(buffer), "%s", path) >= (int)sizeof(buffer)) return -1;
    for (char *p = buffer + 1; *p; ++p) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(buffer, 0777) && errno != EEXIST) return -1;
            *p = '/';
        }
    }
    return mkdir(buffer, 0777) && errno != EEXIST ? -1 : 0;
}

static int dump_bytes(const char *path, const uint8_t *bytes, size_t size) {
    if (!path) return 0;
    FILE *file = fopen(path, "wb");
    if (!file) return -1;
    int failed = fwrite(bytes, 1, size, file) != size;
    if (fclose(file)) failed = 1;
    return failed ? -1 : 0;
}

int main(int argc, char **argv) {
    int image_mode = 0;
    for (int i = 1; i < argc; ++i) if (!strcmp(argv[i], "--image")) image_mode = 1;
    if (!image_mode) return run_binary(argc, argv);
    const char *path = NULL, *output = NULL, *directory = NULL, *device = "cpu";
    const char *gray_dump = NULL, *input_dump = NULL;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--help")) { usage(argv[0]); return 0; }
        if (i + 1 >= argc) { usage(argv[0]); return 2; }
        if (!strcmp(argv[i], "--image")) path = argv[++i];
        else if (!strcmp(argv[i], "--output")) output = argv[++i];
        else if (!strcmp(argv[i], "--output-dir")) directory = argv[++i];
        else if (!strcmp(argv[i], "--device")) device = argv[++i];
        else if (!strcmp(argv[i], "--dump-gray") || !strcmp(argv[i], "--dump-gray64")) gray_dump = argv[++i];
        else if (!strcmp(argv[i], "--dump-input")) input_dump = argv[++i];
        else { usage(argv[0]); return 2; }
    }
    if (strcmp(device, "cpu") && strcmp(device, "auto")) {
        fprintf(stderr, "INT8 inference supports CPU only. Use --device cpu or auto.\n"); return 2;
    }
    if (!path || (output && directory)) { usage(argv[0]); return 2; }
    const char *destinations[] = {output, gray_dump, input_dump};
    for (size_t i = 0; i < sizeof(destinations) / sizeof(destinations[0]); ++i) {
        if (destinations[i] && !strcmp(destinations[i], path)) {
            fprintf(stderr, "Image and output paths must differ.\n"); return 2;
        }
    }

    /* Complete inference lifecycle is controlled here; no Python or subprocess. */
    DecodedImage image;
    char error[256];
    if (image_decode_file(path, &image, error, sizeof(error))) {
        fprintf(stderr, "%s\n", error); return 2;
    }
    int status = image_preprocess_rgba8(image.rgba, image.width, image.height,
                                       (size_t)image.width * 4, image.orientation, gray_resized);
    int width = image.width, height = image.height, orientation = image.orientation;
    image_decode_free(&image);
    if (status || model_gray_to_input(gray_resized, input_u8)) {
        fprintf(stderr, "C preprocessing failed.\n"); return 2;
    }
    uint8_t q[MODEL_CLASS_COUNT];
    float logits[MODEL_CLASS_COUNT], probabilities[MODEL_CLASS_COUNT];
    if (model_infer_u8(input_u8, q, &workspace)) {
        fprintf(stderr, "C INT8 inference failed.\n"); return 2;
    }
    model_dequantize_output(q, logits);
    int predicted = model_argmax(q);
    float sum = 0.0f;
    for (int i = 0; i < MODEL_CLASS_COUNT; ++i) {
        probabilities[i] = expf(logits[i] - logits[predicted]); sum += probabilities[i];
    }
    for (int i = 0; i < MODEL_CLASS_COUNT; ++i) probabilities[i] /= sum;
    if (dump_bytes(gray_dump, gray_resized, sizeof(gray_resized)) || dump_bytes(input_dump, input_u8, sizeof(input_u8))) {
        perror("preprocessing dump"); return 2;
    }
    printf("Model: INT8_C; Device: cpu; Runtime: C11 standalone\n");
    printf("Image: %s (%dx%d, EXIF orientation=%d)\n", path, width, height, orientation);
    printf("Prediction: %s (%.6f%%)\n", model_class_names[predicted], (double)probabilities[predicted] * 100.0);
    for (int i = 0; i < MODEL_CLASS_COUNT; ++i)
        printf("  %s: %.6f%% (q=%u, logit=%.9g)\n", model_class_names[i],
               (double)probabilities[i] * 100.0, (unsigned)q[i], (double)logits[i]);
    char output_path[4096];
    if (directory) {
        if (make_directory(directory) || snprintf(output_path, sizeof(output_path), "%s/prediction.json", directory)
                >= (int)sizeof(output_path)) { perror("output directory"); return 2; }
        output = output_path;
    }
    if (output) {
        FILE *file = fopen(output, "w");
        if (!file) { perror(output); return 2; }
        write_prediction(file, path, predicted, q, logits, probabilities);
        int failed = ferror(file);
        if (fclose(file)) failed = 1;
        if (failed) { fprintf(stderr, "JSON output failed\n"); return 2; }
    }
    return 0;
}

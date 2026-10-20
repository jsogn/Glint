#ifndef GLINT_ONNX_RUNTIME_H
#define GLINT_ONNX_RUNTIME_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GlintORTHandle GlintORTHandle;

typedef struct {
    float *data;
    int64_t rank;
    int64_t dimensions[3];
    int64_t element_count;
} GlintORTResult;

typedef struct {
    int32_t *indices;
    float *scores;
    int64_t count;
} GlintCTCResult;

GlintORTHandle *glint_ort_create(
    const char *runtime_path,
    const char *model_path,
    int32_t thread_count,
    char **error_message
);

int32_t glint_ort_run(
    GlintORTHandle *handle,
    const float *input,
    int32_t height,
    int32_t width,
    GlintORTResult *result,
    char **error_message
);

void glint_ort_result_free(GlintORTResult *result);
int32_t glint_ctc_greedy_decode(
    const float *values,
    int64_t timesteps,
    int64_t class_count,
    GlintCTCResult *result
);
void glint_ctc_result_free(GlintCTCResult *result);
void glint_ort_string_free(char *string);
void glint_ort_destroy(GlintORTHandle *handle);

#ifdef __cplusplus
}
#endif

#endif

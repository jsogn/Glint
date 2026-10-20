#include "GlintONNXRuntime.h"

#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "onnxruntime_c_api.h"

struct GlintORTHandle {
    void *library;
    const OrtApi *api;
    OrtEnv *env;
    OrtSessionOptions *options;
    OrtSession *session;
    OrtMemoryInfo *memory_info;
};

typedef const OrtApiBase *(*OrtGetApiBaseFunction)(void);

static void set_error(char **error_message, const char *message) {
    if (error_message == NULL) {
        return;
    }
    *error_message = strdup(message == NULL ? "unknown ONNX Runtime error" : message);
}

static void set_status_error(
    GlintORTHandle *handle,
    OrtStatus *status,
    char **error_message
) {
    if (status == NULL) {
        return;
    }
    const char *message = handle->api->GetErrorMessage(status);
    set_error(error_message, message);
    handle->api->ReleaseStatus(status);
}

GlintORTHandle *glint_ort_create(
    const char *runtime_path,
    const char *model_path,
    int32_t thread_count,
    char **error_message
) {
    if (error_message != NULL) {
        *error_message = NULL;
    }
    GlintORTHandle *handle = calloc(1, sizeof(GlintORTHandle));
    if (handle == NULL) {
        set_error(error_message, "cannot allocate ONNX Runtime handle");
        return NULL;
    }

    handle->library = dlopen(runtime_path, RTLD_NOW | RTLD_LOCAL);
    if (handle->library == NULL) {
        set_error(error_message, dlerror());
        free(handle);
        return NULL;
    }

    OrtGetApiBaseFunction get_api_base = NULL;
    *(void **)(&get_api_base) = dlsym(handle->library, "OrtGetApiBase");
    if (get_api_base == NULL) {
        set_error(error_message, "OrtGetApiBase is missing from libonnxruntime");
        glint_ort_destroy(handle);
        return NULL;
    }

    handle->api = get_api_base()->GetApi(ORT_API_VERSION);
    if (handle->api == NULL) {
        set_error(error_message, "ONNX Runtime rejected the requested C API version");
        glint_ort_destroy(handle);
        return NULL;
    }

    OrtStatus *status = handle->api->CreateEnv(
        ORT_LOGGING_LEVEL_WARNING,
        "GlintOCR",
        &handle->env
    );
    if (status != NULL) {
        set_status_error(handle, status, error_message);
        glint_ort_destroy(handle);
        return NULL;
    }

    status = handle->api->CreateSessionOptions(&handle->options);
    if (status != NULL) {
        set_status_error(handle, status, error_message);
        glint_ort_destroy(handle);
        return NULL;
    }
    status = handle->api->SetSessionGraphOptimizationLevel(
        handle->options,
        ORT_ENABLE_ALL
    );
    if (status != NULL) {
        set_status_error(handle, status, error_message);
        glint_ort_destroy(handle);
        return NULL;
    }
    status = handle->api->SetIntraOpNumThreads(
        handle->options,
        thread_count > 0 ? thread_count : 2
    );
    if (status != NULL) {
        set_status_error(handle, status, error_message);
        glint_ort_destroy(handle);
        return NULL;
    }
    status = handle->api->SetSessionExecutionMode(
        handle->options,
        ORT_SEQUENTIAL
    );
    if (status != NULL) {
        set_status_error(handle, status, error_message);
        glint_ort_destroy(handle);
        return NULL;
    }

    status = handle->api->CreateSession(
        handle->env,
        model_path,
        handle->options,
        &handle->session
    );
    if (status != NULL) {
        set_status_error(handle, status, error_message);
        glint_ort_destroy(handle);
        return NULL;
    }

    status = handle->api->CreateCpuMemoryInfo(
        OrtArenaAllocator,
        OrtMemTypeDefault,
        &handle->memory_info
    );
    if (status != NULL) {
        set_status_error(handle, status, error_message);
        glint_ort_destroy(handle);
        return NULL;
    }

    return handle;
}

int32_t glint_ort_run(
    GlintORTHandle *handle,
    const float *input,
    int32_t height,
    int32_t width,
    GlintORTResult *result,
    char **error_message
) {
    if (error_message != NULL) {
        *error_message = NULL;
    }
    if (result != NULL) {
        memset(result, 0, sizeof(GlintORTResult));
    }
    if (handle == NULL || input == NULL || result == NULL ||
        height <= 0 || width <= 0) {
        set_error(error_message, "invalid ONNX Runtime input");
        return 1;
    }

    int64_t input_dimensions[4] = {1, 3, height, width};
    size_t input_bytes =
        (size_t)width * (size_t)height * 3 * sizeof(float);
    OrtValue *input_tensor = NULL;
    OrtStatus *status = handle->api->CreateTensorWithDataAsOrtValue(
        handle->memory_info,
        (void *)input,
        input_bytes,
        input_dimensions,
        4,
        ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
        &input_tensor
    );
    if (status != NULL) {
        set_status_error(handle, status, error_message);
        return 2;
    }

    const char *input_names[] = {"x"};
    const char *output_names[] = {"fetch_name_0"};
    OrtValue *output_tensor = NULL;
    status = handle->api->Run(
        handle->session,
        NULL,
        input_names,
        (const OrtValue *const *)&input_tensor,
        1,
        output_names,
        1,
        &output_tensor
    );
    handle->api->ReleaseValue(input_tensor);
    if (status != NULL) {
        set_status_error(handle, status, error_message);
        return 3;
    }

    OrtTensorTypeAndShapeInfo *shape_info = NULL;
    status = handle->api->GetTensorTypeAndShape(output_tensor, &shape_info);
    if (status != NULL) {
        set_status_error(handle, status, error_message);
        handle->api->ReleaseValue(output_tensor);
        return 4;
    }

    ONNXTensorElementDataType element_type;
    status = handle->api->GetTensorElementType(shape_info, &element_type);
    if (status != NULL) {
        set_status_error(handle, status, error_message);
        handle->api->ReleaseTensorTypeAndShapeInfo(shape_info);
        handle->api->ReleaseValue(output_tensor);
        return 4;
    }
    size_t rank = 0;
    status = handle->api->GetDimensionsCount(shape_info, &rank);
    if (status != NULL) {
        set_status_error(handle, status, error_message);
        handle->api->ReleaseTensorTypeAndShapeInfo(shape_info);
        handle->api->ReleaseValue(output_tensor);
        return 4;
    }
    if (element_type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || rank > 3) {
        set_error(error_message, "unexpected ONNX output type or rank");
        handle->api->ReleaseTensorTypeAndShapeInfo(shape_info);
        handle->api->ReleaseValue(output_tensor);
        return 5;
    }

    int64_t dimensions[3] = {0, 0, 0};
    status = handle->api->GetDimensions(shape_info, dimensions, rank);
    if (status != NULL) {
        set_status_error(handle, status, error_message);
        handle->api->ReleaseTensorTypeAndShapeInfo(shape_info);
        handle->api->ReleaseValue(output_tensor);
        return 5;
    }
    size_t element_count_size = 0;
    status = handle->api->GetTensorShapeElementCount(
        shape_info,
        &element_count_size
    );
    if (status != NULL) {
        set_status_error(handle, status, error_message);
        handle->api->ReleaseTensorTypeAndShapeInfo(shape_info);
        handle->api->ReleaseValue(output_tensor);
        return 5;
    }
    int64_t element_count = (int64_t)element_count_size;

    float *output_data = NULL;
    status = handle->api->GetTensorMutableData(
        output_tensor,
        (void **)&output_data
    );
    if (status != NULL || output_data == NULL) {
        if (status != NULL) {
            set_status_error(handle, status, error_message);
        } else {
            set_error(error_message, "ONNX output data is unavailable");
        }
        handle->api->ReleaseTensorTypeAndShapeInfo(shape_info);
        handle->api->ReleaseValue(output_tensor);
        return 6;
    }

    float *copied = malloc((size_t)element_count * sizeof(float));
    if (copied == NULL) {
        set_error(error_message, "cannot allocate ONNX output buffer");
        handle->api->ReleaseTensorTypeAndShapeInfo(shape_info);
        handle->api->ReleaseValue(output_tensor);
        return 7;
    }
    memcpy(copied, output_data, (size_t)element_count * sizeof(float));

    result->data = copied;
    result->rank = (int64_t)rank;
    result->dimensions[0] = dimensions[0];
    result->dimensions[1] = dimensions[1];
    result->dimensions[2] = dimensions[2];
    result->element_count = element_count;

    handle->api->ReleaseTensorTypeAndShapeInfo(shape_info);
    handle->api->ReleaseValue(output_tensor);
    return 0;
}

void glint_ort_result_free(GlintORTResult *result) {
    if (result == NULL) {
        return;
    }
    free(result->data);
    memset(result, 0, sizeof(GlintORTResult));
}

int32_t glint_ctc_greedy_decode(
    const float *values,
    int64_t timesteps,
    int64_t class_count,
    GlintCTCResult *result
) {
    if (result != NULL) {
        memset(result, 0, sizeof(GlintCTCResult));
    }
    if (values == NULL || result == NULL ||
        timesteps <= 0 || class_count <= 0) {
        return 1;
    }

    int32_t *indices = malloc((size_t)timesteps * sizeof(int32_t));
    float *scores = malloc((size_t)timesteps * sizeof(float));
    if (indices == NULL || scores == NULL) {
        free(indices);
        free(scores);
        return 2;
    }

    int32_t previous = -1;
    int64_t count = 0;
    for (int64_t timestep = 0; timestep < timesteps; timestep++) {
        int64_t offset = timestep * class_count;
        int32_t best_index = 0;
        float best_value = -INFINITY;
        for (int64_t class_index = 0;
             class_index < class_count;
             class_index++) {
            float value = values[offset + class_index];
            if (value > best_value) {
                best_value = value;
                best_index = (int32_t)class_index;
            }
        }
        if (best_index != 0 && best_index != previous) {
            indices[count] = best_index;
            scores[count] = best_value;
            count++;
        }
        previous = best_index;
    }

    result->indices = indices;
    result->scores = scores;
    result->count = count;
    return 0;
}

void glint_ctc_result_free(GlintCTCResult *result) {
    if (result == NULL) {
        return;
    }
    free(result->indices);
    free(result->scores);
    memset(result, 0, sizeof(GlintCTCResult));
}

void glint_ort_string_free(char *string) {
    free(string);
}

void glint_ort_destroy(GlintORTHandle *handle) {
    if (handle == NULL) {
        return;
    }
    if (handle->api != NULL) {
        if (handle->memory_info != NULL) {
            handle->api->ReleaseMemoryInfo(handle->memory_info);
        }
        if (handle->session != NULL) {
            handle->api->ReleaseSession(handle->session);
        }
        if (handle->options != NULL) {
            handle->api->ReleaseSessionOptions(handle->options);
        }
        if (handle->env != NULL) {
            handle->api->ReleaseEnv(handle->env);
        }
    }
    if (handle->library != NULL) {
        dlclose(handle->library);
    }
    free(handle);
}

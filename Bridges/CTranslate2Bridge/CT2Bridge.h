#pragma once

#ifdef __cplusplus
extern "C" {
#endif

void* glint_ct2_create(const char* model_dir, char** error);
char* glint_ct2_translate(void* handle, const char* text);
void glint_ct2_free_string(char* value);
void glint_ct2_destroy(void* handle);

#ifdef __cplusplus
}
#endif

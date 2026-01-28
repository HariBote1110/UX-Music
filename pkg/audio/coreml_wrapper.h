#ifndef COREML_WRAPPER_H
#define COREML_WRAPPER_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// CoreMLUpsampler represents the ANE-backed upsampler instance
typedef struct CoreMLUpsampler CoreMLUpsampler;

// Create a new upsampler instance with the specified model path
CoreMLUpsampler *coreml_upsampler_create(const char *model_path);

// Process audio samples
// input: float32 array of mono samples
// output: float32 array of upsampled/BWE samples
// Returns true on success
bool coreml_upsampler_process(CoreMLUpsampler *upsampler, const float *input,
                              size_t input_size, float *output,
                              size_t *output_size);

// Destroy the upsampler instance
void coreml_upsampler_destroy(CoreMLUpsampler *upsampler);

#ifdef __cplusplus
}
#endif

#endif // COREML_WRAPPER_H

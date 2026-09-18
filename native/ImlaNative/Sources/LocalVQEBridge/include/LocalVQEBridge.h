#ifndef IMLA_LOCALVQE_BRIDGE_H
#define IMLA_LOCALVQE_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ImlaLocalVQEContext ImlaLocalVQEContext;

ImlaLocalVQEContext *imla_localvqe_create(
    const char *model_path,
    const char *library_path,
    int threads,
    char *error_buffer,
    int error_buffer_length
);

void imla_localvqe_destroy(ImlaLocalVQEContext *context);
void imla_localvqe_reset(ImlaLocalVQEContext *context);

int imla_localvqe_process_frame_f32(
    ImlaLocalVQEContext *context,
    const float *mic,
    const float *reference,
    int hop_samples,
    float *output
);

int imla_localvqe_sample_rate(ImlaLocalVQEContext *context);
int imla_localvqe_hop_length(ImlaLocalVQEContext *context);
const char *imla_localvqe_last_error(ImlaLocalVQEContext *context);

#ifdef __cplusplus
}
#endif

#endif

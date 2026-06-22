// Minimal C header for libDF (DeepFilterNet) — the subset the Crisp engine uses.
// Backed by poc/model/DeepFilterNet/libDF/src/capi.rs (pure-Rust tract inference).
#ifndef CRISP_DF_H
#define CRISP_DF_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DFState DFState;

// Load a model from a .tar.gz path. atten_lim in dB (100 = full suppression).
// log_level may be NULL.
DFState* df_create(const char* path, float atten_lim, const char* log_level);

// Frames the model consumes/produces per df_process_frame call (the hop size, samples).
size_t df_get_frame_length(DFState* st);

// Live strength control. lim_db: 0 = bypass ... 100 = full suppression.
void df_set_atten_lim(DFState* st, float lim_db);

// Process one mono hop in place. input/output are df_get_frame_length() floats.
// Returns the estimated local SNR (dB).
float df_process_frame(DFState* st, float* input, float* output);

void df_free(DFState* model);

#ifdef __cplusplus
}
#endif

#endif // CRISP_DF_H

// Phase 2 verification: stream raw float32 mono 48kHz audio through libDF
// frame-by-frame (exactly as the real-time audio callback will), proving the
// streaming C-API path is real-time capable from compiled native code.
//
// Usage: df_stream_test <model.tar.gz> <atten_db> <in.f32> <out.f32>
//   in/out are raw 32-bit float, mono, 48 kHz (use ffmpeg -f f32le to convert).

#include "df.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

int main(int argc, char** argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: %s <model.tar.gz> <atten_db> <in.f32> <out.f32>\n", argv[0]);
        return 2;
    }
    const char* model = argv[1];
    float atten = (float)atof(argv[2]);

    DFState* st = df_create(model, atten, NULL);
    if (!st) { fprintf(stderr, "df_create failed\n"); return 1; }
    size_t hop = df_get_frame_length(st);
    fprintf(stderr, "model loaded. hop=%zu samples (%.2f ms @48k)\n", hop, hop / 48000.0 * 1000.0);

    FILE* fin = fopen(argv[3], "rb");
    FILE* fout = fopen(argv[4], "wb");
    if (!fin || !fout) { fprintf(stderr, "file open failed\n"); return 1; }

    float* in = malloc(hop * sizeof(float));
    float* out = malloc(hop * sizeof(float));
    size_t frames = 0, samples = 0;
    double proc_seconds = 0;

    size_t n;
    while ((n = fread(in, sizeof(float), hop, fin)) > 0) {
        for (size_t i = n; i < hop; i++) in[i] = 0.0f;   // zero-pad last frame
        struct timespec t0, t1;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        df_process_frame(st, in, out);                   // <-- per-hop streaming inference
        clock_gettime(CLOCK_MONOTONIC, &t1);
        proc_seconds += (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
        fwrite(out, sizeof(float), n, fout);
        frames++; samples += n;
    }

    double audio_seconds = samples / 48000.0;
    double rtf = proc_seconds / audio_seconds;
    double per_hop_ms = proc_seconds / frames * 1000.0;
    double hop_budget_ms = hop / 48000.0 * 1000.0;
    fprintf(stderr, "frames=%zu  audio=%.2fs  proc=%.3fs\n", frames, audio_seconds, proc_seconds);
    fprintf(stderr, "RTF=%.4f  per-hop=%.3fms (budget %.2fms)  %s\n",
            rtf, per_hop_ms, hop_budget_ms,
            per_hop_ms < hop_budget_ms ? "REAL-TIME OK" : "TOO SLOW");

    free(in); free(out); fclose(fin); fclose(fout); df_free(st);
    return 0;
}

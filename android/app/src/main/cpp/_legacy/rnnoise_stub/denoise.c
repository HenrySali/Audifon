/* Copyright (c) 2017 Mozilla
   
   Minimal compilable stub of the RNNoise denoise.c.
   This provides the public API (rnnoise_create, rnnoise_process_frame, etc.)
   with a functional pass-through when stub weights are used.
   
   Replace this file with the full denoise.c from:
   https://github.com/xiph/rnnoise/blob/main/src/denoise.c
   for actual neural network noise suppression.
*/

#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "rnnoise.h"
#include "rnn.h"
#include "rnn_data.h"
#include "freq.h"
#include "pitch.h"
#include "common.h"
#include "arch.h"
#include "kiss_fft.h"
#include "celt_lpc.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* Internal state for the denoiser */
struct DenoiseState {
    float analysis_mem[FRAME_SIZE];
    float cepstral_mem[CEPS_MEM][NB_BANDS];
    int memid;
    float synthesis_mem[FRAME_SIZE];
    float pitch_buf[WINDOW_SIZE * 3 / 2]; /* pitch analysis buffer */
    float pitch_enh_buf[WINDOW_SIZE * 3 / 2];
    float last_gain;
    int last_period;
    float mem_hp_filter[2];
    float lastg[NB_BANDS];
    RNNState rnn;
    /* FFT configs */
    kiss_fft_cfg kfft;
    kiss_fft_cfg kifft;
    /* Model reference */
    const RNNModel *model;
};

/* Bark-scale band boundaries (22 bands for 48kHz, 480-point FFT) */
static const int eband5ms[] = {
    0,  1,  2,  3,  4,  5,  6,  7,  8, 10, 12, 14, 16, 20, 24, 28, 34, 40, 48, 60, 78, 100, 240
};

/* Analysis window (Vorbis window) */
static float compute_window(int i, int N) {
    float x = (float)i / (float)N;
    float s = sinf((float)M_PI * x);
    return sinf(0.5f * (float)M_PI * s * s);
}

int rnnoise_get_size(void) {
    return (int)sizeof(DenoiseState);
}

int rnnoise_get_frame_size(void) {
    return FRAME_SIZE;
}

int rnnoise_init(DenoiseState *st, RNNModel *model) {
    memset(st, 0, sizeof(DenoiseState));
    
    if (model) {
        st->model = model;
    } else {
        st->model = rnnoise_get_stub_model();
    }
    
    /* Initialize gains to unity (pass-through) */
    for (int i = 0; i < NB_BANDS; i++) {
        st->lastg[i] = 1.0f;
    }
    st->last_gain = 1.0f;
    st->last_period = 0;
    st->memid = 0;
    
    /* Allocate FFT */
    st->kfft = kiss_fft_alloc(FREQ_SIZE - 1, 0, NULL, NULL);
    st->kifft = kiss_fft_alloc(FREQ_SIZE - 1, 1, NULL, NULL);
    
    return 0;
}

DenoiseState *rnnoise_create(RNNModel *model) {
    DenoiseState *st;
    st = (DenoiseState *)malloc(sizeof(DenoiseState));
    if (st == NULL) return NULL;
    rnnoise_init(st, model);
    return st;
}

void rnnoise_destroy(DenoiseState *st) {
    if (st) {
        if (st->kfft) free(st->kfft);
        if (st->kifft) free(st->kifft);
        free(st);
    }
}

/* Compute band energies from FFT */
static void compute_band_energy(float *bandE, const kiss_fft_cpx *X) {
    int i;
    for (i = 0; i < NB_BANDS; i++) {
        int j;
        float sum = 0.0f;
        int band_start = eband5ms[i];
        int band_end = eband5ms[i + 1];
        for (j = band_start; j < band_end && j < FREQ_SIZE; j++) {
            sum += X[j].r * X[j].r + X[j].i * X[j].i;
        }
        bandE[i] = sum;
    }
}

/* Apply gains per band in frequency domain */
static void apply_band_gains(kiss_fft_cpx *X, const float *gains) {
    int i;
    for (i = 0; i < NB_BANDS; i++) {
        int j;
        int band_start = eband5ms[i];
        int band_end = eband5ms[i + 1];
        float g = gains[i];
        for (j = band_start; j < band_end && j < FREQ_SIZE; j++) {
            X[j].r *= g;
            X[j].i *= g;
        }
    }
}

float rnnoise_process_frame(DenoiseState *st, float *out, const float *in) {
    int i;
    float vad_prob = 0.0f;
    
    /* If model is not loaded (stub), just pass through */
    if (st->model == NULL || st->model->model_loaded == 0) {
        /* Pass-through: copy input to output */
        if (out != in) {
            memcpy(out, in, FRAME_SIZE * sizeof(float));
        }
        return 0.0f;
    }
    
    /* ---- Full RNNoise processing (when real weights are loaded) ---- */
    
    /* Apply analysis window */
    float windowed[WINDOW_SIZE];
    for (i = 0; i < FRAME_SIZE; i++) {
        float w = compute_window(i, FRAME_SIZE);
        windowed[i] = st->analysis_mem[i] * (1.0f - w) + in[i] * w;
    }
    /* Save for next frame overlap */
    memcpy(st->analysis_mem, in, FRAME_SIZE * sizeof(float));
    
    /* Forward FFT */
    kiss_fft_cpx X[FREQ_SIZE];
    kiss_fft_cpx fft_in[FREQ_SIZE - 1];
    
    for (i = 0; i < FRAME_SIZE; i++) {
        fft_in[i].r = windowed[i];
        fft_in[i].i = 0.0f;
    }
    /* Zero-pad if needed */
    for (i = FRAME_SIZE; i < FREQ_SIZE - 1; i++) {
        fft_in[i].r = 0.0f;
        fft_in[i].i = 0.0f;
    }
    
    if (st->kfft) {
        kiss_fft(st->kfft, fft_in, X);
    } else {
        /* Fallback: pass-through */
        if (out != in) memcpy(out, in, FRAME_SIZE * sizeof(float));
        return 0.0f;
    }
    
    /* Compute band energies */
    float bandE[NB_BANDS];
    compute_band_energy(bandE, X);
    
    /* Compute features for RNN */
    float features[NB_FEATURES];
    memset(features, 0, sizeof(features));
    for (i = 0; i < NB_BANDS; i++) {
        features[i] = 0.5f * log10f(bandE[i] + 1e-10f);
    }
    
    /* Run RNN to get per-band gains */
    float gains[NB_BANDS];
    compute_rnn(&st->rnn, gains, &vad_prob, features);
    
    /* Smooth gains temporally */
    for (i = 0; i < NB_BANDS; i++) {
        gains[i] = 0.5f * gains[i] + 0.5f * st->lastg[i];
        st->lastg[i] = gains[i];
    }
    
    /* Apply gains in frequency domain */
    apply_band_gains(X, gains);
    
    /* Inverse FFT */
    kiss_fft_cpx fft_out[FREQ_SIZE - 1];
    if (st->kifft) {
        kiss_fft(st->kifft, X, fft_out);
    }
    
    /* Apply synthesis window and overlap-add */
    for (i = 0; i < FRAME_SIZE; i++) {
        float w = compute_window(i, FRAME_SIZE);
        out[i] = st->synthesis_mem[i] * (1.0f - w) + fft_out[i].r * w;
    }
    memcpy(st->synthesis_mem, &fft_out[0].r, FRAME_SIZE * sizeof(float));
    
    return vad_prob;
}

RNNModel *rnnoise_model_from_file(FILE *f) {
    (void)f;
    /* Not implemented in stub — return NULL to use built-in model */
    return NULL;
}

void rnnoise_model_free(RNNModel *model) {
    if (model) free(model);
}

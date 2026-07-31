/* Copyright (c) 2017 Mozilla */
/**
   @file rnnoise.h
   @brief Public API for RNNoise — Recurrent Neural Network noise suppression
   
   RNNoise uses a deep recurrent neural network to perform noise suppression
   on 48kHz audio. It processes frames of exactly 480 samples (10ms at 48kHz).
   
   Usage:
     DenoiseState *st = rnnoise_create(NULL);
     float frame[480];
     // fill frame with 480 samples scaled to [-32768, 32768]
     float vad = rnnoise_process_frame(st, frame, frame);
     // frame now contains denoised audio
     rnnoise_destroy(st);
*/
#ifndef RNNOISE_H
#define RNNOISE_H

#include <stddef.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef RNNOISE_EXPORT
# define RNNOISE_EXPORT
#endif

typedef struct DenoiseState DenoiseState;
typedef struct RNNModel RNNModel;

/**
 * Get the size of DenoiseState
 */
RNNOISE_EXPORT int rnnoise_get_size(void);

/**
 * Get the number of samples processed per frame (always 480)
 */
RNNOISE_EXPORT int rnnoise_get_frame_size(void);

/**
 * Initializes a pre-allocated DenoiseState
 * If model is NULL, the built-in model is used.
 */
RNNOISE_EXPORT int rnnoise_init(DenoiseState *st, RNNModel *model);

/**
 * Allocate and initialize a DenoiseState
 * If model is NULL, the built-in model is used.
 */
RNNOISE_EXPORT DenoiseState *rnnoise_create(RNNModel *model);

/**
 * Free a DenoiseState
 */
RNNOISE_EXPORT void rnnoise_destroy(DenoiseState *st);

/**
 * Denoise a frame of audio.
 * @param st Denoiser state
 * @param out Output buffer (480 samples, can be same as in)
 * @param in Input buffer (480 samples, float scaled to [-32768, 32768])
 * @return VAD probability (0.0 to 1.0)
 * 
 * The input/output are float arrays of exactly 480 samples.
 * Audio should be scaled to the range [-32768, 32768] (int16 range).
 */
RNNOISE_EXPORT float rnnoise_process_frame(DenoiseState *st, float *out, const float *in);

/**
 * Load a model from a file (binary format)
 */
RNNOISE_EXPORT RNNModel *rnnoise_model_from_file(FILE *f);

/**
 * Free a model loaded from file
 */
RNNOISE_EXPORT void rnnoise_model_free(RNNModel *model);

#ifdef __cplusplus
}
#endif

#endif /* RNNOISE_H */

/**
 * @file dfn3_api.h
 * @brief C API for DeepFilterNet3 speech enhancement (Rust/tract backend).
 *
 * This header is consumed by the C++ audio engine. The implementation lives
 * in libdfn3.so (compiled from the Rust crate in dfn3_rust/).
 *
 * Thread safety:
 *   - dfn3_process_hop: uses try_lock — safe from audio thread (never blocks).
 *   - dfn3_set_intensity/dfn3_is_active: thread-safe (mutex).
 *   - dfn3_init/dfn3_free: call from main thread only.
 */

#ifndef DFN3_API_H
#define DFN3_API_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Hop size in samples (10 ms @ 48 kHz). */
#define DFN3_HOP_SIZE 480

/** Native sample rate. */
#define DFN3_SAMPLE_RATE 48000

/**
 * Initialize the DeepFilterNet3 engine.
 *
 * @param model_dir  Path to directory containing enc.onnx, erb_dec.onnx,
 *                   df_dec.onnx (null-terminated C string).
 * @return true if initialization succeeded.
 */
bool dfn3_init(const char* model_dir);

/**
 * Process one audio hop (480 samples @ 48 kHz) in-place.
 *
 * Call from the audio thread. Uses try_lock internally — if the engine is
 * busy (e.g., during init/free), returns false immediately without blocking.
 *
 * @param buffer  Pointer to 480 float samples in [-1.0, 1.0]. Modified in-place
 *               with enhanced audio. Untouched if engine is not ready.
 * @return true if processing succeeded.
 */
bool dfn3_process_hop(float* buffer);

/**
 * Set enhancement intensity [0.0, 1.0].
 * 0.0 = bypass (output = input), 1.0 = full enhancement.
 */
void dfn3_set_intensity(float intensity);

/** Get current intensity value. */
float dfn3_get_intensity(void);

/** Check if the engine is initialized and ready. */
bool dfn3_is_active(void);

/** Free all engine resources. Safe to call multiple times. */
void dfn3_free(void);

#ifdef __cplusplus
}
#endif

#endif /* DFN3_API_H */

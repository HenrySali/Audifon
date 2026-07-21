/// @file rnnoise_denoiser.cpp
/// @brief C++ wrapper around xiph/rnnoise v0.1.1 (statically linked).

#include "rnnoise_denoiser.h"

#include <algorithm>
#include <android/log.h>
#include <chrono>
#include <cmath>
#include <cstring>

// RNNoise C API — statically compiled into this .so via CMakeLists.txt.
extern "C" {
#include "rnnoise/include/rnnoise.h"
}

#define RNN_TAG "RnnoiseDenoiser"
#define RNN_LOGI(...) __android_log_print(ANDROID_LOG_INFO, RNN_TAG, __VA_ARGS__)
#define RNN_LOGW(...) __android_log_print(ANDROID_LOG_WARN, RNN_TAG, __VA_ARGS__)

namespace rnnoise_denoiser {

// ─── Lifetime ─────────────────────────────────────────────────────────────

RnnoiseDenoiser::~RnnoiseDenoiser() {
    if (state_) {
        rnnoise_destroy(state_);
        state_ = nullptr;
    }
    initialized_ = false;
}

bool RnnoiseDenoiser::initialize() {
    if (initialized_) return true;

    // Sanity check: build-time FRAME_SIZE must match ours. RNNoise's
    // rnnoise_get_frame_size() reads the compiled-in value; if the vendored
    // sources ever get bumped to a different frame length, refuse to run
    // instead of silently corrupting the audio.
    const int libFrame = rnnoise_get_frame_size();
    if (libFrame != kFrameSize) {
        RNN_LOGW("rnnoise_get_frame_size()=%d != kFrameSize=%d — refusing init",
                 libFrame, kFrameSize);
        return false;
    }

    // NULL model → use the default (baked-in) tiny model.
    state_ = rnnoise_create(nullptr);
    if (!state_) {
        RNN_LOGW("rnnoise_create returned NULL");
        return false;
    }

    residualCount_ = 0;
    residualOutRemaining_ = 0;
    crossfadeGain_ = 0.0f;
    crossfadeTarget_ = 0.0f;
    effectiveIntensity_ = 0.0f;
    initialized_ = true;

    RNN_LOGI("RNNoise initialized (frame=%d @ 48 kHz, tiny model)", kFrameSize);
    return true;
}

// ─── Public setters ───────────────────────────────────────────────────────

void RnnoiseDenoiser::setEnabled(bool enabled) {
    enabled_.store(enabled, std::memory_order_release);
}

void RnnoiseDenoiser::setIntensity(float intensity) {
    intensity_.store(std::clamp(intensity, 0.0f, 1.0f),
                     std::memory_order_release);
}

// ─── Audio processing ─────────────────────────────────────────────────────
//
// Design (mirrors Dfn3Denoiser::process for behavioural parity):
//
// The audio bus is float [-1,+1] at 48 kHz. RNNoise's canonical API operates
// on float samples pre-scaled to the int16 range (see rnnoise_demo.c in the
// upstream v0.1.1 examples) and processes exactly kFrameSize (480) samples
// per call. Oboe delivers variable burst sizes to our callback, so we buffer.
//
// Per call:
//   1. If we already had a partial hop stashed in residual_ from the previous
//      call, complete it by taking (kFrameSize - residualCount_) samples from
//      the front of buffer[]. Run RNNoise on the completed hop, then write
//      the wet result back to the buffer positions that were "consumed" to
//      finish the hop. The wet corresponding to the samples that came from
//      the *previous* call is discarded (they've already been output raw one
//      hop earlier — this is the classic hop-aligned discard).
//   2. Consume full aligned hops from the middle of buffer[]. dry/wet mix
//      goes back in-place.
//   3. Any tail smaller than kFrameSize is stashed for the next call.
//
// This yields exactly ONE hop (10 ms) of denoising latency — the same as
// DFN3 — and never corrupts the phase alignment of the mono channel.

void RnnoiseDenoiser::process(float* buffer, int blockSize) {
    if (!buffer || blockSize <= 0 || !initialized_ || !state_) return;

    const bool en = enabled_.load(std::memory_order_acquire);

    // Fast path: fully disabled AND crossfade already at 0 → pure bypass.
    // Note: we lose one hop of RNNoise state each time this branch is taken,
    // but that's acceptable — the on-ramp when the user re-enables will
    // simply warm the internal filters back up within a few hops.
    if (!en && crossfadeGain_ <= 0.0f) return;

    crossfadeTarget_ = en ? 1.0f : 0.0f;
    const float userIntensity = intensity_.load(std::memory_order_acquire);
    int pos = 0;

    // ─── Step 1: complete the residual from the previous call, if any. ────
    if (residualCount_ > 0) {
        const int take = std::min(kFrameSize - residualCount_, blockSize);
        std::memcpy(residualIn_ + residualCount_, buffer, take * sizeof(float));
        residualCount_ += take;
        pos += take;

        if (residualCount_ == kFrameSize) {
            // Run RNNoise on the completed hop.
            float dry[kFrameSize];
            std::memcpy(dry, residualIn_, sizeof(dry));
            float scaled[kFrameSize];
            for (int i = 0; i < kFrameSize; ++i) {
                scaled[i] = residualIn_[i] * kInt16Scale;
            }
            const auto t0 = std::chrono::steady_clock::now();
            const float vad = rnnoise_process_frame(state_, scaled, scaled);
            const auto t1 = std::chrono::steady_clock::now();
            const auto us = std::chrono::duration_cast<
                std::chrono::microseconds>(t1 - t0).count();
            lastInferenceUs_.store(static_cast<uint32_t>(us),
                                   std::memory_order_release);
            processedFrames_.fetch_add(1, std::memory_order_relaxed);
            lastVadProb_.store(vad, std::memory_order_release);

            // Write wet back to the buffer positions that were consumed to
            // finish the hop. Samples that came from the *previous* call
            // (idx < 0) are dropped — this is the classic hop-aligned
            // discard, identical to DFN3.
            for (int i = 0; i < kFrameSize; ++i) {
                if (crossfadeGain_ < crossfadeTarget_) {
                    crossfadeGain_ = std::min(crossfadeTarget_,
                                              crossfadeGain_ + kCrossfadeStep);
                } else if (crossfadeGain_ > crossfadeTarget_) {
                    crossfadeGain_ = std::max(crossfadeTarget_,
                                              crossfadeGain_ - kCrossfadeStep);
                }
                const int idx = pos - kFrameSize + i;
                if (idx >= 0 && idx < blockSize) {
                    const float wet = scaled[i] * kInt16InvScale;
                    const float mix = crossfadeGain_ * userIntensity;
                    const float out = dry[i] * (1.0f - mix) + wet * mix;
                    buffer[idx] = std::clamp(out, -1.0f, 1.0f);
                }
            }
            residualCount_ = 0;
        }
    }

    // ─── Step 2: consume full 480-sample hops from buffer[pos..]. ─────────
    while (pos + kFrameSize <= blockSize) {
        float dry[kFrameSize];
        std::memcpy(dry, buffer + pos, sizeof(dry));

        float scaled[kFrameSize];
        for (int i = 0; i < kFrameSize; ++i) {
            scaled[i] = dry[i] * kInt16Scale;
        }
        const auto t0 = std::chrono::steady_clock::now();
        const float vad = rnnoise_process_frame(state_, scaled, scaled);
        const auto t1 = std::chrono::steady_clock::now();
        const auto us = std::chrono::duration_cast<std::chrono::microseconds>(
                            t1 - t0).count();
        lastInferenceUs_.store(static_cast<uint32_t>(us),
                               std::memory_order_release);
        processedFrames_.fetch_add(1, std::memory_order_relaxed);
        lastVadProb_.store(vad, std::memory_order_release);

        for (int i = 0; i < kFrameSize; ++i) {
            if (crossfadeGain_ < crossfadeTarget_) {
                crossfadeGain_ = std::min(crossfadeTarget_,
                                          crossfadeGain_ + kCrossfadeStep);
            } else if (crossfadeGain_ > crossfadeTarget_) {
                crossfadeGain_ = std::max(crossfadeTarget_,
                                          crossfadeGain_ - kCrossfadeStep);
            }
            const float wet = scaled[i] * kInt16InvScale;
            const float mix = crossfadeGain_ * userIntensity;
            const float out = dry[i] * (1.0f - mix) + wet * mix;
            buffer[pos + i] = std::clamp(out, -1.0f, 1.0f);
        }
        pos += kFrameSize;
    }

    // ─── Step 3: stash any tail (< kFrameSize) for the next call. ─────────
    // Those samples pass through raw for now; they'll be denoised in Step 1
    // of the next call (with the classic 1-hop delay for the discarded part).
    if (pos < blockSize) {
        const int leftover = blockSize - pos;
        std::memcpy(residualIn_, buffer + pos, leftover * sizeof(float));
        residualCount_ = leftover;
    }

    effectiveIntensity_ = crossfadeGain_ * userIntensity;
}

}  // namespace rnnoise_denoiser

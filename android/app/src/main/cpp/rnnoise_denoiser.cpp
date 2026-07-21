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

    // NULL model → use the default (baked-in) small model. rnnoise_create
    // allocates and initializes DenoiseState with the built-in weights.
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

    RNN_LOGI("RNNoise initialized (frame=%d @ 48 kHz, ~416 KB tiny model)",
             kFrameSize);
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
// Design: RNNoise expects float samples scaled to int16 range and processes
// exactly kFrameSize (480) samples per call. Our audio_engine feeds Oboe
// bursts that can be smaller or larger than 480 — so we buffer.
//
// The residual buffer stashes leftover input samples that can't yet form a
// full 480-sample hop; the previous hop's denoised output is drained first
// so the caller sees continuous audio. The DFN3 wrapper uses the same
// pattern (see dfn3_denoiser.cpp) — this keeps behaviour uniform when the
// audio_engine swaps between denoisers.

void RnnoiseDenoiser::process(float* buffer, int blockSize) {
    if (!buffer || blockSize <= 0 || !initialized_ || !state_) return;

    const bool en = enabled_.load(std::memory_order_acquire);

    // Fast path: fully disabled AND crossfade already at 0 → pure bypass.
    if (!en && crossfadeGain_ <= 0.0f) {
        // Keep RNNoise state fresh so switching ON doesn't produce a burst
        // of nonsense while the internal filters warm up. We still buffer
        // and run frames, but discard the wet output.
        // (For now we simply skip; the crossfade will smooth the on-ramp.)
        return;
    }

    crossfadeTarget_ = en ? 1.0f : 0.0f;

    const float userIntensity = intensity_.load(std::memory_order_acquire);

    int pos = 0;

    // ─── Step 1: drain any residual output from the previous call. ────────
    while (residualOutRemaining_ > 0 && pos < blockSize) {
        const int src = kFrameSize - residualOutRemaining_;
        // Advance crossfade.
        if (crossfadeGain_ < crossfadeTarget_) {
            crossfadeGain_ = std::min(crossfadeTarget_,
                                      crossfadeGain_ + kCrossfadeStep);
        } else if (crossfadeGain_ > crossfadeTarget_) {
            crossfadeGain_ = std::max(crossfadeTarget_,
                                      crossfadeGain_ - kCrossfadeStep);
        }
        const float wet = residualOut_[src];
        const float dry = buffer[pos];
        // Combined dry/wet mix: crossfade gates enable/disable, intensity
        // gates the user slider. Both act linearly on the wet path.
        const float mix = crossfadeGain_ * userIntensity;
        buffer[pos] = std::clamp(dry * (1.0f - mix) + wet * mix, -1.0f, 1.0f);
        pos++;
        residualOutRemaining_--;
    }

    // ─── Step 2: consume full 480-sample hops from the input. ─────────────
    while (pos + kFrameSize - residualCount_ <= blockSize) {
        // Assemble a full hop of input (dry) into residualIn_.
        const int take = kFrameSize - residualCount_;
        std::memcpy(residualIn_ + residualCount_, buffer + pos,
                    take * sizeof(float));
        residualCount_ = kFrameSize;

        // Snapshot dry for the mix.
        float dry[kFrameSize];
        std::memcpy(dry, residualIn_, sizeof(dry));

        // Scale to int16 range, run RNNoise, scale back.
        float scaled[kFrameSize];
        for (int i = 0; i < kFrameSize; ++i) {
            scaled[i] = residualIn_[i] * kInt16Scale;
        }
        // Time the inference so the UI diagnostics panel can report it
        // ("Inferencia: X ms"). steady_clock is monotonic and safe on
        // the audio thread on Android (no syscall beyond vDSO on arm64).
        const auto t0 = std::chrono::steady_clock::now();
        const float vad = rnnoise_process_frame(state_, scaled, scaled);
        const auto t1 = std::chrono::steady_clock::now();
        const auto us = std::chrono::duration_cast<std::chrono::microseconds>(
                            t1 - t0)
                            .count();
        lastInferenceUs_.store(static_cast<uint32_t>(us),
                               std::memory_order_release);
        processedFrames_.fetch_add(1, std::memory_order_relaxed);
        lastVadProb_.store(vad, std::memory_order_release);

        // Wet output samples, dry/wet mixed per-sample with rolling crossfade.
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
            const int dstIdx = pos + i;
            if (dstIdx < blockSize) {
                buffer[dstIdx] = std::clamp(out, -1.0f, 1.0f);
            } else {
                // Doesn't fit — stash the remainder of the wet output.
                residualOut_[i] = wet;
            }
        }

        // If the whole hop fit into `buffer`, advance pos and reset residual.
        if (pos + kFrameSize <= blockSize) {
            pos += kFrameSize;
            residualCount_ = 0;
        } else {
            // Some wet samples couldn't be written to this block. Compute
            // how many landed in output vs how many need to wait for the
            // next call. We wrote (blockSize - pos) samples of wet into
            // buffer and stashed (kFrameSize - (blockSize - pos)) samples
            // into residualOut_ starting at index (blockSize - pos).
            const int written = blockSize - pos;
            const int leftover = kFrameSize - written;
            // Compact residualOut_ so that unread samples start at index
            // (kFrameSize - leftover), matching the drain logic in Step 1.
            std::memmove(residualOut_ + (kFrameSize - leftover),
                         residualOut_ + written,
                         leftover * sizeof(float));
            residualOutRemaining_ = leftover;
            residualCount_ = 0;
            pos = blockSize;  // done with this call
            break;
        }
    }

    // ─── Step 3: stash any leftover input for the next call. ─────────────
    if (pos < blockSize) {
        const int leftover = blockSize - pos;
        // leftover < kFrameSize (guaranteed by the loop condition above)
        std::memcpy(residualIn_ + residualCount_, buffer + pos,
                    leftover * sizeof(float));
        residualCount_ += leftover;
    }

    effectiveIntensity_ =
        crossfadeGain_ * intensity_.load(std::memory_order_acquire);
}

}  // namespace rnnoise_denoiser

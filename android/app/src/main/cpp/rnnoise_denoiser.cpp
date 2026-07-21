/// @file rnnoise_denoiser.cpp
/// @brief C++ wrapper around xiph/rnnoise v0.1.1 (statically linked).

#include "rnnoise_denoiser.h"

#include <algorithm>
#include <android/log.h>
#include <chrono>
#include <cmath>
#include <cstring>

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

    const int libFrame = rnnoise_get_frame_size();
    if (libFrame != kFrameSize) {
        RNN_LOGW("rnnoise_get_frame_size()=%d != kFrameSize=%d — refusing init",
                 libFrame, kFrameSize);
        return false;
    }

    state_ = rnnoise_create(nullptr);
    if (!state_) {
        RNN_LOGW("rnnoise_create returned NULL");
        return false;
    }

    inCount_ = 0;
    outStart_ = 0;
    outAvail_ = 0;
    crossfadeGain_ = 0.0f;
    crossfadeTarget_ = 0.0f;
    effectiveIntensity_ = 0.0f;
    initialized_ = true;

    RNN_LOGI("RNNoise initialized (frame=%d @ 48 kHz, tiny model, ring-buffer)",
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
// Per-sample ring-buffer algorithm. Every input sample is:
//   1) pushed into inBuffer_ (dry, waiting to be denoised)
//   2) once inBuffer_ is full (kFrameSize samples), a hop runs and
//      outBuffer_ is filled with the wet result
//   3) if outBuffer_ has anything, one wet sample is drained per input
//      sample and mixed with the current dry sample.
//
// At cold start the first kFrameSize samples pass through dry because
// outBuffer_ is empty. After that, every sample is wet (delayed by 10 ms).
//
// Why this algorithm and not the "in-place hop within the block" approach
// used by dfn3_denoiser.cpp: when Oboe delivers 256-sample bursts and the
// hop is 480, the in-place approach ends up leaving ~50 % of callbacks
// entirely dry (no full hop fits, and no residual output is drained).
// The user perceives that as "toggle makes no difference" because half the
// audio is untouched. The ring-buffer approach guarantees a continuous
// wet output stream at the cost of one hop of latency (~10 ms), which is
// well within the acceptable range for real-time hearing aid processing.

void RnnoiseDenoiser::process(float* buffer, int blockSize) {
    if (!buffer || blockSize <= 0 || !initialized_ || !state_) return;

    const bool en = enabled_.load(std::memory_order_acquire);

    // Full bypass fast-path: disabled AND fully crossfaded out.
    if (!en && crossfadeGain_ <= 0.0f) return;

    crossfadeTarget_ = en ? 1.0f : 0.0f;
    const float userIntensity = intensity_.load(std::memory_order_acquire);

    // Per-hop diagnostic: RMS of dry input and wet output on the hop we
    // just ran, so adb logcat can confirm attenuation. Updated inside the
    // hop-run branch below; logged once every 200 hops.
    double lastDryE = -1.0, lastWetE = -1.0;

    for (int i = 0; i < blockSize; ++i) {
        const float dry = buffer[i];

        // 1) Push dry into the input hop buffer.
        inBuffer_[inCount_++] = dry;

        // 2) If we filled a full hop, run RNNoise now.
        if (inCount_ >= kFrameSize) {
            // Snapshot dry energy for diagnostics.
            double dryE = 0.0;
            for (int k = 0; k < kFrameSize; ++k) {
                dryE += static_cast<double>(inBuffer_[k]) * inBuffer_[k];
            }

            // Scale to int16 range, run RNNoise in-place, scale back.
            for (int k = 0; k < kFrameSize; ++k) {
                inBuffer_[k] *= kInt16Scale;
            }
            const auto t0 = std::chrono::steady_clock::now();
            const float vad =
                rnnoise_process_frame(state_, inBuffer_, inBuffer_);
            const auto t1 = std::chrono::steady_clock::now();
            const auto us = std::chrono::duration_cast<
                std::chrono::microseconds>(t1 - t0).count();
            lastInferenceUs_.store(static_cast<uint32_t>(us),
                                   std::memory_order_release);
            processedFrames_.fetch_add(1, std::memory_order_relaxed);
            lastVadProb_.store(vad, std::memory_order_release);

            double wetE = 0.0;
            for (int k = 0; k < kFrameSize; ++k) {
                const float w = inBuffer_[k] * kInt16InvScale;
                outBuffer_[k] = w;
                wetE += static_cast<double>(w) * w;
            }
            outStart_ = 0;
            outAvail_ = kFrameSize;
            inCount_ = 0;

            lastDryE = dryE;
            lastWetE = wetE;
        }

        // 3) Drain one wet sample and mix with the current dry sample.
        //    During cold-start warm-up outAvail_ is 0 and we leave the
        //    audio callback's buffer untouched (dry passthrough).
        if (outAvail_ > 0) {
            if (crossfadeGain_ < crossfadeTarget_) {
                crossfadeGain_ = std::min(crossfadeTarget_,
                                          crossfadeGain_ + kCrossfadeStep);
            } else if (crossfadeGain_ > crossfadeTarget_) {
                crossfadeGain_ = std::max(crossfadeTarget_,
                                          crossfadeGain_ - kCrossfadeStep);
            }
            const float wet = outBuffer_[outStart_++];
            outAvail_--;
            const float mix = crossfadeGain_ * userIntensity;
            const float out = dry * (1.0f - mix) + wet * mix;
            buffer[i] = std::clamp(out, -1.0f, 1.0f);
        }
    }

    effectiveIntensity_ = crossfadeGain_ * userIntensity;

    // Diagnostic log once every 200 hops (~2 s at 48 kHz).
    if (lastDryE >= 0.0) {
        const uint64_t hops =
            processedFrames_.load(std::memory_order_relaxed);
        if ((hops % 200) == 0 && hops > 0) {
            const double dryRms = std::sqrt(lastDryE / kFrameSize) + 1e-12;
            const double wetRms = std::sqrt(lastWetE / kFrameSize) + 1e-12;
            const double dryDb = 20.0 * std::log10(dryRms);
            const double wetDb = 20.0 * std::log10(wetRms);
            RNN_LOGI("hop=%llu dry=%.1f dBFS wet=%.1f dBFS delta=%.1f dB "
                     "vad=%.2f mix=%.2f inferUs=%u",
                     (unsigned long long)hops, dryDb, wetDb, wetDb - dryDb,
                     lastVadProb_.load(std::memory_order_relaxed),
                     effectiveIntensity_,
                     lastInferenceUs_.load(std::memory_order_relaxed));
        }
    }
}

}  // namespace rnnoise_denoiser

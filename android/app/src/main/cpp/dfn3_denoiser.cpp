/// @file dfn3_denoiser.cpp
/// @brief C++ wrapper for DeepFilterNet3 Rust/tract backend.

#include "dfn3_denoiser.h"

#include <algorithm>
#include <android/log.h>
#include <cmath>
#include <cstring>

#define DFN3_TAG "Dfn3Denoiser"
#define DFN3_LOGI(...) __android_log_print(ANDROID_LOG_INFO, DFN3_TAG, __VA_ARGS__)
#define DFN3_LOGW(...) __android_log_print(ANDROID_LOG_WARN, DFN3_TAG, __VA_ARGS__)

namespace dfn3_denoiser {

Dfn3Denoiser::~Dfn3Denoiser() {
    dfn3_free();
}


bool Dfn3Denoiser::initialize(const std::string& modelDir) {
    const bool ok = dfn3_init(modelDir.c_str());
    initialized_ = ok;
    if (ok) {
        DFN3_LOGI("initialize: DeepFilterNet3 engine ready");
    } else {
        DFN3_LOGW("initialize: failed to load models from %s", modelDir.c_str());
    }
    return ok;
}

bool Dfn3Denoiser::isActive() const {
    return initialized_ && dfn3_is_active();
}

float Dfn3Denoiser::getIntensity() const {
    return dfn3_get_intensity();
}

void Dfn3Denoiser::setEnabled(bool enabled) {
    enabled_.store(enabled, std::memory_order_release);
}

void Dfn3Denoiser::setIntensity(float intensity) {
    dfn3_set_intensity(std::max(0.0f, std::min(1.0f, intensity)));
}


void Dfn3Denoiser::process(float* buffer, int blockSize) {
    if (buffer == nullptr || blockSize <= 0) return;

    const bool en = enabled_.load(std::memory_order_acquire);
    const bool act = isActive();

    // Fast path: bypass.
    if (!en && crossfadeGain_ <= 0.0f) return;
    if (!act) {
        crossfadeTarget_ = 0.0f;
        if (crossfadeGain_ > 0.0f) {
            for (int i = 0; i < blockSize; ++i) {
                crossfadeGain_ = std::max(0.0f, crossfadeGain_ - kCrossfadeStep);
            }
        }
        return;
    }

    crossfadeTarget_ = en ? 1.0f : 0.0f;

    // Process hop-by-hop.
    int pos = 0;

    // If there's residual from previous call, fill it first.
    if (residualCount_ > 0) {
        const int need = kHopSize - residualCount_;
        const int take = std::min(need, blockSize);
        std::memcpy(residual_ + residualCount_, buffer, take * sizeof(float));
        residualCount_ += take;
        pos += take;

        if (residualCount_ == kHopSize) {
            // Process the full hop.
            float dry[kHopSize];
            std::memcpy(dry, residual_, kHopSize * sizeof(float));
            dfn3_process_hop(residual_);
            // Mix and write back to the correct position in buffer.
            const int writeStart = pos - kHopSize;
            for (int i = 0; i < kHopSize; ++i) {
                if (crossfadeGain_ < crossfadeTarget_) {
                    crossfadeGain_ = std::min(crossfadeTarget_,
                                              crossfadeGain_ + kCrossfadeStep);
                } else if (crossfadeGain_ > crossfadeTarget_) {
                    crossfadeGain_ = std::max(crossfadeTarget_,
                                              crossfadeGain_ - kCrossfadeStep);
                }
                const int idx = writeStart + i;
                if (idx >= 0 && idx < blockSize) {
                    buffer[idx] = std::max(-1.0f, std::min(1.0f,
                        dry[i] * (1.0f - crossfadeGain_) +
                        residual_[i] * crossfadeGain_));
                }
            }
            residualCount_ = 0;
        }
    }


    // Process full hops from the remaining buffer.
    while (pos + kHopSize <= blockSize) {
        float dry[kHopSize];
        std::memcpy(dry, buffer + pos, kHopSize * sizeof(float));

        // Run DFN3 on this hop in-place.
        float wet[kHopSize];
        std::memcpy(wet, buffer + pos, kHopSize * sizeof(float));
        dfn3_process_hop(wet);

        // Mix dry/wet with crossfade.
        for (int i = 0; i < kHopSize; ++i) {
            if (crossfadeGain_ < crossfadeTarget_) {
                crossfadeGain_ = std::min(crossfadeTarget_,
                                          crossfadeGain_ + kCrossfadeStep);
            } else if (crossfadeGain_ > crossfadeTarget_) {
                crossfadeGain_ = std::max(crossfadeTarget_,
                                          crossfadeGain_ - kCrossfadeStep);
            }
            buffer[pos + i] = std::max(-1.0f, std::min(1.0f,
                dry[i] * (1.0f - crossfadeGain_) + wet[i] * crossfadeGain_));
        }
        pos += kHopSize;
    }

    // Save leftover samples as residual for next call.
    const int leftover = blockSize - pos;
    if (leftover > 0) {
        std::memcpy(residual_, buffer + pos, leftover * sizeof(float));
        residualCount_ = leftover;
    }

    effectiveIntensity_ = dfn3_get_intensity() * crossfadeGain_;
}

}  // namespace dfn3_denoiser

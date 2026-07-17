/// @file dfn3_denoiser.cpp
/// @brief C++ wrapper for DeepFilterNet3 — loads libdfn3.so via dlopen.
///
/// Si libdfn3.so no está presente en el dispositivo, initialize() retorna
/// false y el audio engine usa GTCRN como fallback. Sin #ifdef, sin stubs.

#include "dfn3_denoiser.h"

#include <algorithm>
#include <android/log.h>
#include <cmath>
#include <cstring>
#include <dlfcn.h>

#define DFN3_TAG "Dfn3Denoiser"
#define DFN3_LOGI(...) __android_log_print(ANDROID_LOG_INFO, DFN3_TAG, __VA_ARGS__)
#define DFN3_LOGW(...) __android_log_print(ANDROID_LOG_WARN, DFN3_TAG, __VA_ARGS__)

namespace dfn3_denoiser {

// ─── Function pointers loaded via dlopen ─────────────────────────────────────

using FnInit = bool (*)(const char*);
using FnProcessHop = bool (*)(float*);
using FnSetIntensity = void (*)(float);
using FnGetIntensity = float (*)();
using FnIsActive = bool (*)();
using FnFree = void (*)();

static void* sLibHandle = nullptr;
static FnInit sFnInit = nullptr;
static FnProcessHop sFnProcessHop = nullptr;
static FnSetIntensity sFnSetIntensity = nullptr;
static FnGetIntensity sFnGetIntensity = nullptr;
static FnIsActive sFnIsActive = nullptr;
static FnFree sFnFree = nullptr;

static bool loadLibrary() {
    if (sLibHandle) return true;
    sLibHandle = dlopen("libdfn3.so", RTLD_NOW);
    if (!sLibHandle) {
        DFN3_LOGW("dlopen failed: %s", dlerror());
        return false;
    }
    sFnInit = (FnInit)dlsym(sLibHandle, "dfn3_init");
    sFnProcessHop = (FnProcessHop)dlsym(sLibHandle, "dfn3_process_hop");
    sFnSetIntensity = (FnSetIntensity)dlsym(sLibHandle, "dfn3_set_intensity");
    sFnGetIntensity = (FnGetIntensity)dlsym(sLibHandle, "dfn3_get_intensity");
    sFnIsActive = (FnIsActive)dlsym(sLibHandle, "dfn3_is_active");
    sFnFree = (FnFree)dlsym(sLibHandle, "dfn3_free");
    if (!sFnInit || !sFnProcessHop || !sFnSetIntensity ||
        !sFnGetIntensity || !sFnIsActive || !sFnFree) {
        DFN3_LOGW("missing symbols in libdfn3.so");
        dlclose(sLibHandle);
        sLibHandle = nullptr;
        return false;
    }
    DFN3_LOGI("libdfn3.so loaded OK");
    return true;
}

// ─── Implementation ──────────────────────────────────────────────────────────

Dfn3Denoiser::~Dfn3Denoiser() {
    if (initialized_ && sFnFree) sFnFree();
}

bool Dfn3Denoiser::initialize(const std::string& modelDir) {
    if (!loadLibrary()) return false;
    initialized_ = sFnInit(modelDir.c_str());
    return initialized_;
}

bool Dfn3Denoiser::isActive() const {
    return initialized_ && sFnIsActive && sFnIsActive();
}

float Dfn3Denoiser::getIntensity() const {
    return (sFnGetIntensity) ? sFnGetIntensity() : 0.6f;
}

void Dfn3Denoiser::setEnabled(bool enabled) {
    enabled_.store(enabled, std::memory_order_release);
}

void Dfn3Denoiser::setIntensity(float intensity) {
    if (sFnSetIntensity) sFnSetIntensity(std::clamp(intensity, 0.0f, 1.0f));
}

void Dfn3Denoiser::process(float* buffer, int blockSize) {
    if (!buffer || blockSize <= 0 || !initialized_ || !sFnProcessHop) return;

    const bool en = enabled_.load(std::memory_order_acquire);
    if (!en && crossfadeGain_ <= 0.0f) return;

    crossfadeTarget_ = en ? 1.0f : 0.0f;
    int pos = 0;

    // Residual from previous call.
    if (residualCount_ > 0) {
        const int take = std::min(kHopSize - residualCount_, blockSize);
        std::memcpy(residual_ + residualCount_, buffer, take * sizeof(float));
        residualCount_ += take;
        pos += take;
        if (residualCount_ == kHopSize) {
            float dry[kHopSize];
            std::memcpy(dry, residual_, sizeof(dry));
            sFnProcessHop(residual_);
            for (int i = 0; i < kHopSize; ++i) {
                if (crossfadeGain_ < crossfadeTarget_)
                    crossfadeGain_ = std::min(crossfadeTarget_, crossfadeGain_ + kCrossfadeStep);
                else if (crossfadeGain_ > crossfadeTarget_)
                    crossfadeGain_ = std::max(crossfadeTarget_, crossfadeGain_ - kCrossfadeStep);
                const int idx = pos - kHopSize + i;
                if (idx >= 0 && idx < blockSize)
                    buffer[idx] = std::clamp(
                        dry[i] * (1.f - crossfadeGain_) + residual_[i] * crossfadeGain_, -1.f, 1.f);
            }
            residualCount_ = 0;
        }
    }

    // Full hops.
    while (pos + kHopSize <= blockSize) {
        float dry[kHopSize], wet[kHopSize];
        std::memcpy(dry, buffer + pos, sizeof(dry));
        std::memcpy(wet, buffer + pos, sizeof(wet));
        sFnProcessHop(wet);
        for (int i = 0; i < kHopSize; ++i) {
            if (crossfadeGain_ < crossfadeTarget_)
                crossfadeGain_ = std::min(crossfadeTarget_, crossfadeGain_ + kCrossfadeStep);
            else if (crossfadeGain_ > crossfadeTarget_)
                crossfadeGain_ = std::max(crossfadeTarget_, crossfadeGain_ - kCrossfadeStep);
            buffer[pos + i] = std::clamp(
                dry[i] * (1.f - crossfadeGain_) + wet[i] * crossfadeGain_, -1.f, 1.f);
        }
        pos += kHopSize;
    }

    // Leftover.
    if (pos < blockSize) {
        std::memcpy(residual_, buffer + pos, (blockSize - pos) * sizeof(float));
        residualCount_ = blockSize - pos;
    }

    effectiveIntensity_ = crossfadeGain_;
}

}  // namespace dfn3_denoiser

/// @file rnnoise_denoiser.h
/// @brief RNNoise (Xiph) C++ wrapper for the Audifon audio engine.
///
/// Static linking of xiph/rnnoise v0.1.1 — the classic tiny model used in
/// production by OBS Studio, Mumble, ffmpeg (arnndn filter), and many
/// hearing aid research prototypes.
///
/// Pipeline position (same slot as Dfn3Denoiser / DnnDenoiser):
///
///   Input → [RnnoiseDenoiser] → EQ → WDRC → Volume → MPO → Output
///
/// Key characteristics:
///   - 48 kHz native (no resampler)
///   - Frame size 480 samples (10 ms)
///   - Model baked into the .so (~90 KB compiled)
///   - BSD 3-Clause license
///
/// LATENCY: exactly one hop (~10 ms) after the first buffered hop lands.
/// Every input sample eventually leaves as wet — no intermittent
/// pass-through samples (that was the bug that made toggling appear to
/// have no effect: with Oboe bursts of 256 samples and hops of 480,
/// the previous "DFN3-style" algorithm left ~50 % of samples untouched).

#ifndef HEARING_AID_RNNOISE_DENOISER_H
#define HEARING_AID_RNNOISE_DENOISER_H

#include <atomic>
#include <cstdint>

// Forward decl of RNNoise's opaque state.
struct DenoiseState;

namespace rnnoise_denoiser {

/// Hop size at 48 kHz (10 ms). Matches RNNoise's compile-time FRAME_SIZE.
static constexpr int kFrameSize = 480;

/// Sample rate expected by RNNoise. Fixed at build time.
static constexpr int kSampleRate = 48000;

/// Crossfade samples for enable/disable toggle (50 ms @ 48 kHz).
static constexpr int kCrossfadeSamples = 2400;
static constexpr float kCrossfadeStep =
    1.0f / static_cast<float>(kCrossfadeSamples);

/// RNNoise's canonical API operates on floats in int16 range [-32768, +32767].
/// Our audio bus is [-1, +1] float, so we scale here.
static constexpr float kInt16Scale = 32768.0f;
static constexpr float kInt16InvScale = 1.0f / 32768.0f;

/// C++ wrapper around xiph/rnnoise DenoiseState.
class RnnoiseDenoiser {
public:
    RnnoiseDenoiser() = default;
    ~RnnoiseDenoiser();

    RnnoiseDenoiser(const RnnoiseDenoiser&) = delete;
    RnnoiseDenoiser& operator=(const RnnoiseDenoiser&) = delete;

    bool initialize();
    void process(float* buffer, int blockSize);
    void setEnabled(bool enabled);
    void setIntensity(float intensity);

    // ─── Getters (thread-safe) ─────────────────────────────────────────
    bool isEnabled() const { return enabled_.load(std::memory_order_acquire); }
    bool isActive() const { return initialized_ && state_ != nullptr; }
    float getIntensity() const {
        return intensity_.load(std::memory_order_acquire);
    }
    float getEffectiveIntensity() const { return effectiveIntensity_; }
    float getLastVadProb() const {
        return lastVadProb_.load(std::memory_order_acquire);
    }
    uint64_t getProcessedFrames() const {
        return processedFrames_.load(std::memory_order_acquire);
    }
    uint64_t getDroppedFrames() const { return 0; }  // synchronous engine
    uint32_t getLastInferenceUs() const {
        return lastInferenceUs_.load(std::memory_order_acquire);
    }

private:
    /// Opaque state from rnnoise/include/rnnoise.h.
    DenoiseState* state_ = nullptr;
    bool initialized_ = false;

    std::atomic<bool> enabled_{false};
    std::atomic<float> intensity_{0.6f};
    std::atomic<float> lastVadProb_{0.0f};
    std::atomic<uint64_t> processedFrames_{0};
    std::atomic<uint32_t> lastInferenceUs_{0};

    /// Crossfade state (audio thread only).
    float crossfadeGain_ = 0.0f;
    float crossfadeTarget_ = 0.0f;
    float effectiveIntensity_ = 0.0f;

    // ─── Ring-buffer state (audio thread only) ─────────────────────────
    //
    // inBuffer_ accumulates dry input samples until we have a full hop.
    // outBuffer_ holds wet samples ready to be drained sample-by-sample
    // into the audio callback's buffer.
    //
    // Invariants:
    //   0 <= inCount_ < kFrameSize                     (partial hop being filled)
    //   0 <= outStart_ <= outAvail_ + outStart_ <= kFrameSize
    //   When inCount_ hits kFrameSize we run RNNoise and refill outBuffer_.
    //
    // Latency: at cold start we drain nothing until we've accumulated
    // kFrameSize samples of input (i.e. up to 10 ms of dry passthrough).
    // After that, every audio callback sample is denoised. The 10 ms delay
    // between "sample enters" and "sample leaves as wet" is intrinsic to
    // hop-based DNN denoising.
    float inBuffer_[kFrameSize];
    float outBuffer_[kFrameSize];
    int inCount_ = 0;
    int outStart_ = 0;
    int outAvail_ = 0;
};

}  // namespace rnnoise_denoiser

#endif  // HEARING_AID_RNNOISE_DENOISER_H

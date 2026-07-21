/// @file rnnoise_denoiser.h
/// @brief RNNoise (Xiph) C++ wrapper for the Audifon audio engine.
///
/// Static linking of xiph/rnnoise v0.1.1 — the classic tiny model (~416 KB
/// source, ~90 KB after -O3) used in production by OBS Studio, Mumble,
/// ffmpeg (arnndn filter), and many hearing aid research prototypes.
///
/// Pipeline position (same slot as Dfn3Denoiser / DnnDenoiser):
///
///   Input → [RnnoiseDenoiser] → EQ → WDRC → Volume → MPO → Output
///
/// Key characteristics:
///   - 48 kHz native (no resampler)
///   - Frame size 480 samples (10 ms) — same as DFN3, matches Oboe bursts
///   - ~10 ms algorithmic latency, ~0.1 ms compute on arm64 (single core)
///   - Model baked into the .so (no filesystem I/O, no asset extraction)
///   - BSD 3-Clause license — compatible with the app
///
/// Compared to the alternatives in this project:
///   - GTCRN (ONNX)   : better SNR floor but ~2 MB model, needs OnnxRuntime
///   - DFN3 (Rust)    : best quality (~PESQ 3.3) but 8 MB models + dlopen
///                      of libdfn3.so; SIGABRT crash observed in runtime
///   - RNNoise        : most stable in production, tiniest footprint,
///                      slightly lower SNR floor than GTCRN/DFN3 but zero
///                      artifacts and zero crash surface — the safe pick
///                      for shipping to end users.
///
/// THREAD SAFETY:
///   - process(): safe from audio thread. No allocation. No lock. State is
///     private to the instance; RNNoise's internal `DenoiseState` is single-
///     threaded so we access it only from the audio thread.
///   - setEnabled/setIntensity: thread-safe (atomic).
///   - initialize()/destroy(): NOT thread-safe; call ONCE at startup.

#ifndef HEARING_AID_RNNOISE_DENOISER_H
#define HEARING_AID_RNNOISE_DENOISER_H

#include <atomic>
#include <cstdint>

// Forward decl of RNNoise's opaque state (defined in rnnoise/include/rnnoise.h).
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
///
/// Provides the same interface shape as Dfn3Denoiser so audio_engine can
/// dispatch to any denoiser via a single flag.
class RnnoiseDenoiser {
public:
    RnnoiseDenoiser() = default;
    ~RnnoiseDenoiser();

    RnnoiseDenoiser(const RnnoiseDenoiser&) = delete;
    RnnoiseDenoiser& operator=(const RnnoiseDenoiser&) = delete;

    /// Initialize: allocate the DenoiseState with the default (baked-in) model.
    /// @return true if allocation succeeded and engine is ready.
    bool initialize();

    /// Process audio in-place. Call from audio thread only.
    /// Handles crossfade on enable/disable, intensity mixing, clamping,
    /// and non-hop-aligned block sizes via an internal residual buffer.
    /// If not enabled and crossfade has fully faded out, the buffer is
    /// left untouched (bypass).
    ///
    /// @param buffer     Float audio [-1,+1] at 48 kHz. Modified in-place.
    /// @param blockSize  Number of samples. Any positive value accepted;
    ///                   full 480-sample hops are processed and any tail
    ///                   is stashed for the next call.
    void process(float* buffer, int blockSize);

    /// Enable/disable the denoiser (with 50 ms crossfade).
    void setEnabled(bool enabled);

    /// Set user intensity [0.0, 1.0].
    /// 1.0 = fully denoised output, 0.0 = passthrough. Applied as a
    /// linear dry/wet mix on top of the crossfade.
    void setIntensity(float intensity);

    // ─── Getters (thread-safe) ─────────────────────────────────────────
    bool isEnabled() const { return enabled_.load(std::memory_order_acquire); }
    /// isActive == initialized and ready to process. Independent of the
    /// enabled flag (an initialized denoiser that is currently in bypass
    /// still reports isActive() == true).
    bool isActive() const { return initialized_ && state_ != nullptr; }
    float getIntensity() const {
        return intensity_.load(std::memory_order_acquire);
    }
    float getEffectiveIntensity() const { return effectiveIntensity_; }

    /// Last VAD probability returned by RNNoise for the most recent frame
    /// (in [0,1]). Useful for UI-side speech detection or as a gate signal.
    float getLastVadProb() const {
        return lastVadProb_.load(std::memory_order_acquire);
    }

private:
    /// Opaque state from rnnoise/include/rnnoise.h.
    DenoiseState* state_ = nullptr;
    bool initialized_ = false;

    std::atomic<bool> enabled_{false};
    std::atomic<float> intensity_{0.6f};
    std::atomic<float> lastVadProb_{0.0f};

    /// Crossfade state (audio thread only).
    float crossfadeGain_ = 0.0f;
    float crossfadeTarget_ = 0.0f;

    /// Effective intensity after crossfade (for diagnostics).
    float effectiveIntensity_ = 0.0f;

    /// Residual buffer for non-hop-aligned block sizes.
    float residualIn_[kFrameSize];
    float residualOut_[kFrameSize];
    int residualCount_ = 0;
    /// Number of residualOut_ samples still to drain into the next call's
    /// output before we process the next hop. Kept in [0, kFrameSize].
    int residualOutRemaining_ = 0;
};

}  // namespace rnnoise_denoiser

#endif  // HEARING_AID_RNNOISE_DENOISER_H

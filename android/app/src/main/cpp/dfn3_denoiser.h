/// @file dfn3_denoiser.h
/// @brief DeepFilterNet3 C++ wrapper for the Audifon audio engine.
///
/// Replaces the GTCRN-based DnnDenoiser with DeepFilterNet3 (48 kHz native,
/// no resampler needed). Uses the Rust/tract backend via C FFI (dfn3_api.h).
///
/// Pipeline position (same as the old DnnDenoiser):
///
///   Input → [Dfn3Denoiser] → EQ → WDRC → Volume → MPO → Output
///
/// Key differences vs GTCRN:
///   - 48 kHz native (no polyphase resampler, no dryDelayRing pre-fill issues)
///   - 3-stage architecture (ERB gains + deep filtering) instead of single STFT mask
///   - Higher PESQ (~3.3 vs ~2.8), less musical noise, no "matraca" artifacts
///   - Larger model (~8.5 MB vs ~2 MB) but similar RTF on arm64
///
/// THREAD SAFETY:
///   - process(): safe from audio thread (try_lock inside Rust, never blocks)
///   - setEnabled/setIntensity/getters: thread-safe (atomic + mutex in Rust)
///   - initialize(): NOT thread-safe; call ONCE at startup from main thread

#ifndef HEARING_AID_DFN3_DENOISER_H
#define HEARING_AID_DFN3_DENOISER_H

#include <atomic>
#include <cstdint>
#include <string>

// Constants from DFN3 (duplicated here to avoid header dependency on dfn3_api.h
// since we load libdfn3.so dynamically via dlopen).
#ifndef DFN3_HOP_SIZE
#define DFN3_HOP_SIZE 480
#endif
#ifndef DFN3_SAMPLE_RATE
#define DFN3_SAMPLE_RATE 48000
#endif

namespace dfn3_denoiser {

/// Hop size at 48 kHz (10 ms).
static constexpr int kHopSize = DFN3_HOP_SIZE;  // 480

/// Sample rate.
static constexpr int kSampleRate = DFN3_SAMPLE_RATE;  // 48000

/// Crossfade samples for enable/disable toggle (50 ms @ 48 kHz).
static constexpr int kCrossfadeSamples = 2400;
static constexpr float kCrossfadeStep = 1.0f / static_cast<float>(kCrossfadeSamples);

/// C++ wrapper around the Rust DeepFilterNet3 engine.
///
/// Provides the same interface as the old DnnDenoiser so audio_engine can
/// swap it in with minimal changes.
class Dfn3Denoiser {
public:
    Dfn3Denoiser() = default;
    ~Dfn3Denoiser();

    Dfn3Denoiser(const Dfn3Denoiser&) = delete;
    Dfn3Denoiser& operator=(const Dfn3Denoiser&) = delete;

    /// Initialize: loads the 3 ONNX models from the given directory.
    /// @param modelDir  Path to directory with enc.onnx, erb_dec.onnx, df_dec.onnx.
    /// @return true if models loaded and engine is ready.
    bool initialize(const std::string& modelDir);

    /// Process audio in-place. Call from audio thread.
    /// Handles crossfade on enable/disable, intensity mixing, and clamping.
    /// If not enabled or not active, the buffer is untouched (bypass).
    ///
    /// @param buffer  Float audio [-1,+1] at 48 kHz. Modified in-place.
    /// @param blockSize  Number of samples (must be multiple of kHopSize for
    ///                   optimal operation; handles arbitrary sizes gracefully).
    void process(float* buffer, int blockSize);

    /// Enable/disable the denoiser (with crossfade).
    void setEnabled(bool enabled);

    /// Set user intensity [0.0, 1.0].
    void setIntensity(float intensity);

    /// Getters.
    bool isEnabled() const { return enabled_.load(std::memory_order_acquire); }
    bool isActive() const;
    float getIntensity() const;
    float getEffectiveIntensity() const { return effectiveIntensity_; }

private:
    std::atomic<bool> enabled_{false};
    bool initialized_ = false;

    /// Crossfade state (audio thread only).
    float crossfadeGain_ = 0.0f;
    float crossfadeTarget_ = 0.0f;

    /// Effective intensity after crossfade.
    float effectiveIntensity_ = 0.6f;

    /// Residual buffer for handling non-hop-aligned block sizes.
    float residual_[DFN3_HOP_SIZE];
    int residualCount_ = 0;
};

}  // namespace dfn3_denoiser

#endif  // HEARING_AID_DFN3_DENOISER_H
// trigger

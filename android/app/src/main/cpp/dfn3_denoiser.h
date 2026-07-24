/// @file dfn3_denoiser.h
/// @brief DeepFilterNet3 denoiser — OnnxRuntime backend (replaces Rust/tract).
///
/// Implementación directa con OnnxRuntime que elimina la dependencia de
/// libdfn3.so (Rust/tract). Corre los mismos 3 modelos ONNX (enc, erb_dec,
/// df_dec) que antes procesaba tract, pero sin el bug off-by-one (index 481
/// en buffer de len 481) que causaba crash en runtime.
///
/// Pipeline position:
///   Input → [Dfn3Denoiser] → EQ → WDRC → Volume → MPO → Output
///
/// Procesamiento interno por hop (480 samples @ 48 kHz = 10 ms):
///   1. STFT analysis (FFT 960, Hann window, hop 480) → 481 complex bins
///   2. ERB feature extraction (481 bins → 32 ERB bands, log-compressed)
///   3. Spectral feature extraction (96 bins × 2 channels re/im)
///   4. Encoder inference (OnnxRuntime)
///   5. ERB decoder inference → 32 ERB gains
///   6. Interpolate ERB gains to 481 bins & apply mask to spectrum
///   7. iSTFT synthesis (OLA) → 480 output samples
///
/// Thread safety:
///   - process(): audio thread only (never blocks)
///   - setEnabled/setIntensity/getters: thread-safe (atomics)
///   - initialize(): NOT thread-safe — call ONCE from main thread

#ifndef HEARING_AID_DFN3_DENOISER_H
#define HEARING_AID_DFN3_DENOISER_H

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>

struct AAssetManager;

namespace dfn3_denoiser {

// ─── DFN3 constants ──────────────────────────────────────────────────────────
static constexpr int kSampleRate = 48000;
static constexpr int kHopSize    = 480;        ///< 10 ms @ 48 kHz
static constexpr int kFftSize    = 960;        ///< FFT window size
static constexpr int kNbFreqs    = kFftSize / 2 + 1;  ///< 481 complex bins
static constexpr int kNbErb      = 32;         ///< ERB bands
static constexpr int kNbDf       = 96;         ///< DF bins (low freq)

/// Crossfade samples for enable/disable toggle (50 ms @ 48 kHz).
static constexpr int kCrossfadeSamples = 2400;
static constexpr float kCrossfadeStep = 1.0f / static_cast<float>(kCrossfadeSamples);

/// DeepFilterNet3 denoiser using OnnxRuntime directly.
///
/// Eliminates the dependency on libdfn3.so (Rust/tract) that had a runtime
/// crash (index out of bounds: len 481, index 481). Uses the same ONNX models
/// (enc.onnx, erb_dec.onnx) loaded via AAssetManager into OnnxRuntime sessions.
class Dfn3Denoiser {
public:
    Dfn3Denoiser();
    ~Dfn3Denoiser();

    Dfn3Denoiser(const Dfn3Denoiser&) = delete;
    Dfn3Denoiser& operator=(const Dfn3Denoiser&) = delete;

    /// Initialize: loads enc.onnx and erb_dec.onnx from assets via AAssetManager.
    /// @param mgr Android AAssetManager (non-null).
    /// @param assetDir Asset subdirectory containing the models (e.g. "dfn3").
    /// @return true if models loaded and engine is ready.
    bool initialize(AAssetManager* mgr, const char* assetDir = "dfn3");

    /// Process audio in-place. Call from audio thread.
    /// Handles residual buffering for non-hop-aligned block sizes,
    /// crossfade on enable/disable, intensity mixing, and clamping.
    ///
    /// @param buffer  Float audio [-1,+1] at 48 kHz. Modified in-place.
    /// @param blockSize  Number of samples (any size handled gracefully).
    void process(float* buffer, int blockSize);

    /// Enable/disable the denoiser (with crossfade).
    void setEnabled(bool enabled);

    /// Set user intensity [0.0, 1.0] (dry/wet mix).
    void setIntensity(float intensity);

    /// Reset internal state (STFT buffers, model caches).
    void reset();

    /// Getters.
    bool isEnabled() const { return enabled_.load(std::memory_order_acquire); }
    bool isActive() const { return initialized_; }
    float getIntensity() const { return intensity_.load(std::memory_order_acquire); }
    float getEffectiveIntensity() const { return effectiveIntensity_; }
    uint64_t getProcessedFrames() const { return processedFrames_; }

private:
    /// PIMPL to hide OnnxRuntime and DSP internals from consumers.
    struct Impl;
    std::unique_ptr<Impl> impl_;

    std::atomic<bool>  enabled_{false};
    std::atomic<float> intensity_{0.8f};
    bool initialized_ = false;

    /// Crossfade state (audio thread only).
    float crossfadeGain_ = 0.0f;
    float crossfadeTarget_ = 0.0f;

    /// Effective intensity after crossfade (for getters).
    float effectiveIntensity_ = 0.0f;

    /// Processed hops counter.
    uint64_t processedFrames_ = 0;

    /// Residual buffer for non-hop-aligned blocks.
    float residual_[kHopSize] = {};
    int residualCount_ = 0;

    /// Process a single hop (kHopSize samples) through the DFN3 pipeline.
    /// @param hop Input/output buffer of kHopSize floats.
    /// @return true if inference succeeded, false = bypass (hop unchanged).
    bool processHop(float* hop);
};

}  // namespace dfn3_denoiser

#endif  // HEARING_AID_DFN3_DENOISER_H

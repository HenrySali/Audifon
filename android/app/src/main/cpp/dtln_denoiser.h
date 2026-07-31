/// @file dtln_denoiser.h
/// @brief DTLN (Dual-signal Transformation LSTM Network) denoiser.
///
/// Pipeline dual con dos modelos ONNX secuenciales:
///   Core 1: STFT magnitude → mask → masked complex STFT
///   Core 2: señal temporal (block 512) → LSTM → señal limpia
///
/// Parámetros: block=512, shift=128, FFT=512, bins=257, @16 kHz.
/// Resample 48→16 entrada, 16→48 salida (sinc Kaldi-style).
///
/// Referencia: Westhausen & Meyer (2020) "Dual-Signal Transformation LSTM
/// Network" — modelos MIT license desde github.com/breizhn/DTLN.

#ifndef HEARING_AID_DTLN_DENOISER_H
#define HEARING_AID_DTLN_DENOISER_H

#include "i_denoiser_engine.h"

#include <atomic>
#include <cstdint>
#include <memory>

struct AAssetManager;

namespace dtln_denoiser {

// ─── Constants ───────────────────────────────────────────────────────────────
static constexpr int kModelSr      = 16000;   ///< Model sample rate
static constexpr int kBlockSize    = 512;     ///< DTLN block size @16 kHz
static constexpr int kShift        = 128;     ///< Hop / shift (8 ms @16 kHz)
static constexpr int kFftSize      = 512;     ///< FFT size
static constexpr int kNBins        = 257;     ///< kFftSize/2 + 1
static constexpr int kXfadeSamples = 800;     ///< Crossfade ≈16.7 ms @ 48 kHz

/// DTLN denoiser — dual ONNX model pipeline with PIMPL.
class DtlnDenoiser {
public:
    DtlnDenoiser();
    ~DtlnDenoiser();

    // Non-copyable
    DtlnDenoiser(const DtlnDenoiser&) = delete;
    DtlnDenoiser& operator=(const DtlnDenoiser&) = delete;

    /// Initialize: loads model_1.onnx and model_2.onnx from assets.
    /// @param mgr Android AAssetManager (non-null).
    /// @param assetDir Asset directory (default "dtln").
    /// @return true if both models loaded and engine is ready.
    bool initialize(AAssetManager* mgr, const char* assetDir = "dtln");

    /// Process audio in-place. Call ONLY from audio thread.
    void process(float* buffer, int blockSize);

    /// Enable/disable with smooth crossfade.
    void setEnabled(bool enabled);

    /// Set intensity [0.0, 1.0] — dry/wet mix. Thread-safe.
    void setIntensity(float intensity);

    /// Reset internal state (DSP buffers + LSTM hidden states).
    void reset();

    // ─── Getters (thread-safe) ───────────────────────────────────────────
    bool isEnabled() const { return enabled_.load(std::memory_order_acquire); }
    bool isActive() const { return active_.load(std::memory_order_acquire); }
    const char* name() const { return "DTLN"; }
    float getEffectiveIntensity() const;
    uint64_t getProcessedFrames() const;
    uint64_t getDroppedFrames() const;
    uint32_t getLastInferenceUs() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;

    std::atomic<bool>     enabled_{false};
    std::atomic<float>    intensity_{0.8f};
    std::atomic<bool>     active_{false};
    std::atomic<uint64_t> processedFrames_{0};
    std::atomic<uint64_t> droppedFrames_{0};
    std::atomic<uint32_t> lastInferenceUs_{0};

    float crossfadeGain_   = 0.0f;
    float crossfadeTarget_ = 0.0f;
    float effectiveIntensity_ = 0.0f;
};

} // namespace dtln_denoiser

// ═══════════════════════════════════════════════════════════════════════════════
// ADAPTER — thin wrapper implementing IDenoiserEngine
// ═══════════════════════════════════════════════════════════════════════════════

class DtlnAdapter : public IDenoiserEngine {
public:
    explicit DtlnAdapter(dtln_denoiser::DtlnDenoiser* impl,
                         const char* displayName = "DTLN")
        : impl_(impl), displayName_(displayName) {}

    bool initialize(AAssetManager* mgr) override {
        return impl_->initialize(mgr);
    }
    void process(float* buf, int n) override {
        impl_->process(buf, n);
    }
    void setEnabled(bool e) override {
        impl_->setEnabled(e);
    }
    void setIntensity(float v) override {
        impl_->setIntensity(v);
    }
    bool isActive() const override {
        return impl_->isActive();
    }
    bool isEnabled() const override {
        return impl_->isEnabled();
    }
    void reset() override {
        impl_->reset();
    }
    const char* name() const override {
        return displayName_;
    }
    uint64_t getProcessedFrames() const override {
        return impl_->getProcessedFrames();
    }
    uint64_t getDroppedFrames() const override {
        return impl_->getDroppedFrames();
    }
    uint32_t getLastInferenceUs() const override {
        return impl_->getLastInferenceUs();
    }
    float getEffectiveIntensity() const override {
        return impl_->getEffectiveIntensity();
    }

private:
    dtln_denoiser::DtlnDenoiser* impl_;
    const char* displayName_;
};

#endif // HEARING_AID_DTLN_DENOISER_H

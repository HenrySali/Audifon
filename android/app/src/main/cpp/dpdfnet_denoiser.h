/// @file dpdfnet_denoiser.h
/// @brief DPDFNet-4 denoiser — OnnxRuntime backend, polyphase resample, Vorbis window.
///
/// Cuarto motor de denoising (kDPDFNet = 3) para el DenoiserSelector.
/// Modelo DPDFNet-4 (2.36 MB, Apache 2.0, sherpa-onnx) opera a 16 kHz con
/// hop=160 (10 ms), ventana Vorbis, spec shape [1,1,161,2].
///
/// Pipeline:
///   48kHz in → polyphase↓3 → accum → STFT(Vorbis,320,hop160,FFT512)
///            → ONNX Run → iSTFT/OLA → polyphase↑3 → intensity mix
///            → crossfade → clamp → 48kHz out
///
/// Thread safety:
///   - process(): audio thread only (never blocks, zero heap alloc)
///   - setEnabled/setIntensity/getters: thread-safe (atomics)
///   - initialize(): NOT thread-safe — call ONCE from main thread

#ifndef HEARING_AID_DPDFNET_DENOISER_H
#define HEARING_AID_DPDFNET_DENOISER_H

#include "i_denoiser_engine.h"

#include <atomic>
#include <cstdint>
#include <memory>

struct AAssetManager;

namespace dpdfnet_denoiser {

// ─── Constants ───────────────────────────────────────────────────────────────
static constexpr int kModelSr      = 16000;   ///< Model sample rate
static constexpr int kHopSize      = 160;     ///< 10 ms @ 16 kHz
static constexpr int kWinSize      = 320;     ///< 2 * hop (50% overlap)
static constexpr int kFftSize      = 512;     ///< Next power of 2 for FFT
static constexpr int kNBins        = 161;     ///< kFftSize/2 + 1 (but only WinSize/2+1 used)
static constexpr int kProtoTaps    = 72;      ///< Polyphase FIR prototype length
static constexpr int kXfadeSamples = 800;     ///< Crossfade ≈16.7 ms @ 48 kHz
static constexpr int kAccumMax     = 1600;    ///< Overflow guard (10 hops)
static constexpr int kWetBufCap    = 4096;    ///< Wet ring capacity @ 16 kHz

/// DPDFNet-4 denoiser — full pipeline with PIMPL.
///
/// Resample 48→16, STFT Vorbis, ONNX inference, iSTFT OLA, resample 16→48,
/// crossfade + intensity mix. Zero heap allocations in process().
class DpdfnetDenoiser {
public:
    DpdfnetDenoiser();
    ~DpdfnetDenoiser();

    // Non-copyable
    DpdfnetDenoiser(const DpdfnetDenoiser&) = delete;
    DpdfnetDenoiser& operator=(const DpdfnetDenoiser&) = delete;

    /// Initialize: loads dpdfnet4.onnx from assets via AAssetManager.
    /// Idempotent: second call returns true without recreating session.
    /// @param mgr Android AAssetManager (non-null).
    /// @param assetPath Asset path (default "dpdfnet/dpdfnet4.onnx").
    /// @return true if model loaded and engine is ready.
    bool initialize(AAssetManager* mgr,
                    const char* assetPath = "dpdfnet/dpdfnet4.onnx");

    /// Process audio in-place. Call ONLY from audio thread.
    /// Handles buffering, hop processing, crossfade, intensity, clamping.
    /// ZERO heap allocations (all buffers pre-allocated in Impl).
    /// @param buffer Float audio [-1,+1] at 48 kHz. Modified in-place.
    /// @param blockSize Number of samples.
    void process(float* buffer, int blockSize);

    /// Enable/disable with smooth crossfade (800 samples @ 48 kHz).
    void setEnabled(bool enabled);

    /// Set intensity [0.0, 1.0] — dry/wet mix. Thread-safe.
    void setIntensity(float intensity);

    /// Reset internal state (DSP buffers + model state to init values).
    void reset();

    // ─── Getters (thread-safe) ───────────────────────────────────────────────
    bool isEnabled() const { return enabled_.load(std::memory_order_acquire); }
    bool isActive() const { return active_.load(std::memory_order_acquire); }
    const char* name() const { return "DPDFNet-4"; }
    float getEffectiveIntensity() const;
    uint64_t getProcessedFrames() const;
    uint64_t getDroppedFrames() const;
    uint32_t getLastInferenceUs() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;

    // ─── Atomics (control ↔ audio thread communication) ─────────────────────
    std::atomic<bool>     enabled_{false};
    std::atomic<float>    intensity_{0.8f};
    std::atomic<bool>     active_{false};
    std::atomic<uint64_t> processedFrames_{0};
    std::atomic<uint64_t> droppedFrames_{0};
    std::atomic<uint32_t> lastInferenceUs_{0};

    // ─── Crossfade state (audio-thread-only, no atomic needed) ──────────────
    float crossfadeGain_   = 0.0f;
    float crossfadeTarget_ = 0.0f;
    float effectiveIntensity_ = 0.0f;
};

} // namespace dpdfnet_denoiser

// ═══════════════════════════════════════════════════════════════════════════════
// ADAPTER — thin wrapper implementing IDenoiserEngine
// ═══════════════════════════════════════════════════════════════════════════════

/// Adapter exposing DpdfnetDenoiser through the IDenoiserEngine interface
/// so DenoiserSelector can manage it uniformly with other motors.
class DpdfnetAdapter : public IDenoiserEngine {
public:
    explicit DpdfnetAdapter(dpdfnet_denoiser::DpdfnetDenoiser* impl)
        : impl_(impl) {}

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
        return impl_->name();
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
    dpdfnet_denoiser::DpdfnetDenoiser* impl_;  ///< Non-owning pointer
};

#endif // HEARING_AID_DPDFNET_DENOISER_H

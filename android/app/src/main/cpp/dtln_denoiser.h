/// @file dtln_denoiser.h
/// @brief DTLN (Dual-signal Transformation LSTM Network) denoiser engine.
///
/// Two-stage speech enhancement:
///   Stage 1 (model_1): operates on STFT magnitude, predicts spectral mask.
///   Stage 2 (model_2): operates on time-domain signal, refines output.
///
/// Both stages carry explicit LSTM hidden state as tensor I/O (no internal
/// state reset issues — the state is a regular tensor updated each frame).
///
/// Frame: 512 samples @ 16 kHz (32 ms). FFT: 512 points, 257 bins.
/// Window: sqrt-Hann (analysis + synthesis -> COLA with 50% overlap).
/// OLA hop: 256 samples (50% overlap for output reconstruction).
///
/// Models: assets/dtln/model_1.onnx (~1.4 MB), model_2.onnx (~2.5 MB).
/// License: MIT (breizhn/DTLN).

#ifndef HEARING_AID_DTLN_DENOISER_H
#define HEARING_AID_DTLN_DENOISER_H

#include "i_denoiser_engine.h"
#include <atomic>
#include <memory>

struct AAssetManager;

namespace dtln {

class DtlnDenoiser {
public:
    DtlnDenoiser();
    ~DtlnDenoiser();
    DtlnDenoiser(const DtlnDenoiser&) = delete;
    DtlnDenoiser& operator=(const DtlnDenoiser&) = delete;

    bool initialize(AAssetManager* mgr);
    void process(float* buffer, int blockSize);
    void setEnabled(bool enabled);
    void setIntensity(float intensity);
    void reset();
    bool isActive() const;
    bool isEnabled() const;
    const char* name() const { return "DTLN"; }
    uint64_t getProcessedFrames() const;
    uint64_t getDroppedFrames() const { return 0; }
    uint32_t getLastInferenceUs() const;
    float getEffectiveIntensity() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace dtln

class DtlnAdapter : public IDenoiserEngine {
public:
    explicit DtlnAdapter(dtln::DtlnDenoiser* engine) : engine_(engine) {}
    bool initialize(AAssetManager* mgr) override { return engine_->initialize(mgr); }
    void process(float* buffer, int blockSize) override { engine_->process(buffer, blockSize); }
    void setEnabled(bool enabled) override { engine_->setEnabled(enabled); }
    void setIntensity(float intensity) override { engine_->setIntensity(intensity); }
    bool isActive() const override { return engine_->isActive(); }
    bool isEnabled() const override { return engine_->isEnabled(); }
    void reset() override { engine_->reset(); }
    const char* name() const override { return engine_->name(); }
    uint64_t getProcessedFrames() const override { return engine_->getProcessedFrames(); }
    uint64_t getDroppedFrames() const override { return engine_->getDroppedFrames(); }
    uint32_t getLastInferenceUs() const override { return engine_->getLastInferenceUs(); }
    float getEffectiveIntensity() const override { return engine_->getEffectiveIntensity(); }
private:
    dtln::DtlnDenoiser* engine_;
};

#endif // HEARING_AID_DTLN_DENOISER_H

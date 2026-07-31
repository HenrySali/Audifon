/// @file rnnoise_adapter.h
/// @brief Adapter header-only que wrappea RnnoiseDenoiser bajo IDenoiserEngine.
///
/// Delega todas las llamadas a la instancia existente sin modificarla.
/// Spec: ruidolimpio.md § 4.1, tarea 1.2

#ifndef HEARING_AID_RNNOISE_ADAPTER_H
#define HEARING_AID_RNNOISE_ADAPTER_H

#include "i_denoiser_engine.h"
#include "rnnoise_denoiser.h"

/// Adapter que expone RnnoiseDenoiser vía la interfaz IDenoiserEngine.
/// No posee la instancia — recibe un puntero no-owning al miembro de AudioEngine.
class RnnoiseAdapter : public IDenoiserEngine {
public:
    explicit RnnoiseAdapter(rnnoise_denoiser::RnnoiseDenoiser* impl)
        : impl_(impl) {}

    bool initialize(AAssetManager* /*mgr*/) override {
        // RNNoise no necesita AssetManager — modelo baked-in.
        return impl_->initialize();
    }

    void process(float* buffer, int blockSize) override {
        impl_->process(buffer, blockSize);
    }

    void setEnabled(bool enabled) override {
        impl_->setEnabled(enabled);
    }

    void setIntensity(float intensity) override {
        impl_->setIntensity(intensity);
    }

    bool isActive() const override {
        return impl_->isActive();
    }

    bool isEnabled() const override {
        return impl_->isEnabled();
    }

    void reset() override {
        // RNNoise no expone reset() público — no-op seguro.
        // El estado interno se limpia al re-initialize.
    }

    const char* name() const override {
        return "RNNoise";
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
    rnnoise_denoiser::RnnoiseDenoiser* impl_;
};

#endif // HEARING_AID_RNNOISE_ADAPTER_H

/// @file gtcrn_adapter.h
/// @brief Adapter header-only que wrappea DnnDenoiser (GTCRN) bajo IDenoiserEngine.
///
/// Delega todas las llamadas a la instancia existente sin modificarla.
/// El initialize() pasa "dnn_denoiser/gtcrn.onnx" como asset path.
/// Spec: ruidolimpio.md § 4.1, tarea 1.2

#ifndef HEARING_AID_GTCRN_ADAPTER_H
#define HEARING_AID_GTCRN_ADAPTER_H

#include "i_denoiser_engine.h"
#include "dnn_denoiser/dnn_denoiser.h"

/// Adapter que expone DnnDenoiser (GTCRN mono) vía la interfaz IDenoiserEngine.
/// No posee la instancia — recibe un puntero no-owning al miembro de AudioEngine.
class GtcrnAdapter : public IDenoiserEngine {
public:
    explicit GtcrnAdapter(dnn_denoiser::DnnDenoiser* impl)
        : impl_(impl) {}

    bool initialize(AAssetManager* mgr) override {
        return impl_->initialize(mgr, "dnn_denoiser/gtcrn.onnx");
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
        impl_->reset();
    }

    const char* name() const override {
        return "GTCRN";
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
    dnn_denoiser::DnnDenoiser* impl_;
};

#endif // HEARING_AID_GTCRN_ADAPTER_H

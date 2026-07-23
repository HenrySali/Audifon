/// @file dfn3_adapter.h
/// @brief Adapter header-only que wrappea Dfn3Denoiser bajo IDenoiserEngine.
///
/// Delega todas las llamadas a la instancia existente sin modificarla.
/// El initialize() carga los modelos directamente desde assets vía
/// AAssetManager (OnnxRuntime directo, sin extracción a filesystem).
/// Spec: ruidolimpio.md § 4.1, tarea 1.2

#ifndef HEARING_AID_DFN3_ADAPTER_H
#define HEARING_AID_DFN3_ADAPTER_H

#include "i_denoiser_engine.h"
#include "dfn3_denoiser.h"

#include <android/asset_manager.h>

/// Adapter que expone Dfn3Denoiser vía la interfaz IDenoiserEngine.
/// No posee la instancia — recibe un puntero no-owning al miembro de AudioEngine.
class Dfn3Adapter : public IDenoiserEngine {
public:
    /// @param impl Puntero no-owning al Dfn3Denoiser existente en AudioEngine.
    explicit Dfn3Adapter(dfn3_denoiser::Dfn3Denoiser* impl)
        : impl_(impl) {}

    bool initialize(AAssetManager* mgr) override {
        if (!mgr || !impl_) return false;
        // Carga enc.onnx + erb_dec.onnx desde assets/dfn3/ directamente
        // en memoria OnnxRuntime (sin extracción a filesystem).
        return impl_->initialize(mgr, "dfn3");
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
        return "DeepFilterNet3";
    }

    uint64_t getProcessedFrames() const override {
        return impl_->getProcessedFrames();
    }

    uint64_t getDroppedFrames() const override {
        return 0;
    }

    uint32_t getLastInferenceUs() const override {
        return 0;
    }

    float getEffectiveIntensity() const override {
        return impl_->getEffectiveIntensity();
    }

private:
    dfn3_denoiser::Dfn3Denoiser* impl_;
};

#endif // HEARING_AID_DFN3_ADAPTER_H

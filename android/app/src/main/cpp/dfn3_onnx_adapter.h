/// @file dfn3_onnx_adapter.h
/// @brief Adapter header-only que wrappea Dfn3OnnxDenoiser bajo IDenoiserEngine.
///
/// Delega todas las llamadas a la instancia existente sin modificarla.
/// Ocupa el slot "Premium" (DenoiserType::kDFN3) del DenoiserSelector,
/// reemplazando al viejo Dfn3Denoiser (enc/erb_dec manual) por el export
/// ONNX autocontenido de DeepFilterNet3 (audio crudo 48 kHz, torchDF).
///
/// El initialize() carga el modelo desde assets/dfn3_onnx/denoiser_model.onnx
/// directamente en OnnxRuntime (sin extracción a filesystem, sin Rust/tract).
/// Spec: ruidolimpio.md § 4.1 (patrón de adapters).

#ifndef HEARING_AID_DFN3_ONNX_ADAPTER_H
#define HEARING_AID_DFN3_ONNX_ADAPTER_H

#include "i_denoiser_engine.h"
#include "dfn3_onnx_denoiser.h"

#include <android/asset_manager.h>

/// Adapter que expone Dfn3OnnxDenoiser vía la interfaz IDenoiserEngine.
/// No posee la instancia — recibe un puntero no-owning al miembro de AudioEngine.
class Dfn3OnnxAdapter : public IDenoiserEngine {
public:
    /// @param impl Puntero no-owning al Dfn3OnnxDenoiser existente en AudioEngine.
    explicit Dfn3OnnxAdapter(dfn3_onnx::Dfn3OnnxDenoiser* impl)
        : impl_(impl) {}

    bool initialize(AAssetManager* mgr) override {
        if (!mgr || !impl_) return false;
        // Carga denoiser_model.onnx (DFN3-48k autocontenido) desde assets
        // directamente en memoria OnnxRuntime.
        return impl_->initialize(mgr, "dfn3_onnx/denoiser_model.onnx");
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
        return "DeepFilterNet3 (ONNX)";
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
    dfn3_onnx::Dfn3OnnxDenoiser* impl_;
};

#endif // HEARING_AID_DFN3_ONNX_ADAPTER_H

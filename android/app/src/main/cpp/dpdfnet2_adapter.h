/// @file dpdfnet2_adapter.h
/// @brief Adapter exposing Dpdfnet2_48khzDenoiser through the IDenoiserEngine interface.
///
/// Header-only adapter que delega todas las llamadas a un puntero non-owning
/// de Dpdfnet2_48khzDenoiser. Sigue el patrón exacto de DpdfnetAdapter para
/// consistencia con los demás motores del DenoiserSelector.
///
/// El DenoiserSelector usa esta interfaz para conmutar exclusivamente entre
/// motores con crossfade sin conocer la implementación subyacente.
///
/// Requirements: 1.3, 6.2

#ifndef HEARING_AID_DPDFNET2_ADAPTER_H
#define HEARING_AID_DPDFNET2_ADAPTER_H

#include "i_denoiser_engine.h"
#include "dpdfnet2_48khz_denoiser.h"

// ═══════════════════════════════════════════════════════════════════════════════

/// Adapter exposing Dpdfnet2_48khzDenoiser through the IDenoiserEngine interface
/// so DenoiserSelector can manage it uniformly with other motors.
class DPDFNet2Adapter : public IDenoiserEngine {
public:
    explicit DPDFNet2Adapter(dpdfnet2_denoiser::Dpdfnet2_48khzDenoiser* impl)
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
    dpdfnet2_denoiser::Dpdfnet2_48khzDenoiser* impl_;  ///< Non-owning pointer
};

#endif // HEARING_AID_DPDFNET2_ADAPTER_H

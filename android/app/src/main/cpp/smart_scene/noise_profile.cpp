/// @file noise_profile.cpp
/// @brief Implementación del estimador de piso de ruido (minimum statistics).
///
/// Validates: Requirements 1.1

#include "noise_profile.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace smart_scene {

NoiseProfile::NoiseProfile() {
    reset();
}

void NoiseProfile::reset() {
    for (int b = 0; b < kSceneNumBands; ++b) {
        noiseDb_[b] = -60.0f;
        for (int i = 0; i < kMinWindowSize; ++i) {
            history_[b][i] = -90.0f;
        }
    }
    historyIdx_ = 0;
    historyFill_ = 0;
    globalNoiseFloorDb_ = -90.0f;
}

void NoiseProfile::update(const float bandEnergyDb[kSceneNumBands]) {
    if (bandEnergyDb == nullptr) return;

    // Push al ringbuffer y actualizar el mínimo por banda.
    for (int b = 0; b < kSceneNumBands; ++b) {
        float e = bandEnergyDb[b];
        if (!std::isfinite(e)) e = -90.0f;
        history_[b][historyIdx_] = e;
    }

    historyIdx_ = (historyIdx_ + 1) % kMinWindowSize;
    if (historyFill_ < kMinWindowSize) {
        ++historyFill_;
    }

    // Para cada banda, mínimo en la ventana + un release suave para subir.
    double sumGlobal = 0.0;
    for (int b = 0; b < kSceneNumBands; ++b) {
        float minVal = history_[b][0];
        for (int i = 1; i < historyFill_; ++i) {
            if (history_[b][i] < minVal) {
                minVal = history_[b][i];
            }
        }
        // Si el mínimo crece (señal sostenida sin pausas) subimos lentamente
        // para no perder el piso real cuando la voz cae.
        if (minVal > noiseDb_[b]) {
            noiseDb_[b] = (1.0f - kRiseAlpha) * noiseDb_[b] +
                          kRiseAlpha * minVal;
        } else {
            noiseDb_[b] = minVal;
        }
        sumGlobal += noiseDb_[b];
    }
    globalNoiseFloorDb_ = static_cast<float>(sumGlobal / kSceneNumBands);
}

} // namespace smart_scene

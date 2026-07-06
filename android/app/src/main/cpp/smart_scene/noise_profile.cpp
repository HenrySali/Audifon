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
    // FIX escala R2 (mvdr-noise-clarity-tuning, tarea 2.2): el piso de ruido
    // se inicializa a un valor físicamente plausible (~-50 dBFS, el orden de
    // magnitud del ruido propio del mic del Moto G32) en vez de -90/-60. El
    // arranque en -90 hacía que el minimum-statistics undertrackeara y
    // reportara -77..-97 dBFS (imposible para un mic real) hasta converger,
    // saturando el SNR del snapshot. El consumidor (scene_analyzer) acota el
    // piso a [-60, -40] dBFS de forma defensiva.
    for (int b = 0; b < kSceneNumBands; ++b) {
        noiseDb_[b] = kInitNoiseFloorDb;
        for (int i = 0; i < kMinWindowSize; ++i) {
            history_[b][i] = kInitNoiseFloorDb;
        }
    }
    historyIdx_ = 0;
    historyFill_ = 0;
    globalNoiseFloorDb_ = kInitNoiseFloorDb;
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
    // Compensación de sesgo del mínimo (Martin 2001, B_min): el promedio de
    // los mínimos por banda subestima ~9 dB la potencia media del ruido
    // estacionario. Sumamos el offset SOLO al escalar global (el perfil por
    // banda noiseDb_/getProfileDb() queda crudo para el VAD). El consumidor
    // (scene_analyzer) acota luego a [-60,-40] dBFS de forma defensiva.
    globalNoiseFloorDb_ =
        static_cast<float>(sumGlobal / kSceneNumBands) + kMinStatBiasCompDb;
}

} // namespace smart_scene

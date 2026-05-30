/// @file noise_profile.h
/// @brief Estimador del perfil de ruido por banda — minimum statistics.
///
/// Implementa una versión simplificada del algoritmo de Martin (2001) para
/// estimar el piso de ruido por banda. Mantiene una ventana corta (ringbuf)
/// del valor mínimo observado por banda y aplica un ligero "lift" para
/// evitar undertrack del ruido cuando la voz cae.
///
/// El piso de ruido se mantiene por las 12 bandas EQ (kSceneNumBands).
///
/// Referencias:
/// - NOISE-MARTIN-2001 (referencia clásica de minimum statistics).
/// - design.md: noise_profile.{h,cpp} — minimum statistics simplificado.
///
/// Validates: Requirements 1.1

#ifndef HEARING_AID_SMART_SCENE_NOISE_PROFILE_H
#define HEARING_AID_SMART_SCENE_NOISE_PROFILE_H

#include "scene_types.h"

namespace smart_scene {

/// Estimador de perfil de ruido por banda.
class NoiseProfile {
public:
    /// Tamaño de la ventana de mínimos (frames). 50 frames * ~5 ms = 250 ms.
    static constexpr int kMinWindowSize = 50;

    NoiseProfile();

    /// Reinicia el estado interno.
    void reset();

    /// Actualiza el perfil con la energía actual por banda.
    /// @param bandEnergyDb Array de tamaño kSceneNumBands con la energía
    ///                     instantánea por banda en dB.
    void update(const float bandEnergyDb[kSceneNumBands]);

    /// Devuelve el piso de ruido por banda actual (dB).
    /// @return Puntero al array interno (válido hasta el próximo update).
    const float* getProfileDb() const { return noiseDb_; }

    /// Estimación scalar del piso de ruido global (promedio en dB).
    float getNoiseFloorDb() const { return globalNoiseFloorDb_; }

private:
    float noiseDb_[kSceneNumBands];

    // Ringbuffer simple por banda (kMinWindowSize valores recientes).
    float history_[kSceneNumBands][kMinWindowSize];
    int historyIdx_ = 0;
    int historyFill_ = 0;

    float globalNoiseFloorDb_ = -90.0f;

    /// Suavizado exponencial al subir el piso (release).
    static constexpr float kRiseAlpha = 0.05f;
};

} // namespace smart_scene

#endif // HEARING_AID_SMART_SCENE_NOISE_PROFILE_H

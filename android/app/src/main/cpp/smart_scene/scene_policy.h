/// @file scene_policy.h
/// @brief Tabla unificada de decisiones por SceneClass.
///
/// Reemplaza la lógica dual (EnvironmentClassifier + SceneDecisionMaker)
/// con una sola tabla que mapea cada SceneClass a todos los parámetros
/// del sistema: NR, WDRC, Enhancement Mode, TNR, EQ preset hint.
///
/// El EnvironmentClassifier se mantiene en el código por compatibilidad
/// pero ya NO toma decisiones — solo se usa como fallback si Smart está OFF.
/// Cuando Smart está ON, esta tabla manda.

#ifndef HEARING_AID_SCENE_POLICY_H
#define HEARING_AID_SCENE_POLICY_H

#include "../dsp_pipeline.h"
#include "scene_types.h"

namespace smart_scene {

/// Política completa para una clase de escena.
struct ScenePolicy {
    int nrLevel;                ///< 0=off, 1=bajo, 2=medio, 3=alto
    float compressionKnee;      ///< dB SPL
    float compressionRatio;     ///< input:output
    bool tnrEnabled;            ///< Transient Noise Reducer
    int enhancementMode;        ///< 0=Bypass, 1=DualDNN, 2=MVDR, 3=Hybrid
    float mpoThresholdDbSpl;    ///< MPO broadband
};

/// Tabla de políticas indexada por SceneClass (0-7).
/// Orden: UNKNOWN, SILENCE, VOICE_ONLY, VOICE_IN_NOISE_LOW,
///        VOICE_IN_NOISE_MID, NOISE_LOW_DOMINANT, NOISE_HIGH_DOMINANT, MUSIC
///
/// Enhancement modes disponibles para uso automático:
///   0 = Bypass (sin realce)
///   1 = DualDNN (recomendado para cualquier ruido)
///   MVDR (2, 3) no se usa automáticamente — no funciona en Moto G32
///   (aliasing espacial a 1071 Hz con 16 cm de mic spacing).
///
/// Fundamento de los compression knees por escena:
///   - En SILENCIO/VOZ pura: knee bajo (52-55 dB) para expandir dinámica
///     de voz suave y comprimir voz fuerte (mantener confort).
///   - En VOZ+RUIDO: knee MÁS ALTO (65-70 dB) para que la compresión NO
///     aplaste la voz que compite con el ruido. Según NAL-NL2 (Keidser et
///     al., 2012): en ruido, reducir la compresión (subir knee / bajar ratio)
///     preserva las fluctuaciones temporales del habla → mejor inteligibilidad.
///   - En RUIDO dominante (sin voz): knee moderado (60 dB), ratio bajo (1.3-1.5)
///     para no atenuar excesivamente — la DNN ya se encarga de separar.
///   - En MÚSICA: knee alto (65 dB), ratio mínimo (1.2) para preservar dinámica.
///
/// Referencia: Dillon (2012) "Hearing Aids" Cap 6; Keidser et al. (2012)
/// "NAL-NL2 Empirical Adjustments" Trends in Hearing; IEC 60118-2.
static constexpr ScenePolicy kScenePolicies[] = {
    // UNKNOWN (0): conservador, DualDNN por seguridad
    { /* nr */ 1, /* knee */ 55.0f, /* ratio */ 2.0f, /* tnr */ false,
      /* enhancement */ 1, /* mpo */ 110.0f },

    // SILENCE (1): bypass total, mínimo procesamiento
    { /* nr */ 0, /* knee */ 55.0f, /* ratio */ 1.5f, /* tnr */ false,
      /* enhancement */ 0, /* mpo */ 110.0f },

    // VOICE_ONLY (2): DualDNN para limpiar, compresión estándar
    { /* nr */ 1, /* knee */ 52.0f, /* ratio */ 2.0f, /* tnr */ false,
      /* enhancement */ 1, /* mpo */ 110.0f },

    // VOICE_IN_NOISE_LOW (3): DualDNN, NR medio, knee ALTO para preservar voz
    { /* nr */ 2, /* knee */ 65.0f, /* ratio */ 1.5f, /* tnr */ false,
      /* enhancement */ 1, /* mpo */ 110.0f },

    // VOICE_IN_NOISE_MID (4): DualDNN, NR alto, knee ALTO, ratio bajo
    { /* nr */ 3, /* knee */ 70.0f, /* ratio */ 1.4f, /* tnr */ true,
      /* enhancement */ 1, /* mpo */ 110.0f },

    // NOISE_LOW_DOMINANT (5): DualDNN, NR máximo + TNR, knee moderado
    // Sin voz detectada → podemos comprimir más, pero no excesivamente
    // porque la DNN ya limpia. Ratio bajo para no matar la señal.
    { /* nr */ 3, /* knee */ 60.0f, /* ratio */ 1.4f, /* tnr */ true,
      /* enhancement */ 1, /* mpo */ 110.0f },

    // NOISE_HIGH_DOMINANT (6): DualDNN, NR máximo + TNR, knee moderado
    // Subte, tráfico, maquinaria — misma lógica que NOISE_LOW.
    { /* nr */ 3, /* knee */ 60.0f, /* ratio */ 1.4f, /* tnr */ true,
      /* enhancement */ 1, /* mpo */ 110.0f },

    // MUSIC (7): bypass NR, compresión mínima para preservar dinámica
    { /* nr */ 0, /* knee */ 65.0f, /* ratio */ 1.2f, /* tnr */ false,
      /* enhancement */ 0, /* mpo */ 115.0f },
};

/// Obtiene la política para una clase dada (bounds-checked).
inline ScenePolicy getPolicyForClass(uint8_t sceneClass) {
    if (sceneClass >= 8) sceneClass = 0;  // fallback a UNKNOWN
    return kScenePolicies[sceneClass];
}

} // namespace smart_scene

#endif // HEARING_AID_SCENE_POLICY_H

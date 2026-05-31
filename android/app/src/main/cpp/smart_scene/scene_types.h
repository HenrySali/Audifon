/// @file scene_types.h
/// @brief Tipos compartidos del módulo Smart Scene Engine — Fase 1.
///
/// Define el enum SceneClass y la struct SceneSnapshot que se serializa
/// hacia Dart vía JNI (ByteArray). Diseñado para layout estable y POD-safe
/// (trivially copyable) para poder copiarse atómicamente en la C++ side.
///
/// La numeración del enum es contractual con `lib/scene/scene_snapshot.dart`
/// y futuro `scene_class.dart` — NO reordenar.
///
/// Referencias:
/// - design.md: data model "Scene Snapshot (compartido C++/Dart)"
/// - requirements.md: REQ-1.1, REQ-6.1
///
/// Validates: Requirements 1.1, 6.1

#ifndef HEARING_AID_SMART_SCENE_TYPES_H
#define HEARING_AID_SMART_SCENE_TYPES_H

#include <cstdint>

namespace smart_scene {

// ─────────────────────────────────────────────────────────────────────────────
// Constantes
// ─────────────────────────────────────────────────────────────────────────────

/// Cantidad de bandas EQ usadas para describir el perfil de ruido.
/// Coincide con las 12 bandas del Equalizer del pipeline DSP existente.
static constexpr int kSceneNumBands = 12;

// ─────────────────────────────────────────────────────────────────────────────
// Enumeración de clases de escena
// ─────────────────────────────────────────────────────────────────────────────

/// Clases de escena acústica detectables por el Smart Scene Engine.
/// Orden contractual con Dart: NO reordenar (los valores se serializan).
enum class SceneClass : uint8_t {
    UNKNOWN              = 0,  ///< Indeterminado (Fase 1: siempre se devuelve esto)
    SILENCE              = 1,  ///< Nivel < 30 dB SPL
    VOICE_ONLY           = 2,  ///< Voz limpia, SNR > 15 dB
    VOICE_IN_NOISE_LOW   = 3,  ///< Voz con ruido grave (subte, motores)
    VOICE_IN_NOISE_MID   = 4,  ///< Voz con ruido medio (bar, oficina)
    NOISE_LOW_DOMINANT   = 5,  ///< Ruido grave dominante sin voz
    NOISE_HIGH_DOMINANT  = 6,  ///< Ruido agudo dominante (calle, viento)
    MUSIC                = 7,  ///< Música (espectro armónico estable)
};

// ─────────────────────────────────────────────────────────────────────────────
// Snapshot del estado del analizador
// ─────────────────────────────────────────────────────────────────────────────

/// Snapshot de las métricas computadas por el SceneAnalyzer.
///
/// Se transfiere a Dart como bloque crudo (ByteArray) usando memcpy.
/// Por eso DEBE ser POD/trivially copyable y mantener el orden y tipos
/// exactos con `lib/scene/scene_snapshot.dart`.
///
/// Se acompaña con `#pragma pack(1)` para garantizar layout sin padding,
/// alineado al parser Dart.
#pragma pack(push, 1)
struct SceneSnapshot {
    // ─── Identidad temporal ─────────────────────────────────────────────
    uint64_t timestamp_us;          ///< Microsegundos desde inicio del analyzer.

    // ─── Niveles de presión sonora ──────────────────────────────────────
    float input_db_spl;             ///< Nivel RMS de entrada (dB SPL).
    float noise_floor_db_spl;       ///< Estimación de piso de ruido (dB SPL).
    float snr_db;                   ///< SNR estimado (dB), clampeado [-20, 40].

    // ─── Voice Activity Detection ───────────────────────────────────────
    float vad_score;                ///< Score combinado [0, 1] suavizado con EMA.
    float vad_confidence;           ///< Confianza derivada del score [0, 1].
    uint8_t voice_active;           ///< 0/1 — true cuando el VAD decide voz.
    uint8_t vad_hangover_active;    ///< 0/1 — voice_active activo solo por hangover.
    uint8_t vad_stationarity_q8;    ///< Estacionariedad del ruido [0..255] (Q8).
    uint8_t vad_mid_snr_q8;         ///< Mid-band SNR clamp [0..30 dB] mapeado a [0..255].

    // ─── Features espectrales ───────────────────────────────────────────
    float spectral_tilt_db;         ///< Pendiente espectral (dB/octava).
    float spectral_centroid_hz;     ///< Centroide espectral (Hz).
    float spectral_flatness;        ///< Flatness geometric/arithmetic [0, 1].
    float spectral_flux;            ///< Flux entre frames consecutivos.
    float low_band_energy_db;       ///< Energía banda baja (250-750 Hz, dB).
    float mid_band_energy_db;       ///< Energía banda media (750 Hz-3 kHz, dB).
    float high_band_energy_db;      ///< Energía banda alta (3-8 kHz, dB).

    // ─── Perfil de ruido por banda ──────────────────────────────────────
    float noise_per_band_db[kSceneNumBands]; ///< Piso de ruido en 12 bandas EQ.

    // ─── Eventos discretos ──────────────────────────────────────────────
    uint16_t impulse_count;         ///< Conteo de impulsos detectados (Fase 4+).
    uint8_t _pad1[2];               ///< Padding hasta alineación 32-bit.

    // ─── Clasificación (placeholder Fase 1) ─────────────────────────────
    uint8_t scene_class;            ///< Valor del enum SceneClass.
    uint8_t _pad2[3];               ///< Padding hasta float.
    float scene_confidence;         ///< Confianza de la clase [0, 1].
};
#pragma pack(pop)

// Cuentas estáticas para detectar regresiones de layout sin tener que
// lanzar el debugger. Si alguien edita SceneSnapshot rompiendo el layout
// el build falla aquí (en compile time).
static_assert(sizeof(uint64_t) == 8, "uint64_t must be 8 bytes");
static_assert(sizeof(float) == 4, "float must be 4 bytes");
static_assert(sizeof(SceneSnapshot) ==
                  /* timestamp     */ 8 +
                  /* 3 floats      */ 3 * 4 +
                  /* 2 floats VAD  */ 2 * 4 +
                  /* voice + 3*u8  */ 1 + 3 +
                  /* 7 floats spec */ 7 * 4 +
                  /* 12 floats     */ 12 * 4 +
                  /* impulse + pad */ 2 + 2 +
                  /* class + pad   */ 1 + 3 +
                  /* conf          */ 4,
              "SceneSnapshot layout drift — sync with scene_snapshot.dart");

} // namespace smart_scene

#endif // HEARING_AID_SMART_SCENE_TYPES_H

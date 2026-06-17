/// @file environment_classifier.h
/// @brief Clasificador automático de entorno acústico (C++ nativo).
///
/// Clasifica el entorno en 4 categorías: QUIET, SPEECH, SPEECH_IN_NOISE, NOISE.
/// Usa EMA smoothing y hold timer para estabilidad temporal.
/// Ajusta automáticamente NR y WDRC según el entorno detectado.
///
/// Crítico para usuarios pediátricos que no pueden cambiar perfiles manualmente.
///
/// Diseño:
/// - EMA smoothing (α=0.05, ~800ms time constant @ 4ms blocks)
/// - Hold timer (750 bloques = 3 s) para evitar oscilación rápida
/// - Lookup tables para NR level y WDRC params por entorno
/// - SNR estimation desde el noise reducer
/// - Thread-safe: lecturas atómicas del estado actual

#ifndef HEARING_AID_ENVIRONMENT_CLASSIFIER_H
#define HEARING_AID_ENVIRONMENT_CLASSIFIER_H

#include <atomic>
#include <cstdint>

// ─────────────────────────────────────────────────────────────────────────────
// Constantes del clasificador (deben coincidir con firmware y simulador web)
// ─────────────────────────────────────────────────────────────────────────────

/// Factor de suavizado EMA (~800 ms time constant @ 4 ms blocks)
static constexpr float kEnvAlpha = 0.05f;

/// Bloques de hold tras una transición de clase de entorno.
/// 1250 bloques × 4 ms/bloque = 5 segundos de hold.
///
/// Histórico:
/// - 500 ms (125 bloques): producía oscilación audible en transiciones
///   SPEECH ↔ SPEECH_IN_NOISE.
/// - 3 s (750 bloques): estable subjetivamente para adultos pero a 3 s en
///   pediátrico el aparato seguía cambiando demasiado seguido en escenas
///   reales (aula→patio→comedor del jardín en <1 min) y aumentaba la
///   fatiga auditiva reportada (Hornsby/Bess; PMC 10023143).
/// - 5 s (1250 bloques): valor pediátrico actual. Se alinea con el rango
///   sugerido por AAA Pediatric Amplification 2013 y la práctica
///   conservadora documentada en The Hearing Journal 2014 ("Stop and
///   Verify"). Phonak Sky usa "extensive smoothing progression" (no
///   publican número, pero implícito >3 s). Reduce número de cambios
///   audibles por unidad de tiempo sin perder reactividad clínica.
static constexpr int kEnvHoldBlocks = 1250;

/// Umbral de nivel para entorno silencioso (dB SPL).
/// Recalibrado (FIX clasificador, splOffset=93 dB del mic celular): un
/// ambiente tranquilo ronda 40-48 dB SPL; la voz normal ~60-65 dB SPL queda
/// claramente por encima. Antes 45 dB SPL.
static constexpr float kEnvLevelQuietThreshold = 48.0f;

/// Umbral de nivel máximo para clasificar como habla (dB SPL).
/// Recalibrado: con el SNR real (razón señal/ruido del NR) el discriminador
/// principal es el SNR, no el nivel; subimos el techo a 80 dB SPL para no
/// bloquear voz fuerte legítima. El ruido fuerte cae en NOISE por SNR bajo,
/// no por nivel. Antes 70 dB SPL.
static constexpr float kEnvLevelSpeechMax = 80.0f;

/// Umbral de SNR para ENTRAR a SPEECH (dB) — histéresis alta.
/// Recalibrado contra el SNR autoconsistente del NR
/// (tools/sim_v3/validate_classifier.py): voz limpia ≈ 10 dB; voz en ruido
/// ≈ 2.7 dB; ruido/música < 1 dB. Entrar a SPEECH con SNR > 6 dB separa voz
/// limpia del resto. Antes 12 dB (calibrado para el SNR falso = nivel-30).
static constexpr float kEnvSnrSpeechEnter = 6.0f;

/// Umbral de SNR para SALIR de SPEECH (dB) — histéresis baja.
/// Zona muerta [4, 6] dB mantiene el estado y evita chatter. Antes 5 dB.
static constexpr float kEnvSnrSpeechExit = 4.0f;

/// Umbral de SNR por debajo del cual el entorno es NOISE (dB).
/// Recalibrado: ruido estacionario/música dan SNR < 1.5 dB (señal≈ruido);
/// voz en ruido da ~2.7 dB → SPEECH_IN_NOISE. Antes 0 dB (inalcanzable con
/// el SNR falso). Ambos (NOISE y SPEECH_IN_NOISE) se muestran como "Ruidoso".
static constexpr float kEnvSnrNoiseThreshold = 1.5f;

/// SNR mínimo clampeable (dB)
static constexpr float kEnvSnrMin = -20.0f;

/// SNR máximo clampeable (dB)
static constexpr float kEnvSnrMax = 40.0f;

/// Ceiling de headroom para el guard post-EQ
static constexpr float kHeadroomCeiling = 0.95f;

// ─────────────────────────────────────────────────────────────────────────────
// Enumeración de clases de entorno
// ─────────────────────────────────────────────────────────────────────────────

/// Clasificación del entorno acústico.
enum class EnvironmentClass : int {
    QUIET = 0,            ///< Nivel < 48 dB SPL
    SPEECH = 1,           ///< Nivel 48-80 dB SPL, SNR > 6 dB
    SPEECH_IN_NOISE = 2,  ///< SNR 1.5-6 dB
    NOISE = 3             ///< Nivel > 80 dB SPL o SNR < 1.5 dB
};

// ─────────────────────────────────────────────────────────────────────────────
// Parámetros recomendados por entorno
// ─────────────────────────────────────────────────────────────────────────────

/// Parámetros WDRC recomendados para un entorno dado.
struct EnvWdrcParams {
    float compressionKnee;   ///< dB SPL
    float compressionRatio;  ///< ratio
};

// ─────────────────────────────────────────────────────────────────────────────
// Clase principal
// ─────────────────────────────────────────────────────────────────────────────

/// Clasificador automático de entorno acústico.
///
/// Uso típico:
/// @code
///   EnvironmentClassifier classifier;
///   // En hilo de audio (cada bloque):
///   auto envClass = classifier.update(inputLevelDb, snrDb);
///   int nrLevel = classifier.getRecommendedNrLevel();
///   auto wdrcParams = classifier.getRecommendedWdrcParams();
///   // Desde hilo de UI (thread-safe):
///   int currentClass = classifier.getCurrentClass();
/// @endcode
class EnvironmentClassifier {
public:
    EnvironmentClassifier();
    ~EnvironmentClassifier() = default;

    /// Actualiza la clasificación con nuevas mediciones.
    /// Llamar una vez por bloque (~250 veces/segundo a 64 muestras @ 16kHz).
    ///
    /// @param inputLevelDbSpl Nivel de entrada RMS en dB SPL [0, 120]
    /// @param estimatedSnrDb SNR estimado en dB [-20, 40]
    /// @return Clasificación actual del entorno
    EnvironmentClass update(float inputLevelDbSpl, float estimatedSnrDb);

    /// Obtiene la clasificación actual (thread-safe, lectura atómica).
    /// @return Clase de entorno actual (0-3)
    int getCurrentClass() const {
        return currentClass_.load(std::memory_order_relaxed);
    }

    /// Obtiene el nivel de NR recomendado para el entorno actual.
    /// @return 0=off, 1=bajo, 2=medio, 3=alto
    int getRecommendedNrLevel() const;

    /// Obtiene los parámetros WDRC recomendados para el entorno actual.
    /// @return Struct con compressionKnee y compressionRatio
    EnvWdrcParams getRecommendedWdrcParams() const;

    /// Estima el SNR a partir de las potencias por banda del NR Wiener.
    ///
    /// SNR autoconsistente = 10·log10( Σ signalPower / Σ noisePower ), usando
    /// las potencias de señal y ruido del mismo banco de filtros del NR (misma
    /// referencia → sin sesgo SPL/dBFS). Valida en
    /// tools/sim_v3/validate_classifier.py: voz limpia ≈ 10 dB, voz en ruido
    /// ≈ 2.7 dB, ruido/música < 1 dB (el enfoque previo "señal banda-ancha −
    /// promedio de ruido por banda" NO discriminaba: comprimía todo a ~10-16 dB).
    ///
    /// @param signalEstimate Array de potencias de señal por banda (energía lineal)
    /// @param noiseEstimate  Array de potencias de ruido por banda (energía lineal)
    /// @param numBands       Número de bandas en los arrays
    /// @return SNR estimado en dB, clampeado a [-20, 40]
    static float estimateSnrFromNr(const float* signalEstimate,
                                   const float* noiseEstimate, int numBands);

    /// Reinicia el clasificador al estado inicial (QUIET).
    void reset();

private:
    // --- Estado interno (solo accedido desde hilo de audio) ---
    float smoothedLevelDb_ = 0.0f;    ///< Nivel suavizado EMA (dB SPL)
    float smoothedSnrDb_ = 0.0f;      ///< SNR suavizado EMA (dB)
    int holdCounter_ = 0;             ///< Bloques restantes en hold
    EnvironmentClass prevClass_ = EnvironmentClass::QUIET;

    // --- Estado publicado (legible desde cualquier hilo) ---
    std::atomic<int> currentClass_{static_cast<int>(EnvironmentClass::QUIET)};
};

#endif // HEARING_AID_ENVIRONMENT_CLASSIFIER_H

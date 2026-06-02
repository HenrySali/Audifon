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
/// 750 bloques × 4 ms/bloque = 3 segundos de hold.
///
/// Histórico: el valor original (500 ms = 125 bloques) producía oscilación
/// audible en transiciones SPEECH ↔ SPEECH_IN_NOISE. Subido a 3 s tras
/// pruebas en escenas reales para mayor estabilidad subjetiva.
static constexpr int kEnvHoldBlocks = 750;

/// Umbral de nivel para entorno silencioso (dB SPL)
static constexpr float kEnvLevelQuietThreshold = 45.0f;

/// Umbral de nivel máximo para clasificar como habla (dB SPL)
static constexpr float kEnvLevelSpeechMax = 70.0f;

/// Umbral de SNR para habla limpia (dB)
static constexpr float kEnvSnrSpeechThreshold = 10.0f;

/// Umbral de SNR para habla en ruido — límite inferior (dB)
static constexpr float kEnvSnrNoiseThreshold = 0.0f;

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
    QUIET = 0,            ///< Nivel < 45 dB SPL
    SPEECH = 1,           ///< Nivel 45-70 dB SPL, SNR > 10 dB
    SPEECH_IN_NOISE = 2,  ///< SNR 0-10 dB
    NOISE = 3             ///< Nivel > 70 dB SPL o SNR < 0 dB
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

    /// Estima el SNR a partir de las potencias de ruido del NR.
    ///
    /// @param noiseEstimate Array de estimaciones de ruido por banda (energía lineal)
    /// @param numBands Número de bandas en el array
    /// @param signalRmsDb Nivel RMS de la señal actual en dB
    /// @return SNR estimado en dB, clampeado a [-20, 40]
    static float estimateSnrFromNr(const float* noiseEstimate, int numBands,
                                   float signalRmsDb);

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

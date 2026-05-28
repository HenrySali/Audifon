/// @file environment_classifier.cpp
/// @brief Implementación del clasificador automático de entorno acústico.
///
/// Algoritmo:
/// 1. Suavizar nivel y SNR con EMA (α=0.05, ~800 ms time constant)
/// 2. Clasificar según umbrales de nivel y SNR
/// 3. Aplicar hold timer (125 bloques = 500 ms) para estabilidad
/// 4. Proveer parámetros NR y WDRC según entorno detectado
///
/// Portado del firmware C (environment_classifier.c) a C++ nativo para Android.
/// Mismos umbrales, misma lógica, mismos lookup tables.

#include "environment_classifier.h"

#include <algorithm>
#include <cmath>

// ─────────────────────────────────────────────────────────────────────────────
// Lookup Tables — Parámetros por Entorno
// ─────────────────────────────────────────────────────────────────────────────

/// Tabla de nivel NR por clase de entorno.
/// Índice = valor de EnvironmentClass.
static constexpr int kEnvNrLevelTable[] = {
    0,  // QUIET:           NR off — no hay ruido que reducir
    1,  // SPEECH:          NR bajo — preservar claridad del habla
    2,  // SPEECH_IN_NOISE: NR medio — balance habla/ruido
    3   // NOISE:           NR alto — máxima reducción de ruido
};

/// Tabla de compression knee por clase de entorno (dB SPL).
/// Entornos más ruidosos → knee más bajo → compresión más temprana.
static constexpr float kEnvWdrcKneeTable[] = {
    55.0f,  // QUIET:           Compresión suave, knee alto
    50.0f,  // SPEECH:          Compresión estándar
    45.0f,  // SPEECH_IN_NOISE: Compresión más temprana
    40.0f   // NOISE:           Compresión agresiva, knee bajo
};

/// Tabla de compression ratio por clase de entorno.
/// Entornos más ruidosos → ratio más alto → compresión más fuerte.
static constexpr float kEnvWdrcRatioTable[] = {
    1.5f,   // QUIET:           Ratio suave
    2.0f,   // SPEECH:          Ratio estándar
    2.5f,   // SPEECH_IN_NOISE: Ratio moderado
    3.0f    // NOISE:           Ratio fuerte
};

// ─────────────────────────────────────────────────────────────────────────────
// Constructor / Reset
// ─────────────────────────────────────────────────────────────────────────────

EnvironmentClassifier::EnvironmentClassifier() {
    reset();
}

void EnvironmentClassifier::reset() {
    smoothedLevelDb_ = 0.0f;
    smoothedSnrDb_ = 0.0f;
    holdCounter_ = 0;
    prevClass_ = EnvironmentClass::QUIET;
    currentClass_.store(static_cast<int>(EnvironmentClass::QUIET),
                        std::memory_order_relaxed);
}

// ─────────────────────────────────────────────────────────────────────────────
// Actualización principal (llamada cada bloque desde hilo de audio)
// ─────────────────────────────────────────────────────────────────────────────

EnvironmentClass EnvironmentClassifier::update(float inputLevelDbSpl,
                                               float estimatedSnrDb) {
    // Step 1: Suavizado EMA del nivel y SNR
    smoothedLevelDb_ += kEnvAlpha * (inputLevelDbSpl - smoothedLevelDb_);
    smoothedSnrDb_ += kEnvAlpha * (estimatedSnrDb - smoothedSnrDb_);

    // Step 2: Clasificación rule-based según valores suavizados
    EnvironmentClass newClass;
    float level = smoothedLevelDb_;
    float snr = smoothedSnrDb_;

    if (level < kEnvLevelQuietThreshold) {
        newClass = EnvironmentClass::QUIET;
    } else if (snr > kEnvSnrSpeechThreshold && level <= kEnvLevelSpeechMax) {
        newClass = EnvironmentClass::SPEECH;
    } else if (snr > kEnvSnrNoiseThreshold && snr <= kEnvSnrSpeechThreshold) {
        newClass = EnvironmentClass::SPEECH_IN_NOISE;
    } else {
        newClass = EnvironmentClass::NOISE;
    }

    // Step 3: Hold timer — prevenir oscilación rápida entre estados
    if (holdCounter_ > 0) {
        holdCounter_--;
        return static_cast<EnvironmentClass>(currentClass_.load(std::memory_order_relaxed));
    }

    // Step 4: Transición con período de hold
    EnvironmentClass current = static_cast<EnvironmentClass>(
        currentClass_.load(std::memory_order_relaxed));

    if (newClass != current) {
        prevClass_ = current;
        currentClass_.store(static_cast<int>(newClass), std::memory_order_relaxed);
        holdCounter_ = kEnvHoldBlocks;
    }

    return static_cast<EnvironmentClass>(currentClass_.load(std::memory_order_relaxed));
}

// ─────────────────────────────────────────────────────────────────────────────
// Consultas de parámetros recomendados
// ─────────────────────────────────────────────────────────────────────────────

int EnvironmentClassifier::getRecommendedNrLevel() const {
    int classIdx = currentClass_.load(std::memory_order_relaxed);
    // Validar rango
    classIdx = std::max(0, std::min(3, classIdx));
    return kEnvNrLevelTable[classIdx];
}

EnvWdrcParams EnvironmentClassifier::getRecommendedWdrcParams() const {
    int classIdx = currentClass_.load(std::memory_order_relaxed);
    // Validar rango
    classIdx = std::max(0, std::min(3, classIdx));

    EnvWdrcParams params;
    params.compressionKnee = kEnvWdrcKneeTable[classIdx];
    params.compressionRatio = kEnvWdrcRatioTable[classIdx];
    return params;
}

// ─────────────────────────────────────────────────────────────────────────────
// Estimación de SNR desde el módulo de NR
// ─────────────────────────────────────────────────────────────────────────────

float EnvironmentClassifier::estimateSnrFromNr(const float* noiseEstimate,
                                               int numBands,
                                               float signalRmsDb) {
    if (noiseEstimate == nullptr || numBands <= 0) {
        return 0.0f;
    }

    // Promediar energía de ruido en todas las sub-bandas
    float noiseEnergySum = 0.0f;
    for (int band = 0; band < numBands; ++band) {
        noiseEnergySum += noiseEstimate[band];
    }
    float avgNoiseEnergy = noiseEnergySum / static_cast<float>(numBands);

    // Convertir energía promedio de ruido a dB
    float noiseDb;
    if (avgNoiseEnergy > 1e-10f) {
        noiseDb = 10.0f * std::log10(avgNoiseEnergy);
    } else {
        noiseDb = -90.0f;
    }

    // SNR = nivel de señal - nivel de ruido
    float snr = signalRmsDb - noiseDb;

    // Clampear al rango práctico [-20, 40] dB
    snr = std::max(kEnvSnrMin, std::min(kEnvSnrMax, snr));

    return snr;
}

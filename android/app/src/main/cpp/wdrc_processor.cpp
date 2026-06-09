/// @file wdrc_processor.cpp
/// @brief WDRC con ganancia prescrita integrada (modelo audífono real).
///
/// Arquitectura basada en:
/// - UC San Diego Open Speech Platform (NIH R01-DC015436)
/// - openMHA (HoerTech, University of Oldenburg)
/// - NAL-NL2 (Keidser et al., 2011)
/// - Starkey Compression Handbook (4th ed.)
/// - PMC4168964: "Linear gain of 30 dB is applied below the compression
///   threshold of 40 dB SPL. Above this input level, a compression ratio
///   of 2:1 is applied."
///
/// Modelo I/O de 3 regiones con GANANCIA PRESCRITA:
///
///   Región 1 — Expansión (input < expansionKnee):
///     gain = prescribedGain - reductionDb
///     Efecto: atenúa ruido de fondo, pero aún amplifica si es habla suave
///
///   Región 2 — Lineal (expansionKnee ≤ input ≤ compressionKnee):
///     gain = prescribedGain (completo)
///     Efecto: amplificación prescrita por NAL-NL2, sin modificación
///
///   Región 3 — Compresión (input > compressionKnee):
///     gain = prescribedGain - reductionDb
///     Efecto: reduce ganancia progresivamente para sonidos fuertes
///
/// Diferencia crítica vs implementación anterior:
///   ANTES: gainFactor ∈ [0.0, 1.0] → NUNCA amplificaba
///   AHORA: gainFactor puede ser > 1.0 → amplifica según prescripción

#include "wdrc_processor.h"

#include <algorithm>
#include <cmath>

// Ganancia máxima permitida para protección (50 dB = factor 316×).
// Esto es un safety clamp — la ganancia real debería ser mucho menor.
static constexpr float kMaxGainFactor = 316.0f;  // +50 dB

// ─────────────────────────────────────────────────────────────────────────────
// Constructor / Inicialización
// ─────────────────────────────────────────────────────────────────────────────

WdrcProcessor::WdrcProcessor()
    : sampleRate_(16000)
    , smoothedGain_(1.0f)
    , attackCoeff_(0.0f)
    , releaseCoeff_(0.0f) {
    updateCoefficients();
}

void WdrcProcessor::init(int sampleRate) {
    sampleRate_ = (sampleRate > 0) ? sampleRate : 16000;
    smoothedGain_ = 1.0f;
    updateCoefficients();
}

// ─────────────────────────────────────────────────────────────────────────────
// Procesamiento principal
// ─────────────────────────────────────────────────────────────────────────────

void WdrcProcessor::process(float* buffer, int blockSize, float inputLevelDb) {
    if (buffer == nullptr || blockSize <= 0) {
        return;
    }

    // 1. Calcular el factor de ganancia objetivo basado en el nivel PRE-EQ
    //    y la ganancia prescrita actual.
    float targetGain = computeGainFactor(inputLevelDb);

    // 2. Leer coeficientes actuales (pueden cambiar entre bloques).
    float attack = attackCoeff_;
    float release = releaseCoeff_;

    // 3. Aplicar ganancia suavizada muestra-por-muestra.
    for (int i = 0; i < blockSize; ++i) {
        // Suavizado asimétrico: attack rápido, release lento
        if (targetGain < smoothedGain_) {
            smoothedGain_ += attack * (targetGain - smoothedGain_);
        } else {
            smoothedGain_ += release * (targetGain - smoothedGain_);
        }

        // Clamp a [0.0, kMaxGainFactor] — ahora SÍ puede amplificar
        smoothedGain_ = std::max(0.0f, std::min(kMaxGainFactor, smoothedGain_));

        // Aplicar ganancia a la muestra
        buffer[i] *= smoothedGain_;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Cálculo de ganancia por región CON ganancia prescrita
// ─────────────────────────────────────────────────────────────────────────────

float WdrcProcessor::computeGainFactor(float inputLevelDb) const {
    // Leer parámetros atómicos (thread-safe)
    float expKnee = params_.expansionKnee.load(std::memory_order_relaxed);
    float expRatio = params_.expansionRatio.load(std::memory_order_relaxed);
    float compKnee = params_.compressionKnee.load(std::memory_order_relaxed);
    float compRatio = params_.compressionRatio.load(std::memory_order_relaxed);
    float prescribedGainDb = prescribedGainDb_.load(std::memory_order_relaxed);

    // Protección contra ratios inválidos
    if (expRatio < 1.0f) expRatio = 1.0f;
    if (compRatio < 1.0f) compRatio = 1.0f;

    // Clamp ganancia prescrita a rango seguro [0, 50] dB
    prescribedGainDb = std::max(0.0f, std::min(50.0f, prescribedGainDb));

    float effectiveGainDb = prescribedGainDb;

    if (inputLevelDb < expKnee) {
        // ─── Región 1: EXPANSIÓN ─────────────────────────────────────
        // Reduce la ganancia prescrita para señales por debajo del knee
        // de expansión. Esto atenúa ruido de fondo.
        // Cuanto más lejos del knee, más se reduce la ganancia.
        float belowKnee = expKnee - inputLevelDb;
        float reductionDb = belowKnee * (1.0f - 1.0f / expRatio);
        effectiveGainDb = prescribedGainDb - reductionDb;
        // Si la reducción supera la ganancia prescrita, atenuar por debajo
        // de unity (suprimir ruido de fondo)
        if (effectiveGainDb < -20.0f) effectiveGainDb = -20.0f;

    } else if (inputLevelDb > compKnee) {
        // ─── Región 3: COMPRESIÓN ────────────────────────────────────
        // Reduce la ganancia prescrita para señales fuertes.
        // Protege el oído de sonidos excesivos.
        float aboveKnee = inputLevelDb - compKnee;
        float reductionDb = aboveKnee * (1.0f - 1.0f / compRatio);
        effectiveGainDb = prescribedGainDb - reductionDb;
        // Mínimo 0 dB (unity) — nunca atenuar señales fuertes por debajo
        // del original, solo reducir la amplificación.
        if (effectiveGainDb < 0.0f) effectiveGainDb = 0.0f;
    }
    // Región 2 (lineal): effectiveGainDb = prescribedGainDb (sin cambio)

    // Convertir dB a factor lineal
    float gainFactor = std::pow(10.0f, effectiveGainDb / 20.0f);

    // Safety clamp
    return std::max(0.0f, std::min(kMaxGainFactor, gainFactor));
}

// ─────────────────────────────────────────────────────────────────────────────
// Actualización de parámetros (thread-safe)
// ─────────────────────────────────────────────────────────────────────────────

void WdrcProcessor::setExpansionKnee(float knee) {
    params_.expansionKnee.store(knee, std::memory_order_relaxed);
}

void WdrcProcessor::setExpansionRatio(float ratio) {
    params_.expansionRatio.store(ratio, std::memory_order_relaxed);
}

void WdrcProcessor::setCompressionKnee(float knee) {
    params_.compressionKnee.store(knee, std::memory_order_relaxed);
}

void WdrcProcessor::setCompressionRatio(float ratio) {
    params_.compressionRatio.store(ratio, std::memory_order_relaxed);
}

void WdrcProcessor::setAttackMs(float ms) {
    params_.attackMs.store(ms, std::memory_order_relaxed);
    updateCoefficients();
}

void WdrcProcessor::setReleaseMs(float ms) {
    params_.releaseMs.store(ms, std::memory_order_relaxed);
    updateCoefficients();
}

void WdrcProcessor::setPrescribedGainDb(float gainDb) {
    prescribedGainDb_.store(std::max(0.0f, std::min(50.0f, gainDb)),
                            std::memory_order_relaxed);
}

// ─────────────────────────────────────────────────────────────────────────────
// Headroom Guard (post-processing peak protection)
// ─────────────────────────────────────────────────────────────────────────────

void WdrcProcessor::applyHeadroomGuard(float* buffer, int blockSize) {
    if (buffer == nullptr || blockSize <= 0) {
        return;
    }

    float peak = 0.0f;
    for (int i = 0; i < blockSize; ++i) {
        float absVal = std::abs(buffer[i]);
        if (absVal > peak) {
            peak = absVal;
        }
    }

    static constexpr float kCeiling = 0.95f;
    if (peak > kCeiling) {
        float scale = kCeiling / peak;
        for (int i = 0; i < blockSize; ++i) {
            buffer[i] *= scale;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Funciones internas
// ─────────────────────────────────────────────────────────────────────────────

void WdrcProcessor::updateCoefficients() {
    float attackMs = params_.attackMs.load(std::memory_order_relaxed);
    float releaseMs = params_.releaseMs.load(std::memory_order_relaxed);

    if (attackMs <= 0.0f) attackMs = 5.0f;
    if (releaseMs <= 0.0f) releaseMs = 100.0f;

    float attackSamples = attackMs * static_cast<float>(sampleRate_) / 1000.0f;
    float releaseSamples = releaseMs * static_cast<float>(sampleRate_) / 1000.0f;

    attackCoeff_ = 1.0f - std::exp(-1.0f / attackSamples);
    releaseCoeff_ = 1.0f - std::exp(-1.0f / releaseSamples);
}

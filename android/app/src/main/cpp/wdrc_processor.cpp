/// @file wdrc_processor.cpp
/// @brief Implementación completa del WDRC con modelo de 3 regiones.
///
/// Modelo I/O de 3 regiones (estándar clínico):
///
///   Región 1 — Expansión (input < expansionKnee):
///     reductionDb = (expansionKnee - input) × (1 - 1/ER)
///     gainFactor = 10^(-reductionDb / 20)
///     Efecto: atenúa ruido de fondo progresivamente
///
///   Región 2 — Lineal (expansionKnee ≤ input ≤ compressionKnee):
///     gainFactor = 1.0
///     Efecto: pasa sin modificación (ganancia completa del EQ)
///
///   Región 3 — Compresión (input > compressionKnee):
///     reductionDb = (input - compressionKnee) × (1 - 1/CR)
///     gainFactor = 10^(-reductionDb / 20)
///     Efecto: protege de sonidos fuertes
///
/// Envelope detector (suavizado de ganancia muestra-por-muestra):
///   - Si targetGain < smoothedGain: attack (rápido, protege de picos)
///   - Si targetGain > smoothedGain: release (lento, evita pumping)
///
/// Coeficientes:
///   attackCoeff = 1 - exp(-1 / (attackMs × sampleRate / 1000))
///   releaseCoeff = 1 - exp(-1 / (releaseMs × sampleRate / 1000))

#include "wdrc_processor.h"

#include <algorithm>
#include <cmath>

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

    // 1. Calcular el factor de ganancia objetivo basado en el nivel PRE-EQ.
    //    La DECISIÓN de región usa el nivel del bloque completo (PRE-EQ).
    float targetGain = computeGainFactor(inputLevelDb);

    // 2. Leer coeficientes actuales (pueden cambiar entre bloques si el
    //    usuario actualiza attackMs/releaseMs desde el hilo de UI).
    float attack = attackCoeff_;
    float release = releaseCoeff_;

    // 3. Aplicar ganancia suavizada muestra-por-muestra.
    //    El envelope detector suaviza la transición entre el gain actual
    //    (smoothedGain_) y el gain objetivo (targetGain) para evitar
    //    discontinuidades audibles entre bloques.
    for (int i = 0; i < blockSize; ++i) {
        // Suavizado asimétrico: attack rápido, release lento
        if (targetGain < smoothedGain_) {
            // Ganancia bajando → attack (rápido, protege de picos)
            smoothedGain_ += attack * (targetGain - smoothedGain_);
        } else {
            // Ganancia subiendo → release (lento, evita pumping)
            smoothedGain_ += release * (targetGain - smoothedGain_);
        }

        // Clamp gainFactor a [0.0, 1.0] — WDRC nunca amplifica
        smoothedGain_ = std::max(0.0f, std::min(1.0f, smoothedGain_));

        // Aplicar ganancia a la muestra
        buffer[i] *= smoothedGain_;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Cálculo de ganancia por región (sin suavizado)
// ─────────────────────────────────────────────────────────────────────────────

float WdrcProcessor::computeGainFactor(float inputLevelDb) const {
    // Leer parámetros atómicos (thread-safe)
    float expKnee = params_.expansionKnee.load(std::memory_order_relaxed);
    float expRatio = params_.expansionRatio.load(std::memory_order_relaxed);
    WdrcCompressionParams cp = params_.compression.load(std::memory_order_relaxed);
    float compKnee  = cp.compressionKnee;
    float compRatio = cp.compressionRatio;

    // Protección contra ratios inválidos (evitar división por cero)
    if (expRatio < 1.0f) expRatio = 1.0f;
    if (compRatio < 1.0f) compRatio = 1.0f;

    if (inputLevelDb < expKnee) {
        // ─── Región 1: EXPANSIÓN ─────────────────────────────────────
        // Atenúa señales por debajo del knee de expansión.
        // Cuanto más lejos del knee, más atenuación.
        // Con ER=2:1, cada dB debajo del knee produce 0.5 dB de reducción.
        float belowKnee = expKnee - inputLevelDb;
        float reductionDb = belowKnee * (1.0f - 1.0f / expRatio);
        float gainFactor = std::pow(10.0f, -reductionDb / 20.0f);
        // Clamp a [0.0, 1.0]
        return std::max(0.0f, std::min(1.0f, gainFactor));

    } else if (inputLevelDb > compKnee) {
        // ─── Región 3: COMPRESIÓN ────────────────────────────────────
        // Atenúa señales por encima del knee de compresión.
        // Cuanto más lejos del knee, más atenuación.
        // Con CR=2:1, cada dB encima del knee produce 0.5 dB de reducción.
        float aboveKnee = inputLevelDb - compKnee;
        float reductionDb = aboveKnee * (1.0f - 1.0f / compRatio);
        float gainFactor = std::pow(10.0f, -reductionDb / 20.0f);
        // Clamp a [0.0, 1.0]
        return std::max(0.0f, std::min(1.0f, gainFactor));
    }

    // ─── Región 2: LINEAL ────────────────────────────────────────────
    // Entre los dos knees: ganancia unitaria (sin modificación).
    return 1.0f;
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

void WdrcProcessor::setCompressionParams(float knee, float ratio) {
    WdrcCompressionParams cp{ knee, ratio };
    params_.compression.store(cp, std::memory_order_relaxed);
}

void WdrcProcessor::setAttackMs(float ms) {
    params_.attackMs.store(ms, std::memory_order_relaxed);
    updateCoefficients();
}

void WdrcProcessor::setReleaseMs(float ms) {
    params_.releaseMs.store(ms, std::memory_order_relaxed);
    updateCoefficients();
}

// ─────────────────────────────────────────────────────────────────────────────
// Headroom Guard (post-EQ peak protection)
// ─────────────────────────────────────────────────────────────────────────────

void WdrcProcessor::applyHeadroomGuard(float* buffer, int blockSize) {
    if (buffer == nullptr || blockSize <= 0) {
        return;
    }

    // Scan for peak amplitude in the buffer
    float peak = 0.0f;
    for (int i = 0; i < blockSize; ++i) {
        float absVal = std::abs(buffer[i]);
        if (absVal > peak) {
            peak = absVal;
        }
    }

    // If peak exceeds ceiling, scale entire block to fit
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

    // Protección contra valores inválidos
    if (attackMs <= 0.0f) attackMs = 5.0f;
    if (releaseMs <= 0.0f) releaseMs = 100.0f;

    // Fórmula: coeff = 1 - exp(-1 / (timeMs * sampleRate / 1000))
    // Esto produce un filtro de primer orden con constante de tiempo = timeMs.
    // Después de ~3× timeMs, la señal alcanza ~95% del valor objetivo.
    float attackSamples = attackMs * static_cast<float>(sampleRate_) / 1000.0f;
    float releaseSamples = releaseMs * static_cast<float>(sampleRate_) / 1000.0f;

    attackCoeff_ = 1.0f - std::exp(-1.0f / attackSamples);
    releaseCoeff_ = 1.0f - std::exp(-1.0f / releaseSamples);
}

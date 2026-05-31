/// @file vad_detector.cpp
/// @brief Implementación VAD pitch-based (Springer 2019).
///
/// Validates: Requirements 2.1, 2.2, 2.3

#include "vad_detector.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace smart_scene {

VadDetector::VadDetector() = default;

void VadDetector::init(int sampleRate) {
    sampleRate_ = sampleRate;
    // lag = sampleRate / pitch  →  lag más grande = pitch más bajo.
    minLag_ = static_cast<int>(static_cast<float>(sampleRate_) / kPitchMaxHz);
    maxLag_ = static_cast<int>(static_cast<float>(sampleRate_) / kPitchMinHz);
    if (minLag_ < 1) minLag_ = 1;
    reset();
}

void VadDetector::reset() {
    smoothedScore_ = 0.0f;
    lastPitchStrength_ = 0.0f;
    voiceActive_ = false;
    samplesAccumulated_ = 0;
    std::fill(pitchBuffer_, pitchBuffer_ + kPitchBufferSize, 0.0f);
}

void VadDetector::process(const float* samples,
                          int numSamples,
                          float flatness,
                          float energyDbSpl) {
    if (samples == nullptr || numSamples <= 0) {
        return;
    }

    // Sanitizar entradas externas antes de combinarlas.
    if (!std::isfinite(flatness) || flatness < 0.0f) flatness = 0.0f;
    if (flatness > 1.0f) flatness = 1.0f;
    if (!std::isfinite(energyDbSpl)) energyDbSpl = 0.0f;

    // Acumular en ring buffer para que la autocorrelación tenga
    // suficiente longitud (≥ 2 períodos del pitch más bajo, ~600 samples
    // a 48 kHz para 80 Hz). El analyzer entrega bloques de 256 muestras.
    if (numSamples >= kPitchBufferSize) {
        // Bloque más grande que el buffer: copiamos solo los últimos N.
        std::memcpy(pitchBuffer_,
                    samples + (numSamples - kPitchBufferSize),
                    kPitchBufferSize * sizeof(float));
        samplesAccumulated_ = kPitchBufferSize;
    } else {
        // Shift left para hacer espacio.
        int keep = kPitchBufferSize - numSamples;
        std::memmove(pitchBuffer_, pitchBuffer_ + numSamples,
                     keep * sizeof(float));
        std::memcpy(pitchBuffer_ + keep, samples,
                    numSamples * sizeof(float));
        samplesAccumulated_ =
            std::min(samplesAccumulated_ + numSamples, kPitchBufferSize);
    }

    float pitchStrength = 0.0f;
    if (samplesAccumulated_ > maxLag_ + 1) {
        pitchStrength =
            computePitchStrength(pitchBuffer_, samplesAccumulated_);
    }
    if (!std::isfinite(pitchStrength)) pitchStrength = 0.0f;
    pitchStrength = std::clamp(pitchStrength, 0.0f, 1.0f);
    lastPitchStrength_ = pitchStrength;

    float energyNorm = normalizeEnergy(energyDbSpl);
    float tonality = 1.0f - flatness;     // ruido = 0, tono puro = 1

    float instantaneous =
        kWeightPitch    * pitchStrength +
        kWeightFlatness * tonality +
        kWeightEnergy   * energyNorm;

    instantaneous = std::clamp(instantaneous, 0.0f, 1.0f);

    // EMA con alpha=0.3 (Springer 2019).
    smoothedScore_ =
        kEmaAlpha * instantaneous + (1.0f - kEmaAlpha) * smoothedScore_;

    // Histéresis + gate por nivel mínimo: silencio fuerza voiceActive=false.
    if (energyDbSpl < kMinSpeechDbSpl) {
        voiceActive_ = false;
    } else if (voiceActive_) {
        voiceActive_ = smoothedScore_ > kVoiceThresholdLow;
    } else {
        voiceActive_ = smoothedScore_ > kVoiceThresholdHigh;
    }
}

float VadDetector::getConfidence() const {
    // Confianza = qué tan lejos está el score del threshold.
    // Score=0.5 → confidence ~ 0; Score=1 o 0 → confidence ~ 1.
    float dist = std::abs(smoothedScore_ - kVoiceThreshold) * 2.0f;
    return std::clamp(dist, 0.0f, 1.0f);
}

// ─────────────────────────────────────────────────────────────────────────────
// Pitch strength por autocorrelación normalizada
// ─────────────────────────────────────────────────────────────────────────────

float VadDetector::computePitchStrength(const float* samples,
                                        int numSamples) const {
    // Necesitamos al menos numSamples > maxLag_ para tener buena resolución.
    if (numSamples <= maxLag_ + 1) {
        return 0.0f;
    }

    // Normalizador R(0) — energía total.
    double r0 = 0.0;
    for (int i = 0; i < numSamples; ++i) {
        r0 += static_cast<double>(samples[i]) * samples[i];
    }
    if (r0 < 1e-9) return 0.0f;

    // Buscar el máximo R(lag) / R(0) en el rango pitch.
    double maxRatio = 0.0;
    for (int lag = minLag_; lag <= maxLag_; ++lag) {
        double rLag = 0.0;
        int n = numSamples - lag;
        for (int i = 0; i < n; ++i) {
            rLag += static_cast<double>(samples[i]) * samples[i + lag];
        }
        // Normalizar por R(0).
        double ratio = rLag / r0;
        if (ratio > maxRatio) {
            maxRatio = ratio;
        }
    }

    // ratio puede ser ligeramente negativo o > 1 por discretización; clamp.
    if (maxRatio < 0.0) maxRatio = 0.0;
    if (maxRatio > 1.0) maxRatio = 1.0;
    return static_cast<float>(maxRatio);
}

// ─────────────────────────────────────────────────────────────────────────────
// Energía normalizada
// ─────────────────────────────────────────────────────────────────────────────

float VadDetector::normalizeEnergy(float dbSpl) {
    // Mapea [30, 80] dB SPL a [0, 1] linealmente, clampea fuera del rango.
    constexpr float kLow = 30.0f;
    constexpr float kHigh = 80.0f;
    if (dbSpl <= kLow) return 0.0f;
    if (dbSpl >= kHigh) return 1.0f;
    return (dbSpl - kLow) / (kHigh - kLow);
}

} // namespace smart_scene

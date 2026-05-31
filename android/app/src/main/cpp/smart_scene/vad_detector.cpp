/// @file vad_detector.cpp
/// @brief Implementación del VAD híbrido robusto.
///
/// Ver vad_detector.h y Amplificador/.kiro/specs/smart-scene-engine/vad-redesign.md
/// para la justificación de cada feature, los pesos y los gates.
///
/// Validates: Requirements 2.1, 2.2, 2.3.

#include "vad_detector.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace smart_scene {

// ─────────────────────────────────────────────────────────────────────────────
// Construcción / init
// ─────────────────────────────────────────────────────────────────────────────

VadDetector::VadDetector() = default;

void VadDetector::init(int sampleRate) {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000;
    // lag = sampleRate / pitch  →  lag más grande = pitch más bajo.
    minLag_ = static_cast<int>(static_cast<float>(sampleRate_) / kPitchMaxHz);
    maxLag_ = static_cast<int>(static_cast<float>(sampleRate_) / kPitchMinHz);
    if (minLag_ < 1) minLag_ = 1;
    // Garantizar que el buffer es suficiente para la ventana de pitch.
    if (maxLag_ >= kPitchBufferSize - 32) {
        maxLag_ = kPitchBufferSize - 32;
    }
    reset();
}

void VadDetector::reset() {
    samplesAccumulated_ = 0;
    hpfXPrev_           = 0.0f;
    hpfYPrev_           = 0.0f;
    std::fill(pitchBuffer_, pitchBuffer_ + kPitchBufferSize, 0.0f);

    for (int b = 0; b < kSceneNumBands; ++b) {
        xiPrev_[b] = 0.0f;
        for (int i = 0; i < kLtsdWindow; ++i) ltsdHistory_[i][b] = -90.0f;
        for (int i = 0; i < kStatWindow; ++i) statHistory_[i][b] = -90.0f;
    }
    ltsdIdx_ = 0;
    ltsdFill_ = 0;
    statIdx_ = 0;
    statFill_ = 0;

    smoothedScore_  = 0.0f;
    pitchStrength_  = 0.0f;
    lrtScore_       = 0.0f;
    midSnrDb_       = 0.0f;
    ltsdDb_         = 0.0f;
    stationarity_   = 0.0f;
    hangover_       = 0;
    voiceActive_    = false;
    hangoverActive_ = false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Pipeline principal
// ─────────────────────────────────────────────────────────────────────────────

void VadDetector::process(const float* samples,
                          int numSamples,
                          const float bandEnergyDb[kSceneNumBands],
                          const float noiseFloorDb[kSceneNumBands],
                          float flatness,
                          float energyDbSpl) {
    (void)flatness; // mantenido en la firma por compatibilidad histórica.
    if (samples == nullptr || numSamples <= 0 ||
        bandEnergyDb == nullptr || noiseFloorDb == nullptr) {
        return;
    }
    if (!std::isfinite(energyDbSpl)) energyDbSpl = 0.0f;

    // 1) Acumular muestras con HPF para matar DC + hum.
    pushSamplesWithHpf(samples, numSamples);

    // 2) Pitch strength sobre el buffer ya pre-blanqueado.
    pitchStrength_ = (samplesAccumulated_ > maxLag_ + 1)
                         ? computePitchStrength()
                         : 0.0f;
    if (!std::isfinite(pitchStrength_)) pitchStrength_ = 0.0f;
    pitchStrength_ = std::clamp(pitchStrength_, 0.0f, 1.0f);

    // 3) Decision-directed a-priori SNR.
    updateAprioriSnr(bandEnergyDb, noiseFloorDb);

    // 4) LRT promediado en bandas vocales.
    lrtScore_ = computeLrt(bandEnergyDb, noiseFloorDb);

    // 5) Mid-band SNR.
    midSnrDb_ = computeMidSnrDb(bandEnergyDb, noiseFloorDb);

    // 6) LTSD ventana 8 frames.
    pushLtsdHistory(bandEnergyDb);
    ltsdDb_ = computeLtsdDb(noiseFloorDb);

    // 7) Noise stationarity.
    pushStatHistory(bandEnergyDb);
    stationarity_ = computeStationarity();

    // 8) Combinar (todas las features están en escalas comparables tras
    //    su normalización).
    const float lrtNorm  = sigmoid((lrtScore_ - 0.5f) / 1.5f);
    const float msnrNorm = std::clamp((midSnrDb_ - 3.0f) / 12.0f, 0.0f, 1.0f);
    const float ltsdNorm = std::clamp((ltsdDb_ - 8.0f) / 12.0f, 0.0f, 1.0f);
    const float pitchNorm = pitchStrength_;

    float instantaneous = kWeightLrt    * lrtNorm
                        + kWeightPitch  * pitchNorm
                        + kWeightMidSnr * msnrNorm
                        + kWeightLtsd   * ltsdNorm;
    instantaneous = std::clamp(instantaneous, 0.0f, 1.0f);

    // 9) EMA suavizado.
    smoothedScore_ = kEmaAlpha * instantaneous +
                     (1.0f - kEmaAlpha) * smoothedScore_;

    // 10) Decisión con gates + histéresis + hangover.
    if (energyDbSpl < kMinSpeechDbSpl) {
        // Gate 1: silencio absoluto.
        voiceActive_   = false;
        hangover_      = 0;
        hangoverActive_ = false;
    } else if (stationarity_ > kStationarityGate &&
               midSnrDb_ < kMidSnrGateDb) {
        // Gate 2: ruido continuo dominante (ventilador, AC, motores).
        // Aunque el LRT instantáneo sea alto por algún transitorio, si
        // el espectro vocal lleva 32 frames sin moverse y el SNR mid
        // está por debajo de 4 dB, no hay voz humana.
        voiceActive_   = false;
        hangover_      = 0;
        hangoverActive_ = false;
    } else if (voiceActive_) {
        if (smoothedScore_ > kVoiceThresholdLow) {
            voiceActive_   = true;
            hangoverActive_ = false;
        } else if (hangover_ > 0) {
            voiceActive_   = true;
            hangoverActive_ = true;
            --hangover_;
        } else {
            voiceActive_   = false;
            hangoverActive_ = false;
        }
    } else {
        if (smoothedScore_ > kVoiceThresholdHigh) {
            voiceActive_   = true;
            hangover_      = kHangoverFrames;
            hangoverActive_ = false;
        } else {
            voiceActive_   = false;
            hangoverActive_ = false;
        }
    }
}

float VadDetector::getConfidence() const {
    // Confianza = qué tan lejos está el score del 0.5 central.
    // Score = 0.5 → confidence ~ 0; score = 0 ó 1 → confidence ~ 1.
    float dist = std::abs(smoothedScore_ - 0.5f) * 2.0f;
    return std::clamp(dist, 0.0f, 1.0f);
}

// ─────────────────────────────────────────────────────────────────────────────
// Push de samples con HPF de primer orden
// ─────────────────────────────────────────────────────────────────────────────

void VadDetector::pushSamplesWithHpf(const float* samples, int numSamples) {
    // y[n] = a*(y[n-1] + x[n] - x[n-1])
    const float a = kHpfCoeff;

    if (numSamples >= kPitchBufferSize) {
        // Bloque más grande que el buffer: aplicamos HPF a los últimos N
        // y reemplazamos todo el contenido. Inicializamos prev con el
        // primer sample del segmento que entra.
        const int start = numSamples - kPitchBufferSize;
        float xPrev = samples[start];
        float yPrev = 0.0f;
        for (int i = 0; i < kPitchBufferSize; ++i) {
            const float x = samples[start + i];
            const float y = a * (yPrev + x - xPrev);
            pitchBuffer_[i] = y;
            xPrev = x;
            yPrev = y;
        }
        hpfXPrev_ = xPrev;
        hpfYPrev_ = yPrev;
        samplesAccumulated_ = kPitchBufferSize;
        return;
    }

    // Caso normal: shift left y append con HPF aplicado.
    const int keep = kPitchBufferSize - numSamples;
    std::memmove(pitchBuffer_, pitchBuffer_ + numSamples,
                 keep * sizeof(float));
    for (int i = 0; i < numSamples; ++i) {
        const float x = samples[i];
        const float y = a * (hpfYPrev_ + x - hpfXPrev_);
        pitchBuffer_[keep + i] = y;
        hpfXPrev_ = x;
        hpfYPrev_ = y;
    }
    samplesAccumulated_ =
        std::min(samplesAccumulated_ + numSamples, kPitchBufferSize);
}

// ─────────────────────────────────────────────────────────────────────────────
// Pitch strength (autocorrelación normalizada sobre buffer pre-blanqueado)
// ─────────────────────────────────────────────────────────────────────────────

float VadDetector::computePitchStrength() const {
    const int n = samplesAccumulated_;
    if (n <= maxLag_ + 1) return 0.0f;

    // R(0): energía total del segmento blanqueado.
    double r0 = 0.0;
    for (int i = 0; i < n; ++i) {
        r0 += static_cast<double>(pitchBuffer_[i]) * pitchBuffer_[i];
    }
    if (r0 < 1e-9) return 0.0f;

    double maxRatio = 0.0;
    for (int lag = minLag_; lag <= maxLag_; ++lag) {
        double rLag = 0.0;
        const int m = n - lag;
        for (int i = 0; i < m; ++i) {
            rLag += static_cast<double>(pitchBuffer_[i]) *
                    pitchBuffer_[i + lag];
        }
        const double ratio = rLag / r0;
        if (ratio > maxRatio) maxRatio = ratio;
    }

    if (maxRatio < 0.0) maxRatio = 0.0;
    if (maxRatio > 1.0) maxRatio = 1.0;
    return static_cast<float>(maxRatio);
}

// ─────────────────────────────────────────────────────────────────────────────
// A-priori SNR decision-directed (Ephraim-Malah / Sohn)
// ─────────────────────────────────────────────────────────────────────────────

void VadDetector::updateAprioriSnr(const float bandEnergyDb[kSceneNumBands],
                                   const float noiseFloorDb[kSceneNumBands]) {
    for (int b = 0; b < kSceneNumBands; ++b) {
        float postDb = bandEnergyDb[b] - noiseFloorDb[b];
        if (!std::isfinite(postDb)) postDb = 0.0f;
        if (postDb < 0.0f) postDb = 0.0f;
        // Convertir a γ a posteriori lineal: γ = 10^(postDb/10).
        const float gammaLin = std::pow(10.0f, postDb * 0.1f);
        const float instant  = std::max(0.0f, gammaLin - 1.0f);
        // Decision-directed update (Ephraim-Malah).
        xiPrev_[b] = kAlphaDD * xiPrev_[b] + (1.0f - kAlphaDD) * instant;
        if (!std::isfinite(xiPrev_[b]) || xiPrev_[b] < 0.0f) {
            xiPrev_[b] = 0.0f;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// LRT estilo Sohn 1999 simplificado, promediado en bandas vocales
// ─────────────────────────────────────────────────────────────────────────────

float VadDetector::computeLrt(const float bandEnergyDb[kSceneNumBands],
                              const float noiseFloorDb[kSceneNumBands]) const {
    // Λ_b = (xi/(1+xi)) * gamma_lin - log(1 + xi)
    // donde gamma es γ a posteriori. Promediado sobre [kBandLrtLo, kBandLrtHi].
    double sum = 0.0;
    int count = 0;
    for (int b = kBandLrtLo; b <= kBandLrtHi && b < kSceneNumBands; ++b) {
        const float xi = xiPrev_[b];
        float postDb = bandEnergyDb[b] - noiseFloorDb[b];
        if (!std::isfinite(postDb)) postDb = 0.0f;
        if (postDb < 0.0f) postDb = 0.0f;
        const float gammaLin = std::pow(10.0f, postDb * 0.1f);
        const float lambdaB =
            (xi / (1.0f + xi + 1e-9f)) * gammaLin - std::log1p(xi);
        if (std::isfinite(lambdaB)) {
            sum += static_cast<double>(lambdaB);
            ++count;
        }
    }
    if (count == 0) return 0.0f;
    return static_cast<float>(sum / count);
}

// ─────────────────────────────────────────────────────────────────────────────
// Mid-band SNR (1.1-5.5 kHz)
// ─────────────────────────────────────────────────────────────────────────────

float VadDetector::computeMidSnrDb(const float bandEnergyDb[kSceneNumBands],
                                   const float noiseFloorDb[kSceneNumBands])
    const {
    double sum = 0.0;
    int count = 0;
    for (int b = kBandMidLo; b <= kBandMidHi && b < kSceneNumBands; ++b) {
        float diff = bandEnergyDb[b] - noiseFloorDb[b];
        if (!std::isfinite(diff)) diff = 0.0f;
        sum += static_cast<double>(diff);
        ++count;
    }
    if (count == 0) return 0.0f;
    return static_cast<float>(sum / count);
}

// ─────────────────────────────────────────────────────────────────────────────
// LTSD (Ramirez 2004): pico sobre ventana - piso de ruido
// ─────────────────────────────────────────────────────────────────────────────

void VadDetector::pushLtsdHistory(const float bandEnergyDb[kSceneNumBands]) {
    for (int b = 0; b < kSceneNumBands; ++b) {
        float v = bandEnergyDb[b];
        if (!std::isfinite(v)) v = -90.0f;
        ltsdHistory_[ltsdIdx_][b] = v;
    }
    ltsdIdx_ = (ltsdIdx_ + 1) % kLtsdWindow;
    if (ltsdFill_ < kLtsdWindow) ++ltsdFill_;
}

float VadDetector::computeLtsdDb(const float noiseFloorDb[kSceneNumBands])
    const {
    if (ltsdFill_ == 0) return 0.0f;
    double sum = 0.0;
    int count = 0;
    for (int b = kBandLrtLo; b <= kBandLrtHi && b < kSceneNumBands; ++b) {
        float peak = ltsdHistory_[0][b];
        for (int i = 1; i < ltsdFill_; ++i) {
            if (ltsdHistory_[i][b] > peak) peak = ltsdHistory_[i][b];
        }
        float diff = peak - noiseFloorDb[b];
        if (!std::isfinite(diff)) diff = 0.0f;
        sum += static_cast<double>(diff);
        ++count;
    }
    if (count == 0) return 0.0f;
    return static_cast<float>(sum / count);
}

// ─────────────────────────────────────────────────────────────────────────────
// Noise stationarity (varianza temporal en bandas vocales)
// ─────────────────────────────────────────────────────────────────────────────

void VadDetector::pushStatHistory(const float bandEnergyDb[kSceneNumBands]) {
    for (int b = 0; b < kSceneNumBands; ++b) {
        float v = bandEnergyDb[b];
        if (!std::isfinite(v)) v = -90.0f;
        statHistory_[statIdx_][b] = v;
    }
    statIdx_ = (statIdx_ + 1) % kStatWindow;
    if (statFill_ < kStatWindow) ++statFill_;
}

float VadDetector::computeStationarity() const {
    // Necesitamos suficientes frames para que la varianza tenga sentido.
    if (statFill_ < kStatWindow / 2) return 0.0f;

    double sumVar = 0.0;
    int count = 0;
    for (int b = kBandLrtLo; b <= kBandLrtHi && b < kSceneNumBands; ++b) {
        // Media.
        double mean = 0.0;
        for (int i = 0; i < statFill_; ++i) {
            mean += static_cast<double>(statHistory_[i][b]);
        }
        mean /= statFill_;
        // Varianza poblacional.
        double var = 0.0;
        for (int i = 0; i < statFill_; ++i) {
            const double d = statHistory_[i][b] - mean;
            var += d * d;
        }
        var /= statFill_;
        sumVar += var;
        ++count;
    }
    if (count == 0) return 0.0f;
    const double meanVar = sumVar / count;
    // Mapeo: var = 0 (idéntico) → station = 1.
    //        var = 50 dB² (típico voz natural) → station = 0.
    double s = 1.0 - (meanVar / 50.0);
    if (s < 0.0) s = 0.0;
    if (s > 1.0) s = 1.0;
    return static_cast<float>(s);
}

// ─────────────────────────────────────────────────────────────────────────────
// Sigmoid utility
// ─────────────────────────────────────────────────────────────────────────────

float VadDetector::sigmoid(float x) {
    // Saturar para evitar exp() de números enormes.
    if (x >  20.0f) return 1.0f;
    if (x < -20.0f) return 0.0f;
    return 1.0f / (1.0f + std::exp(-x));
}

} // namespace smart_scene

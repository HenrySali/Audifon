/// @file transient_reducer.cpp
/// @brief Implementación del TNR multi-banda profesional.

#include "transient_reducer.h"
#include <cmath>
#include <algorithm>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// Frecuencias de crossover (Linkwitz-Riley 4th order)
// Banda 0: 0-500 Hz (graves - rumble, golpes de puertas)
// Banda 1: 500-2000 Hz (medios bajos - vocales, timbre de subte)
// Banda 2: 2000-5000 Hz (medios altos - consonantes, bocinas)
// Banda 3: 5000+ Hz (agudos - fricativas, keys jingling)
static constexpr float kCrossoverFreqs[3] = {500.0f, 2000.0f, 5000.0f};

void TransientReducer::init(int sampleRate) {
    sampleRate_ = sampleRate;

    // Coeficientes de envelope detection
    // Fast envelope: ~1ms (peak tracking instantáneo)
    fastCoeff_ = 1.0f - std::exp(-1.0f / (0.001f * sampleRate));
    
    // Slow envelope: ~100ms (RMS background)
    slowCoeff_ = 1.0f - std::exp(-1.0f / (0.100f * sampleRate));
    
    // Smooth gating (elimina "tktktkt")
    // Attack: 15 ms (rise moderado)
    attackCoeff_ = 1.0f - std::exp(-1.0f / (0.015f * sampleRate));
    // Release: 80 ms (fade suave)
    releaseCoeff_ = 1.0f - std::exp(-1.0f / (0.080f * sampleRate));
    
    // Hold time: 20ms
    holdSamples_ = static_cast<int>(0.020f * sampleRate);

    // Calcular coeficientes de crossover (Linkwitz-Riley 4th order)
    // Banda 0: Lowpass @ 500 Hz (2× cascaded)
    crossoverCoeffs_[0][0] = computeCrossoverCoeffs(kCrossoverFreqs[0], sampleRate, true);
    crossoverCoeffs_[0][1] = computeCrossoverCoeffs(kCrossoverFreqs[0], sampleRate, true);
    
    // Banda 1: Bandpass 500-2000 Hz = (HP @ 500) × (LP @ 2000)
    crossoverCoeffs_[1][0] = computeCrossoverCoeffs(kCrossoverFreqs[0], sampleRate, false); // HP 500
    crossoverCoeffs_[1][1] = computeCrossoverCoeffs(kCrossoverFreqs[1], sampleRate, true);  // LP 2000
    
    // Banda 2: Bandpass 2000-5000 Hz = (HP @ 2000) × (LP @ 5000)
    crossoverCoeffs_[2][0] = computeCrossoverCoeffs(kCrossoverFreqs[1], sampleRate, false); // HP 2000
    crossoverCoeffs_[2][1] = computeCrossoverCoeffs(kCrossoverFreqs[2], sampleRate, true);  // LP 5000
    
    // Banda 3: Highpass @ 5000 Hz (2× cascaded)
    crossoverCoeffs_[3][0] = computeCrossoverCoeffs(kCrossoverFreqs[2], sampleRate, false);
    crossoverCoeffs_[3][1] = computeCrossoverCoeffs(kCrossoverFreqs[2], sampleRate, false);

    // Reset estado
    for (int b = 0; b < kTnrBands; ++b) {
        bandStates_[b] = BandState{};
        bandGains_[b] = 1.0f;
        for (int stage = 0; stage < 2; ++stage) {
            crossoverStates_[b][stage] = CrossoverState{};
        }
    }
}

void TransientReducer::process(float* buffer, int blockSize) {
    if (!enabled_.load(std::memory_order_relaxed)) return;
    if (buffer == nullptr || blockSize <= 0) return;

    // Leer parámetros configurables
    float threshold = thresholdRatio_.load(std::memory_order_relaxed);
    float attenuation = attenuationLinear_.load(std::memory_order_relaxed);

    // Buffers temporales por banda
    float bandBuffers[kTnrBands][256]; // Asume blockSize <= 256
    if (blockSize > 256) blockSize = 256;

    // Paso 1: Dividir señal en bandas con crossover
    for (int i = 0; i < blockSize; ++i) {
        float sample = buffer[i];
        
        for (int b = 0; b < kTnrBands; ++b) {
            // Aplicar 2 etapas de filtro cascaded (Linkwitz-Riley 4th order)
            float filtered = applyBiquad(sample, crossoverCoeffs_[b][0], crossoverStates_[b][0]);
            filtered = applyBiquad(filtered, crossoverCoeffs_[b][1], crossoverStates_[b][1]);
            bandBuffers[b][i] = filtered;
        }
    }

    // Paso 2: Detectar transientes y calcular ganancia POR BANDA
    for (int b = 0; b < kTnrBands; ++b) {
        BandState& state = bandStates_[b];
        
        for (int i = 0; i < blockSize; ++i) {
            float absSample = std::fabs(bandBuffers[b][i]);

            // Actualizar envelopes
            state.fastEnv += fastCoeff_ * (absSample - state.fastEnv);
            state.slowEnv += slowCoeff_ * (absSample - state.slowEnv);

            float safeSlowEnv = std::fmax(state.slowEnv, 1e-6f);
            float ratio = state.fastEnv / safeSlowEnv;

            // Detección de transitorio
            float targetGain = 1.0f;
            if (ratio > threshold) {
                // Transitorio detectado - atenuación proporcional
                float excess = ratio / threshold;
                targetGain = 1.0f / excess;
                if (targetGain < attenuation) {
                    targetGain = attenuation;
                }
                state.holdCounter = holdSamples_;
            } else if (state.holdCounter > 0) {
                state.holdCounter--;
                targetGain = state.smoothGain; // Mantener
            }

            // Smooth gating (elimina "tktktkt")
            float coeff = (targetGain < state.smoothGain) ? attackCoeff_ : releaseCoeff_;
            state.smoothGain += coeff * (targetGain - state.smoothGain);
            
            // Clamp
            if (state.smoothGain < attenuation) state.smoothGain = attenuation;
            if (state.smoothGain > 1.0f) state.smoothGain = 1.0f;

            // Aplicar ganancia a la banda
            bandBuffers[b][i] *= state.smoothGain;
        }

        bandGains_[b] = state.smoothGain; // Para diagnóstico
    }

    // Paso 3: Recombinar bandas (suma simple - Linkwitz-Riley suma plana)
    for (int i = 0; i < blockSize; ++i) {
        float output = 0.0f;
        for (int b = 0; b < kTnrBands; ++b) {
            output += bandBuffers[b][i];
        }
        buffer[i] = output;
    }
}

TransientReducer::BiquadCoeffs TransientReducer::computeCrossoverCoeffs(
    float centerFreq, int sampleRate, bool isLowPass) {
    
    BiquadCoeffs coeffs;
    float omega = 2.0f * M_PI * centerFreq / sampleRate;
    float cosOmega = std::cos(omega);
    float sinOmega = std::sin(omega);
    float Q = 0.707f; // Butterworth (Linkwitz-Riley usa Q=0.707 para suma plana)
    float alpha = sinOmega / (2.0f * Q);

    if (isLowPass) {
        // Lowpass biquad
        float b0 = (1.0f - cosOmega) / 2.0f;
        float b1 = 1.0f - cosOmega;
        float b2 = (1.0f - cosOmega) / 2.0f;
        float a0 = 1.0f + alpha;
        float a1 = -2.0f * cosOmega;
        float a2 = 1.0f - alpha;

        coeffs.b0 = b0 / a0;
        coeffs.b1 = b1 / a0;
        coeffs.b2 = b2 / a0;
        coeffs.a1 = a1 / a0;
        coeffs.a2 = a2 / a0;
    } else {
        // Highpass biquad
        float b0 = (1.0f + cosOmega) / 2.0f;
        float b1 = -(1.0f + cosOmega);
        float b2 = (1.0f + cosOmega) / 2.0f;
        float a0 = 1.0f + alpha;
        float a1 = -2.0f * cosOmega;
        float a2 = 1.0f - alpha;

        coeffs.b0 = b0 / a0;
        coeffs.b1 = b1 / a0;
        coeffs.b2 = b2 / a0;
        coeffs.a1 = a1 / a0;
        coeffs.a2 = a2 / a0;
    }

    return coeffs;
}

float TransientReducer::applyBiquad(float input, const BiquadCoeffs& coeffs, CrossoverState& state) {
    float output = coeffs.b0 * input + coeffs.b1 * state.x1 + coeffs.b2 * state.x2
                 - coeffs.a1 * state.y1 - coeffs.a2 * state.y2;
    
    state.x2 = state.x1;
    state.x1 = input;
    state.y2 = state.y1;
    state.y1 = output;
    
    return output;
}

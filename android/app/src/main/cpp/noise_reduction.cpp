/// @file noise_reduction.cpp
/// @brief Implementación de reducción de ruido basada en filtrado de Wiener (8 sub-bandas).
///
/// Algoritmo:
/// 1. Para cada sub-banda, filtrar la señal con un bandpass biquad de 2° orden
/// 2. Estimar potencia de señal y ruido por sub-banda con promedio exponencial
/// 3. Calcular ganancia Wiener: G = max(1 - noise_power/signal_power, gain_floor)
/// 4. Aplicar ganancia ponderada al buffer original
///
/// La estimación de ruido se actualiza lentamente (alpha = 0.02) y solo cuando
/// la señal está cerca del piso de ruido. Esto permite que el NR se adapte
/// al ruido de fondo sin afectar la señal de habla.
///
/// Restricciones:
/// - NR solo atenúa: ganancia por sub-banda siempre ≤ 1.0
/// - Piso de ganancia preserva consonantes: nunca elimina completamente una banda
/// - Eficiente para tiempo real en móvil (sin FFT, solo filtros IIR simples)

#include "noise_reduction.h"

#include <cmath>
#include <algorithm>
#include <cstring>

// ─────────────────────────────────────────────────────────────────────────────
// Constantes internas
// ─────────────────────────────────────────────────────────────────────────────

/// Frecuencias centrales de las 8 sub-bandas (Hz).
/// Cada banda cubre 1000 Hz: [0-1000], [1000-2000], ..., [7000-8000]
static constexpr float kBandCenterFreqs[kNrSubBands] = {
    500.0f,   // Banda 0: 0-1000 Hz
    1500.0f,  // Banda 1: 1000-2000 Hz
    2500.0f,  // Banda 2: 2000-3000 Hz
    3500.0f,  // Banda 3: 3000-4000 Hz
    4500.0f,  // Banda 4: 4000-5000 Hz
    5500.0f,  // Banda 5: 5000-6000 Hz
    6500.0f,  // Banda 6: 6000-7000 Hz
    7500.0f,  // Banda 7: 7000-8000 Hz
};

/// Pisos de ganancia por nivel de NR.
/// Nivel 0 = off (1.0 = pass-through)
/// Nivel 1 = bajo (0.5 = -6 dB máx atenuación)
/// Nivel 2 = medio (0.3 = -10 dB máx atenuación)
/// Nivel 3 = alto (0.18 = -15 dB máx atenuación)
static constexpr float kGainFloors[4] = {
    1.0f,   // Off — no atenúa nada
    0.5f,   // Bajo — preserva más señal
    0.3f,   // Medio — balance
    0.18f,  // Alto — máxima reducción de ruido
};

// ─────────────────────────────────────────────────────────────────────────────
// Constructor
// ─────────────────────────────────────────────────────────────────────────────

NoiseReduction::NoiseReduction() {
    // Inicializar coeficientes de filtro bandpass para cada sub-banda
    for (int i = 0; i < kNrSubBands; ++i) {
        bandCoeffs_[i] = computeBandpassCoeffs(
            kBandCenterFreqs[i],
            kNrBandWidthHz,
            static_cast<float>(kNrSampleRate)
        );
    }

    // Inicializar estado
    reset();
}

// ─────────────────────────────────────────────────────────────────────────────
// Reset
// ─────────────────────────────────────────────────────────────────────────────

void NoiseReduction::reset() {
    for (int i = 0; i < kNrSubBands; ++i) {
        bandStates_[i] = BiquadState{};
        noisePower_[i] = kMinPower;
        signalPower_[i] = kMinPower;
    }
    prevGain_ = 1.0f;
}

// ─────────────────────────────────────────────────────────────────────────────
// Procesamiento principal
// ─────────────────────────────────────────────────────────────────────────────

void NoiseReduction::process(float* buffer, int blockSize) {
    if (buffer == nullptr || blockSize <= 0) {
        return;
    }

    // Si NR está desactivado (nivel 0), pass-through sin modificar
    int currentLevel = level_.load(std::memory_order_relaxed);
    if (currentLevel == 0) {
        return;
    }

    // Obtener piso de ganancia para el nivel actual
    float gainFloor = getGainFloor();

    // --- Paso 1: Estimar potencia de señal por sub-banda ---
    // Filtrar el bloque completo por cada sub-banda y calcular energía
    float bandEnergy[kNrSubBands] = {};

    for (int band = 0; band < kNrSubBands; ++band) {
        float energy = 0.0f;
        // Copiar estado del filtro para no modificar el estado principal
        // durante la estimación (usamos el estado principal directamente
        // ya que se actualiza bloque a bloque)
        for (int i = 0; i < blockSize; ++i) {
            float filtered = applyBiquad(buffer[i], bandCoeffs_[band],
                                         bandStates_[band]);
            energy += filtered * filtered;
        }
        // Energía promedio por muestra en esta banda
        bandEnergy[band] = energy / static_cast<float>(blockSize);
    }

    // --- Paso 2: Actualizar estimaciones de potencia de señal y ruido ---
    float gains[kNrSubBands];

    for (int band = 0; band < kNrSubBands; ++band) {
        float currentEnergy = std::max(bandEnergy[band], kMinPower);

        // Actualizar potencia de señal (suavizado rápido)
        signalPower_[band] += kSignalAlpha * (currentEnergy - signalPower_[band]);

        // Actualizar estimación de ruido solo cuando la señal está cerca
        // del piso de ruido (no hay habla presente en esta banda)
        float snrEstimate = signalPower_[band] / std::max(noisePower_[band], kMinPower);

        if (snrEstimate < kSignalPresenceThreshold) {
            // No hay señal significativa — actualizar estimación de ruido
            noisePower_[band] += kNoiseAlpha * (currentEnergy - noisePower_[band]);
        } else {
            // Hay señal presente — actualizar ruido muy lentamente
            // (para adaptarse a cambios graduales del ruido de fondo)
            noisePower_[band] += (kNoiseAlpha * 0.1f) * (currentEnergy - noisePower_[band]);
        }

        // Asegurar que la estimación de ruido no exceda la señal
        noisePower_[band] = std::min(noisePower_[band], signalPower_[band]);

        // --- Paso 3: Calcular ganancia Wiener ---
        // G = max(1 - noise_power / signal_power, gain_floor)
        float wienerGain = 1.0f - (noisePower_[band] / std::max(signalPower_[band], kMinPower));

        // Aplicar piso de ganancia (preserva consonantes)
        wienerGain = std::max(wienerGain, gainFloor);

        // NR solo atenúa — ganancia nunca > 1.0
        wienerGain = std::min(wienerGain, 1.0f);

        gains[band] = wienerGain;
    }

    // --- Paso 4: Aplicar ganancias al buffer original ---
    // Usamos una ponderación por sub-banda basada en la contribución
    // de energía de cada banda a la señal total.
    // Enfoque simplificado: calcular ganancia compuesta como promedio
    // ponderado por energía de las ganancias por sub-banda.

    float totalEnergy = 0.0f;
    for (int band = 0; band < kNrSubBands; ++band) {
        totalEnergy += bandEnergy[band];
    }

    if (totalEnergy < kMinPower) {
        // Señal en silencio total — no modificar
        return;
    }

    // Para cada muestra, calcular la ganancia compuesta basada en la
    // contribución de cada sub-banda. Como no tenemos la descomposición
    // muestra-por-muestra sin FFT, usamos la ganancia promedio ponderada
    // por energía del bloque (block-rate NR, que es aceptable para NR
    // según el diseño — NR puede operar a block-rate).
    float compositeGain = 0.0f;
    for (int band = 0; band < kNrSubBands; ++band) {
        float weight = bandEnergy[band] / totalEnergy;
        compositeGain += weight * gains[band];
    }

    // Asegurar restricciones finales
    compositeGain = std::max(compositeGain, gainFloor);
    compositeGain = std::min(compositeGain, 1.0f);

    // Suavizado temporal: attack rápido (ruido aparece), release lento (ruido desaparece)
    // Esto evita clicks y transiciones abruptas entre bloques.
    if (compositeGain < prevGain_) {
        // Attack: ruido detectado → atenuar rápido (~5ms)
        compositeGain = prevGain_ + 0.4f * (compositeGain - prevGain_);
    } else {
        // Release: ruido desaparece → restaurar lento (~50ms)
        compositeGain = prevGain_ + 0.1f * (compositeGain - prevGain_);
    }
    prevGain_ = compositeGain;

    // Aplicar ganancia compuesta al buffer
    for (int i = 0; i < blockSize; ++i) {
        buffer[i] *= compositeGain;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Funciones auxiliares
// ─────────────────────────────────────────────────────────────────────────────

float NoiseReduction::getGainFloor() const {
    int level = level_.load(std::memory_order_relaxed);
    // Clamp al rango válido [0, 3]
    level = std::max(0, std::min(3, level));
    return kGainFloors[level];
}

NoiseReduction::BiquadCoeffs NoiseReduction::computeBandpassCoeffs(
    float centerFreq, float bandwidth, float sampleRate) {

    // Diseño de filtro bandpass biquad (tipo RBJ Audio EQ Cookbook)
    // Referencia: Robert Bristow-Johnson's Audio EQ Cookbook
    const float w0 = 2.0f * static_cast<float>(M_PI) * centerFreq / sampleRate;
    const float cosW0 = std::cos(w0);
    const float sinW0 = std::sin(w0);

    // Q calculado a partir del ancho de banda
    // BW = bandwidth / centerFreq para Q constante
    // alpha = sin(w0) * sinh(ln(2)/2 * BW * w0/sin(w0))
    // Simplificación: alpha = sin(w0) / (2 * Q)
    // donde Q = centerFreq / bandwidth
    float Q = centerFreq / bandwidth;
    // Q mínimo para estabilidad
    Q = std::max(Q, 0.3f);
    float alpha = sinW0 / (2.0f * Q);

    // Coeficientes bandpass (peak gain = Q)
    // Normalizamos para ganancia unitaria en la frecuencia central
    float a0 = 1.0f + alpha;

    BiquadCoeffs coeffs;
    coeffs.b0 = alpha / a0;
    coeffs.b1 = 0.0f;
    coeffs.b2 = -alpha / a0;
    coeffs.a1 = -(-2.0f * cosW0) / a0;  // Negado para la ecuación y = b0*x + b1*x1 + b2*x2 + a1*y1 + a2*y2
    coeffs.a2 = -(1.0f - alpha) / a0;   // Negado

    return coeffs;
}

float NoiseReduction::applyBiquad(float input, const BiquadCoeffs& coeffs,
                                  BiquadState& state) {
    // Direct Form I:
    // y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] + a1*y[n-1] + a2*y[n-2]
    // (a1, a2 ya están negados en los coeficientes)
    float output = coeffs.b0 * input
                 + coeffs.b1 * state.x1
                 + coeffs.b2 * state.x2
                 + coeffs.a1 * state.y1
                 + coeffs.a2 * state.y2;

    // Actualizar delays
    state.x2 = state.x1;
    state.x1 = input;
    state.y2 = state.y1;
    state.y1 = output;

    return output;
}

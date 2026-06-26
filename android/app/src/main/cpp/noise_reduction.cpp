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
    // usando el sample rate por defecto (kNrSampleRate). DspPipeline::init()
    // debe llamar init(sampleRate) para fijar la fs real (ver fix sim_v3).
    for (int i = 0; i < kNrSubBands; ++i) {
        bandCoeffs_[i] = computeBandpassCoeffs(
            kBandCenterFreqs[i],
            kNrBandWidthHz,
            static_cast<float>(sampleRate_)
        );
    }

    // Inicializar estado
    reset();
}

// ─────────────────────────────────────────────────────────────────────────────
// Inicialización con sample rate real (FIX sim_v3)
// ─────────────────────────────────────────────────────────────────────────────

void NoiseReduction::init(int sampleRate) {
    // Guardar la fs real y recomputar los bandpass para que los centros de las
    // 8 sub-bandas (500..7500 Hz) queden bien ubicados. A 48 kHz el resultado
    // es idéntico al del constructor (cambio behavior-neutral en runtime común).
    sampleRate_ = (sampleRate > 0) ? sampleRate : kNrSampleRate;
    for (int i = 0; i < kNrSubBands; ++i) {
        bandCoeffs_[i] = computeBandpassCoeffs(
            kBandCenterFreqs[i],
            kNrBandWidthHz,
            static_cast<float>(sampleRate_)
        );
    }

    // MEJORA PROFESIONAL: Calcular coeficientes de smooth envelope follower
    // Attack: 40 ms (rise time moderado - deja pasar transientes leves)
    attackCoeff_ = 1.0f - std::exp(-1.0f / (0.040f * sampleRate_));
    // Release: 250 ms (fade lento - evita cortes abruptos "tktktkt")
    releaseCoeff_ = 1.0f - std::exp(-1.0f / (0.250f * sampleRate_));

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
        bandEnergy_[i] = 0.0f;
    }
    prevGain_ = 1.0f;
    smoothEnvelope_ = 1.0f;  // Inicializar smooth envelope en 1.0 (pass-through)
}

// ─────────────────────────────────────────────────────────────────────────────
// Procesamiento principal
// ─────────────────────────────────────────────────────────────────────────────

void NoiseReduction::process(float* buffer, int blockSize) {
    if (buffer == nullptr || blockSize <= 0) {
        return;
    }

    // Paso 0: actualizar SIEMPRE las estimaciones de potencia señal/ruido por
    // banda (también las usa el clasificador de entorno vía getSignalEstimate/
    // getNoiseEstimate). Esto deja el SNR del clasificador fresco incluso en
    // nivel 0. NO modifica el audio.
    updateBandPowers(buffer, blockSize);

    // Si NR está desactivado (nivel 0), pass-through sin modificar el audio.
    // Las estimaciones ya quedaron actualizadas arriba.
    int currentLevel = level_.load(std::memory_order_relaxed);
    if (currentLevel == 0) {
        return;
    }

    // Obtener piso de ganancia para el nivel actual
    float gainFloor = getGainFloor();

    // --- Paso 3: Calcular ganancia Wiener por sub-banda ---
    // Las potencias signalPower_/noisePower_ ya fueron actualizadas en
    // updateBandPowers(); aquí solo derivamos la ganancia.
    float gains[kNrSubBands];
    for (int band = 0; band < kNrSubBands; ++band) {
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
        totalEnergy += bandEnergy_[band];
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
        float weight = bandEnergy_[band] / totalEnergy;
        compositeGain += weight * gains[band];
    }

    // Asegurar restricciones finales
    compositeGain = std::max(compositeGain, gainFloor);
    compositeGain = std::min(compositeGain, 1.0f);

    // Suavizado temporal MEJORADO: smooth envelope follower (elimina "tktktkt")
    // ANTES: attack/release lineal con alpha fijos (0.4/0.1) → saltos audibles
    // AHORA: envelope exponencial con attack 40ms / release 250ms → transiciones suaves
    float targetGain = compositeGain;
    float coeff = (targetGain < smoothEnvelope_) ? attackCoeff_ : releaseCoeff_;
    smoothEnvelope_ += coeff * (targetGain - smoothEnvelope_);
    
    // Clamp para evitar valores fuera de [gainFloor, 1.0]
    if (smoothEnvelope_ < gainFloor) smoothEnvelope_ = gainFloor;
    if (smoothEnvelope_ > 1.0f) smoothEnvelope_ = 1.0f;

    // Aplicar ganancia SUAVE al buffer (sin clicks ni "tktktkt")
    for (int i = 0; i < blockSize; ++i) {
        buffer[i] *= smoothEnvelope_;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Análisis sin aplicar ganancia (camino DNN/bypass) — mantiene vivo el SNR
// ─────────────────────────────────────────────────────────────────────────────

void NoiseReduction::analyzeOnly(const float* buffer, int blockSize) {
    if (buffer == nullptr || blockSize <= 0) {
        return;
    }
    updateBandPowers(buffer, blockSize);
}

// ─────────────────────────────────────────────────────────────────────────────
// Actualización de potencias por banda (compartida por process/analyzeOnly)
// ─────────────────────────────────────────────────────────────────────────────

void NoiseReduction::updateBandPowers(const float* buffer, int blockSize) {
    // --- Paso 1: Estimar potencia de señal por sub-banda ---
    // Filtrar el bloque completo por cada sub-banda y calcular energía
    for (int band = 0; band < kNrSubBands; ++band) {
        float energy = 0.0f;
        for (int i = 0; i < blockSize; ++i) {
            float filtered = applyBiquad(buffer[i], bandCoeffs_[band],
                                         bandStates_[band]);
            energy += filtered * filtered;
        }
        // Energía promedio por muestra en esta banda
        bandEnergy_[band] = energy / static_cast<float>(blockSize);
    }

    // --- Paso 2: Actualizar estimaciones de potencia de señal y ruido ---
    for (int band = 0; band < kNrSubBands; ++band) {
        float currentEnergy = std::max(bandEnergy_[band], kMinPower);

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
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Getters de estimaciones por banda (para el clasificador de entorno)
// ─────────────────────────────────────────────────────────────────────────────

void NoiseReduction::getSignalEstimate(float* out, int maxBands) const {
    if (out == nullptr || maxBands <= 0) {
        return;
    }
    int n = std::min(maxBands, kNrSubBands);
    for (int band = 0; band < n; ++band) {
        out[band] = signalPower_[band];
    }
}

void NoiseReduction::getNoiseEstimate(float* out, int maxBands) const {
    if (out == nullptr || maxBands <= 0) {
        return;
    }
    int n = std::min(maxBands, kNrSubBands);
    for (int band = 0; band < n; ++band) {
        out[band] = noisePower_[band];
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

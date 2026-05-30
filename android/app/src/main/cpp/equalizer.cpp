/// @file equalizer.cpp
/// @brief Implementación del EQ paramétrico de 12 bandas con suavizado de coeficientes.
///
/// Técnica: Interpolación exponencial de coeficientes bloque-a-bloque.
///
/// Cuando se cambian las ganancias (ej: cambio de preset EQ), los coeficientes
/// TARGET se recalculan inmediatamente. Pero los coeficientes CURRENT (los que
/// realmente procesan el audio) se mueven exponencialmente hacia el TARGET
/// en cada bloque de audio.
///
/// Esto es exactamente lo que hace:
/// - DSP Concepts "BiquadSmoothed" (chips ON Semiconductor para audífonos)
/// - MATLAB "Parameter Smoother" block
/// - openMHA "smoothgain_bridge" plugin
/// - vinniefalco/DSPFilters "smooth interpolation of biquad coefficients"
///
/// Fórmula por bloque:
///   currentCoeffs += smoothingCoeff * (targetCoeffs - currentCoeffs)
///
/// Con smoothingCoeff = 1 - exp(-1/N), donde N = número de bloques para ~95%.
/// Para N=5 bloques de 4ms = 20ms de transición total.
///
/// Referencia académica:
/// - Kalinichenko (2006) DAFx-06: "Smooth and Safe Parameter Interpolation"
/// - Zetterberg & Zhang (1988): "Elimination of transients in adaptive filters"
/// - Wishnick (2014) DAFx-14: "Time-Varying Filters for Musical Applications"

#include "equalizer.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// ============================================================================
// Constructor
// ============================================================================

Equalizer::Equalizer() {
    for (int i = 0; i < kEqBandCount; ++i) {
        gains_[i].store(0.0f, std::memory_order_relaxed);
        appliedGains_[i] = 0.0f;
        states_[i].reset();
        targetCoeffs_[i] = BiquadCoeffs{};   // pass-through
        currentCoeffs_[i] = BiquadCoeffs{};  // pass-through
        smoothingActive_[i] = false;
    }
    gainsChanged_.store(false, std::memory_order_relaxed);
    smoothingCoeff_ = 1.0f - std::exp(-1.0f / static_cast<float>(kSmoothingBlocks));
}

// ============================================================================
// Inicialización
// ============================================================================

void Equalizer::init(int sampleRate) {
    sampleRate_ = sampleRate;

    // Recalcular coeficiente de suavizado
    smoothingCoeff_ = 1.0f - std::exp(-1.0f / static_cast<float>(kSmoothingBlocks));

    // Resetear todo
    for (int i = 0; i < kEqBandCount; ++i) {
        states_[i].reset();
        appliedGains_[i] = 0.0f;
        targetCoeffs_[i] = BiquadCoeffs{};
        currentCoeffs_[i] = BiquadCoeffs{};
        smoothingActive_[i] = false;
    }

    // Forzar recálculo de coeficientes en el próximo process()
    gainsChanged_.store(true, std::memory_order_release);
}

// ============================================================================
// Actualización de ganancias (thread-safe, llamado desde hilo de UI)
// ============================================================================

void Equalizer::setGains(const float gains[kEqBandCount]) {
    for (int i = 0; i < kEqBandCount; ++i) {
        // Clamp al rango válido [0, 50] dB
        float g = gains[i];
        if (g < 0.0f) g = 0.0f;
        if (g > 50.0f) g = 50.0f;
        gains_[i].store(g, std::memory_order_relaxed);
    }
    // Señalar que hay cambio pendiente
    gainsChanged_.store(true, std::memory_order_release);
}

float Equalizer::getGain(int band) const {
    if (band < 0 || band >= kEqBandCount) return 0.0f;
    return gains_[band].load(std::memory_order_relaxed);
}

float Equalizer::getMaxGain() const {
    float maxGain = 0.0f;
    for (int i = 0; i < kEqBandCount; ++i) {
        float g = gains_[i].load(std::memory_order_relaxed);
        if (g > maxGain) maxGain = g;
    }
    return maxGain;
}

void Equalizer::processWithScale(float* buffer, int blockSize, float scale) {
    if (buffer == nullptr || blockSize <= 0) return;

    // Apply EQ normally (preserves frequency shape)
    process(buffer, blockSize);

    // Post-scale: reduce the amplified signal to fit in headroom.
    for (int i = 0; i < blockSize; ++i) {
        buffer[i] *= scale;
    }
}

// ============================================================================
// Cálculo de coeficientes (Audio EQ Cookbook — Peaking EQ)
// ============================================================================

BiquadCoeffs Equalizer::computePeakingCoeffs(float frequencyHz, float gainDb, float q) const {
    BiquadCoeffs c;

    // Si ganancia es 0 dB, el filtro es pass-through
    if (gainDb < 0.001f) {
        c.b0 = 1.0f;
        c.b1 = 0.0f;
        c.b2 = 0.0f;
        c.a1 = 0.0f;
        c.a2 = 0.0f;
        return c;
    }

    // Audio EQ Cookbook: Peaking EQ
    const float A = std::pow(10.0f, gainDb / 40.0f);
    const float w0 = 2.0f * static_cast<float>(M_PI) * frequencyHz / static_cast<float>(sampleRate_);
    const float sinW0 = std::sin(w0);
    const float cosW0 = std::cos(w0);
    const float alpha = sinW0 / (2.0f * q);

    const float b0 = 1.0f + alpha * A;
    const float b1 = -2.0f * cosW0;
    const float b2 = 1.0f - alpha * A;
    const float a0 = 1.0f + alpha / A;
    const float a1 = -2.0f * cosW0;
    const float a2 = 1.0f - alpha / A;

    // Normalizar por a0
    const float invA0 = 1.0f / a0;
    c.b0 = b0 * invA0;
    c.b1 = b1 * invA0;
    c.b2 = b2 * invA0;
    c.a1 = a1 * invA0;
    c.a2 = a2 * invA0;

    return c;
}

// ============================================================================
// Recálculo de coeficientes TARGET (llamado desde hilo de audio)
// ============================================================================

void Equalizer::updateTargetCoefficients() {
    for (int i = 0; i < kEqBandCount; ++i) {
        const float newGain = gains_[i].load(std::memory_order_relaxed);

        // Solo recalcular si la ganancia cambió significativamente
        if (std::fabs(newGain - appliedGains_[i]) > 0.01f) {
            targetCoeffs_[i] = computePeakingCoeffs(kEqFrequencies[i], newGain, kEqQFactors[i]);
            appliedGains_[i] = newGain;

            // Activar suavizado para esta banda si los coeficientes son diferentes
            if (currentCoeffs_[i].significantlyDifferent(targetCoeffs_[i])) {
                smoothingActive_[i] = true;
            }
        }
    }
}

// ============================================================================
// Suavizado exponencial de coeficientes (por bloque)
// ============================================================================

/// Aplica un paso de suavizado exponencial a los coeficientes current
/// acercándolos a los target. Retorna true si aún hay diferencia significativa.
static bool smoothCoeffsStep(BiquadCoeffs& current, const BiquadCoeffs& target, float coeff) {
    current.b0 += coeff * (target.b0 - current.b0);
    current.b1 += coeff * (target.b1 - current.b1);
    current.b2 += coeff * (target.b2 - current.b2);
    current.a1 += coeff * (target.a1 - current.a1);
    current.a2 += coeff * (target.a2 - current.a2);

    // Verificar si ya convergió (diferencia < epsilon)
    const float eps = 1e-7f;
    bool stillMoving = std::fabs(target.b0 - current.b0) > eps ||
                       std::fabs(target.b1 - current.b1) > eps ||
                       std::fabs(target.b2 - current.b2) > eps ||
                       std::fabs(target.a1 - current.a1) > eps ||
                       std::fabs(target.a2 - current.a2) > eps;

    if (!stillMoving) {
        // Snap to target para evitar drift numérico
        current = target;
    }

    return stillMoving;
}

// ============================================================================
// Procesamiento de una muestra a través de un biquad (Direct Form I)
// ============================================================================

float Equalizer::processBiquadSample(float sample, const BiquadCoeffs& coeffs,
                                     BiquadState& state) {
    // Direct Form I:
    // y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
    const float output = coeffs.b0 * sample
                       + coeffs.b1 * state.x1
                       + coeffs.b2 * state.x2
                       - coeffs.a1 * state.y1
                       - coeffs.a2 * state.y2;

    // Actualizar estado
    state.x2 = state.x1;
    state.x1 = sample;
    state.y2 = state.y1;
    state.y1 = output;

    return output;
}

// ============================================================================
// Procesamiento de bloque (llamado desde hilo de audio)
// ============================================================================

void Equalizer::process(float* buffer, int blockSize) {
    if (buffer == nullptr || blockSize <= 0) return;

    // ─── 1. Verificar si hay cambio de ganancias pendiente ──────────────
    if (gainsChanged_.load(std::memory_order_acquire)) {
        updateTargetCoefficients();
        gainsChanged_.store(false, std::memory_order_release);
    }

    // ─── 2. Suavizar coeficientes (un paso exponencial por bloque) ──────
    // Esto es la técnica "BiquadSmoothed" de DSP Concepts:
    // currentCoeffs += smoothingCoeff * (targetCoeffs - currentCoeffs)
    for (int band = 0; band < kEqBandCount; ++band) {
        if (smoothingActive_[band]) {
            smoothingActive_[band] = smoothCoeffsStep(
                currentCoeffs_[band], targetCoeffs_[band], smoothingCoeff_);
        }
    }

    // ─── 3. Aplicar cada banda en serie con per-band limiter ────────────
    for (int band = 0; band < kEqBandCount; ++band) {
        // Si los coeficientes son pass-through (b0≈1, resto≈0), skip
        const BiquadCoeffs& coeffs = currentCoeffs_[band];
        if (std::fabs(coeffs.b0 - 1.0f) < 1e-6f &&
            std::fabs(coeffs.b1) < 1e-6f &&
            std::fabs(coeffs.b2) < 1e-6f &&
            std::fabs(coeffs.a1) < 1e-6f &&
            std::fabs(coeffs.a2) < 1e-6f) {
            continue;
        }

        BiquadState& state = states_[band];

        for (int i = 0; i < blockSize; ++i) {
            float sample = processBiquadSample(buffer[i], coeffs, state);

            // Per-band limiter (protección contra overflow inter-banda)
            const float absSample = std::fabs(sample);
            if (absSample > kPerBandCeiling) {
                sample *= kPerBandCeiling / absSample;
            }

            buffer[i] = sample;
        }
    }
}

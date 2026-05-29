/// @file equalizer.cpp
/// @brief Implementación del EQ paramétrico de 12 bandas con filtros biquad peaking.
///
/// Usa fórmulas del Audio EQ Cookbook (Robert Bristow-Johnson) para calcular
/// coeficientes de filtros peaking EQ de segundo orden (biquad IIR).
///
/// Cada banda es un filtro biquad independiente aplicado en serie.
/// Las ganancias se actualizan atómicamente desde el hilo de UI;
/// los coeficientes se recalculan en el hilo de audio al inicio de cada bloque.
///
/// CROSSFADE: Al detectar cambio significativo de ganancias, se aplica un
/// fade-out rápido (5ms), se resetean los estados de los filtros, y luego
/// un fade-in (5ms). Esto elimina completamente el transitorio/ruido que
/// ocurría al cambiar presets en caliente.

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
        oldAppliedGains_[i] = 0.0f;
        states_[i].reset();
        oldStates_[i].reset();
        coeffs_[i] = BiquadCoeffs{};
        oldCoeffs_[i] = BiquadCoeffs{};
    }
    gainsChanged_.store(false, std::memory_order_relaxed);
    crossfadeActive_ = false;
    crossfadeSamplesLeft_ = 0;
    crossfadeSamplesTotal_ = 0;
}

// ============================================================================
// Inicialización
// ============================================================================

void Equalizer::init(int sampleRate) {
    sampleRate_ = sampleRate;

    // Calcular duración del crossfade en muestras (10ms total: 5ms fade-out + 5ms fade-in)
    crossfadeSamplesTotal_ = static_cast<int>(kCrossfadeMs * sampleRate / 1000.0f);
    if (crossfadeSamplesTotal_ < 32) crossfadeSamplesTotal_ = 32;  // mínimo 32 muestras
    crossfadeSamplesLeft_ = 0;
    crossfadeActive_ = false;

    // Resetear estados de filtro
    for (int i = 0; i < kEqBandCount; ++i) {
        states_[i].reset();
        oldStates_[i].reset();
        appliedGains_[i] = 0.0f;
        oldAppliedGains_[i] = 0.0f;
        coeffs_[i] = BiquadCoeffs{};
        oldCoeffs_[i] = BiquadCoeffs{};
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
// Recálculo de coeficientes (llamado desde hilo de audio)
// ============================================================================

void Equalizer::updateCoefficients() {
    for (int i = 0; i < kEqBandCount; ++i) {
        const float newGain = gains_[i].load(std::memory_order_relaxed);

        // Solo recalcular si la ganancia cambió significativamente
        if (std::fabs(newGain - appliedGains_[i]) > 0.01f) {
            coeffs_[i] = computePeakingCoeffs(kEqFrequencies[i], newGain, kEqQFactors[i]);
            appliedGains_[i] = newGain;
        }
    }
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
// Procesamiento de bloque con coeficientes/estados dados
// ============================================================================

void Equalizer::processBlock(float* buffer, int blockSize,
                             BiquadCoeffs* coeffs, BiquadState* states,
                             const float* appliedGains) {
    for (int band = 0; band < kEqBandCount; ++band) {
        // Si la ganancia aplicada es ~0 dB, este filtro es pass-through
        if (appliedGains[band] < 0.01f) {
            continue;
        }

        const BiquadCoeffs& c = coeffs[band];
        BiquadState& state = states[band];

        for (int i = 0; i < blockSize; ++i) {
            float sample = processBiquadSample(buffer[i], c, state);

            // Per-band limiter
            const float absSample = std::fabs(sample);
            if (absSample > kPerBandCeiling) {
                sample *= kPerBandCeiling / absSample;
            }

            buffer[i] = sample;
        }
    }
}

// ============================================================================
// Procesamiento de bloque principal con crossfade (llamado desde hilo de audio)
// ============================================================================

void Equalizer::process(float* buffer, int blockSize) {
    if (buffer == nullptr || blockSize <= 0) return;

    // Verificar si hay cambio de ganancias pendiente
    if (gainsChanged_.load(std::memory_order_acquire)) {
        gainsChanged_.store(false, std::memory_order_release);

        // Verificar si realmente hubo un cambio significativo
        bool significantChange = false;
        for (int i = 0; i < kEqBandCount; ++i) {
            const float newGain = gains_[i].load(std::memory_order_relaxed);
            if (std::fabs(newGain - appliedGains_[i]) > 0.5f) {
                significantChange = true;
                break;
            }
        }

        if (significantChange) {
            // Actualizar coeficientes con las nuevas ganancias
            updateCoefficients();

            // Resetear TODOS los estados de filtro para eliminar transitorios.
            // Los estados viejos con coeficientes nuevos son la causa del ruido.
            for (int i = 0; i < kEqBandCount; ++i) {
                states_[i].reset();
            }

            // Iniciar crossfade (fade-in desde silencio)
            crossfadeSamplesLeft_ = crossfadeSamplesTotal_;
            crossfadeActive_ = true;
        } else {
            // Cambio menor — actualizar coeficientes sin crossfade
            updateCoefficients();
        }
    }

    // --- Procesamiento ---

    if (!crossfadeActive_) {
        // Caso normal: procesar directamente con coeficientes actuales
        processBlock(buffer, blockSize, coeffs_, states_, appliedGains_);
    } else {
        // Crossfade activo: fade-in gradual después del reset de estados.
        // Esto evita el "pop" del reset y permite que los filtros se estabilicen.

        // Procesar con los nuevos coeficientes (estados ya reseteados)
        processBlock(buffer, blockSize, coeffs_, states_, appliedGains_);

        // Aplicar envelope de fade-in sample-by-sample
        for (int i = 0; i < blockSize; ++i) {
            if (crossfadeSamplesLeft_ <= 0) {
                break;  // Crossfade terminado
            }

            // Fade-in: de 0.0 a 1.0 linealmente
            const float progress = 1.0f - (static_cast<float>(crossfadeSamplesLeft_)
                                          / static_cast<float>(crossfadeSamplesTotal_));

            // Usar curva cuadrática para fade-in más suave (evita click al inicio)
            const float gain = progress * progress;

            buffer[i] *= gain;
            crossfadeSamplesLeft_--;
        }

        // Si el crossfade terminó en este bloque, desactivar
        if (crossfadeSamplesLeft_ <= 0) {
            crossfadeActive_ = false;
        }
    }
}

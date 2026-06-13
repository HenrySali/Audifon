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
/// FIX ruido sostenido al cambiar EQ en caliente: las ganancias objetivo se
/// suavizan por bloque (stepGainRamp) y los coeficientes se derivan del valor
/// suavizado, eliminando el transitorio del hard-swap de coeficientes en
/// Direct Form I. processBiquadSample sanitiza NaN/Inf para impedir que un
/// blow-up del IIR se auto-propague indefinidamente.

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
        rampGains_[i] = 0.0f;
        states_[i].reset();
        // Coeficientes por defecto: pass-through (b0=1, resto=0)
        coeffs_[i] = BiquadCoeffs{};
    }
    gainsChanged_.store(false, std::memory_order_relaxed);
}

// ============================================================================
// Inicialización
// ============================================================================

void Equalizer::init(int sampleRate) {
    sampleRate_ = sampleRate;

    // Resetear estados de filtro
    for (int i = 0; i < kEqBandCount; ++i) {
        states_[i].reset();
        appliedGains_[i] = 0.0f;
        // El valor suavizado arranca desde el target actual para no rampear
        // desde 0 en cada init() (el engine puede reiniciarse con un preset ya
        // cargado). Así init() = estado limpio, sin transitorio espurio.
        rampGains_[i] = gains_[i].load(std::memory_order_relaxed);
        coeffs_[i] = BiquadCoeffs{};
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
// Paso de rampa de ganancias + recálculo de coeficientes (hilo de audio)
// ============================================================================
//
// FIX ruido sostenido al cambiar EQ en caliente:
// Antes esta función (updateCoefficients) hacía un HARD-SWAP: tomaba el target
// crudo de gains_ y reemplazaba de golpe los coeficientes, mientras los estados
// del biquad (x1,x2,y1,y2) conservaban valores calculados con los coeficientes
// VIEJOS. En Direct Form I, esa discontinuidad genera un transitorio; con 12
// biquads peaking en serie y ganancias de hasta 50 dB ese transitorio puede
// saturar a Inf/NaN, que en un IIR recursivo se auto-propaga PARA SIEMPRE
// (de ahí el "ruido fuerte hasta resetear el engine").
//
// Ahora interpolamos el TARGET hacia un valor SUAVIZADO (rampGains_) por bloque
// y recalculamos los coeficientes a partir del valor suavizado. Los saltos de
// coeficientes entre bloques son pequeños → sin zipper noise audible.
// Ref: DSP.SE "Avoiding clicks with changing biquad coefficients";
//      parameter smoothing (JUCE SmoothedValue, Max biquad~/filtercoeff~).
void Equalizer::stepGainRamp() {
    for (int i = 0; i < kEqBandCount; ++i) {
        const float target = gains_[i].load(std::memory_order_relaxed);
        float r = rampGains_[i];

        if (std::fabs(target - r) < kEqGainSnapEps) {
            r = target;  // snap: evita recálculo perpetuo cuando ya convergió
        } else {
            // Rampa exponencial de un polo (one-pole smoothing)
            r += kEqRampAlpha * (target - r);
        }
        rampGains_[i] = r;

        // Recalcular coeficientes solo si el valor suavizado se movió.
        if (std::fabs(r - appliedGains_[i]) > kEqCoeffRecalcEps) {
            coeffs_[i] = computePeakingCoeffs(kEqFrequencies[i], r, kEqQFactors[i]);
            appliedGains_[i] = r;
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

    // SANITIZACIÓN (FIX ruido sostenido): en un IIR Direct Form I, si la salida
    // se vuelve NaN/Inf (overflow por transitorio de cambio de coeficientes en
    // serie), ese valor se realimenta en y1/y2 y se auto-propaga indefinidamente
    // — produce ruido fuerte hasta reiniciar el engine. Si detectamos un valor
    // no finito, reseteamos el estado de la banda y dejamos pasar la muestra de
    // entrada, cortando la propagación sin necesidad de reset externo.
    if (!std::isfinite(output)) {
        state.reset();
        return sample;
    }

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

    // Avanzar la rampa de ganancias y recalcular coeficientes CADA bloque.
    // Se ejecuta siempre (sin condicional sobre gainsChanged_) para que el
    // valor suavizado converja al target de forma continua. El recálculo de
    // coeficientes interno está gated por diferencia, así que cuando la rampa
    // ya convergió el costo es solo 12 comparaciones (sin pow/sin/cos).
    stepGainRamp();
    gainsChanged_.store(false, std::memory_order_release);

    // Aplicar cada banda en serie.
    for (int band = 0; band < kEqBandCount; ++band) {
        // Si la ganancia aplicada (suavizada) es ~0 dB, este filtro es
        // pass-through (coeficientes identidad) → se puede saltear.
        if (appliedGains_[band] < 0.01f) {
            continue;
        }

        const BiquadCoeffs& coeffs = coeffs_[band];
        BiquadState& state = states_[band];

        for (int i = 0; i < blockSize; ++i) {
            buffer[i] = processBiquadSample(buffer[i], coeffs, state);
        }
    }
}

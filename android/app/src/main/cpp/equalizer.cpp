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
///
/// Fase D — Commit transaccional + crossfade:
/// - setGains() escribe un EqSnapshot completo con doble buffer atómico.
/// - checkForNewSnapshot() detecta el cambio en el hilo de audio y prepara
///   crossfade copiando los coeficientes "viejos" antes de que stepGainRamp
///   los recalcule.
/// - El crossfade lineal (5 bloques ~20 ms) elimina el click del transitorio
///   de 12 biquads DF-I en serie al cambiar preset.

#include "equalizer.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// ============================================================================
// Constructor
// ============================================================================

Equalizer::Equalizer() {
    for (int i = 0; i < kEqBandCount; ++i) {
        appliedGains_[i] = 0.0f;
        rampGains_[i] = 0.0f;
        states_[i].reset();
        // Coeficientes por defecto: pass-through (b0=1, resto=0)
        coeffs_[i] = BiquadCoeffs{};
    }
    // Snapshots: ambos arrancan con seq=0 y gains=0.
    for (auto& snap : snapshots_) {
        std::memset(snap.gains, 0, sizeof(snap.gains));
        snap.seq = 0;
    }
    readSnapshotSeq_.store(0, std::memory_order_relaxed);
    writeSnapshotSeq_.store(0, std::memory_order_relaxed);
}

// ============================================================================
// Inicialización
// ============================================================================

void Equalizer::init(int sampleRate) {
    sampleRate_ = sampleRate;

    // Resetear estados de filtro
    for (int i = 0; i < kEqBandCount; ++i) {
        states_[i].reset();
        prevStates_[i] = BiquadPrevState{};
        crossfader_.active[i] = false;
        crossfader_.progress[i] = 0.0f;
        appliedGains_[i] = 0.0f;
        // El valor suavizado arranca desde el snapshot actual para no rampear
        // desde 0 en cada init() (el engine puede reiniciarse con un preset ya
        // cargado).
        const auto seq = readSnapshotSeq_.load(std::memory_order_relaxed);
        const int snapIdx = (seq % 2 == 0) ? 0 : 1;
        rampGains_[i] = snapshots_[snapIdx].gains[i];
        coeffs_[i] = BiquadCoeffs{};
    }
}

// ============================================================================
// Commit transaccional (llamado desde hilo de UI, thread-safe)
// ============================================================================

uint64_t Equalizer::commitNewSnapshot(const float gains[kEqBandCount]) {
    // Leer la secuencia actual de escritura y calcular el nuevo índice.
    const uint64_t oldWriteSeq = writeSnapshotSeq_.load(std::memory_order_acquire);
    const int writeIdx = (oldWriteSeq % 2 == 0) ? 1 : 0;  // alternar buffer
    const uint64_t newSeq = oldWriteSeq + 1;

    // Escribir el snapshot completo en el buffer de escritura.
    snapshots_[writeIdx].store(gains, newSeq);

    // Publicar: store release del nuevo índice.
    writeSnapshotSeq_.store(newSeq, std::memory_order_release);
    return newSeq;
}

void Equalizer::setGains(const float gains[kEqBandCount]) {
    // Clamp al rango válido [0, 50] dB
    float clamped[kEqBandCount];
    for (int i = 0; i < kEqBandCount; ++i) {
        float g = gains[i];
        if (g < 0.0f) g = 0.0f;
        if (g > 50.0f) g = 50.0f;
        clamped[i] = g;
    }
    commitNewSnapshot(clamped);
}

float Equalizer::getGain(int band) const {
    if (band < 0 || band >= kEqBandCount) return 0.0f;
    // Leer el snapshot más reciente y devolver la ganancia de esa banda.
    const auto seq = readSnapshotSeq_.load(std::memory_order_acquire);
    const int snapIdx = (seq % 2 == 0) ? 0 : 1;
    return snapshots_[snapIdx].gains[band];
}

float Equalizer::getMaxGain() const {
    float maxGain = 0.0f;
    const auto seq = readSnapshotSeq_.load(std::memory_order_acquire);
    const int snapIdx = (seq % 2 == 0) ? 0 : 1;
    for (int i = 0; i < kEqBandCount; ++i) {
        if (snapshots_[snapIdx].gains[i] > maxGain) {
            maxGain = snapshots_[snapIdx].gains[i];
        }
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
// Detección de nuevo snapshot + preparación de crossfade (hilo de audio)
// ============================================================================

void Equalizer::checkForNewSnapshot() {
    const uint64_t writeSeq = writeSnapshotSeq_.load(std::memory_order_acquire);
    const uint64_t readSeq = readSnapshotSeq_.load(std::memory_order_relaxed);

    if (writeSeq == readSeq) {
        // No hay snapshot nuevo — nada que hacer.
        return;
    }

    // Hay un nuevo snapshot. El índice de lectura es: readSeq % 2; pero debemos
    // leer desde el buffer que el writer escribió, que está en writeSeq % 2.
    // Como writeSeq > readSeq, el writer escribió en (writeSeq % 2).
    // Avanzamos readSeq y apuntamos al buffer de lectura correcto.
    const int readIdx = (writeSeq % 2 == 0) ? 0 : 1;
    const EqSnapshot& snap = snapshots_[readIdx];

    // Preparar crossfade por banda: guardar los coeficientes y estados VIEJOS
    // antes de que stepGainRamp() los recalcule con las nuevas ganancias.
    for (int i = 0; i < kEqBandCount; ++i) {
        const float newGain = snap.gains[i];
        const float oldRamp = rampGains_[i];
        // Solo activar crossfade si la diferencia es significativa (> 1 dB).
        if (std::fabs(newGain - oldRamp) > 1.0f) {
            // Preservar coeficientes y estado viejos para crossfade
            prevStates_[i].coeffs = coeffs_[i];
            prevStates_[i].state = states_[i];
            prevStates_[i].valid = true;
            crossfader_.active[i] = true;
            crossfader_.progress[i] = 0.0f;
        }
    }

    // Actualizar las ganancias target con el nuevo snapshot.
    // stepGainRamp() empezará a rampear desde el valor suavizado actual
    // hacia estos nuevos targets.
    for (int i = 0; i < kEqBandCount; ++i) {
        // Escribir la ganancia del snapshot en el atomic legacy para que
        // stepGainRamp() la vea como nuevo target.
        gains_[i].store(snap.gains[i], std::memory_order_relaxed);
    }

    // Actualizar la secuencia de lectura para marcar el snapshot como consumido.
    readSnapshotSeq_.store(writeSeq, std::memory_order_release);
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

/// Aplica crossfade a una muestra: interpola linealmente entre la salida del
/// filtro "viejo" (prevCoeffs, prevState) y la del filtro "nuevo" (newOutput).
/// Avanza el progreso del crossfade en [progress] y lo desactiva cuando
/// alcanza 1.0.
static float applyCrossfade(float sample, float newOutput,
                            const BiquadCoeffs& prevCoeffs,
                            BiquadState& prevState,
                            bool& active, float& progress) {
    if (!active) {
        return newOutput;  // Sin crossfade activo — pasar la nueva señal.
    }

    // Calcular la salida del filtro VIEJO con la muestra actual.
    // Direct Form I inline (processBiquadSample es private, no accesible aquí).
    float oldOutput = prevCoeffs.b0 * sample
                    + prevCoeffs.b1 * prevState.x1
                    + prevCoeffs.b2 * prevState.x2
                    - prevCoeffs.a1 * prevState.y1
                    - prevCoeffs.a2 * prevState.y2;
    if (!std::isfinite(oldOutput)) { oldOutput = sample; prevState.reset(); }
    prevState.x2 = prevState.x1; prevState.x1 = sample;
    prevState.y2 = prevState.y1; prevState.y1 = oldOutput;

    // Interpolación lineal: cuando progress=0 → 100% old; progress=1 → 100% new.
    const float blend = (1.0f - progress) * oldOutput + progress * newOutput;

    // Avanzar el crossfade. Si llegó a 1.0, desactivar.
    progress += EqCrossfader::kStep;
    if (progress >= 1.0f) {
        progress = 1.0f;
        active = false;
    }

    return blend;
}

// ============================================================================
// Procesamiento de bloque (llamado desde hilo de audio)
// ============================================================================

void Equalizer::process(float* buffer, int blockSize) {
    if (buffer == nullptr || blockSize <= 0) return;

    // 0. Detectar nuevo snapshot transaccional y preparar crossfade.
    checkForNewSnapshot();

    // 1. Avanzar la rampa de ganancias y recalcular coeficientes CADA bloque.
    //    Se ejecuta siempre (sin condicional sobre gainsChanged_) para que el
    //    valor suavizado converja al target de forma continua. El recálculo de
    //    coeficientes interno está gated por diferencia, así que cuando la rampa
    //    ya convergió el costo es solo 12 comparaciones (sin pow/sin/cos).
    stepGainRamp();

    // 2. Aplicar cada banda en serie, con crossfade donde esté activo.
    for (int band = 0; band < kEqBandCount; ++band) {
        // Si la ganancia aplicada (suavizada) es ~0 dB, este filtro es
        // pass-through (coeficientes identidad) → se puede saltear.
        if (appliedGains_[band] < 0.01f && !crossfader_.active[band]) {
            continue;
        }

        const BiquadCoeffs& coeffs = coeffs_[band];
        BiquadState& state = states_[band];
        const bool hasCrossfade = crossfader_.active[band];

        if (hasCrossfade) {
            // Crossfade activo: procesar cada muestra con ambos filtros y
            // blendear.
            BiquadPrevState& prev = prevStates_[band];
            for (int i = 0; i < blockSize; ++i) {
                const float newOutput = processBiquadSample(buffer[i], coeffs, state);
                buffer[i] = applyCrossfade(
                    buffer[i], newOutput,
                    prev.coeffs, prev.state,
                    crossfader_.active[band],
                    crossfader_.progress[band]);
            }
            // Si el crossfade terminó durante este bloque, marcar prev como inválido.
            if (!crossfader_.active[band]) {
                prev.valid = false;
            }
        } else {
            // Sin crossfade: procesamiento normal.
            for (int i = 0; i < blockSize; ++i) {
                buffer[i] = processBiquadSample(buffer[i], coeffs, state);
            }
        }
    }
}
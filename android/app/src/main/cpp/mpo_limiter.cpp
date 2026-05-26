/// @file mpo_limiter.cpp
/// @brief Implementación del limitador MPO de picos muestra-por-muestra.
///
/// El MPO (Maximum Power Output) es la ÚLTIMA etapa del pipeline DSP.
/// Su función es garantizar que ninguna muestra de salida exceda el threshold
/// configurado, protegiendo la audición del usuario.
///
/// Algoritmo por muestra:
/// 1. Calcular |sample|
/// 2. Si |sample| > threshold → calcular ganancia objetivo y aplicar attack rápido
/// 3. Si |sample| ≤ threshold → release lento hacia ganancia unitaria
/// 4. Aplicar ganancia suavizada: output = sample * gain
/// 5. Hard-clamp de seguridad: si |output| > threshold → saturar a threshold
///
/// El hard-clamp en paso 5 es la garantía absoluta. Incluso si el attack
/// suavizado no ha convergido completamente (transitorio), la salida NUNCA
/// excede el threshold.
///
/// Parámetros por defecto:
/// - Threshold: 100 dB SPL con offset 120 → -20 dBFS → 0.1 lineal
/// - Attack: 0.5 ms → attackCoeff ≈ 0.1175 @ 16 kHz
/// - Release: 10 ms → releaseCoeff ≈ 0.00625 @ 16 kHz
///
/// Requisitos validados: 2.6, 7.3, 9.1, 9.5

#include "mpo_limiter.h"

#include <algorithm>
#include <cmath>

// ============================================================================
// Constructor
// ============================================================================

MpoLimiter::MpoLimiter() {
    computeCoefficients();
}

// ============================================================================
// Inicialización
// ============================================================================

void MpoLimiter::init(int sampleRate) {
    sampleRate_ = sampleRate > 0 ? sampleRate : 16000;
    computeCoefficients();
    reset();
}

// ============================================================================
// Procesamiento principal — bloque completo
// ============================================================================

void MpoLimiter::process(float* buffer, int blockSize) {
    if (buffer == nullptr || blockSize <= 0) {
        return;
    }

    // Leer threshold una vez por bloque (atómico, thread-safe)
    const float threshold = thresholdLinear_.load(std::memory_order_relaxed);

    // Protección: threshold debe ser positivo y razonable
    if (threshold <= 0.0f) {
        return;
    }

    // Procesar muestra por muestra
    for (int i = 0; i < blockSize; ++i) {
        const float sample = buffer[i];
        const float absSample = std::fabs(sample);

        if (absSample > threshold) {
            // --- ATTACK: la muestra excede el threshold ---
            // Calcular ganancia objetivo para que output = threshold
            const float targetGain = threshold / absSample;

            // Suavizar hacia ganancia objetivo con attack rápido
            // gain += attackCoeff * (targetGain - gain)
            gain_ += attackCoeff_ * (targetGain - gain_);
        } else {
            // --- RELEASE: la muestra está dentro del threshold ---
            // Recuperar lentamente hacia ganancia unitaria (1.0)
            // gain += releaseCoeff * (1.0 - gain)
            gain_ += releaseCoeff_ * (1.0f - gain_);
        }

        // Asegurar que la ganancia nunca excede 1.0 (MPO nunca amplifica)
        if (gain_ > 1.0f) {
            gain_ = 1.0f;
        }

        // Asegurar que la ganancia nunca es negativa (protección numérica)
        if (gain_ < 0.0f) {
            gain_ = 0.0f;
        }

        // Aplicar ganancia suavizada
        float output = sample * gain_;

        // --- HARD-CLAMP DE SEGURIDAD ---
        // Garantía absoluta: incluso durante transitorio de attack,
        // la salida NUNCA excede el threshold.
        if (output > threshold) {
            output = threshold;
        } else if (output < -threshold) {
            output = -threshold;
        }

        buffer[i] = output;
    }
}

// ============================================================================
// Configuración de threshold
// ============================================================================

void MpoLimiter::setThreshold(float thresholdDbSpl, float splOffset) {
    // Convertir dB SPL a dBFS usando el offset
    // dBFS = dB_SPL - splOffset
    const float thresholdDbFs = thresholdDbSpl - splOffset;

    // Convertir dBFS a amplitud lineal
    // linear = 10^(dBFS / 20)
    const float linear = std::pow(10.0f, thresholdDbFs / 20.0f);

    // Almacenar atómicamente (thread-safe)
    thresholdLinear_.store(linear, std::memory_order_relaxed);
}

void MpoLimiter::setThresholdLinear(float linear) {
    if (linear > 0.0f) {
        thresholdLinear_.store(linear, std::memory_order_relaxed);
    }
}

// ============================================================================
// Getters
// ============================================================================

float MpoLimiter::getThresholdLinear() const {
    return thresholdLinear_.load(std::memory_order_relaxed);
}

float MpoLimiter::getCurrentGain() const {
    return gain_;
}

// ============================================================================
// Reset
// ============================================================================

void MpoLimiter::reset() {
    gain_ = 1.0f;
}

// ============================================================================
// Cálculo de coeficientes internos
// ============================================================================

void MpoLimiter::computeCoefficients() {
    // attackCoeff = 1 - exp(-1 / (attackTime_sec * sampleRate))
    // Para 0.5 ms @ 16 kHz: 1 - exp(-1 / (0.0005 * 16000))
    //                      = 1 - exp(-1 / 8)
    //                      = 1 - exp(-0.125)
    //                      ≈ 1 - 0.8825
    //                      ≈ 0.1175
    const float attackSamples = kAttackTimeSec * static_cast<float>(sampleRate_);
    if (attackSamples > 0.0f) {
        attackCoeff_ = 1.0f - std::exp(-1.0f / attackSamples);
    } else {
        attackCoeff_ = 1.0f; // Instantáneo si tiempo = 0
    }

    // releaseCoeff = 1 - exp(-1 / (releaseTime_sec * sampleRate))
    // Para 10 ms @ 16 kHz: 1 - exp(-1 / (0.01 * 16000))
    //                     = 1 - exp(-1 / 160)
    //                     = 1 - exp(-0.00625)
    //                     ≈ 1 - 0.99377
    //                     ≈ 0.00623
    const float releaseSamples = kReleaseTimeSec * static_cast<float>(sampleRate_);
    if (releaseSamples > 0.0f) {
        releaseCoeff_ = 1.0f - std::exp(-1.0f / releaseSamples);
    } else {
        releaseCoeff_ = 1.0f; // Instantáneo si tiempo = 0
    }
}

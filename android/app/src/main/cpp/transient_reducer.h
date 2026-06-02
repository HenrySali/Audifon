/// @file transient_reducer.h
/// @brief Transient Noise Reduction (TNR) — atenúa impulsos abruptos sin afectar voz.
///
/// Detecta y atenúa sonidos impulsivos como:
/// - Timbre del subte/metro
/// - Puertas que se cierran fuerte
/// - Bocinas, sirenas
/// - Platos chocando, llaves cayendo
///
/// Algoritmo basado en Phonak SoundRelax (2006) — referencia clínica:
/// Acta Acustica 2023 "Evaluation of impulse noise reduction in hearing aids"
/// PMC8542075 "Personalizing Transient Noise Reduction Algorithm Settings"
///
/// Mecanismo:
/// 1. Calcular envelope de energía instantánea (rápido) y promedio (lento)
/// 2. Si energía instantánea >> promedio → es un transitorio
/// 3. Aplicar atenuación PROPORCIONAL al exceso sobre el threshold
///    (pico pequeño → atenuación suave; pico enorme → atenuación máxima)
/// 4. Mantener atenuación por hold time (~20 ms)
/// 5. Recovery exponencial gradual al volver a 0 dB
///
/// Diseño: opera sample-by-sample, lock-free, mínimo overhead CPU.

#ifndef HEARING_AID_TRANSIENT_REDUCER_H
#define HEARING_AID_TRANSIENT_REDUCER_H

#include <atomic>
#include <cmath>

/// Transient Noise Reduction — protección contra impulsos fuertes.
///
/// Uso típico:
/// @code
///   TransientReducer tnr;
///   tnr.init(16000);
///   tnr.setEnabled(true);
///   tnr.process(buffer, blockSize);  // in-place, antes del NR
/// @endcode
class TransientReducer {
public:
    TransientReducer() = default;
    ~TransientReducer() = default;

    /// Inicializa con el sample rate del sistema.
    /// @param sampleRate Hz (típicamente 16000 o 48000)
    void init(int sampleRate) {
        sampleRate_ = sampleRate;

        // Coeficientes de envelope detection
        // Fast envelope: ~1ms time constant (sigue picos instantáneos)
        fastCoeff_ = 1.0f - std::exp(-1.0f / (0.001f * sampleRate));

        // Slow envelope: ~100ms time constant (promedio de fondo)
        slowCoeff_ = 1.0f - std::exp(-1.0f / (0.100f * sampleRate));

        // Hold time: 20ms (cuántas muestras mantener atenuación tras detección)
        holdSamples_ = static_cast<int>(0.020f * sampleRate);

        // Recovery: 30ms (cuánto tarda en volver a 0 dB tras hold)
        recoveryCoeff_ = 1.0f - std::exp(-1.0f / (0.030f * sampleRate));

        // Reset estado
        fastEnv_ = 0.0f;
        slowEnv_ = 1e-6f;
        currentGain_ = 1.0f;
        holdCounter_ = 0;
    }

    /// Procesa un bloque de audio in-place.
    /// @param buffer Audio float32 [-1.0, +1.0]
    /// @param blockSize Número de muestras
    void process(float* buffer, int blockSize) {
        if (!enabled_.load(std::memory_order_relaxed)) return;
        if (buffer == nullptr || blockSize <= 0) return;

        // Leer parámetros configurables (atomic)
        float threshold = thresholdRatio_.load(std::memory_order_relaxed);
        float attenuation = attenuationLinear_.load(std::memory_order_relaxed);

        for (int i = 0; i < blockSize; ++i) {
            float absSample = std::fabs(buffer[i]);

            // 1. Actualizar envelopes (fast tracking, slow average)
            // Fast: sigue rápido los picos
            fastEnv_ += fastCoeff_ * (absSample - fastEnv_);
            // Slow: promedio de largo plazo (energía de fondo)
            slowEnv_ += slowCoeff_ * (absSample - slowEnv_);

            // Evitar división por cero
            float safeSlowEnv = std::fmax(slowEnv_, 1e-6f);

            // 2. Detección de transitorio
            // Si fast >> slow × threshold, hay un transitorio
            float ratio = fastEnv_ / safeSlowEnv;

            if (ratio > threshold) {
                // ¡Transitorio detectado! Atenuación PROPORCIONAL al exceso.
                // ratio = cuánto excede el fast envelope sobre el slow.
                // threshold = umbral mínimo para considerar transitorio.
                // Ejemplo con threshold=8:
                //   ratio=10 (pico leve) → excess=1.25 → ~-4 dB
                //   ratio=24 (pico medio) → excess=3.0 → ~-10 dB
                //   ratio=64 (pico enorme) → excess=8.0 → atenuación máxima
                //
                // Fórmula: ganancia = max(attenuation, 1.0 / excess)
                // donde excess = ratio / threshold (≥ 1.0)
                // Esto produce atenuación proporcional clampeada al piso configurado.
                float excess = ratio / threshold; // siempre ≥ 1.0
                float proportionalGain = 1.0f / excess;
                // Clamp: nunca atenuar más que el piso configurado (ej: -12 dB = 0.25)
                if (proportionalGain < attenuation) {
                    proportionalGain = attenuation;
                }
                currentGain_ = proportionalGain;
                holdCounter_ = holdSamples_;
            } else if (holdCounter_ > 0) {
                // Mantener atenuación durante hold time
                holdCounter_--;
            } else {
                // Recovery: volver gradualmente a 1.0
                currentGain_ += recoveryCoeff_ * (1.0f - currentGain_);
            }

            // 3. Aplicar ganancia (siempre <= 1.0, solo atenúa)
            buffer[i] *= currentGain_;
        }
    }

    /// Habilita/deshabilita el TNR (thread-safe).
    void setEnabled(bool enabled) {
        enabled_.store(enabled, std::memory_order_relaxed);
    }

    bool isEnabled() const {
        return enabled_.load(std::memory_order_relaxed);
    }

    /// Establece el umbral de detección (ratio fast/slow envelope).
    /// Default: 8.0 (transitorio = 8× sobre el promedio).
    /// Rango recomendado: 4.0 (sensible) a 12.0 (conservador).
    void setThreshold(float ratio) {
        if (ratio < 2.0f) ratio = 2.0f;
        if (ratio > 20.0f) ratio = 20.0f;
        thresholdRatio_.store(ratio, std::memory_order_relaxed);
    }

    /// Establece la atenuación máxima (piso) en dB (negativo).
    /// Con atenuación proporcional, este valor es el PISO: el TNR nunca
    /// atenúa más que esto, pero picos leves se atenúan menos.
    /// Default: -12 dB (factor 0.25).
    /// Rango recomendado: -6 dB (suave) a -18 dB (agresivo).
    void setAttenuationDb(float db) {
        if (db > 0.0f) db = 0.0f;
        if (db < -24.0f) db = -24.0f;
        float linear = std::pow(10.0f, db / 20.0f);
        attenuationLinear_.store(linear, std::memory_order_relaxed);
    }

    /// Lee el último gain aplicado (para diagnóstico/UI).
    float getCurrentGain() const { return currentGain_; }

private:
    int sampleRate_ = 16000;

    // Coeficientes pre-calculados
    float fastCoeff_ = 0.0f;
    float slowCoeff_ = 0.0f;
    float recoveryCoeff_ = 0.0f;
    int holdSamples_ = 0;

    // Estado del detector (audio thread only)
    float fastEnv_ = 0.0f;
    float slowEnv_ = 1e-6f;
    float currentGain_ = 1.0f;
    int holdCounter_ = 0;

    // Parámetros atómicos (UI thread settable)
    std::atomic<bool> enabled_{true};
    std::atomic<float> thresholdRatio_{8.0f};       // Default: 8× sobre promedio
    std::atomic<float> attenuationLinear_{0.25f};   // Default: -12 dB
};

#endif // HEARING_AID_TRANSIENT_REDUCER_H

/// @file expander.h
/// @brief Expansor de baja frecuencia (≤1000 Hz) — downward expansion header-only.
///
/// Requisito R1 del spec `mvdr-noise-clarity-tuning`: en las pausas de voz el
/// ruido propio del micrófono (hiss) se amplifica porque la ganancia efectiva
/// del audífono sigue alta. La expansión hacia abajo (downward expansion) por
/// debajo de un knee configurable ATENÚA la ganancia cuando el nivel de entrada
/// es bajo. La literatura (AudiologyOnline art. 934; Brennan & Souza PMC2784644)
/// recomienda LIMITAR la expansión a baja frecuencia (≤1000 Hz) para NO comerse
/// las consonantes de alta frecuencia.
///
/// Diseño (header-only, patrón transient_reducer.h / feedback_suppressor.h → no
/// requiere entrada en CMakeLists.txt):
///   1. Split de banda: low = LPF_1000Hz(x) (Butterworth 2º orden),
///      high = x - low (complementario → suma reconstruye x exacto).
///   2. Downward expansion sobre la banda BAJA según el nivel de entrada
///      (inputLevelDb, dB SPL, mismo que usa el WDRC PRE-EQ).
///   3. Recombinar: out = high + low * gain. La banda alta queda intacta
///      (preserva consonantes → AC2).
///   4. Envelope de ganancia con attack/release INDEPENDIENTES:
///      - attack (≤50 ms): recuperación RÁPIDA de la ganancia cuando el nivel
///        sube sobre el knee (no cortar el arranque de la voz → AC6).
///      - release (~300-500 ms): atenuación LENTA cuando el nivel cae (evita
///        el bombeo audible → AC4a).
///
/// DECISIÓN T1(a) (mvdr-noise-clarity-tuning, tarea 1): el `expansionRatio`
/// REAL que Dart envía por `updateWdrcParams` es 2.0 (default de
/// `WdrcParams` en lib/domain/entities/wdrc_params.dart; el bloc construye
/// `WdrcParams(expansionKnee: bundle.expansionKneeDbSpl, ...)` sin fijar
/// `expansionRatio`, y audio_bridge_impl lo reenvía). El doc que decía 1.0
/// estaba desactualizado. Por lo tanto la expansión del WDRC está ACTIVA
/// (broadband, knee 35 dB SPL, ratio 2.0) y NO es selectiva en frecuencia.
/// Este Expansor NO reemplaza la del WDRC: COEXISTE como etapa independiente
/// y band-limitada ≤1000 Hz, con default OFF/ratio 1.0 (passthrough) → no
/// cambia el comportamiento previo (R6.3). El técnico lo activa aparte.
///
/// Defaults: enabled=false, ratio=1.0 → passthrough bit-exacto (R6.3, AC5, AC7).
///
/// Validates: Requirements 1.1, 1.2, 1.3, 1.4, 1.4a, 1.5, 1.6, 1.7

#ifndef HEARING_AID_EXPANDER_H
#define HEARING_AID_EXPANDER_H

#include <atomic>
#include <cmath>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/// Expansor hacia abajo band-limitado (≤1000 Hz). Header-only, thread-safe
/// (parámetros std::atomic, lock-free desde el hilo de UI).
class Expander {
public:
    Expander() = default;
    ~Expander() = default;

    /// Inicializa con el sample rate del sistema y recomputa los coeficientes.
    /// @param sampleRate Hz (típicamente 16000 o 48000).
    void init(int sampleRate) {
        sampleRate_ = sampleRate > 0 ? sampleRate : 16000;
        // Resetear estado del filtro y la ganancia suavizada.
        lpX1_ = lpX2_ = lpY1_ = lpY2_ = 0.0f;
        smoothedGain_ = 1.0f;
        updateLpfCoeffs();
        updateGainCoeffs();
    }

    /// Procesa un bloque in-place aplicando expansión band-limitada.
    /// @param buffer Audio float32 [-1, 1] (modificado in-place).
    /// @param blockSize Número de muestras.
    /// @param inputLevelDb Nivel de entrada PRE-EQ en dB SPL (el mismo que usa
    ///        el WDRC). Decide la ganancia objetivo de la expansión.
    void process(float* buffer, int blockSize, float inputLevelDb) {
        if (buffer == nullptr || blockSize <= 0) {
            return;
        }
        // AC5/AC7 + R6.3: OFF o ratio 1.0 → passthrough bit-exacto.
        if (!enabled_.load(std::memory_order_acquire)) {
            return;
        }
        const float ratio = ratio_.load(std::memory_order_relaxed);
        if (ratio <= 1.0f) {
            return;  // ratio 1.0 = sin reducción (AC3/AC7)
        }

        const float knee = kneeDbSpl_.load(std::memory_order_relaxed);

        // Ganancia objetivo por bloque (downward expansion). Misma fórmula que
        // la expansión del WDRC del proyecto para coherencia:
        //   reductionDb = (knee - level) * (1 - 1/ratio)   [solo si level<knee]
        //   targetGain  = 10^(-reductionDb/20)
        float targetGain = 1.0f;  // AC3: por encima del knee, sin reducción
        if (std::isfinite(inputLevelDb) && inputLevelDb < knee) {
            const float belowKnee = knee - inputLevelDb;
            const float reductionDb = belowKnee * (1.0f - 1.0f / ratio);
            targetGain = std::pow(10.0f, -reductionDb / 20.0f);
            if (targetGain < 0.0f) targetGain = 0.0f;
            if (targetGain > 1.0f) targetGain = 1.0f;
        }

        // Coeficiente de suavizado según dirección:
        //   subir ganancia (nivel sube sobre knee) → attack RÁPIDO (AC6, ≤50ms)
        //   bajar ganancia (nivel cae bajo knee)   → release LENTO (AC4a)
        const float attackCoeff  = attackCoeff_.load(std::memory_order_relaxed);
        const float releaseCoeff = releaseCoeff_.load(std::memory_order_relaxed);

        for (int i = 0; i < blockSize; ++i) {
            float x = buffer[i];
            if (!std::isfinite(x)) {
                // Sanitizar NaN/Inf como el EQ: resetear estado y emitir 0.
                x = 0.0f;
                lpX1_ = lpX2_ = lpY1_ = lpY2_ = 0.0f;
            }

            // LPF 1000 Hz (banda baja).
            float low = lpB0_ * x + lpB1_ * lpX1_ + lpB2_ * lpX2_
                      - lpA1_ * lpY1_ - lpA2_ * lpY2_;
            if (!std::isfinite(low)) {
                low = 0.0f;
                lpX1_ = lpX2_ = lpY1_ = lpY2_ = 0.0f;
            }
            lpX2_ = lpX1_; lpX1_ = x;
            lpY2_ = lpY1_; lpY1_ = low;

            // Banda alta complementaria (intacta → preserva consonantes).
            const float high = x - low;

            // Suavizar la ganancia hacia el objetivo (attack/release por dir).
            const float coeff = (targetGain > smoothedGain_) ? attackCoeff
                                                             : releaseCoeff;
            smoothedGain_ = coeff * smoothedGain_ + (1.0f - coeff) * targetGain;

            // Recombinar: banda alta intacta + banda baja expandida.
            buffer[i] = high + low * smoothedGain_;
        }
    }

    // ─── Toggle + parámetros (thread-safe) ───────────────────────────────

    /// Toggle de activación (AC5). Default OFF.
    void setEnabled(bool e) { enabled_.store(e, std::memory_order_release); }
    bool isEnabled() const { return enabled_.load(std::memory_order_acquire); }

    /// Knee de expansión en dB SPL (AC1). Default 45 dB SPL.
    void setKneeDbSpl(float knee) {
        kneeDbSpl_.store(knee, std::memory_order_relaxed);
    }

    /// Ratio de expansión (AC4). 1.0 = passthrough. Default 1.0.
    void setRatio(float ratio) {
        if (ratio < 1.0f) ratio = 1.0f;
        if (ratio > 10.0f) ratio = 10.0f;
        ratio_.store(ratio, std::memory_order_relaxed);
    }

    /// Frecuencia de corte superior del split (AC2). Default 1000 Hz.
    void setCutoffHz(float hz) {
        if (hz < 100.0f) hz = 100.0f;
        if (hz > static_cast<float>(sampleRate_) * 0.45f) {
            hz = static_cast<float>(sampleRate_) * 0.45f;
        }
        cutoffHz_.store(hz, std::memory_order_relaxed);
        updateLpfCoeffs();
    }

    /// Tiempo de ataque (recuperación de ganancia) en ms (AC6, ≤50 ms).
    void setAttackMs(float ms) {
        if (ms < 1.0f) ms = 1.0f;
        if (ms > 50.0f) ms = 50.0f;  // AC6: ataque acotado a ≤50 ms
        attackMs_.store(ms, std::memory_order_relaxed);
        updateGainCoeffs();
    }

    /// Tiempo de liberación (atenuación) en ms (AC4a). Default ~400 ms.
    void setReleaseMs(float ms) {
        if (ms < 10.0f) ms = 10.0f;
        if (ms > 2000.0f) ms = 2000.0f;
        releaseMs_.store(ms, std::memory_order_relaxed);
        updateGainCoeffs();
    }

private:
    /// Recalcula los coeficientes del LPF Butterworth 2º orden.
    void updateLpfCoeffs() {
        const float fc = cutoffHz_.load(std::memory_order_relaxed);
        const float fs = static_cast<float>(sampleRate_);
        const float omega = 2.0f * static_cast<float>(M_PI) * fc / fs;
        const float cosw = std::cos(omega);
        const float sinw = std::sin(omega);
        const float Q = 0.70710678f;  // Butterworth
        const float alpha = sinw / (2.0f * Q);

        const float a0 = 1.0f + alpha;
        lpB0_ = ((1.0f - cosw) * 0.5f) / a0;
        lpB1_ = (1.0f - cosw) / a0;
        lpB2_ = ((1.0f - cosw) * 0.5f) / a0;
        lpA1_ = (-2.0f * cosw) / a0;
        lpA2_ = (1.0f - alpha) / a0;
    }

    /// Recalcula los coeficientes de suavizado de la ganancia (one-pole).
    /// coeff = exp(-1 / (tauMs * 0.001 * fs)); mayor → más lento.
    void updateGainCoeffs() {
        const float fs = static_cast<float>(sampleRate_);
        const float atkMs = attackMs_.load(std::memory_order_relaxed);
        const float relMs = releaseMs_.load(std::memory_order_relaxed);
        attackCoeff_.store(std::exp(-1.0f / (atkMs * 0.001f * fs)),
                           std::memory_order_relaxed);
        releaseCoeff_.store(std::exp(-1.0f / (relMs * 0.001f * fs)),
                            std::memory_order_relaxed);
    }

    int sampleRate_ = 16000;

    // Parámetros (atómicos). Defaults = passthrough (R6.3, AC5, AC7).
    std::atomic<bool>  enabled_{false};
    std::atomic<float> kneeDbSpl_{45.0f};   // AC1
    std::atomic<float> ratio_{1.0f};        // AC4 (1.0 = passthrough)
    std::atomic<float> cutoffHz_{1000.0f};  // AC2
    std::atomic<float> attackMs_{30.0f};    // AC6 (≤50 ms)
    std::atomic<float> releaseMs_{400.0f};  // AC4a (release lento anti-bombeo)

    // Coeficientes de suavizado de ganancia (pre-calculados).
    std::atomic<float> attackCoeff_{0.0f};
    std::atomic<float> releaseCoeff_{0.0f};

    // Estado del LPF Butterworth 2º orden.
    float lpB0_ = 0.0f, lpB1_ = 0.0f, lpB2_ = 0.0f;
    float lpA1_ = 0.0f, lpA2_ = 0.0f;
    float lpX1_ = 0.0f, lpX2_ = 0.0f, lpY1_ = 0.0f, lpY2_ = 0.0f;

    // Ganancia suavizada actual (envelope). 1.0 = sin atenuación.
    float smoothedGain_ = 1.0f;
};

#endif // HEARING_AID_EXPANDER_H

/// @file auditory_model.h
/// @brief Modelo auditivo humano simplificado — 6 etapas fisiológicas header-only.
///
/// Simula la cadena periférica del oído humano para que la señal procesada
/// por el audífono se acerque a la percepción natural. El modelo es una
/// simplificación broadband para ejecución en tiempo real (no descompone en
/// 12 bandas gammatone separadas para evitar 12×4 biquads).
///
/// Etapas:
///   1. Resonancia del canal auditivo: peaking EQ 2700 Hz, +12 dB, Q=1.5
///   2. Oído medio: bandpass 400-4000 Hz, +3 dB (biquad)
///   3. Gammatone broadband: filtro coloreado según audiograma (cascada 4º orden)
///   4. Compresor OHC broadband: compresión basada en HL promedio
///   5. IHC (Inner Hair Cell): half-wave rectification + LP 1000 Hz + log compression
///   6. Nervio auditivo: envelope LP 50 Hz, modulación ×1.5
///
/// Referencias:
///   - Lyon, R. (2024). "Human and Machine Hearing" — modelo de cascada.
///   - Zilany, M.S.A. et al. (2014). "Updated auditory nerve model" — IHC/AN.
///   - Glasberg, B. & Moore, B. (1990). "Derivation of auditory filter shapes" — ERB.
///   - Moore, B. (2003). "An Introduction to the Psychology of Hearing" — OHC/IHC.
///   - Dillon, H. (2012). "Hearing Aids" — compresión clínica WDRC.
///
/// Diseño: header-only, patrón expander.h. Parámetros atómicos, lock-free.
/// Default: DESACTIVADO. Si !enabled → passthrough bit-exacto.

#ifndef HEARING_AID_AUDITORY_MODEL_H
#define HEARING_AID_AUDITORY_MODEL_H

#include <atomic>
#include <cmath>
#include <cstring>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/// Modelo auditivo humano simplificado para procesamiento en tiempo real.
/// Header-only, thread-safe (parámetros std::atomic, lock-free desde el hilo de UI).
class AuditoryModel {
public:
    static constexpr int kNumBands = 12;
    /// SPL offset del pipeline (constante de calibración).
    static constexpr float kSplOffset = 93.0f;

    AuditoryModel() = default;
    ~AuditoryModel() = default;

    /// Inicializa el modelo con el sample rate del sistema.
    /// Resetea todos los estados de filtro.
    /// @param sampleRate Hz (típicamente 16000 o 48000).
    void init(int sampleRate) {
        sampleRate_ = sampleRate > 0 ? sampleRate : 16000;
        resetState();
        computeEarCanalCoeffs();
        computeMiddleEarCoeffs();
        computeGammatoneCoeffs();
        computeIhcLpfCoeffs();
        computeAnEnvelopeCoeffs();
    }

    /// Procesa un bloque in-place aplicando el modelo auditivo acústico.
    /// Si el modelo está deshabilitado → passthrough bit-exacto.
    ///
    /// Solo se aplican etapas que colorean la señal de forma perceptualmente
    /// útil sin destruir el contenido espectral:
    ///   1. Resonancia canal auditivo: peaking suave 2700 Hz, +6 dB, Q=0.8
    ///   2. Oído medio: shelving (tilt) que atenúa <400 Hz y >4000 Hz suavemente
    ///   4. Compresor OHC broadband (compensación de reclutamiento)
    ///
    /// NOTA: La etapa 3 (Gammatone BPF) fue REMOVIDA del path serie porque un
    /// solo filtro gammatone angosto (Q=8, BW=186 Hz) recorta todo fuera de
    /// 1500 Hz y genera ruido resonante. El gammatone solo tiene sentido en un
    /// banco de filtros paralelos (análisis-síntesis), no en cadena serie.
    ///
    /// @param buffer Audio float32 [-1, 1] (modificado in-place).
    /// @param blockSize Número de muestras.
    void process(float* buffer, int blockSize) {
        if (buffer == nullptr || blockSize <= 0) return;
        if (!enabled_.load(std::memory_order_acquire)) return;

        for (int i = 0; i < blockSize; ++i) {
            float x = buffer[i];
            if (!std::isfinite(x)) x = 0.0f;

            // ─── Etapa 1: Resonancia del canal auditivo (peaking 2700 Hz) ──────
            // Reducida a +6 dB (vs +12 original) y Q=0.8 (más ancha) para
            // simular la resonancia sin amplificar excesivamente el ruido de piso.
            x = processBiquad(x, ecB0_, ecB1_, ecB2_, ecA1_, ecA2_,
                              ecX1_, ecX2_, ecY1_, ecY2_);

            // ─── Etapa 2: Oído medio (shelving suave) ──────────────────────────
            // Modela la transferencia mecánica como un tilt leve, no como un BPF
            // angosto que recortaba contenido útil.
            x = processBiquad(x, meB0_, meB1_, meB2_, meA1_, meA2_,
                              meX1_, meX2_, meY1_, meY2_);

            // ─── Etapa 3: BYPASS (gammatone removido — ver nota arriba) ─────────

            // ─── Etapa 4: Compresor OHC broadband ──────────────────────────────
            x = processOhcCompression(x);

            // Saturar suavemente a [-1, 1] para no romper etapas posteriores.
            if (x > 1.0f) x = 1.0f;
            if (x < -1.0f) x = -1.0f;

            buffer[i] = x;
        }
    }

    // ─── Setters thread-safe ─────────────────────────────────────────────────

    /// Habilita/deshabilita el modelo auditivo. Default: OFF.
    void setEnabled(bool e) { enabled_.store(e, std::memory_order_release); }
    bool isEnabled() const { return enabled_.load(std::memory_order_acquire); }

    /// Configura el audiograma de 12 bandas (dB HL) para adaptar la compresión OHC.
    /// Las 12 bandas corresponden a: 250, 500, 750, 1000, 1500, 2000, 2500,
    /// 3000, 3500, 4000, 6000, 8000 Hz.
    /// @param thresholds Array de 12 valores dB HL.
    void setAudiogram(const float thresholds[kNumBands]) {
        if (thresholds == nullptr) return;
        // Calcular HL promedio para la compresión broadband.
        float sum = 0.0f;
        for (int i = 0; i < kNumBands; ++i) {
            sum += thresholds[i];
        }
        float avgHl = sum / static_cast<float>(kNumBands);
        // Derivar ratio de compresión OHC según el HL promedio:
        //   HL < 20: sin compensación (ratio = 1.0, solo unity gain)
        //   HL 20-60: expansión (ratio = 1 - (HL-20)/80)
        //   HL > 60: ganancia lineal (ratio = 0.5 — compresión mínima fija)
        float ratio;
        if (avgHl < 20.0f) {
            ratio = 1.0f;  // Audición normal, sin compensar
        } else if (avgHl <= 60.0f) {
            ratio = 1.0f - (avgHl - 20.0f) / 80.0f;  // [1.0 → 0.5]
        } else {
            ratio = 0.5f;  // Pérdida severa, compresión máxima
        }
        ohcRatio_.store(ratio, std::memory_order_relaxed);
    }

private:
    int sampleRate_ = 16000;

    // ─── Parámetros atómicos ─────────────────────────────────────────────────
    std::atomic<bool>  enabled_{false};
    /// Ratio de compresión OHC derivado del audiograma. 1.0 = sin compresión.
    std::atomic<float> ohcRatio_{1.0f};

    // ─── Biquad genérico (Direct Form I) ────────────────────────────────────
    static float processBiquad(float x,
                               float b0, float b1, float b2,
                               float a1, float a2,
                               float& x1, float& x2,
                               float& y1, float& y2) {
        float y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        if (!std::isfinite(y)) {
            y = 0.0f;
            x1 = x2 = y1 = y2 = 0.0f;
        }
        x2 = x1; x1 = x;
        y2 = y1; y1 = y;
        return y;
    }

    // ─── Etapa 1: Resonancia canal auditivo ─────────────────────────────────
    // Peaking EQ @ 2700 Hz, +12 dB, Q=1.5 (modela la resonancia del conducto
    // auditivo externo, típicamente 2.5-3 kHz, pico de 10-15 dB — Shaw 1974).
    float ecB0_ = 1.0f, ecB1_ = 0.0f, ecB2_ = 0.0f;
    float ecA1_ = 0.0f, ecA2_ = 0.0f;
    float ecX1_ = 0.0f, ecX2_ = 0.0f, ecY1_ = 0.0f, ecY2_ = 0.0f;

    void computeEarCanalCoeffs() {
        // Peaking EQ @ 2700 Hz, +6 dB (conservador), Q=0.8 (ancho).
        // Modela la resonancia del conducto auditivo sin amplificar el ruido
        // de piso del micrófono. Shaw (1974): pico real ~12-17 dB pero el
        // mic ya captura parte de esa resonancia → solo realzamos +6 dB.
        const float fc = 2700.0f;
        const float gainDb = 6.0f;   // era 12 → reducido
        const float Q = 0.8f;        // era 1.5 → más ancho, menos resonante
        const float fs = static_cast<float>(sampleRate_);
        const float omega = 2.0f * static_cast<float>(M_PI) * fc / fs;
        const float sinw = std::sin(omega);
        const float cosw = std::cos(omega);
        const float A = std::pow(10.0f, gainDb / 40.0f);
        const float alpha = sinw / (2.0f * Q);

        const float a0 = 1.0f + alpha / A;
        ecB0_ = (1.0f + alpha * A) / a0;
        ecB1_ = (-2.0f * cosw) / a0;
        ecB2_ = (1.0f - alpha * A) / a0;
        ecA1_ = (-2.0f * cosw) / a0;
        ecA2_ = (1.0f - alpha / A) / a0;
    }

    // ─── Etapa 2: Oído medio ────────────────────────────────────────────────
    // Bandpass 400-4000 Hz con +3 dB de ganancia (modela la transferencia
    // mecánica del tímpano + cadena osicular — Voss et al. 2000).
    float meB0_ = 1.0f, meB1_ = 0.0f, meB2_ = 0.0f;
    float meA1_ = 0.0f, meA2_ = 0.0f;
    float meX1_ = 0.0f, meX2_ = 0.0f, meY1_ = 0.0f, meY2_ = 0.0f;

    void computeMiddleEarCoeffs() {
        // HIGH-SHELF inverso @ 4000 Hz, -3 dB. Modela la atenuación natural
        // del oído medio por encima de 4 kHz, sin recortar graves (el BPF
        // anterior con Q=0.35 era demasiado agresivo y generaba ruido por
        // recortar energía útil). Este shelf solo atenúa suavemente >4 kHz.
        const float fc = 4000.0f;
        const float gainDb = -3.0f;  // atenuar altas frecuencias
        const float Q = 0.707f;      // Butterworth slope
        const float fs = static_cast<float>(sampleRate_);
        const float omega = 2.0f * static_cast<float>(M_PI) * fc / fs;
        const float sinw = std::sin(omega);
        const float cosw = std::cos(omega);
        const float A = std::pow(10.0f, gainDb / 40.0f);
        const float alpha = sinw / (2.0f * Q);

        // High-shelf coefficients (Audio EQ Cookbook)
        const float a0 = (A + 1.0f) - (A - 1.0f) * cosw + 2.0f * std::sqrt(A) * alpha;
        meB0_ = (A * ((A + 1.0f) + (A - 1.0f) * cosw + 2.0f * std::sqrt(A) * alpha)) / a0;
        meB1_ = (-2.0f * A * ((A - 1.0f) + (A + 1.0f) * cosw)) / a0;
        meB2_ = (A * ((A + 1.0f) + (A - 1.0f) * cosw - 2.0f * std::sqrt(A) * alpha)) / a0;
        meA1_ = (2.0f * ((A - 1.0f) - (A + 1.0f) * cosw)) / a0;
        meA2_ = ((A + 1.0f) - (A - 1.0f) * cosw - 2.0f * std::sqrt(A) * alpha) / a0;
    }

    // ─── Etapa 3: Gammatone broadband ───────────────────────────────────────
    // Cascada de 2 biquads (= 4º orden) centrada en 1500 Hz con ancho ERB.
    // ERB = 24.7 * (4.37 * f/1000 + 1) = 24.7 * (4.37*1.5 + 1) = 24.7 * 7.555 = 186.6 Hz
    // Q = fc / ERB = 1500 / 186.6 ≈ 8.04
    // Glasberg & Moore (1990) — auditory filter shape.
    float gtB0_ = 1.0f, gtB1_ = 0.0f, gtB2_ = 0.0f;
    float gtA1_ = 0.0f, gtA2_ = 0.0f;
    float gtX1_[2] = {0.0f, 0.0f}, gtX2_[2] = {0.0f, 0.0f};
    float gtY1_[2] = {0.0f, 0.0f}, gtY2_[2] = {0.0f, 0.0f};

    void computeGammatoneCoeffs() {
        const float fc = 1500.0f;
        // ERB = 24.7 * (4.37 * fc/1000 + 1)
        const float erb = 24.7f * (4.37f * fc / 1000.0f + 1.0f);
        const float Q = fc / erb;
        const float fs = static_cast<float>(sampleRate_);
        const float omega = 2.0f * static_cast<float>(M_PI) * fc / fs;
        const float sinw = std::sin(omega);
        const float cosw = std::cos(omega);
        const float alpha = sinw / (2.0f * Q);

        // BPF coeficientes (unity gain at center)
        const float a0 = 1.0f + alpha;
        gtB0_ = alpha / a0;
        gtB1_ = 0.0f;
        gtB2_ = -alpha / a0;
        gtA1_ = (-2.0f * cosw) / a0;
        gtA2_ = (1.0f - alpha) / a0;
    }

    // ─── Etapa 4: Compresor OHC ─────────────────────────────────────────────
    // Knee 30 dB SPL (referido al kSplOffset), attack 5 ms, release 100 ms.
    // Ratio derivado del audiograma (setAudiogram). Simula la compresión activa
    // de las outer hair cells. Dillon (2012), Moore (2003).
    float ohcEnvelope_ = 0.0f;
    float ohcAttackCoeff_ = 0.0f;
    float ohcReleaseCoeff_ = 0.0f;

    float processOhcCompression(float x) {
        const float ratio = ohcRatio_.load(std::memory_order_relaxed);
        if (ratio >= 1.0f) return x; // Sin compresión

        // Knee en amplitud lineal: 30 dB SPL → 30-93 = -63 dBFS → 10^(-63/20)
        constexpr float kneeDbSpl = 30.0f;
        constexpr float kneeDbFs = kneeDbSpl - kSplOffset; // -63
        constexpr float kneeLin = 7.08e-4f; // pow(10, -63/20) ≈ 0.000708

        // Envelope tracking (peak detector con attack/release)
        const float absx = std::fabs(x);
        const float coeff = (absx > ohcEnvelope_) ? ohcAttackCoeff_ : ohcReleaseCoeff_;
        ohcEnvelope_ = coeff * ohcEnvelope_ + (1.0f - coeff) * absx;

        // Si la envolvente está bajo el knee, comprimir.
        if (ohcEnvelope_ < kneeLin && ohcEnvelope_ > 1e-10f) {
            // Ganancia de compresión: gainDb = (kneeDb - levelDb) * (1 - ratio)
            const float levelDb = 20.0f * std::log10(ohcEnvelope_);
            const float kneeLevelDb = 20.0f * std::log10(kneeLin);
            const float reductionDb = (kneeLevelDb - levelDb) * (1.0f - ratio);
            const float gain = std::pow(10.0f, -reductionDb / 20.0f);
            return x * gain;
        }
        return x;
    }

    // ─── Etapa 5: IHC LP 1 kHz ─────────────────────────────────────────────
    float ihcB0_ = 1.0f, ihcB1_ = 0.0f, ihcB2_ = 0.0f;
    float ihcA1_ = 0.0f, ihcA2_ = 0.0f;
    float ihcX1_ = 0.0f, ihcX2_ = 0.0f, ihcY1_ = 0.0f, ihcY2_ = 0.0f;

    void computeIhcLpfCoeffs() {
        computeLpfButterworth(1000.0f, ihcB0_, ihcB1_, ihcB2_, ihcA1_, ihcA2_);
    }

    // ─── Etapa 6: Nervio auditivo LP 50 Hz (envelope) ──────────────────────
    float anB0_ = 1.0f, anB1_ = 0.0f, anB2_ = 0.0f;
    float anA1_ = 0.0f, anA2_ = 0.0f;
    float anX1_ = 0.0f, anX2_ = 0.0f, anY1_ = 0.0f, anY2_ = 0.0f;

    void computeAnEnvelopeCoeffs() {
        computeLpfButterworth(50.0f, anB0_, anB1_, anB2_, anA1_, anA2_);
    }

    // ─── Helper: LPF Butterworth 2º orden ───────────────────────────────────
    void computeLpfButterworth(float fc,
                               float& b0, float& b1, float& b2,
                               float& a1, float& a2) {
        const float fs = static_cast<float>(sampleRate_);
        const float omega = 2.0f * static_cast<float>(M_PI) * fc / fs;
        const float cosw = std::cos(omega);
        const float sinw = std::sin(omega);
        const float Q = 0.70710678f; // Butterworth
        const float alpha = sinw / (2.0f * Q);

        const float a0inv = 1.0f / (1.0f + alpha);
        b0 = ((1.0f - cosw) * 0.5f) * a0inv;
        b1 = (1.0f - cosw) * a0inv;
        b2 = ((1.0f - cosw) * 0.5f) * a0inv;
        a1 = (-2.0f * cosw) * a0inv;
        a2 = (1.0f - alpha) * a0inv;
    }

    /// Resetea todos los estados de filtro y la envolvente OHC.
    void resetState() {
        ecX1_ = ecX2_ = ecY1_ = ecY2_ = 0.0f;
        meX1_ = meX2_ = meY1_ = meY2_ = 0.0f;
        for (int i = 0; i < 2; ++i) {
            gtX1_[i] = gtX2_[i] = gtY1_[i] = gtY2_[i] = 0.0f;
        }
        ihcX1_ = ihcX2_ = ihcY1_ = ihcY2_ = 0.0f;
        anX1_ = anX2_ = anY1_ = anY2_ = 0.0f;
        ohcEnvelope_ = 0.0f;
        // Compute OHC attack/release coeficientes.
        const float fs = static_cast<float>(sampleRate_);
        ohcAttackCoeff_  = std::exp(-1.0f / (5.0f * 0.001f * fs));   // 5 ms
        ohcReleaseCoeff_ = std::exp(-1.0f / (100.0f * 0.001f * fs)); // 100 ms
    }
};

#endif // HEARING_AID_AUDITORY_MODEL_H

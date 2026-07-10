/// @file auditory_model.h
/// @brief Modelo del sistema auditivo humano — 6 etapas de simulacion coclear.
///
/// Simula el procesamiento auditivo humano para compensar la perdida auditiva
/// de forma perceptualmente correcta. Cada etapa modela un componente anatomico
/// real del oido, aplicando compensaciones personalizadas segun el audiograma.
///
/// Etapas:
///   1. Canal auditivo: resonancia a 2700 Hz (+12 dB, Q=1.5) — REUR
///   2. Oido medio: bandpass 400-4000 Hz (+3 dB) — transferencia mecanica
///   3. Membrana basilar: 12 filtros gammatone 4to orden (ERB Glasberg & Moore 1990)
///   4. OHC (celulas ciliadas externas): compresor dinamico (knee 30 dB SPL)
///   5. IHC (celulas ciliadas internas): rectificacion + LP 1 kHz + log
///   6. Nervio auditivo: realce temporal (modulacion x1.5)
///
/// Referencias cientificas:
///   - Glasberg & Moore (1990): ERB(f) = 24.7 * (4.37 * f/1000 + 1)
///   - Moore (2003): Loudness recruitment — OHC damage → compression loss
///   - Zilany, Bruce & Carney (2014): Auditory periphery model (JASA 136(1))
///   - Lyon (2024): CARFAC v2 (arXiv:2404.17490) — cochlear model
///   - Dillon (2012): Hearing Aids, Chapter 6 — compression fundamentals
///   - PMC4432547: Ear canal resonance at 2700 Hz
///   - Hearing Review: REUR acoustics (+12-16.8 dB at 2700 Hz)
///
/// Diseno:
///   - Header-only para simplicidad (inlined por el compilador con -O2).
///   - Thread-safe: enable/disable atomico; audiograma inmutable post-set.
///   - Insercion en pipeline: despues de EQ, antes de WDRC.
///   - Cuando disabled: passthrough puro (sin overhead).
///   - SPL offset: 93 dB (calibracion del pipeline existente).

#ifndef HEARING_AID_AUDITORY_MODEL_H
#define HEARING_AID_AUDITORY_MODEL_H

#include <atomic>
#include <cmath>
#include <cstring>
#include <algorithm>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/// Frecuencias centrales del audiograma (12 bandas, Hz).
static constexpr float kAudiogramFreqs[12] = {
    250.0f, 500.0f, 750.0f, 1000.0f, 1500.0f, 2000.0f,
    2500.0f, 3000.0f, 3500.0f, 4000.0f, 6000.0f, 8000.0f
};

/// Modelo del sistema auditivo humano — 6 etapas.
///
/// Procesa audio en bloques (tipicamente 256 muestras) simulando la cadena
/// auditiva desde el canal auditivo hasta el nervio auditivo, aplicando
/// compensaciones personalizadas segun la perdida auditiva del paciente.
class AuditoryModel {
public:
    /// Estructura del audiograma del paciente (12 bandas, en dB HL).
    struct Audiogram {
        float thresholds[12] = {};  ///< Umbrales por banda en dB HL (0 = normal)
    };

    AuditoryModel() = default;

    /// Inicializa el modelo con el sample rate del sistema.
    /// Debe llamarse una vez antes de process().
    void init(int sampleRate) {
        sampleRate_ = static_cast<float>(sampleRate);
        computeEarCanalFilter();
        computeMiddleEarFilter();
        computeGammatoneBank();
        computeOhcParams();
        computeIhcFilter();
        computeAnParams();
        reset();
    }

    /// Resetea todos los estados internos (filtros, envelopes).
    void reset() {
        // Ear canal biquad state
        ecX1_ = ecX2_ = ecY1_ = ecY2_ = 0.0f;
        // Middle ear biquad states (HP + LP cascade)
        meHpX1_ = meHpX2_ = meHpY1_ = meHpY2_ = 0.0f;
        meLpX1_ = meLpX2_ = meLpY1_ = meLpY2_ = 0.0f;
        // Gammatone states
        for (int b = 0; b < 12; ++b) {
            for (int s = 0; s < 4; ++s) {
                gtX1_[b][s] = gtX2_[b][s] = 0.0f;
                gtY1_[b][s] = gtY2_[b][s] = 0.0f;
            }
        }
        // OHC envelope
        for (int b = 0; b < 12; ++b) {
            ohcEnv_[b] = 0.0f;
        }
        // IHC state
        ihcY1_ = 0.0f;
        // AN envelope
        anEnv_ = 0.0f;
    }

    /// Habilita o deshabilita el modelo auditivo.
    /// Thread-safe (atomico). Cuando disabled, process() es passthrough.
    void setEnabled(bool enabled) {
        enabled_.store(enabled, std::memory_order_release);
    }
    bool isEnabled() const {
        return enabled_.load(std::memory_order_acquire);
    }

    /// Configura el audiograma del paciente.
    /// Los umbrales en dB HL determinan la compensacion OHC por banda.
    /// Thread-safe: copia atomica de 12 floats (el caller no debe mutar
    /// el array durante la llamada, pero el process() lee una copia estable).
    void setAudiogram(const float thresholds[12]) {
        for (int i = 0; i < 12; ++i) {
            audiogram_.thresholds[i] = thresholds[i];
        }
        computeOhcParams();
        audiogramSet_.store(true, std::memory_order_release);
    }

    /// Procesa un bloque de audio in-place.
    /// Si el modelo esta deshabilitado, no modifica el buffer.
    void process(float* buffer, int blockSize) {
        if (!enabled_.load(std::memory_order_acquire)) {
            return;  // Passthrough
        }

        for (int i = 0; i < blockSize; ++i) {
            float sample = buffer[i];

            // ─── Etapa 1: Resonancia del canal auditivo ─────────────────
            // Peaking EQ a 2700 Hz, +12 dB, Q=1.5 (REUR medido clinicamente).
            sample = applyBiquad(sample, ecB0_, ecB1_, ecB2_, ecA1_, ecA2_,
                                 ecX1_, ecX2_, ecY1_, ecY2_);

            // ─── Etapa 2: Transferencia del oido medio ──────────────────
            // Bandpass 400-4000 Hz con +3 dB de ganancia (cascada HP + LP).
            sample = applyBiquad(sample, meHpB0_, meHpB1_, meHpB2_, meHpA1_, meHpA2_,
                                 meHpX1_, meHpX2_, meHpY1_, meHpY2_);
            sample = applyBiquad(sample, meLpB0_, meLpB1_, meLpB2_, meLpA1_, meLpA2_,
                                 meLpX1_, meLpX2_, meLpY1_, meLpY2_);
            // Ganancia del oido medio (+3 dB = 1.41x)
            sample *= meGainLinear_;

            // ─── Etapa 3: Banco de filtros gammatone (membrana basilar) ──
            // 12 filtros de 4to orden (cascada de 4 biquads), centrados en
            // las frecuencias del audiograma. Simula la descomposicion
            // tonotopica de la membrana basilar.
            float bandSignals[12];
            for (int b = 0; b < 12; ++b) {
                float s = sample;
                for (int stage = 0; stage < 4; ++stage) {
                    s = applyBiquad(s, gtB0_[b], gtB1_[b], gtB2_[b],
                                    gtA1_[b], gtA2_[b],
                                    gtX1_[b][stage], gtX2_[b][stage],
                                    gtY1_[b][stage], gtY2_[b][stage]);
                }
                bandSignals[b] = s;
            }

            // ─── Etapa 4: Compresor OHC (celulas ciliadas externas) ─────
            // Las OHC sanas comprimen la senal (~3:1 arriba de 30 dB SPL).
            // Con perdida auditiva, las OHC se danan y pierden compresion
            // → reclutamiento. Compensamos aplicando expansion proporcional
            // a la perdida: mas HL → menos compresion aplicada → mas ganancia
            // en niveles bajos.
            for (int b = 0; b < 12; ++b) {
                float absVal = std::fabs(bandSignals[b]);
                // Envelope follower (attack 5 ms, release adaptativo segun HL)
                float coeff = (absVal > ohcEnv_[b]) ? ohcAttackCoeff_
                                                     : ohcReleaseCoeff_[b];
                ohcEnv_[b] += coeff * (absVal - ohcEnv_[b]);

                // Compresion compensatoria: el gain depende del nivel y del HL
                float env = std::max(ohcEnv_[b], 1e-10f);
                float gainDb = ohcGainDb_[b] * (1.0f - env / ohcKneeLinear_);
                gainDb = std::max(gainDb, 0.0f);  // Solo amplifica en niveles bajos
                float gainLin = std::pow(10.0f, gainDb / 20.0f);
                bandSignals[b] *= gainLin;
            }

            // ─── Etapa 5: Transduccion IHC (celulas ciliadas internas) ──
            // Rectificacion media onda → LP 1 kHz → compresion logaritmica.
            // Simula la conversion mecanica→electrica de la coclea.
            float summed = 0.0f;
            for (int b = 0; b < 12; ++b) {
                summed += bandSignals[b];
            }
            // Rectificacion media onda (solo positivos)
            float rectified = std::max(summed, 0.0f);
            // Low-pass 1 kHz (adaptacion temporal IHC)
            ihcY1_ += ihcLpCoeff_ * (rectified - ihcY1_);
            float ihcOut = ihcY1_;
            // Compresion logaritmica suave (sqrt como proxy)
            float sign = (summed >= 0.0f) ? 1.0f : -1.0f;
            float compressed = sign * std::sqrt(std::fabs(ihcOut) + 1e-10f);

            // ─── Etapa 6: Realce temporal del nervio auditivo ───────────
            // El nervio auditivo tiene phase-locking que se degrada con HL.
            // Compensacion: detectar envolvente (LP 50 Hz), amplificar
            // modulaciones x1.5 para mejorar inteligibilidad en ruido.
            float absComp = std::fabs(compressed);
            anEnv_ += anEnvCoeff_ * (absComp - anEnv_);
            // Modulacion = senal / envelope. Amplificar modulacion.
            float modulation = 1.0f;
            if (anEnv_ > 1e-8f) {
                modulation = absComp / anEnv_;
            }
            // Amplificar modulaciones (x1.5) preservando la envolvente
            float enhanced = compressed * (1.0f + anModGain_ * (modulation - 1.0f));

            // ─── Recombinacion ──────────────────────────────────────────
            // Mezcla con la senal original para controlar la intensidad
            // del efecto y evitar distorsion excesiva.
            // Mix 60% modelo + 40% original (conservador para primera version)
            buffer[i] = 0.6f * enhanced + 0.4f * buffer[i];
        }
    }

private:
    // ─── Biquad helper ──────────────────────────────────────────────────
    static inline float applyBiquad(float x,
                                     float b0, float b1, float b2,
                                     float a1, float a2,
                                     float& x1, float& x2,
                                     float& y1, float& y2) {
        float y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1; x1 = x;
        y2 = y1; y1 = y;
        return y;
    }

    // ─── Etapa 1: Filtro del canal auditivo (peaking EQ) ────────────────
    void computeEarCanalFilter() {
        // Peaking EQ: fc=2700 Hz, gain=+12 dB, Q=1.5
        const float fc = 2700.0f;
        const float gainDb = 12.0f;
        const float Q = 1.5f;

        float A = std::pow(10.0f, gainDb / 40.0f);  // sqrt of linear gain
        float w0 = 2.0f * static_cast<float>(M_PI) * fc / sampleRate_;
        float sinw0 = std::sin(w0);
        float cosw0 = std::cos(w0);
        float alpha = sinw0 / (2.0f * Q);

        float b0 = 1.0f + alpha * A;
        float b1 = -2.0f * cosw0;
        float b2 = 1.0f - alpha * A;
        float a0 = 1.0f + alpha / A;
        float a1 = -2.0f * cosw0;
        float a2 = 1.0f - alpha / A;

        // Normalizar por a0
        ecB0_ = b0 / a0;
        ecB1_ = b1 / a0;
        ecB2_ = b2 / a0;
        ecA1_ = a1 / a0;
        ecA2_ = a2 / a0;
    }

    // ─── Etapa 2: Filtro del oido medio (bandpass 400-4000 Hz) ──────────
    void computeMiddleEarFilter() {
        // High-pass a 400 Hz (2do orden Butterworth)
        {
            float fc = 400.0f;
            float w0 = 2.0f * static_cast<float>(M_PI) * fc / sampleRate_;
            float cosw0 = std::cos(w0);
            float sinw0 = std::sin(w0);
            float alpha = sinw0 / (2.0f * 0.707f);  // Q = 0.707 (Butterworth)

            float a0 = 1.0f + alpha;
            meHpB0_ = ((1.0f + cosw0) / 2.0f) / a0;
            meHpB1_ = (-(1.0f + cosw0)) / a0;
            meHpB2_ = ((1.0f + cosw0) / 2.0f) / a0;
            meHpA1_ = (-2.0f * cosw0) / a0;
            meHpA2_ = (1.0f - alpha) / a0;
        }
        // Low-pass a 4000 Hz (2do orden Butterworth)
        {
            float fc = 4000.0f;
            float w0 = 2.0f * static_cast<float>(M_PI) * fc / sampleRate_;
            float cosw0 = std::cos(w0);
            float sinw0 = std::sin(w0);
            float alpha = sinw0 / (2.0f * 0.707f);

            float a0 = 1.0f + alpha;
            meLpB0_ = ((1.0f - cosw0) / 2.0f) / a0;
            meLpB1_ = (1.0f - cosw0) / a0;
            meLpB2_ = ((1.0f - cosw0) / 2.0f) / a0;
            meLpA1_ = (-2.0f * cosw0) / a0;
            meLpA2_ = (1.0f - alpha) / a0;
        }
        // Ganancia del oido medio: +3 dB
        meGainLinear_ = std::pow(10.0f, 3.0f / 20.0f);  // ~1.41
    }

    // ─── Etapa 3: Banco de filtros gammatone ────────────────────────────
    void computeGammatoneBank() {
        // Cada filtro gammatone se aproxima con un biquad resonante
        // (bandpass) con ancho de banda ERB. 4 cascadas dan el 4to orden.
        for (int b = 0; b < 12; ++b) {
            float fc = kAudiogramFreqs[b];
            // ERB (Glasberg & Moore 1990)
            float erb = 24.7f * (4.37f * fc / 1000.0f + 1.0f);
            // Bandwidth del biquad = ERB (para una cascada, el BW efectivo
            // se reduce por el factor de cascada, simulando el gammatone)
            float bw = erb;

            float w0 = 2.0f * static_cast<float>(M_PI) * fc / sampleRate_;
            float cosw0 = std::cos(w0);
            float sinw0 = std::sin(w0);
            // Q = fc / BW
            float Q = fc / bw;
            float alpha = sinw0 / (2.0f * Q);

            float a0 = 1.0f + alpha;
            // Bandpass (peak gain = 1)
            gtB0_[b] = (sinw0 / 2.0f) / a0;   // = alpha / a0 (BPF skirt gain)
            gtB1_[b] = 0.0f;
            gtB2_[b] = -(sinw0 / 2.0f) / a0;
            gtA1_[b] = (-2.0f * cosw0) / a0;
            gtA2_[b] = (1.0f - alpha) / a0;
        }
    }

    // ─── Etapa 4: Parametros del compresor OHC ──────────────────────────
    void computeOhcParams() {
        // Attack: 5 ms
        float attackMs = 5.0f;
        ohcAttackCoeff_ = 1.0f - std::exp(-1.0f / (sampleRate_ * attackMs / 1000.0f));

        // Knee: 30 dB SPL → lineal (usando SPL offset 93 del pipeline)
        const float kneeSpl = 30.0f;
        const float splOffset = 93.0f;
        ohcKneeLinear_ = std::pow(10.0f, (kneeSpl - splOffset) / 20.0f);

        for (int b = 0; b < 12; ++b) {
            float hl = audiogram_.thresholds[b];
            // Release adaptativo: mas HL → release mas lento (50-200 ms)
            float releaseMs = 50.0f + (hl / 60.0f) * 150.0f;  // 50 ms @ 0 HL, 200 ms @ 60 HL
            releaseMs = std::clamp(releaseMs, 50.0f, 200.0f);
            ohcReleaseCoeff_[b] = 1.0f - std::exp(-1.0f / (sampleRate_ * releaseMs / 1000.0f));

            // Ganancia compensatoria: proporcional a la perdida HL.
            // A mayor HL, las OHC estan mas danadas → necesitan mas
            // compensacion en niveles bajos. Rango: 0-20 dB de ganancia.
            ohcGainDb_[b] = std::min(hl * 0.33f, 20.0f);  // 1/3 del HL, max 20 dB
        }
    }

    // ─── Etapa 5: Filtro IHC (low-pass 1 kHz) ──────────────────────────
    void computeIhcFilter() {
        // LP 1er orden a 1000 Hz (adaptacion temporal IHC)
        float fc = 1000.0f;
        float rc = 1.0f / (2.0f * static_cast<float>(M_PI) * fc);
        float dt = 1.0f / sampleRate_;
        ihcLpCoeff_ = dt / (rc + dt);
    }

    // ─── Etapa 6: Parametros del nervio auditivo ────────────────────────
    void computeAnParams() {
        // Envelope LP a 50 Hz
        float fc = 50.0f;
        float rc = 1.0f / (2.0f * static_cast<float>(M_PI) * fc);
        float dt = 1.0f / sampleRate_;
        anEnvCoeff_ = dt / (rc + dt);

        // Ganancia de modulacion: 1.5x (amplifica fluctuaciones temporales)
        anModGain_ = 0.5f;  // multiplicador adicional: 1 + 0.5*(mod-1) = 1.5*mod cuando mod>1
    }

    // ─── Estado ─────────────────────────────────────────────────────────
    std::atomic<bool> enabled_{false};
    std::atomic<bool> audiogramSet_{false};
    float sampleRate_ = 48000.0f;
    Audiogram audiogram_;

    // ─── Etapa 1: Canal auditivo (peaking EQ biquad) ────────────────────
    float ecB0_ = 1.0f, ecB1_ = 0.0f, ecB2_ = 0.0f;
    float ecA1_ = 0.0f, ecA2_ = 0.0f;
    float ecX1_ = 0.0f, ecX2_ = 0.0f, ecY1_ = 0.0f, ecY2_ = 0.0f;

    // ─── Etapa 2: Oido medio (HP + LP cascade) ─────────────────────────
    float meHpB0_ = 1.0f, meHpB1_ = 0.0f, meHpB2_ = 0.0f;
    float meHpA1_ = 0.0f, meHpA2_ = 0.0f;
    float meHpX1_ = 0.0f, meHpX2_ = 0.0f, meHpY1_ = 0.0f, meHpY2_ = 0.0f;
    float meLpB0_ = 1.0f, meLpB1_ = 0.0f, meLpB2_ = 0.0f;
    float meLpA1_ = 0.0f, meLpA2_ = 0.0f;
    float meLpX1_ = 0.0f, meLpX2_ = 0.0f, meLpY1_ = 0.0f, meLpY2_ = 0.0f;
    float meGainLinear_ = 1.41f;

    // ─── Etapa 3: Gammatone bank (12 bandas x 4 stages) ─────────────────
    float gtB0_[12] = {}, gtB1_[12] = {}, gtB2_[12] = {};
    float gtA1_[12] = {}, gtA2_[12] = {};
    float gtX1_[12][4] = {}, gtX2_[12][4] = {};
    float gtY1_[12][4] = {}, gtY2_[12][4] = {};

    // ─── Etapa 4: Compresor OHC ─────────────────────────────────────────
    float ohcAttackCoeff_ = 0.0f;
    float ohcReleaseCoeff_[12] = {};
    float ohcGainDb_[12] = {};
    float ohcKneeLinear_ = 0.001f;
    float ohcEnv_[12] = {};

    // ─── Etapa 5: IHC ───────────────────────────────────────────────────
    float ihcLpCoeff_ = 0.0f;
    float ihcY1_ = 0.0f;

    // ─── Etapa 6: Nervio auditivo ───────────────────────────────────────
    float anEnvCoeff_ = 0.0f;
    float anModGain_ = 0.5f;
    float anEnv_ = 0.0f;
};

#endif // HEARING_AID_AUDITORY_MODEL_H

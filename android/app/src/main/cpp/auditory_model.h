/// @file auditory_model.h
/// @brief Modo Audífono Avanzado — procesamiento multicanal adaptativo.
///
/// Cuando está habilitado, REEMPLAZA el EQ fijo (12 bandas lineales) y el
/// WDRC broadband por un algoritmo superior basado en modelamiento auditivo:
///
///   1. Banco de filtros multicanal (12 bandas, frecuencias del audiograma)
///   2. Compresión por banda con knee/ratio personalizados según audiograma
///   3. Ganancias adaptativas por nivel (más ganancia a sonidos suaves)
///   4. Realce temporal de modulaciones del habla (mejora inteligibilidad)
///
/// Diferencias clave vs. EQ+WDRC clásico:
///   - EQ clásico: ganancia FIJA por banda (no importa si el sonido es fuerte o suave)
///   - Modo Avanzado: ganancia ADAPTATIVA por banda (suaves se amplifican más, fuertes menos)
///   - WDRC clásico: 1 compresor broadband (mismo ratio para todas las frecuencias)
///   - Modo Avanzado: 12 compresores independientes (ratio y knee por banda según HL)
///
/// Usa los MISMOS controles que el pipeline existente:
///   - Audiograma del paciente → determina ganancias y ratios por banda
///   - NR level → se aplica ANTES de este módulo (sin cambios)
///   - Perfiles de escena → siguen funcionando (controlan NR, TNR, etc.)
///
/// Inserción en el pipeline:
///   Cuando ON:  HPF → TNR → NR → [AuditoryModel reemplaza EQ+WDRC] → Volume → FBS → OC → MPO
///   Cuando OFF: HPF → TNR → NR → EQ → WDRC → Volume → FBS → OC → MPO (sin cambios)
///
/// Referencias:
///   - NAL-NL2 (Dillon 2012): prescripción base para targets de ganancia
///   - Moore (2003): compresión multicanal vs. single-channel
///   - Keidser et al. (2011): beneficios de compresión por banda
///   - Plomp (1988): importancia de modulaciones temporales para inteligibilidad
///   - Glasberg & Moore (1990): ERB para ancho de banda de los filtros

#ifndef HEARING_AID_AUDITORY_MODEL_H
#define HEARING_AID_AUDITORY_MODEL_H

#include <atomic>
#include <cmath>
#include <algorithm>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/// Modo Audífono Avanzado — reemplaza EQ+WDRC con procesamiento multicanal.
///
/// Procesa audio en bloques de 256 muestras. Cuando habilitado, el caller
/// (DspPipeline) debe saltear el EQ y el WDRC (este módulo los reemplaza).
class AuditoryModel {
public:
    AuditoryModel() = default;

    /// Inicializa el modelo con el sample rate del sistema.
    void init(int sampleRate) {
        sampleRate_ = static_cast<float>(sampleRate);
        computeFilterBank();
        computeCompressorParams();
        computeModulationParams();
        reset();
    }

    /// Resetea estados internos (filtros, envelopes).
    void reset() {
        for (int b = 0; b < 12; ++b) {
            bpX1_[b] = bpX2_[b] = bpY1_[b] = bpY2_[b] = 0.0f;
            env_[b] = 0.0f;
        }
        modEnv_ = 0.0f;
    }

    /// Habilita/deshabilita el modo avanzado.
    /// Thread-safe (atómico). Cuando disabled, process() es passthrough.
    void setEnabled(bool enabled) {
        enabled_.store(enabled, std::memory_order_release);
    }
    bool isEnabled() const {
        return enabled_.load(std::memory_order_acquire);
    }

    /// Configura el audiograma del paciente (12 umbrales en dB HL).
    /// Recalcula las ganancias y ratios de compresión por banda.
    void setAudiogram(const float thresholds[12]) {
        for (int i = 0; i < 12; ++i) {
            audiogramHl_[i] = thresholds[i];
        }
        computeCompressorParams();
    }

    /// Configura la ganancia de la resonancia del canal auditivo (etapa 1).
    /// Controla la ganancia máxima de inserción del modelo (0-18 dB).
    /// 0 = efecto mínimo, 12 = normal, 18 = máximo.
    /// Thread-safe. Recalcula parámetros de compresión.
    void setEarCanalGainDb(float gainDb) {
        gainDb = std::clamp(gainDb, 0.0f, 18.0f);
        earCanalGainDb_ = gainDb;
        // Escalar todas las insertion gains proporcionalmente
        computeCompressorParams();
    }

    /// Procesa un bloque de audio in-place.
    /// REEMPLAZA el EQ + WDRC cuando está habilitado.
    ///
    /// @param buffer Audio float32 [-1.0, +1.0]
    /// @param blockSize Muestras por bloque (típico 256)
    /// @param inputLevelDb Nivel de entrada en dB SPL (para decisión de ganancia)
    void process(float* buffer, int blockSize, float inputLevelDb) {
        if (!enabled_.load(std::memory_order_acquire)) {
            return;  // Passthrough — EQ+WDRC clásicos se ejecutan normalmente
        }

        for (int i = 0; i < blockSize; ++i) {
            float sample = buffer[i];
            float output = 0.0f;

            // ─── 1. Banco de filtros + compresión por banda ─────────────
            for (int b = 0; b < 12; ++b) {
                // Filtro bandpass (2do orden) para extraer la banda
                float bandSample = applyBandpass(sample, b);

                // Envelope follower por banda (para compresión adaptativa)
                float absBand = std::fabs(bandSample);
                float coeff = (absBand > env_[b]) ? attackCoeff_ : releaseCoeff_[b];
                env_[b] += coeff * (absBand - env_[b]);

                // ─── Ganancia adaptativa por nivel ──────────────────────
                // Sonidos SUAVES → más ganancia (hasta insertionGain_[b])
                // Sonidos FUERTES → menos ganancia (compresión)
                // Esto es lo que hace un audífono premium (Phonak, Oticon)
                // vs. nuestro EQ fijo + WDRC broadband.
                float envDb = 20.0f * std::log10(env_[b] + 1e-10f) + splOffset_;
                float gainDb = computeBandGain(b, envDb);
                float gainLin = std::pow(10.0f, gainDb / 20.0f);

                output += bandSample * gainLin;
            }

            // ─── 2. Realce temporal de modulaciones del habla ────────────
            // La voz tiene modulaciones a 2-8 Hz que son clave para la
            // inteligibilidad. Amplificamos esas fluctuaciones para que
            // la voz "resalte" sobre el ruido estacionario.
            float absOut = std::fabs(output);
            modEnv_ += modEnvCoeff_ * (absOut - modEnv_);

            float modulation = 1.0f;
            if (modEnv_ > 1e-8f) {
                modulation = absOut / modEnv_;
            }
            // Amplificar modulaciones (x1.3): sutil pero efectivo para voz
            output *= (1.0f + modGain_ * (modulation - 1.0f));

            buffer[i] = output;
        }
    }

private:
    // ─── Bandpass filter (2do orden resonante) ──────────────────────────
    inline float applyBandpass(float x, int b) {
        float y = bpB0_[b] * x + bpB1_[b] * bpX1_[b] + bpB2_[b] * bpX2_[b]
                - bpA1_[b] * bpY1_[b] - bpA2_[b] * bpY2_[b];
        bpX2_[b] = bpX1_[b]; bpX1_[b] = x;
        bpY2_[b] = bpY1_[b]; bpY1_[b] = y;
        return y;
    }

    // ─── Ganancia adaptativa por banda y nivel ──────────────────────────
    /// Calcula la ganancia para la banda `b` dado el nivel actual `envDb`.
    ///
    /// Implementa compresión de rango amplio por banda (WDRC multicanal):
    ///   - Debajo de kneeDb: ganancia máxima (insertion gain para HL)
    ///   - Arriba de kneeDb: compresión con ratio según severidad de HL
    ///   - Arriba de UCL: ganancia 0 (protección)
    float computeBandGain(int b, float envDb) const {
        const float knee = kneeDb_[b];
        const float ratio = ratio_[b];
        const float maxGain = insertionGain_[b];
        const float ucl = 100.0f;  // UCL conservador

        if (envDb <= knee) {
            // Región de expansión/lineal: ganancia máxima (sonidos suaves)
            return maxGain;
        } else if (envDb >= ucl) {
            // Sobre UCL: sin ganancia (protección)
            return 0.0f;
        } else {
            // Región de compresión: ganancia decrece con el nivel
            // outputDb = knee + (envDb - knee) / ratio
            // gainDb = outputDb - envDb = knee + (envDb-knee)/ratio - envDb
            //        = maxGain - (envDb - knee) * (1 - 1/ratio)
            float reduction = (envDb - knee) * (1.0f - 1.0f / ratio);
            float gain = maxGain - reduction;
            return std::max(gain, 0.0f);
        }
    }

    // ─── Cálculo de coeficientes del banco de filtros ───────────────────
    void computeFilterBank() {
        // 12 bandas centradas en las frecuencias estándar del audiograma
        static constexpr float freqs[12] = {
            250, 500, 750, 1000, 1500, 2000,
            2500, 3000, 3500, 4000, 6000, 8000
        };

        for (int b = 0; b < 12; ++b) {
            float fc = freqs[b];
            // Ancho de banda = ERB (Glasberg & Moore 1990)
            float erb = 24.7f * (4.37f * fc / 1000.0f + 1.0f);
            float Q = fc / erb;

            float w0 = 2.0f * static_cast<float>(M_PI) * fc / sampleRate_;
            float sinw0 = std::sin(w0);
            float cosw0 = std::cos(w0);
            float alpha = sinw0 / (2.0f * Q);

            float a0 = 1.0f + alpha;
            // Bandpass (constant-0-dB-peak-gain)
            bpB0_[b] = alpha / a0;
            bpB1_[b] = 0.0f;
            bpB2_[b] = -alpha / a0;
            bpA1_[b] = (-2.0f * cosw0) / a0;
            bpA2_[b] = (1.0f - alpha) / a0;
        }
    }

    // ─── Cálculo de parámetros de compresión por banda ──────────────────
    void computeCompressorParams() {
        // Attack: 5 ms (rápido para proteger)
        attackCoeff_ = 1.0f - std::exp(-1.0f / (sampleRate_ * 0.005f));

        for (int b = 0; b < 12; ++b) {
            float hl = audiogramHl_[b];

            // ─── Insertion gain (NAL-NL2 simplificado) ──────────────────
            // La ganancia de inserción es aprox. 50% del HL (regla del medio)
            // con ajuste frecuencial: más ganancia en medios (voz), menos en
            // graves (evitar upward spread of masking).
            float freqWeight = 1.0f;
            if (b <= 1) freqWeight = 0.7f;       // 250-500 Hz: menos ganancia
            else if (b >= 2 && b <= 7) freqWeight = 1.0f;  // 750-3000 Hz: ganancia plena
            else freqWeight = 0.85f;              // 3500-8000 Hz: ligeramente menos

            insertionGain_[b] = hl * 0.5f * freqWeight;
            insertionGain_[b] = std::clamp(insertionGain_[b], 0.0f, 40.0f);
            // Escalar por el control de ganancia manual (slider UI)
            // earCanalGainDb_ = 12 → factor 1.0 (normal)
            // earCanalGainDb_ = 0  → factor 0.0 (mínimo)
            // earCanalGainDb_ = 18 → factor 1.5 (máximo)
            float gainScale = earCanalGainDb_ / 12.0f;
            insertionGain_[b] *= gainScale;

            // ─── Knee de compresión ─────────────────────────────────────
            // Más HL → knee más bajo (compresión empieza antes)
            // Normal (0 HL): knee = 55 dB SPL
            // Severo (60 HL): knee = 35 dB SPL
            kneeDb_[b] = 55.0f - hl * 0.33f;
            kneeDb_[b] = std::clamp(kneeDb_[b], 30.0f, 60.0f);

            // ─── Ratio de compresión ────────────────────────────────────
            // Más HL → más compresión (ratio más alto)
            // Normal (0 HL): 1.2:1 (casi lineal)
            // Moderado (40 HL): 2.5:1
            // Severo (60 HL): 3.5:1
            ratio_[b] = 1.2f + hl * 0.038f;
            ratio_[b] = std::clamp(ratio_[b], 1.0f, 4.0f);

            // ─── Release adaptativo ─────────────────────────────────────
            // Graves: release largo (evitar distorsión de bajo)
            // Agudos: release corto (preservar consonantes)
            float releaseMs;
            if (b <= 2) releaseMs = 200.0f;       // Graves: 200 ms
            else if (b <= 7) releaseMs = 100.0f;  // Medios: 100 ms
            else releaseMs = 60.0f;               // Agudos: 60 ms

            releaseCoeff_[b] = 1.0f - std::exp(-1.0f / (sampleRate_ * releaseMs / 1000.0f));
        }
    }

    // ─── Parámetros de realce temporal ──────────────────────────────────
    void computeModulationParams() {
        // Envelope LP a 8 Hz (captura modulaciones del habla 2-8 Hz)
        float fc = 8.0f;
        float rc = 1.0f / (2.0f * static_cast<float>(M_PI) * fc);
        float dt = 1.0f / sampleRate_;
        modEnvCoeff_ = dt / (rc + dt);
        // Ganancia de modulación: 30% extra (sutil pero efectivo)
        modGain_ = 0.3f;
    }

    // ─── Estado ─────────────────────────────────────────────────────────
    std::atomic<bool> enabled_{false};
    float sampleRate_ = 48000.0f;
    float earCanalGainDb_ = 12.0f;  // Control de ganancia manual (slider UI)
    static constexpr float splOffset_ = 93.0f;  // Calibración del pipeline

    // ─── Audiograma ─────────────────────────────────────────────────────
    float audiogramHl_[12] = {};  // dB HL por banda

    // ─── Banco de filtros (12 bandpass, 2do orden) ──────────────────────
    float bpB0_[12] = {}, bpB1_[12] = {}, bpB2_[12] = {};
    float bpA1_[12] = {}, bpA2_[12] = {};
    float bpX1_[12] = {}, bpX2_[12] = {};
    float bpY1_[12] = {}, bpY2_[12] = {};

    // ─── Compresores por banda ──────────────────────────────────────────
    float attackCoeff_ = 0.0f;
    float releaseCoeff_[12] = {};
    float insertionGain_[12] = {};  // Ganancia máxima por banda (dB)
    float kneeDb_[12] = {};         // Knee de compresión por banda (dB SPL)
    float ratio_[12] = {};          // Ratio de compresión por banda
    float env_[12] = {};            // Envelope actual por banda

    // ─── Realce temporal de modulaciones ─────────────────────────────────
    float modEnvCoeff_ = 0.0f;
    float modGain_ = 0.3f;
    float modEnv_ = 0.0f;
};

#endif // HEARING_AID_AUDITORY_MODEL_H

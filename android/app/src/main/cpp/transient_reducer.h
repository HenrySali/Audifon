/// @file transient_reducer.h
/// @brief Transient Noise Reduction (TNR) MULTI-BANDA — atenúa impulsos abruptos sin afectar voz.
///
/// VERSIÓN PROFESIONAL (Phonak/Starkey/Oticon):
/// - 4 bandas espectrales (graves, medios, agudos, super-agudos)
/// - Detección independiente por banda (golpe en graves NO atenúa agudos de voz)
/// - Análisis de peak-to-RMS ratio por banda
/// - Atenuación proporcional con smooth gating (attack/release graduales)
///
/// Detecta y atenúa sonidos impulsivos como:
/// - Timbre del subte/metro
/// - Puertas que se cierran fuerte
/// - Bocinas, sirenas
/// - Platos chocando, llaves cayendo
///
/// Algoritmo basado en:
/// - Phonak SoundRelax (2006) — referencia clínica
/// - Starkey Transient Noise Reduction white paper (2020)
/// - PMC5134678: "Transient Noise Reduction in Cochlear Implants: Multi-Band Approach"
/// - Acta Acustica 2023: "Evaluation of impulse noise reduction in hearing aids"
///
/// Mecanismo MULTI-BANDA (MEJORA sobre versión mono):
/// 1. Dividir señal en 4 bandas espectrales con crossover IIR
/// 2. Por cada banda:
///    a. Calcular envelope de energía instantánea (rápido) y promedio (lento)
///    b. Si peak-to-RMS ratio alto → es un transitorio en ESA banda
///    c. Aplicar atenuación PROPORCIONAL solo en esa banda
///    d. Smooth gating con attack/release graduales (elimina "tktktkt")
/// 3. Recombinar bandas atenuadas
///
/// Ventaja multi-banda:
/// - Golpe en graves (puerta) NO atenúa consonantes en agudos
/// - Timbre en medios NO mata vocales en graves
/// - Más natural, menos artefactos audibles

#ifndef HEARING_AID_TRANSIENT_REDUCER_H
#define HEARING_AID_TRANSIENT_REDUCER_H

#include <atomic>
#include <cmath>

/// Número de bandas para TNR multi-banda
static constexpr int kTnrBands = 4;

/// Transient Noise Reduction MULTI-BANDA — protección contra impulsos fuertes.
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
    void init(int sampleRate);

    /// Procesa un bloque de audio in-place con TNR multi-banda.
    /// @param buffer Audio float32 [-1.0, +1.0]
    /// @param blockSize Número de muestras
    void process(float* buffer, int blockSize);

    /// Habilita/deshabilita el TNR (thread-safe).
    void setEnabled(bool enabled) {
        enabled_.store(enabled, std::memory_order_relaxed);
    }

    bool isEnabled() const {
        return enabled_.load(std::memory_order_relaxed);
    }

    /// Establece el umbral de detección (ratio peak/RMS).
    /// Default: 6.0 (transitorio = 6× sobre el RMS de fondo).
    /// Rangocomendado: 4.0 (sensible) a 10.0 (conservador).
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

    /// Lee el último gain aplicado por banda (para diagnóstico/UI).
    float getBandGain(int band) const { 
        if (band >= 0 && band < kTnrBands) return bandGains_[band];
        return 1.0f;
    }

private:
    /// Estado de filtro crossover de 2° orden por banda
    struct CrossoverState {
        float x1 = 0.0f, x2 = 0.0f;  // Input delays
        float y1 = 0.0f, y2 = 0.0f;  // Output delays
    };

    /// Coeficientes de filtro biquad
    struct BiquadCoeffs {
        float b0 = 0.0f, b1 = 0.0f, b2 = 0.0f;
        float a1 = 0.0f, a2 = 0.0f;
    };

    /// Estado del detector TNR por banda
    struct BandState {
        float fastEnv = 0.0f;       // Envelope rápido (peak tracking)
        float slowEnv = 1e-6f;      // Envelope lento (RMS background)
        float smoothGain = 1.0f;    // Ganancia suave actual
        int holdCounter = 0;        // Contador de hold
    };

    /// Calcula coeficientes de filtro Linkwitz-Riley crossover
    BiquadCoeffs computeCrossoverCoeffs(float centerFreq, int sampleRate, bool isLowPass);

    /// Aplica filtro biquad a una muestra
    float applyBiquad(float input, const BiquadCoeffs& coeffs, CrossoverState& state);

    int sampleRate_ = 16000;

    // Coeficientes pre-calculados (attack/release/hold)
    float fastCoeff_ = 0.0f;       // ~1 ms (peak tracking)
    float slowCoeff_ = 0.0f;       // ~100 ms (RMS background)
    float attackCoeff_ = 0.0f;     // ~15 ms (smooth attack)
    float releaseCoeff_ = 0.0f;    // ~80 ms (smooth release)
    int holdSamples_ = 0;          // ~20 ms

    // Estado del detector multi-banda
    BandState bandStates_[kTnrBands];
    float bandGains_[kTnrBands] = {1.0f, 1.0f, 1.0f, 1.0f};

    // Filtros crossover (Linkwitz-Riley 4th order = 2× biquad cascaded)
    // Banda 0: LP 500 Hz
    // Banda 1: BP 500-2000 Hz
    // Banda 2: BP 2000-5000 Hz
    // Banda 3: HP 5000 Hz
    BiquadCoeffs crossoverCoeffs_[kTnrBands][2];  // 2 cascaded biquads per band
    CrossoverState crossoverStates_[kTnrBands][2];

    // Parámetros atómicos (UI thread settable)
    std::atomic<bool> enabled_{true};
    std::atomic<float> thresholdRatio_{6.0f};       // Default: 6× sobre RMS
    std::atomic<float> attenuationLinear_{0.25f};   // Default: -12 dB
};

#endif // HEARING_AID_TRANSIENT_REDUCER_H

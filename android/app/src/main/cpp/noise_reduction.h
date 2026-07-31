/// @file noise_reduction.h
/// @brief Reducción de ruido basada en filtrado de Wiener (8 sub-bandas).
/// Solo atenúa — ganancia por sub-banda siempre ≤ 1.0.
///
/// Diseño:
/// - 8 sub-bandas de 1000 Hz cada una (0-8000 Hz a 16 kHz sample rate)
/// - Estimación de ruido por promedio exponencial durante señal de bajo nivel
/// - Ganancia Wiener: G = max(1 - noise_power/signal_power, gain_floor)
/// - 3 niveles de intensidad: bajo (piso 0.5), medio (0.3), alto (0.18)
/// - Piso de ganancia preserva consonantes (nunca elimina completamente una banda)
/// - Parámetro de nivel atómico para actualizaciones thread-safe desde UI

#ifndef HEARING_AID_NOISE_REDUCTION_H
#define HEARING_AID_NOISE_REDUCTION_H

#include <atomic>
#include <cmath>

/// Número de sub-bandas para la reducción de ruido.
static constexpr int kNrSubBands = 8;

/// Frecuencia de muestreo del sistema.
static constexpr int kNrSampleRate = 48000;

/// Ancho de cada sub-banda en Hz.
/// Para 48kHz, cubrimos 0-8kHz (rango de habla) con 8 bandas de ~1000 Hz.
static constexpr float kNrBandWidthHz = 1000.0f;

/// Reducción de ruido con filtrado de Wiener en 8 sub-bandas.
///
/// Algoritmo simplificado para PSAP móvil (sin FFT completa):
/// 1. Divide la señal en 8 sub-bandas usando filtros IIR simples (2° orden)
/// 2. Estima potencia de ruido por sub-banda con promedio exponencial
/// 3. Calcula ganancia Wiener: G = max(1 - noise/signal, floor)
/// 4. Aplica ganancia por sub-banda al dominio temporal
///
/// Soporta 3 niveles de intensidad: bajo (piso 0.5), medio (0.3), alto (0.18).
/// Nivel 0 = off (pass-through, no modifica la señal).
class NoiseReduction {
public:
    NoiseReduction();
    ~NoiseReduction() = default;

    /// Inicializa el NR con el sample rate real del sistema y recalcula los
    /// coeficientes de los bandpass por sub-banda.
    ///
    /// FIX (auditoría sim_v3): antes los coeficientes se calculaban SOLO en el
    /// constructor usando kNrSampleRate=48000 HARDCODEADO. Si el engine corría
    /// a una fs distinta (p.ej. 16000), cada sub-banda quedaba mal ubicada
    /// (centro_real = centro_nominal × fs/48000 → 3× abajo a 16 kHz), de modo
    /// que el análisis Wiener por banda operaba sobre frecuencias equivocadas.
    /// A 48 kHz el resultado es idéntico al anterior (cambio behavior-neutral
    /// en el runtime habitual). Debe llamarse desde DspPipeline::init().
    /// El NR sigue siendo solo-atenuante (ganancia ≤ 1.0), así que el cambio
    /// no introduce riesgo de clipping.
    /// @param sampleRate Frecuencia de muestreo real en Hz (típicamente 48000)
    void init(int sampleRate);

    /// Procesa un bloque de audio aplicando reducción de ruido in-place.
    /// @param buffer Puntero al buffer de audio float32 [-1.0, +1.0]
    /// @param blockSize Número de muestras en el buffer
    void process(float* buffer, int blockSize);

    /// Establece el nivel de reducción de ruido.
    /// @param level 0=off, 1=bajo (floor 0.5), 2=medio (floor 0.3), 3=alto (floor 0.18)
    void setLevel(int level) {
        level_.store(level, std::memory_order_relaxed);
    }

    /// Obtiene el nivel actual de NR.
    int getLevel() const {
        return level_.load(std::memory_order_relaxed);
    }

    /// Reinicia el estado interno (estimaciones de ruido, filtros).
    void reset();

    /// Actualiza SOLO las estimaciones de potencia de señal/ruido por banda
    /// SIN aplicar ganancia al buffer (no modifica el audio).
    ///
    /// Pensado para el camino en que un denoiser externo (DNN) ya procesó el
    /// audio y el NR Wiener interno está bypasseado (ver DspPipeline::
    /// isNrBypassed): aun así el clasificador de entorno necesita una
    /// estimación de SNR fresca por banda, así que el pipeline llama a este
    /// método para mantener vivas signalPower_/noisePower_.
    ///
    /// @param buffer Buffer de audio float32 (NO se modifica)
    /// @param blockSize Número de muestras en el buffer
    void analyzeOnly(const float* buffer, int blockSize);

    /// Copia la estimación de potencia de SEÑAL por sub-banda (energía lineal
    /// suavizada). Usado por el clasificador de entorno para estimar SNR.
    /// @param out Buffer destino (al menos @p maxBands floats)
    /// @param maxBands Tamaño del buffer destino; se copian min(maxBands, 8) bandas
    void getSignalEstimate(float* out, int maxBands) const;

    /// Copia la estimación de potencia de RUIDO por sub-banda (energía lineal).
    /// Usado por el clasificador de entorno (EnvironmentClassifier::
    /// estimateSnrFromNr) para estimar el SNR del ambiente.
    /// @param out Buffer destino (al menos @p maxBands floats)
    /// @param maxBands Tamaño del buffer destino; se copian min(maxBands, 8) bandas
    void getNoiseEstimate(float* out, int maxBands) const;

private:
    /// Obtiene el piso de ganancia para el nivel actual.
    /// @return Piso de ganancia lineal (0.18, 0.3, 0.5, o 1.0 para off)
    float getGainFloor() const;

    /// Filtra el bloque por las 8 sub-bandas y actualiza las estimaciones de
    /// potencia de señal y ruido (signalPower_/noisePower_) y bandEnergy_.
    /// NO aplica ganancia al buffer. Compartido por process() y analyzeOnly()
    /// para que la estimación de SNR del clasificador esté siempre fresca,
    /// incluso con NR en nivel 0 o bypasseado.
    /// @param buffer Buffer de audio float32 (NO se modifica)
    /// @param blockSize Número de muestras en el buffer
    void updateBandPowers(const float* buffer, int blockSize);

    /// Estado de filtro bandpass de 2° orden (biquad) por sub-banda.
    struct BiquadState {
        float x1 = 0.0f;  ///< Input delay 1
        float x2 = 0.0f;  ///< Input delay 2
        float y1 = 0.0f;  ///< Output delay 1
        float y2 = 0.0f;  ///< Output delay 2
    };

    /// Coeficientes de filtro biquad bandpass.
    struct BiquadCoeffs {
        float b0 = 0.0f;
        float b1 = 0.0f;
        float b2 = 0.0f;
        float a1 = 0.0f;  ///< Negado (a1 se resta en la ecuación)
        float a2 = 0.0f;  ///< Negado
    };

    /// Calcula coeficientes de filtro bandpass para una sub-banda.
    /// @param centerFreq Frecuencia central en Hz
    /// @param bandwidth Ancho de banda en Hz
    /// @param sampleRate Frecuencia de muestreo en Hz
    /// @return Coeficientes del biquad bandpass
    static BiquadCoeffs computeBandpassCoeffs(float centerFreq, float bandwidth,
                                              float sampleRate);

    /// Aplica un filtro biquad a una muestra.
    /// @param input Muestra de entrada
    /// @param coeffs Coeficientes del filtro
    /// @param state Estado del filtro (modificado in-place)
    /// @return Muestra filtrada
    static float applyBiquad(float input, const BiquadCoeffs& coeffs,
                             BiquadState& state);

    // --- Parámetros atómicos ---
    std::atomic<int> level_{1};  ///< Nivel NR: 0=off, 1=bajo, 2=medio, 3=alto

    /// Sample rate real con el que se calcularon los bandpass (Hz).
    /// Default kNrSampleRate (48000); sobrescrito por init() desde el pipeline.
    int sampleRate_ = kNrSampleRate;

    // --- Estado por sub-banda ---
    BiquadCoeffs bandCoeffs_[kNrSubBands];  ///< Coeficientes de filtro por banda
    BiquadState bandStates_[kNrSubBands];   ///< Estado de filtro por banda

    float noisePower_[kNrSubBands];   ///< Estimación de potencia de ruido por banda
    float signalPower_[kNrSubBands];  ///< Potencia de señal por banda (suavizada)
    float bandEnergy_[kNrSubBands] = {}; ///< Energía por banda del último bloque (para ponderar la ganancia compuesta)

    /// Ganancia compuesta del bloque anterior (para suavizado temporal).
    float prevGain_ = 1.0f;

    // --- MEJORA PROFESIONAL: Smooth envelope follower ---
    /// Envelope follower para smooth gating (elimina "tktktkt")
    /// Attack: 40 ms (rise time moderado, deja pasar transientes leves)
    /// Release: 250 ms (fade lento, evita cortes abruptos)
    float smoothEnvelope_ = 1.0f;
    float attackCoeff_ = 0.0f;   // Calculado en init() basado en sampleRate
    float releaseCoeff_ = 0.0f;  // Calculado en init() basado en sampleRate

    // --- Constantes de suavizado ---
    /// Coeficiente de actualización de ruido (lento, ~500 ms)
    static constexpr float kNoiseAlpha = 0.02f;
    /// Coeficiente de actualización de señal (rápido, ~20 ms)
    static constexpr float kSignalAlpha = 0.3f;
    /// Umbral para considerar que hay señal presente (vs silencio/ruido)
    static constexpr float kSignalPresenceThreshold = 2.0f;
    /// Potencia mínima para evitar división por cero
    static constexpr float kMinPower = 1e-10f;
};

#endif // HEARING_AID_NOISE_REDUCTION_H

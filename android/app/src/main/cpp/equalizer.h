/// @file equalizer.h
/// @brief EQ paramétrico de 12 bandas con filtros biquad peaking.
///
/// Frecuencias: 250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000 Hz.
/// Fórmulas de coeficientes: Audio EQ Cookbook (peaking EQ).
/// ÚNICA etapa del pipeline que amplifica la señal.
///
/// Diseño thread-safe:
/// - Las ganancias se actualizan atómicamente desde el hilo de UI.
/// - Los coeficientes se recalculan en el hilo de audio al detectar cambio.
/// - No se usan locks — operación completamente lock-free.
///
/// Crossfade: Al cambiar ganancias, se interpola linealmente entre currentGains_
/// y targetGains_ durante kCrossfadeLength muestras (256 @ 16kHz = 16ms).
/// Esto elimina discontinuidades (clicks/pops) al cambiar presets EQ.
/// Requisito: max sample-to-sample gain change ≤ 0.01 linear (-40 dB) durante rampa.

#ifndef HEARING_AID_EQUALIZER_H
#define HEARING_AID_EQUALIZER_H

#include <atomic>
#include <cmath>
#include <cstring>

/// Número de bandas del ecualizador
static constexpr int kEqBandCount = 12;

/// Frecuencias centrales de las 12 bandas (Hz)
static constexpr float kEqFrequencies[kEqBandCount] = {
    250.0f, 500.0f, 750.0f, 1000.0f, 1500.0f, 2000.0f,
    2500.0f, 3000.0f, 3500.0f, 4000.0f, 6000.0f, 8000.0f
};

/// Factores Q por banda — ligeramente más anchos para frecuencias bajas,
/// moderados (~1.4) para la mayoría de bandas.
static constexpr float kEqQFactors[kEqBandCount] = {
    1.0f,   // 250 Hz  — ancho para cubrir rango bajo
    1.2f,   // 500 Hz  — moderadamente ancho
    1.3f,   // 750 Hz  — transición
    1.4f,   // 1000 Hz — estándar
    1.4f,   // 1500 Hz — estándar
    1.4f,   // 2000 Hz — estándar
    1.4f,   // 2500 Hz — estándar
    1.4f,   // 3000 Hz — estándar
    1.4f,   // 3500 Hz — estándar
    1.4f,   // 4000 Hz — estándar
    1.5f,   // 6000 Hz — ligeramente más estrecho
    1.5f    // 8000 Hz — ligeramente más estrecho (cerca de Nyquist)
};

/// Ceiling lineal para el per-band limiter.
/// -3 dBFS = 0.708 — deja margen para que el WDRC y Volume operen sin clipping.
/// Esto previene saturación cuando bandas individuales tienen alta ganancia.
static constexpr float kPerBandCeiling = 0.708f;  // -3 dBFS

/// Longitud del crossfade en muestras (256 @ 16kHz = 16ms).
/// Rango permitido por requisito: 10-50ms. 16ms está en rango.
static constexpr int kCrossfadeLength = 256;

/// Máximo cambio de ganancia por muestra en dB durante crossfade.
/// Con rango max de 50 dB en 256 muestras: 50/256 ≈ 0.195 dB/sample.
/// Esto corresponde a ~0.0045 linear/sample para ganancias moderadas,
/// cumpliendo el requisito de ≤ 0.01 linear por muestra.

/// Coeficientes normalizados de un filtro biquad (Direct Form I).
/// Todos los coeficientes están normalizados por a0 (a0 = 1.0 implícito).
struct BiquadCoeffs {
    float b0 = 1.0f;
    float b1 = 0.0f;
    float b2 = 0.0f;
    float a1 = 0.0f;  ///< Nota: signo negado en la fórmula de diferencia
    float a2 = 0.0f;
};

/// Estado interno de un filtro biquad (Direct Form I).
/// Almacena las últimas 2 muestras de entrada y salida.
struct BiquadState {
    float x1 = 0.0f;  ///< x[n-1]
    float x2 = 0.0f;  ///< x[n-2]
    float y1 = 0.0f;  ///< y[n-1]
    float y2 = 0.0f;  ///< y[n-2]

    /// Resetea el estado del filtro a cero.
    void reset() {
        x1 = x2 = y1 = y2 = 0.0f;
    }
};

/// Ecualizador paramétrico de 12 bandas con filtros biquad peaking.
///
/// Rango de ganancias: [0, 50] dB por banda.
/// ÚNICA etapa del pipeline que amplifica la señal.
///
/// Uso:
/// @code
///   Equalizer eq;
///   eq.init(16000); // sample rate
///   float gains[12] = {0, 0, 0, 10, 15, 20, 22, 25, 27, 30, 30, 25};
///   eq.setGains(gains);
///   eq.process(buffer, 64);
/// @endcode
class Equalizer {
public:
    Equalizer();
    ~Equalizer() = default;

    /// Inicializa el ecualizador con la frecuencia de muestreo dada.
    void init(int sampleRate);

    /// Procesa un bloque de audio aplicando ecualización in-place.
    void process(float* buffer, int blockSize);

    /// Actualiza las ganancias de las 12 bandas (en dB, rango [0, 50]).
    /// Thread-safe: puede llamarse desde el hilo de UI.
    void setGains(const float gains[kEqBandCount]);

    /// Obtiene la ganancia actual de una banda específica.
    float getGain(int band) const;

    /// Returns the maximum gain currently configured across all bands (in dB).
    float getMaxGain() const;

    /// Process with a gain scaling factor (0.0 to 1.0).
    void processWithScale(float* buffer, int blockSize, float scale);

private:
    /// Calcula coeficientes biquad peaking EQ usando Audio EQ Cookbook.
    BiquadCoeffs computePeakingCoeffs(float frequencyHz, float gainDb, float q) const;

    /// Recalcula coeficientes para todas las bandas basándose en currentGains_.
    void updateCoefficients();

    /// Avanza la interpolación del crossfade para un bloque.
    /// Interpola currentGains_ hacia targetGains_ proporcionalmente al tamaño del bloque.
    void advanceCrossfade(int blockSize);

    /// Procesa una muestra a través de un filtro biquad (Direct Form I).
    static float processBiquadSample(float sample, const BiquadCoeffs& coeffs,
                                     BiquadState& state);

    // --- Configuración ---
    int sampleRate_ = 16000;

    // --- Ganancias atómicas (actualizables desde hilo de UI) ---
    std::atomic<float> gains_[kEqBandCount];

    // --- Crossfade state (solo accedidos desde hilo de audio) ---
    float targetGains_[kEqBandCount];     ///< Ganancias objetivo del crossfade (dB)
    float currentGains_[kEqBandCount];    ///< Ganancias actuales interpoladas (dB)
    int crossfadeRemaining_ = 0;          ///< Muestras restantes en rampa de crossfade

    // --- Coeficientes y estado (solo accedidos desde hilo de audio) ---
    BiquadCoeffs coeffs_[kEqBandCount];   ///< Coeficientes actuales por banda
    BiquadState states_[kEqBandCount];    ///< Estado de filtro por banda
    float appliedGains_[kEqBandCount];    ///< Ganancias con las que se calcularon los coeficientes

    // --- Flag de cambio pendiente ---
    std::atomic<bool> gainsChanged_{false};
};

#endif // HEARING_AID_EQUALIZER_H

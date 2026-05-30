/// @file equalizer.h
/// @brief EQ paramétrico de 12 bandas con filtros biquad peaking y suavizado de coeficientes.
///
/// Frecuencias: 250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000 Hz.
/// Fórmulas de coeficientes: Audio EQ Cookbook (peaking EQ).
/// ÚNICA etapa del pipeline que amplifica la señal.
///
/// Técnica de suavizado: Interpolación exponencial de coeficientes bloque-a-bloque.
/// Basado en:
/// - DSP Concepts Audio Weaver "BiquadSmoothed" (ON Semiconductor Ezairo chips)
/// - Kalinichenko (2006) "Smooth and Safe Parameter Interpolation of Biquadratic
///   Filters in Audio Applications" — DAFx-06, Montreal
/// - vinniefalco/DSPFilters: "Process a block interpolating from old to new coefficients"
/// - Zetterberg & Zhang (1988): Modificar estado al cambiar coeficientes
///
/// Los coeficientes actuales se aproximan exponencialmente a los coeficientes destino
/// en cada bloque de audio (~4ms a 16kHz/64 samples). Esto elimina transitorios
/// al cambiar presets EQ en caliente sin necesidad de reiniciar el engine.
///
/// Diseño thread-safe:
/// - Las ganancias se actualizan atómicamente desde el hilo de UI.
/// - Los coeficientes TARGET se recalculan al detectar cambio.
/// - Los coeficientes CURRENT se interpolan hacia TARGET cada bloque.
/// - No se usan locks — operación completamente lock-free.

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
/// -1 dBFS = 0.891 — permite que la señal amplificada pase con más dinámica.
/// El WDRC y MPO downstream se encargan de la protección final contra clipping.
static constexpr float kPerBandCeiling = 0.891f;  // -1 dBFS

/// Número de bloques para completar la transición de coeficientes (~95%).
/// Con bloques de 64 muestras a 16kHz (4ms/bloque), 5 bloques = 20ms.
/// Esto da una transición suave de ~20ms, imperceptible auditivamente.
/// Referencia: DSP Concepts Audio Weaver usa ~10-50ms típicamente.
static constexpr int kSmoothingBlocks = 5;

/// Número de muestras para el fade-in después de un salto grande de ganancia.
/// 32 muestras a 16kHz = 2ms. Suficiente para evitar click sin ser audible.
static constexpr int kFadeSamples = 32;

/// Coeficientes normalizados de un filtro biquad (Direct Form I).
/// Todos los coeficientes están normalizados por a0 (a0 = 1.0 implícito).
struct BiquadCoeffs {
    float b0 = 1.0f;
    float b1 = 0.0f;
    float b2 = 0.0f;
    float a1 = 0.0f;  ///< Nota: signo negado en la fórmula de diferencia
    float a2 = 0.0f;

    /// Interpola linealmente entre este set de coeficientes y otro.
    /// t=0 retorna *this, t=1 retorna other.
    BiquadCoeffs lerp(const BiquadCoeffs& other, float t) const {
        BiquadCoeffs result;
        result.b0 = b0 + t * (other.b0 - b0);
        result.b1 = b1 + t * (other.b1 - b1);
        result.b2 = b2 + t * (other.b2 - b2);
        result.a1 = a1 + t * (other.a1 - a1);
        result.a2 = a2 + t * (other.a2 - a2);
        return result;
    }

    /// Verifica si dos sets de coeficientes son significativamente diferentes.
    bool significantlyDifferent(const BiquadCoeffs& other) const {
        const float eps = 1e-6f;
        return std::fabs(b0 - other.b0) > eps ||
               std::fabs(b1 - other.b1) > eps ||
               std::fabs(b2 - other.b2) > eps ||
               std::fabs(a1 - other.a1) > eps ||
               std::fabs(a2 - other.a2) > eps;
    }
};

/// Estado interno de un filtro biquad (Transposed Direct Form II).
///
/// TDF2 usa solo 2 variables de estado (vs 4 en DF1), tiene mejor
/// comportamiento numérico con float32 en frecuencias bajas, y es la
/// estructura usada internamente por DSP Concepts Audio Weaver.
///
/// Referencia: Stanford CCRMA — Julius Smith "Introduction to Digital Filters"
/// Referencia: DSP Concepts — "All Biquad filters use Direct Form 2 structure"
struct BiquadState {
    float s1 = 0.0f;  ///< State variable 1 (delay element 1)
    float s2 = 0.0f;  ///< State variable 2 (delay element 2)

    /// Resetea el estado del filtro a cero.
    void reset() {
        s1 = s2 = 0.0f;
    }
};

/// Ecualizador paramétrico de 12 bandas con filtros biquad peaking y
/// suavizado exponencial de coeficientes (técnica BiquadSmoothed).
///
/// Rango de ganancias: [0, 50] dB por banda.
/// ÚNICA etapa del pipeline que amplifica la señal.
///
/// Al cambiar ganancias, los coeficientes TARGET se recalculan inmediatamente
/// pero los coeficientes CURRENT se interpolan exponencialmente hacia el TARGET
/// en cada bloque de audio. Esto elimina transitorios sin necesidad de
/// reiniciar el engine.
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

    /// Recalcula coeficientes TARGET para todas las bandas que cambiaron.
    void updateTargetCoefficients();

    /// Procesa una muestra a través de un filtro biquad (Transposed Direct Form II).
    /// TDF2: y = b0*x + s1; s1 = b1*x - a1*y + s2; s2 = b2*x - a2*y
    /// Referencia: DSP Concepts Audio Weaver, Stanford CCRMA Julius Smith.
    static float processBiquadSample(float sample, const BiquadCoeffs& coeffs,
                                     BiquadState& state);

    // --- Configuración ---
    int sampleRate_ = 16000;

    /// Coeficiente de suavizado exponencial por bloque.
    /// Calculado como: 1 - exp(-1 / kSmoothingBlocks)
    /// Esto da ~95% de convergencia en kSmoothingBlocks bloques.
    float smoothingCoeff_ = 0.0f;

    // --- Ganancias atómicas (actualizables desde hilo de UI) ---
    std::atomic<float> gains_[kEqBandCount];

    // --- Coeficientes TARGET (destino, recalculados al cambiar ganancias) ---
    BiquadCoeffs targetCoeffs_[kEqBandCount];

    // --- Coeficientes CURRENT (los que realmente se usan para procesar) ---
    // Se interpolan exponencialmente hacia targetCoeffs_ cada bloque.
    BiquadCoeffs currentCoeffs_[kEqBandCount];

    // --- Estado de filtro por banda ---
    BiquadState states_[kEqBandCount];

    // --- Ganancias con las que se calcularon los coeficientes TARGET ---
    float appliedGains_[kEqBandCount];

    // --- Flag: true si los coeficientes current aún no alcanzaron target ---
    bool smoothingActive_[kEqBandCount];

    // --- Fade-in counter para saltos grandes de ganancia ---
    // Cuando es > 0, se aplica un fade-in lineal de kFadeSamples muestras.
    // Esto evita el transitorio al cambiar coeficientes directamente.
    int fadeCounter_ = 0;

    // --- Flag de cambio pendiente ---
    std::atomic<bool> gainsChanged_{false};
};

#endif // HEARING_AID_EQUALIZER_H

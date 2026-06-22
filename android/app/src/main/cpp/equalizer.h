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
/// CAMBIO DE GANANCIAS EN CALIENTE (FIX ruido sostenido al cambiar EQ):
/// Las ganancias objetivo (gains_) se suavizan por bloque hacia un valor
/// actual (rampGains_) con una rampa exponencial. Los coeficientes biquad se
/// recalculan a partir del valor SUAVIZADO, no del target crudo. Esto evita
/// el "zipper noise" / transitorio que produce el hard-swap de coeficientes
/// en filtros Direct Form I bajo modulación de parámetros.
/// Ref: DSP.SE "Avoiding clicks with changing biquad coefficients" y la
/// práctica de parameter smoothing (JUCE SmoothedValue, Max biquad~/filtercoeff~).
/// Misma filosofía que la rampa de WDRC/NR ya presente en dsp_pipeline.cpp.
///
/// SANITIZACIÓN: processBiquadSample() detecta estados/salidas no finitas
/// (NaN/Inf) — que en un IIR recursivo se auto-propagan indefinidamente — y
/// resetea el estado de la banda, cortando el ruido sostenido sin necesidad
/// de reiniciar el engine.

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

/// Snapshot atómico de las 12 ganancias del EQ, commitado mediante un índice
/// monotónico. El hilo de audio lee siempre el snapshot más reciente, y el
/// hilo de UI escribe un nuevo snapshot completo. Esto garantiza que las 12
/// ganancias se vean de forma consistente (transaccional) desde el hilo de
/// audio, eliminando la ventana donde algunas bandas tienen el valor nuevo
/// y otras el viejo.
struct EqSnapshot {
    float gains[kEqBandCount]{};
    uint64_t seq = 0;  ///< Secuencia monotónica para detectar snapshots nuevos
    /// Carga las ganancias desde un array y asigna la secuencia.
    void store(const float src[kEqBandCount], uint64_t s) {
        std::memcpy(gains, src, sizeof(gains));
        seq = s;
    }
};

/// Par de buffers de crossfade: cuando los coeficientes biquad cambian
/// significativamente (nuevo preset), interpola linealmente entre la salida
/// del filtro "viejo" y la del filtro "nuevo" durante ~10 ms para eliminar
/// el click del transitorio de cambio de coeficientes en serie.
///
/// El crossfade se aplica por banda, SOLO en el bloque donde se detectó el
/// cambio de coeficientes. Tras el fade, el estado "viejo" se descarta y el
/// crossfade queda inactivo hasta el próximo commit.
struct EqCrossfader {
    /// True mientras hay un crossfade activo en esta banda.
    bool active[kEqBandCount]{};
    /// Progreso del crossfade [0.0, 1.0) en la banda.
    float progress[kEqBandCount]{};
    /// Paso de avance por bloque. 0.2 ≈ 5 bloques ≈ ~20 ms a 4 ms/bloque.
    static constexpr float kStep = 0.2f;
};

/// Estado snapshot por banda para crossfade: conserva los coeficientes y el
/// estado del biquad PREVIO al cambio, usados para calcular la señal "vieja"
/// que se cross-fadea hacia la señal "nueva".
struct BiquadPrevState {
    BiquadCoeffs coeffs;
    BiquadState state;
    bool valid = false;
};

/// Ecualizador paramétrico de 12 bandas con filtros biquad peaking.
///
/// Rango de ganancias: [0, 50] dB por banda.
/// ÚNICA etapa del pipeline que amplifica la señal.
///
/// Mejoras de Fase D (EQ transaccional + crossfade):
/// 1. **Commit transaccional**: las 12 ganancias se escriben como un snapshot
///    atómico completo. El hilo de audio lee el snapshot más reciente (por
///    índice) y nunca ve mezcla de ganancias nuevas/viejas entre bandas.
/// 2. **Crossfade biquad**: cuando los coeficientes cambian (nuevo commit),
///    se preserva el estado "viejo" del biquad y se crossfadea linealmente
///    la salida vieja → nueva en ~20 ms (5 bloques), eliminando el click del
///    transitorio de cambio de coeficientes en serie (12 biquads DF-I).
///
/// Uso:
/// @code
///   Equalizer eq;
///   eq.init(16000); // sample rate
///   float gains[12] = {0, 0, 0, 10, 15, 20, 22, 25, 27, 30, 30, 25};
///   eq.setGains(gains);  // commit transaccional
///   eq.process(buffer, 64);  // rampa + crossfade automático
/// @endcode
class Equalizer {
public:
    Equalizer();
    ~Equalizer() = default;

    /// Inicializa el ecualizador con la frecuencia de muestreo dada.
    void init(int sampleRate);

    /// Procesa un bloque de audio aplicando ecualización in-place.
    /// Incluye rampa exponencial de ganancias, crossfade de coeficientes,
    /// y sanitización NaN/Inf.
    void process(float* buffer, int blockSize);

    /// Commit transaccional de las 12 ganancias (en dB, rango [0, 50]).
    /// Thread-safe: escribe un snapshot completo con un solo store release
    /// del índice. El hilo de audio lo lee atómicamente en el próximo
    /// process() y dispara crossfade si las ganancias cambiaron.
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

    /// Avanza la rampa de ganancias un paso (un bloque) hacia el target y
    /// recalcula los coeficientes de las bandas cuyo valor suavizado cambió.
    /// Se ejecuta CADA bloque desde el hilo de audio.
    void stepGainRamp();

    /// Commit transaccional desde la UI thread: avanza el índice de escritura,
    /// copia las 12 ganancias y publica con release. Retorna el nuevo índice.
    uint64_t commitNewSnapshot(const float gains[kEqBandCount]);

    /// Detecta nuevo snapshot desde audio thread (lectura acquire del índice)
    /// y, si hay uno nuevo, prepara el crossfade copiando los coeficientes +
    /// estados "viejos" antes de que stepGainRamp() los pise.
    void checkForNewSnapshot();

    /// Procesa una muestra a través de un filtro biquad (Direct Form I).
    /// Sanitiza NaN/Inf: si la salida no es finita, resetea el estado y deja
    /// pasar la muestra de entrada (corta la auto-propagación del IIR).
    static float processBiquadSample(float sample, const BiquadCoeffs& coeffs,
                                     BiquadState& state);

    // --- Configuración ---
    int sampleRate_ = 16000;

    // --- Snapshot transaccional (double-buffering) ---
    EqSnapshot snapshots_[2];                      ///< Double buffer: índice 0=lectura, 1=escritura
    std::atomic<uint64_t> readSnapshotSeq_{0};     ///< Secuencia del snapshot que el audio thread está consumiendo
    std::atomic<uint64_t> writeSnapshotSeq_{0};     ///< Última secuencia commitada por la UI thread

    // --- Ganancias target para la rampa (actualizadas desde checkForNewSnapshot) ---
    std::atomic<float> gains_[kEqBandCount];       ///< Targets de ganancia para stepGainRamp (audio thread)

    // --- Coeficientes y estado (solo accedidos desde hilo de audio) ---
    BiquadCoeffs coeffs_[kEqBandCount];   ///< Coeficientes actuales por banda
    BiquadState states_[kEqBandCount];    ///< Estado de filtro por banda
    float appliedGains_[kEqBandCount];    ///< Ganancias con las que se calcularon los coeficientes
    float rampGains_[kEqBandCount];       ///< Ganancia SUAVIZADA actual por banda (audio thread)

    // --- Crossfade entre coeficientes ---
    EqCrossfader crossfader_;                        ///< Estado del crossfade activo por banda
    BiquadPrevState prevStates_[kEqBandCount];       ///< Coeficientes + estados "viejos" para crossfade

    /// Coeficiente de la rampa exponencial de ganancias del EQ.
    /// y[n] = y[n-1] + alpha * (target - y[n-1]) → tau ≈ 1/alpha bloques.
    /// 0.02 ≈ 50 bloques ≈ 200 ms a 64 muestras/16 kHz (≈4 ms/bloque),
    /// alineado con kWdrcRampAlpha del pipeline.
    static constexpr float kEqRampAlpha = 0.02f;
    /// Si |target - ramp| < esto, se hace snap al target (evita recálculo perpetuo).
    static constexpr float kEqGainSnapEps = 0.01f;
    /// Umbral de diferencia para recalcular coeficientes (en dB).
    static constexpr float kEqCoeffRecalcEps = 0.01f;
};

#endif // HEARING_AID_EQUALIZER_H

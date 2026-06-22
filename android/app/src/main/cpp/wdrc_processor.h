/// @file wdrc_processor.h
/// @brief WDRC (Wide Dynamic Range Compression) con modelo de 3 regiones.
///
/// Implementa compresión de rango dinámico amplio con:
/// - Envelope detector muestra-por-muestra con attack/release asimétricos
/// - Modelo de 3 regiones: expansión, lineal, compresión
/// - Usa nivel PRE-EQ (inputLevelDb) para decisión de región
/// - Suavizado de ganancia con attack/release para evitar cambios abruptos
/// - gainFactor siempre ∈ [0.0, 1.0] — WDRC nunca amplifica
///
/// Diseño (compromiso del steering):
///   La DECISIÓN de región se basa en el nivel PRE-EQ por bloque.
///   La APLICACIÓN de ganancia se suaviza muestra-por-muestra usando
///   coeficientes de attack/release para evitar discontinuidades entre bloques.

#ifndef HEARING_AID_WDRC_PROCESSOR_H
#define HEARING_AID_WDRC_PROCESSOR_H

#include <atomic>
#include <cmath>

/// Parámetros compuestos del WDRC commitados atómicamente.
///
/// Fase F/Atomic — reemplaza los 6 atomics individuales por un snapshot
/// que se escribe completo desde UI thread y se lee completo desde audio
/// thread mediante un índice de doble buffer. Esto garantiza que knee,
/// ratio, attack y release se vean de forma consistente (transaccional)
/// desde el audio thread, evitando la ventana donde algunos parámetros
/// tienen el valor nuevo y otros el viejo.
///
/// Usado con AtomicWdrcSnapshot (doble buffer gobernado por un seq atómico).
struct WdrcParamsSnapshot {
    float expansionKnee  = 35.0f;  ///< dB SPL — debajo: expansión
    float expansionRatio = 2.0f;   ///< Ratio de expansión (input:output)
    float compressionKnee  = 55.0f; ///< dB SPL — encima: compresión
    float compressionRatio = 2.0f; ///< Ratio de compresión (input:output)
    float attackMs    = 5.0f;     ///< Tiempo de ataque en ms
    float releaseMs   = 100.0f;   ///< Tiempo de liberación en ms
    uint64_t seq = 0;             ///< Secuencia monotónica para detectar snapshots nuevos
};

/// Double-buffer atómico para commit transaccional de WdrcParamsSnapshot.
/// El UI thread escribe en un buffer y publica el índice; el audio thread
/// detecta el cambio y lee el buffer completo.
struct AtomicWdrcSnapshot {
    WdrcParamsSnapshot snapshots[2];       ///< Double buffer
    std::atomic<uint64_t> readSeq{0};      ///< Última secuencia consumida por audio thread
    std::atomic<uint64_t> writeSeq{0};     ///< Última secuencia publicada por UI thread

    /// Commit transaccional desde UI thread.
    /// @return la nueva secuencia (writeSeq después del commit).
    uint64_t commit(const WdrcParamsSnapshot& src) {
        const uint64_t oldW = writeSeq.load(std::memory_order_acquire);
        const int idx = (oldW % 2 == 0) ? 1 : 0;
        snapshots[idx] = src;
        snapshots[idx].seq = oldW + 1;
        writeSeq.store(oldW + 1, std::memory_order_release);
        return oldW + 1;
    }

    /// Lee el snapshot más reciente desde audio thread.
    /// Devuelve true si hay un snapshot nuevo (y lo copia en out).
    bool tryRead(WdrcParamsSnapshot& out) {
        const uint64_t w = writeSeq.load(std::memory_order_acquire);
        if (w == readSeq.load(std::memory_order_relaxed)) {
            return false;  // no hay snapshot nuevo
        }
        const int idx = (w % 2 == 0) ? 0 : 1;
        out = snapshots[idx];
        readSeq.store(w, std::memory_order_release);
        return true;
    }

    /// Inicializa ambos snapshots con valores por defecto.
    void initDefaults() {
        for (auto& s : snapshots) {
            s = WdrcParamsSnapshot{};
            s.seq = 0;
        }
        readSeq.store(0, std::memory_order_relaxed);
        writeSeq.store(0, std::memory_order_relaxed);
    }
};

/// WDRC con modelo de 3 regiones:
/// - Expansión (input < expansionKnee): atenúa ruido de fondo
/// - Lineal (expansionKnee ≤ input ≤ compressionKnee): ganancia unitaria
/// - Compresión (input > compressionKnee): protege de sonidos fuertes
///
/// El envelope detector opera muestra-por-muestra para capturar transitorios,
/// pero la decisión de región se basa en el nivel PRE-EQ del bloque completo.
/// Esto evita que la amplificación del EQ dispare compresión innecesaria.
class WdrcProcessor {
public:
    /// Constructor. Inicializa con sample rate por defecto (16000 Hz).
    WdrcProcessor();
    ~WdrcProcessor() = default;

    /// Inicializa el procesador con el sample rate del sistema.
    /// Debe llamarse antes de process() para calcular coeficientes correctos.
    /// @param sampleRate Frecuencia de muestreo en Hz (típicamente 16000)
    void init(int sampleRate);

    /// Procesa un bloque de audio aplicando compresión dinámica in-place.
    ///
    /// Algoritmo:
    /// 1. Calcula el gainFactor objetivo basado en inputLevelDb (PRE-EQ)
    /// 2. Para cada muestra, suaviza la transición de ganancia usando
    ///    coeficientes de attack/release (envelope muestra-por-muestra)
    /// 3. Aplica el gainFactor suavizado a cada muestra
    ///
    /// @param buffer Puntero al buffer de audio float32 [-1.0, +1.0]
    /// @param blockSize Número de muestras en el buffer
    /// @param inputLevelDb Nivel de entrada PRE-EQ en dB SPL
    void process(float* buffer, int blockSize, float inputLevelDb);

    // --- Actualización de parámetros (thread-safe, lock-free) ---

    void setExpansionKnee(float knee);
    void setExpansionRatio(float ratio);
    void setCompressionKnee(float knee);
    void setCompressionRatio(float ratio);
    void setAttackMs(float ms);
    void setReleaseMs(float ms);

    /// Calcula el factor de ganancia para un nivel dado (sin suavizado).
    /// Útil para testing y visualización.
    /// @param inputLevelDb Nivel de entrada en dB SPL
    /// @return Factor de ganancia ∈ [0.0, 1.0]
    float computeGainFactor(float inputLevelDb) const;

    /// Escanea el buffer post-EQ para detectar picos y aplica headroom guard.
    /// Garantiza que ninguna muestra excede 0.95 (kHeadroomCeiling).
    /// Llamar DESPUÉS de process() para proteger contra transitorios post-EQ.
    ///
    /// @param buffer Puntero al buffer de audio float32 (modificado in-place)
    /// @param blockSize Número de muestras en el buffer
    void applyHeadroomGuard(float* buffer, int blockSize);

private:
    /// Recalcula los coeficientes de attack/release basados en los tiempos
    /// actuales y el sample rate.
    void updateCoefficients();

    /// Commit transaccional de los 6 parámetros WDRC como snapshot atómico.
    /// Escribe un WdrcParamsSnapshot completo y publica el índice.
    void commitParams(const WdrcParamsSnapshot& src);

    /// Detecta nuevo snapshot desde audio thread y, si lo hay, actualiza
    /// los parámetros locales + recalcula coeficientes.
    void checkForNewParams();

    /// Snapshot atómico de doble buffer para los parámetros WDRC.
    AtomicWdrcSnapshot atomicParams_;

    /// Parámetros activos en el audio thread (copia local del snapshot).
    WdrcParamsSnapshot activeParams_;

    /// Sample rate del sistema (Hz)
    int sampleRate_ = 16000;

    /// Estado del envelope detector (ganancia suavizada actual).
    /// Rango: [0.0, 1.0]. Inicializado a 1.0 (sin atenuación).
    float smoothedGain_ = 1.0f;

    /// Coeficientes de suavizado pre-calculados.
    /// attackCoeff: para transiciones rápidas (ganancia baja → más rápido)
    /// releaseCoeff: para transiciones lentas (ganancia sube → más lento)
    float attackCoeff_ = 0.0f;
    float releaseCoeff_ = 0.0f;
};

#endif // HEARING_AID_WDRC_PROCESSOR_H

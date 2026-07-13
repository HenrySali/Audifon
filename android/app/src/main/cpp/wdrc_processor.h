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
///
/// FIX Causa F (smart-scene-diagnostico-chasquido.md):
///   compressionKnee y compressionRatio se almacenan como un struct atómico
///   (AtomicWdrcCompression) para que el WDRC nunca lea un knee nuevo con
///   un ratio viejo (o viceversa). El setter setCompressionParams() actualiza
///   ambos en un solo store atómico, y computeGainFactor() los lee en un solo
///   load. Esto elimina la ventana de inconsistencia entre los dos atomics
///   individuales anteriores.

#ifndef HEARING_AID_WDRC_PROCESSOR_H
#define HEARING_AID_WDRC_PROCESSOR_H

#include <atomic>
#include <cmath>
#include <cstring>

/// Parámetros de compresión del WDRC (knee + ratio) como un solo struct
/// para store/load atómico. Esto garantiza que el WDRC nunca lea un knee
/// nuevo con un ratio viejo (Causa F).
struct WdrcCompressionParams {
    float compressionKnee;   ///< dB SPL — encima: compresión
    float compressionRatio;  ///< Ratio de compresión (input:output)

    bool operator==(const WdrcCompressionParams& other) const {
        return compressionKnee == other.compressionKnee &&
               compressionRatio == other.compressionRatio;
    }
    bool operator!=(const WdrcCompressionParams& other) const {
        return !(*this == other);
    }
};

/// Parámetros atómicos del WDRC para actualización thread-safe.
/// Cada parámetro se almacena individualmente como atómico para
/// permitir actualizaciones lock-free desde el hilo de UI.
/// EXCEPTO compressionKnee + compressionRatio que viven juntos en
/// un std::atomic<WdrcCompressionParams> para garantizar atomicidad
/// compuesta (Causa F).
struct AtomicWdrcParams {
    std::atomic<float> expansionKnee{35.0f};     ///< dB SPL — debajo: expansión
    std::atomic<float> expansionRatio{2.0f};     ///< Ratio de expansión (input:output)
    std::atomic<WdrcCompressionParams> compression{ {55.0f, 2.0f} }; ///< Knee + ratio atómicos
    std::atomic<float> attackMs{5.0f};           ///< Tiempo de ataque en ms
    std::atomic<float> releaseMs{100.0f};        ///< Tiempo de liberación en ms
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

    /// FIX Causa F: actualiza compressionKnee y compressionRatio en un solo
    /// store atómico. El WDRC nunca leerá un knee nuevo con un ratio viejo.
    /// @param knee Compression knee en dB SPL
    /// @param ratio Compression ratio (input:output, ≥ 1.0)
    void setCompressionParams(float knee, float ratio);

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

    /// Parámetros atómicos (thread-safe, actualizables desde hilo de UI).
    AtomicWdrcParams params_;

    /// Sample rate del sistema (Hz)
    int sampleRate_ = 16000;

    /// Estado del envelope detector (ganancia suavizada actual).
    /// Rango: [0.0, 1.0]. Inicializado a 1.0 (sin atenuación).
    float smoothedGain_ = 1.0f;

public:
    /// Retorna el último gain factor aplicado (post-suavizado).
    /// Thread-safe para lectura casual desde hilo de diagnóstico.
    float getLastGainFactor() const { return smoothedGain_; }

private:

    /// Coeficientes de suavizado pre-calculados.
    /// attackCoeff: para transiciones rápidas (ganancia baja → más rápido)
    /// releaseCoeff: para transiciones lentas (ganancia sube → más lento)
    float attackCoeff_ = 0.0f;
    float releaseCoeff_ = 0.0f;
};

#endif // HEARING_AID_WDRC_PROCESSOR_H
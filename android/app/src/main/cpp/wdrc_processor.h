/// @file wdrc_processor.h
/// @brief WDRC con ganancia prescrita integrada (modelo audífono real).
///
/// Basado en:
/// - UC San Diego Open Speech Platform (WDRC amplifies quiet sounds)
/// - openMHA dynamic compressor with NAL-NL2 insertion gains
/// - PMC4168964: linear gain below compression threshold
/// - Starkey Compression Handbook: max gain at soft inputs
///
/// El WDRC ahora AMPLIFICA la señal según la ganancia prescrita (NAL-NL2).
/// La ganancia varía con el nivel de entrada:
///   - Señales suaves: ganancia completa (prescribedGainDb)
///   - Señales medias: ganancia completa (región lineal)
///   - Señales fuertes: ganancia reducida (compresión)
///   - Ruido de fondo: ganancia reducida (expansión)

#ifndef HEARING_AID_WDRC_PROCESSOR_H
#define HEARING_AID_WDRC_PROCESSOR_H

#include <atomic>
#include <cmath>

/// Parámetros atómicos del WDRC para actualización thread-safe.
struct AtomicWdrcParams {
    std::atomic<float> expansionKnee{35.0f};     ///< dB SPL — debajo: expansión
    std::atomic<float> expansionRatio{2.0f};     ///< Ratio de expansión (input:output)
    std::atomic<float> compressionKnee{55.0f};   ///< dB SPL — encima: compresión
    std::atomic<float> compressionRatio{2.0f};   ///< Ratio de compresión (input:output)
    std::atomic<float> attackMs{5.0f};           ///< Tiempo de ataque en ms
    std::atomic<float> releaseMs{100.0f};        ///< Tiempo de liberación en ms
};

/// WDRC con ganancia prescrita — amplifica según prescripción NAL-NL2.
///
/// Modelo de 3 regiones:
/// - Expansión (input < expKnee): ganancia reducida (suprime ruido)
/// - Lineal (entre knees): ganancia prescrita completa
/// - Compresión (input > compKnee): ganancia reducida (protege el oído)
class WdrcProcessor {
public:
    WdrcProcessor();
    ~WdrcProcessor() = default;

    void init(int sampleRate);

    /// Procesa un bloque aplicando ganancia prescrita con compresión dinámica.
    void process(float* buffer, int blockSize, float inputLevelDb);

    // --- Actualización de parámetros (thread-safe, lock-free) ---

    void setExpansionKnee(float knee);
    void setExpansionRatio(float ratio);
    void setCompressionKnee(float knee);
    void setCompressionRatio(float ratio);
    void setAttackMs(float ms);
    void setReleaseMs(float ms);

    /// Establece la ganancia prescrita broadband (promedio de las 12 bandas).
    /// El EQ aplica las diferencias por banda; el WDRC aplica la base común.
    /// @param gainDb Ganancia en dB [0, 50]. 0 = sin amplificación.
    void setPrescribedGainDb(float gainDb);

    /// Calcula el factor de ganancia para un nivel dado (sin suavizado).
    float computeGainFactor(float inputLevelDb) const;

    /// Protección de headroom post-procesamiento.
    void applyHeadroomGuard(float* buffer, int blockSize);

private:
    void updateCoefficients();

    AtomicWdrcParams params_;

    /// Ganancia prescrita broadband en dB (NAL-NL2 promedio).
    std::atomic<float> prescribedGainDb_{0.0f};

    int sampleRate_ = 16000;
    float smoothedGain_ = 1.0f;
    float attackCoeff_ = 0.0f;
    float releaseCoeff_ = 0.0f;
};

#endif // HEARING_AID_WDRC_PROCESSOR_H

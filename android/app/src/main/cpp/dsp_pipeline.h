/// @file dsp_pipeline.h
/// @brief Pipeline DSP completo para procesamiento de audio en tiempo real.
///
/// Orden del pipeline: HPF 100Hz → NR → medir nivel PRE-EQ → EQ → WDRC → Volume → MPO
///
/// Principios de diseño:
/// - El nivel se mide ANTES del EQ para que el WDRC tome decisiones
///   basadas en el nivel real de entrada, no en el nivel amplificado.
/// - Solo EQ y Volume amplifican. Todo lo demás atenúa o pasa sin cambio.
/// - MPO es la última etapa — red de seguridad absoluta sample-by-sample.
/// - MPO threshold: 110 dB SPL (FDA 21 CFR 800.30 OTC limit: 111 dB SPL).
/// - Offset calibración: 93 dB para mic celular Android con AGC.
/// - Actualizaciones de parámetros son thread-safe (atómicas, lock-free).

#ifndef HEARING_AID_DSP_PIPELINE_H
#define HEARING_AID_DSP_PIPELINE_H

#include <cstdint>
#include <atomic>
#include <cmath>

#include "noise_reduction.h"
#include "equalizer.h"
#include "wdrc_processor.h"
#include "mpo_limiter.h"
#include "environment_classifier.h"
#include "spectrum_analyzer.h"

/// Configuración de audio del sistema
struct AudioConfig {
    int sampleRate = 16000;            ///< Hz
    int bufferSize = 64;               ///< muestras por bloque
    int channels = 1;                  ///< mono
    int bitsPerSample = 16;            ///< PCM16
    float mpoThresholdDbSpl = 110.0f;  ///< dB SPL — threshold del MPO (FDA OTC: 111 dB SPL)
    float splOffset = 93.0f;           ///< Offset dBFS → dB SPL (93 para mic celular con AGC)
};

/// Parámetros del WDRC (Wide Dynamic Range Compression)
struct WdrcParams {
    float expansionKnee = 35.0f;       ///< dB SPL — debajo de esto, expansión
    float expansionRatio = 2.0f;       ///< input:output ratio de expansión
    float compressionKnee = 55.0f;     ///< dB SPL — encima de esto, compresión
    float compressionRatio = 2.0f;     ///< input:output ratio de compresión
    float attackMs = 5.0f;             ///< ms — tiempo de ataque
    float releaseMs = 100.0f;          ///< ms — tiempo de liberación
};

/// Pipeline DSP principal — procesa bloques de audio en tiempo real.
///
/// Uso típico:
/// @code
///   DspPipeline pipeline;
///   pipeline.init(config);
///   // En hilo de audio:
///   pipeline.processBlock(buffer, 64);
///   // Desde hilo de UI (thread-safe):
///   pipeline.setVolume(-5.0f);
///   pipeline.setEqGains(gains);
/// @endcode
class DspPipeline {
public:
    DspPipeline();
    ~DspPipeline();

    /// Inicializa el pipeline con la configuración dada.
    /// Debe llamarse antes de processBlock.
    /// @param config Configuración de audio del sistema
    void init(const AudioConfig& config);

    /// Procesa un bloque de audio float32 [-1.0, +1.0] in-place.
    /// Orden: NR → medir nivel PRE-EQ → EQ → WDRC → Volume → MPO
    /// @param buffer Puntero al buffer de audio (modificado in-place)
    /// @param blockSize Número de muestras en el buffer (típicamente 64)
    void processBlock(float* buffer, int blockSize);

    // --- Métodos de actualización de parámetros (thread-safe, lock-free) ---

    /// Actualiza ganancias del EQ (12 bandas, en dB, rango [0, 50]).
    /// @param gains Array de 12 valores de ganancia en dB
    void setEqGains(const float gains[12]);

    /// Actualiza volumen maestro en dB (rango [-20, +10]).
    /// @param volumeDb Volumen en dB
    void setVolume(float volumeDb);

    /// Actualiza parámetros del WDRC.
    /// @param params Estructura con los nuevos parámetros
    void setWdrcParams(const WdrcParams& params);

    /// Actualiza nivel de reducción de ruido.
    /// @param level 0=off, 1=bajo, 2=medio, 3=alto
    void setNrLevel(int level);

    /// Actualiza offset de calibración SPL (dBFS → dB SPL).
    /// @param offset Offset en dB (120 para mic real, 76 para WAV)
    void setSplOffset(float offset);

    /// Obtiene el último nivel de entrada medido PRE-EQ (dB SPL).
    /// Actualizado cada bloque. Seguro para leer desde cualquier hilo.
    float getLastInputLevelDb() const;

    /// Habilita/deshabilita la clasificación automática de entorno.
    /// Cuando está habilitada, NR y WDRC se ajustan automáticamente.
    /// @param enabled true para habilitar, false para deshabilitar
    void setAutoClassifyEnabled(bool enabled);

    /// Obtiene la clase de entorno actual (thread-safe).
    /// @return 0=QUIET, 1=SPEECH, 2=SPEECH_IN_NOISE, 3=NOISE
    int getCurrentEnvironmentClass() const;

    /// Acceso al analizador de espectro (para JNI bridge).
    SpectrumAnalyzer& getSpectrumAnalyzer() { return spectrumAnalyzer_; }
    const SpectrumAnalyzer& getSpectrumAnalyzer() const { return spectrumAnalyzer_; }

private:
    /// Mide el nivel RMS de un buffer y lo convierte a dB SPL.
    /// @param buffer Buffer de audio float32
    /// @param blockSize Número de muestras
    /// @return Nivel en dB SPL (usando splOffset_ actual)
    float measureRmsDb(const float* buffer, int blockSize) const;

    /// Aplica volumen maestro (factor lineal) al buffer.
    /// @param buffer Buffer de audio float32
    /// @param blockSize Número de muestras
    /// @param volumeLinear Factor lineal de volumen
    static void applyVolume(float* buffer, int blockSize, float volumeLinear);

    /// Estimación simplificada de SNR basada en nivel de entrada.
    /// Usada por el clasificador de entorno cuando no hay acceso directo
    /// a las estimaciones de ruido por banda del NR.
    /// @param inputLevelDb Nivel de entrada en dB SPL
    /// @return SNR estimado en dB, clampeado a [-20, 40]
    float estimateSnrSimple(float inputLevelDb) const;

    // --- Módulos del pipeline ---
    NoiseReduction nr_;       ///< Reducción de ruido (solo atenúa)
    Equalizer eq_;            ///< EQ 12 bandas (AMPLIFICA según prescripción)
    WdrcProcessor wdrc_;      ///< WDRC 3 regiones (solo atenúa)
    MpoLimiter mpo_;          ///< Limitador de picos (solo atenúa)
    EnvironmentClassifier envClassifier_; ///< Clasificador automático de entorno

    // --- Parámetros atómicos (actualizables desde hilo de UI) ---
    std::atomic<float> volumeDb_{0.0f};       ///< Volumen maestro en dB
    std::atomic<float> volumeLinear_{1.0f};   ///< Factor lineal pre-calculado
    std::atomic<float> splOffset_{93.0f};     ///< Offset dBFS → dB SPL (93 para mic celular)
    std::atomic<bool> autoClassifyEnabled_{true}; ///< Clasificación automática habilitada

    // --- Estado de salida (legible desde cualquier hilo) ---
    std::atomic<float> lastInputLevelDb_{0.0f}; ///< Último nivel PRE-EQ medido

    // --- Estado interno para el clasificador ---
    int lastEnvClass_ = 0;  ///< Última clase de entorno aplicada
    int currentNrLevel_ = 0; ///< Nivel NR actual (transiciones graduales)

    // --- Analizador de espectro ---
    SpectrumAnalyzer spectrumAnalyzer_;  ///< FFT 128-point para visualización

    // --- High-pass filter state (2nd order Butterworth @ 150 Hz) ---
    float hpX1_ = 0.0f, hpX2_ = 0.0f;
    float hpY1_ = 0.0f, hpY2_ = 0.0f;
    // Precomputed coefficients (computed in init() for actual sample rate)
    float hpB0_ = 0.0f, hpB1_ = 0.0f, hpB2_ = 0.0f;
    float hpA1_ = 0.0f, hpA2_ = 0.0f;

    /// Computes 2nd-order Butterworth high-pass filter coefficients.
    /// @param sampleRate Sample rate in Hz
    /// @param cutoffHz Cutoff frequency in Hz
    void computeHighPassCoeffs(int sampleRate, float cutoffHz);
};

#endif // HEARING_AID_DSP_PIPELINE_H

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
#include <limits>

#include "noise_reduction.h"
#include "equalizer.h"
#include "wdrc_processor.h"
#include "mpo_limiter.h"
#include "environment_classifier.h"
#include "spectrum_analyzer.h"
#include "transient_reducer.h"

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

    /// Habilita el bypass del NR Wiener interno. Usado cuando un denoiser
    /// externo (DNN) procesó el buffer antes y queremos evitar doble NR.
    /// Thread-safe (atómico).
    void setNrBypassed(bool bypassed) {
        nrBypassed_.store(bypassed, std::memory_order_release);
    }
    bool isNrBypassed() const {
        return nrBypassed_.load(std::memory_order_acquire);
    }

    /// Habilita/deshabilita el Transient Noise Reducer (TNR).
    /// El TNR atenúa impulsos abruptos como timbres del subte, puertas, bocinas.
    void setTnrEnabled(bool enabled) { tnr_.setEnabled(enabled); }
    bool isTnrEnabled() const { return tnr_.isEnabled(); }

    /// Configura el umbral del TNR (ratio fast/slow envelope).
    /// Default: 8.0. Rango: 4.0 (sensible) a 12.0 (conservador).
    void setTnrThreshold(float ratio) { tnr_.setThreshold(ratio); }

    /// Configura la atenuación del TNR en dB (negativo).
    /// Default: -12 dB. Rango: -6 a -18 dB.
    void setTnrAttenuationDb(float db) { tnr_.setAttenuationDb(db); }

    /// Actualiza offset de calibración SPL (dBFS → dB SPL).
    /// @param offset Offset en dB (120 para mic real, 76 para WAV)
    void setSplOffset(float offset);

    /// Actualiza el threshold del limitador MPO en dB SPL en runtime.
    ///
    /// Convierte el valor a amplitud lineal usando el offset SPL actual:
    ///   linear = pow(10, (thresholdDbSpl - splOffset) / 20)
    /// y aplica el resultado al MPO sin reiniciar el motor.
    ///
    /// El valor lineal se clampa al techo de seguridad digital (0.85 ≈ -1.4
    /// dBFS) para preservar la protección anti-clipping. El valor en dB SPL
    /// queda almacenado de forma atómica para ser re-derivado cuando cambie
    /// el offset de calibración (ver setSplOffset).
    ///
    /// Thread-safe: lock-free (atómicos + setThresholdLinear atómico).
    /// Propagación al MPO: 1 atomic store; efectivo en el siguiente bloque
    /// (∼3–6 ms a 16/48 kHz, ≪ 50 ms p95 requerido por la spec).
    ///
    /// @param thresholdDbSpl Threshold en dB SPL (rango clínico [80, 132])
    void setMpoThresholdDbSpl(float thresholdDbSpl);

    /// Obtiene el último nivel de entrada medido PRE-EQ (dB SPL).
    /// Actualizado cada bloque. Seguro para leer desde cualquier hilo.
    float getLastInputLevelDb() const;

    /// Obtiene métricas de todas las etapas del pipeline (para diagnóstico).
    struct StageMetrics {
        float inputLevel;
        float postNrLevel;
        float postEqLevel;
        float postWdrcLevel;
        float postVolumeLevel;
        float outputLevel;
        float peakSample;
        int clipCount;
        float wdrcGainFactor;
        int wdrcRegion;  // 0=expansion, 1=linear, 2=compression
        float eqMaxGain;
        int environmentClass;
    };
    StageMetrics getStageMetrics() const;

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
    TransientReducer tnr_;    ///< Transient Noise Reducer (impulsos abruptos)

    // --- Parámetros atómicos (actualizables desde hilo de UI) ---
    std::atomic<float> volumeDb_{0.0f};       ///< Volumen maestro en dB
    std::atomic<float> volumeLinear_{1.0f};   ///< Factor lineal pre-calculado
    std::atomic<float> splOffset_{93.0f};     ///< Offset dBFS → dB SPL (93 para mic celular)
    /// Threshold del MPO en dB SPL actualizado en runtime via
    /// setMpoThresholdDbSpl(). Se conserva en dB SPL para poder re-derivar
    /// el valor lineal del MPO cuando cambia splOffset_ (calibración del
    /// micrófono). Default: NaN ⇒ usar el threshold lineal fijo configurado
    /// en init() (0.85 ≈ -1.4 dBFS). Cuando es finito, manda y se aplica
    /// como min(linear(threshold,offset), 0.85).
    std::atomic<float> mpoThresholdDbSpl_{std::numeric_limits<float>::quiet_NaN()};
    std::atomic<bool> autoClassifyEnabled_{true}; ///< Clasificación automática habilitada
    std::atomic<bool> nrBypassed_{false};     ///< true: saltear NR Wiener (un denoiser externo lo reemplaza)

    // --- Estado de salida (legible desde cualquier hilo) ---
    std::atomic<float> lastInputLevelDb_{0.0f}; ///< Último nivel PRE-EQ medido

    // --- Métricas por etapa del pipeline (para diagnóstico DSP) ---
    std::atomic<float> lastPostNrLevelDb_{0.0f};     ///< Nivel post-NR
    std::atomic<float> lastPostEqLevelDb_{0.0f};     ///< Nivel post-EQ
    std::atomic<float> lastPostWdrcLevelDb_{0.0f};   ///< Nivel post-WDRC
    std::atomic<float> lastPostVolumeLevelDb_{0.0f}; ///< Nivel post-Volume
    std::atomic<float> lastOutputLevelDb_{0.0f};     ///< Nivel final (post-MPO)
    std::atomic<float> lastPeakSample_{0.0f};        ///< Pico máximo del último bloque
    std::atomic<int> lastClipCount_{0};              ///< Muestras clipeadas en último bloque
    std::atomic<float> lastWdrcGainFactor_{1.0f};    ///< Último gainFactor del WDRC
    std::atomic<int> lastWdrcRegion_{1};             ///< 0=expansion, 1=linear, 2=compression

    // --- Estado interno para el clasificador ---
    int lastEnvClass_ = 0;  ///< Última clase de entorno aplicada
    int currentNrLevel_ = 0; ///< Nivel NR actual (transiciones graduales)

    // --- FIX Causa A (smart-scene-diagnostico-chasquido.md): rampa de WDRC + NR ---
    // Antes el cambio de clase del EnvironmentClassifier sustituía el
    // compressionKnee (55→40), compressionRatio (1.5→3.0) y nrLevel (0→3)
    // en un solo sample, generando un click audible por transición.
    // Ahora el cambio de clase fija TARGETS y la actualización al WDRC se
    // interpola exponencialmente cada bloque (~200 ms hacia el target);
    // el NR avanza un paso discreto cada kNrLevelStepBlocks bloques
    // (~300 ms entre niveles) para evitar el escalón del gainFloor.
    float wdrcKneeRamp_ = 55.0f;             ///< Valor actual (suavizado) del knee
    float wdrcKneeTarget_ = 55.0f;           ///< Target solicitado por el clasificador
    float wdrcRatioRamp_ = 2.0f;             ///< Valor actual (suavizado) del ratio
    float wdrcRatioTarget_ = 2.0f;           ///< Target solicitado por el clasificador
    int   nrLevelTarget_ = 0;                ///< Nivel NR objetivo
    int   nrLevelRampBlocksRemaining_ = 0;   ///< Bloques pendientes hasta el próximo step de NR
    /// Coeficiente de la rampa exponencial del WDRC (~200 ms a 4 ms/bloque).
    /// y[n] = y[n-1] + alpha * (target - y[n-1])  → tau ≈ 1/alpha bloques.
    static constexpr float kWdrcRampAlpha = 0.02f;
    /// Bloques entre incrementos discretos del nrLevel (~300 ms a 4 ms/bloque).
    static constexpr int kNrLevelStepBlocks = 75;
    /// Bloques de “grace period” inicial al detectar cambio de clase (~200 ms)
    /// antes de empezar a mover el NR de nivel — evita aplicar el escalón
    /// del gainFloor justo en el frame de la transición.
    static constexpr int kNrLevelInitialDelayBlocks = 50;

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

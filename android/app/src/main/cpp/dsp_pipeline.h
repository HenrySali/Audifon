/// @file dsp_pipeline.h
/// @brief Pipeline DSP completo para procesamiento de audio en tiempo real.
///
/// Orden del pipeline: HPF 100Hz → TNR → NR → Expansor → SCE → EQ → [AuditoryModel | WDRC] → Volume → FBS → OC → MPO
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
#include "feedback_suppressor.h"
#include "output_compressor.h"
#include "adaptive_feedback_canceller.h"
#include "spectral_contrast_enhancer.h"
#include "expander.h"
#include "auditory_model.h"

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

/// Preset completo del Smart Scene, aplicado atómicamente al pipeline.
///
/// Fase G — applyScenePreset único: contiene todos los parámetros que
/// antes se enviaban como 4 llamadas separadas (EQ, WDRC, NR, TNR).
/// El caller (Dart SceneEngine.apply()) construye este struct y lo
/// envía por un solo MethodChannel. El motor C++ lo aplica en orden
/// seguro (MPO → WDRC → EQ → NR) sin ventana de incoherencia entre
/// llamadas.
struct ScenePreset {
    float gains[12];             ///< Ganancias EQ (dB, [0, 50])
    WdrcParams wdrc;             ///< Parámetros WDRC completos
    int nrLevel = 0;             ///< Nivel de reducción de ruido [0, 3]
    bool tnrEnabled = false;     ///< Transient Noise Reducer ON/OFF
    float mpoThresholdDbSpl = 110.0f; ///< MPO broadband en dB SPL
    bool pinPreset = true;       ///< Si true, fija el pin del preset Smart
    int enhancementMode = 0;     ///< 0=Bypass, 1=DualDNN, 2=MVDR, 3=DualDNN+MVDR(híbrido)
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
    ///
    /// Si se proporciona @p externalLevelDb ≥ 0 (y finito), el WDRC usa ese
    /// valor como nivel de entrada en lugar de medir el RMS local del buffer.
    /// Esto permite al AudioEngine pasar el nivel medido ANTES de la DNN
    /// (pre-DNN) para que el WDRC tome decisiones sobre la señal real de
    /// entrada y no sobre la señal ya atenuada por la red neuronal.
    ///
    /// El valor sentinel -1.0f (default) indica "no hay nivel externo;
    /// medir localmente desde el buffer", preservando retrocompatibilidad
    /// con callers existentes (incluida la app del paciente que clona este
    /// código nativo).
    ///
    /// @param buffer Puntero al buffer de audio (modificado in-place)
    /// @param blockSize Número de muestras en el buffer (típicamente 64)
    /// @param externalLevelDb Nivel pre-DNN en dB SPL ≥ 0 para que lo use el
    ///        WDRC, o -1.0f (default) para medir localmente. Valores NaN/Inf
    ///        se tratan como sentinel y disparan medición local.
    /// @param vadActive Voz humana confirmada por el SmartScene VAD del
    ///        AudioEngine. Default false. El clasificador de entorno usa
    ///        este flag como memoria de voz reciente para evitar el flicker
    ///        SPEECH↔QUIET por las pausas naturales del habla. Si el caller
    ///        no tiene un VAD disponible (paciente / V3 cuando aún no
    ///        clonaron el motor), pasar false da el comportamiento previo.
    void processBlock(float* buffer, int blockSize,
                      float externalLevelDb = -1.0f,
                      bool  vadActive       = false);

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

    /// Habilita/deshabilita el cancelador adaptativo de feedback (AFC).
    /// Estima el camino de feedback y lo resta del mic ANTES de que entre al
    /// pipeline. Preventivo (vs FBS que es reactivo). Activado por default.
    void setAfcEnabled(bool enabled) { afc_.setEnabled(enabled); }
    bool isAfcEnabled() const { return afc_.isEnabled(); }

    /// Step size (mu) del NLMS del AFC. Rango: [0.001, 0.1]. Default: 0.01.
    void setAfcStepSize(float mu) { afc_.setStepSize(mu); }

    /// Nivel del probe noise del AFC (lineal). Default: 0.003 (~-50 dBFS).
    void setAfcProbeLevel(float level) { afc_.setProbeLevel(level); }

    /// Habilita/deshabilita el supresor de realimentación (anti-howling).
    /// Detecta el pitido (Larsen) por tonalidad/persistencia y lo ataca con
    /// notches adaptativos + un guard de ganancia de respaldo. Solo atenúa.
    void setFeedbackSuppressorEnabled(bool enabled) { fbs_.setEnabled(enabled); }
    bool isFeedbackSuppressorEnabled() const { return fbs_.isEnabled(); }

    /// Profundidad de cada notch anti-howling en dB (negativo).
    /// Default: -18 dB. Rango: -6 (suave) a -30 (agresivo).
    void setFeedbackDepthDb(float db) { fbs_.setDepthDb(db); }

    /// Habilita/deshabilita el compresor/soft-limiter de SALIDA (freno pre-MPO).
    /// Baja la ganancia de forma suave (soft-knee + ratio finito) sobre la
    /// señal real de salida ANTES del MPO, para que el MPO casi nunca tenga
    /// que hacer hard-clamp (menos THD). Solo atenúa. Activado por default.
    void setOutputCompressorEnabled(bool enabled) { oc_.setEnabled(enabled); }
    bool isOutputCompressorEnabled() const { return oc_.isEnabled(); }

    /// Habilita/deshabilita el Spectral Contrast Enhancer (SCE).
    /// Realza la voz atenuando los valles espectrales entre formantes.
    /// Solo atenúa valles → nunca amplifica → sin riesgo para MPO.
    void setSceEnabled(bool enabled) { sce_.setEnabled(enabled); }
    bool isSceEnabled() const { return sce_.isEnabled(); }

    /// Intensidad del SCE. factor ∈ [0, 1]: 0=bypass, 0.5=-6dB valles, 1=max.
    void setSceFactor(float factor) { sce_.setFactor(factor); }
    float getSceFactor() const { return sce_.getFactor(); }

    // ─── Modelo Auditivo (simulación del sistema auditivo humano) ────────
    /// Habilita/deshabilita el modelo auditivo (6 etapas cocleares).
    /// Cuando está habilitado, simula la cadena auditiva humana y aplica
    /// compensaciones personalizadas según el audiograma del paciente.
    /// Se inserta después del EQ, antes del WDRC.
    void setAuditoryModelEnabled(bool enabled) { auditoryModel_.setEnabled(enabled); }
    bool isAuditoryModelEnabled() const { return auditoryModel_.isEnabled(); }

    /// Configura el audiograma del paciente para el modelo auditivo.
    /// Los umbrales en dB HL (12 bandas) determinan la compensación OHC.
    /// @param thresholds Array de 12 valores en dB HL (0 = audición normal)
    void setAuditoryModelAudiogram(const float thresholds[12]) {
        auditoryModel_.setAudiogram(thresholds);
    }

    // ─── Expansor de baja frecuencia (R1, tarea 4) ──────────────────────
    /// Configura el Expansor de baja frecuencia (downward expansion ≤1000 Hz).
    /// Default: enabled=false, ratio=1.0 → passthrough (R6.3, AC5, AC7). Los
    /// setters son thread-safe (atómicos en Expander).
    /// @param enabled Toggle de activación (AC5).
    /// @param kneeDbSpl Knee de expansión en dB SPL (AC1, default 45).
    /// @param ratio Ratio de expansión, 1.0 = passthrough (AC4).
    /// @param cutoffHz Frecuencia de corte superior (AC2, default 1000).
    /// @param attackMs Ataque (recuperación de ganancia) en ms (AC6, ≤50).
    /// @param releaseMs Liberación (atenuación) en ms (AC4a, default 400).
    void setExpanderParams(bool enabled, float kneeDbSpl, float ratio,
                           float cutoffHz, float attackMs, float releaseMs) {
        expander_.setKneeDbSpl(kneeDbSpl);
        expander_.setRatio(ratio);
        expander_.setCutoffHz(cutoffHz);
        expander_.setAttackMs(attackMs);
        expander_.setReleaseMs(releaseMs);
        expander_.setEnabled(enabled);
    }
    bool isExpanderEnabled() const { return expander_.isEnabled(); }

    /// Ratio del compresor de salida (input:output). Default: 4.0 (4:1).
    void setOutputCompressorRatio(float ratio) { oc_.setRatio(ratio); }
    /// Ancho del soft-knee del compresor de salida en dB. Default: 6 dB.
    void setOutputCompressorKneeDb(float kneeDb) { oc_.setKneeDb(kneeDb); }

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

    /// Ajusta el ancho de la rodilla suave (soft-knee) del limitador MPO, en
    /// dB. FIX voz ronca: el MPO reduce la ganancia de forma progresiva por
    /// DEBAJO del techo en vez de recortar duro (hard-clamp). Default seguro
    /// (6 dB) aplicado en el constructor del MpoLimiter — este setter sólo se
    /// necesita para afinación/diagnóstico. El invariante |output| ≤ threshold
    /// se mantiene siempre. Thread-safe (1 atomic store).
    /// @param kneeWidthDb Ancho de rodilla en dB (0 = hard-clamp clásico).
    void setMpoKneeWidthDb(float kneeWidthDb);

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
        /// Nivel pre-DNN en dB SPL pasado por el AudioEngine al último
        /// processBlock. -1.0f indica "no disponible" (medición local).
        /// Permite verificar Property 8 del design (compression ratio).
        float preDnnLevelDb = -1.0f;
        /// true si el último processBlock usó el nivel externo (pre-DNN);
        /// false si midió RMS localmente desde el buffer post-DNN.
        bool wdrcUsesExternalLevel = false;
        /// Fracción [0,1] de muestras del último bloque en las que el MPO
        /// estuvo limitando (decisión B audifono-v3). La app la usa para el
        /// aviso de nivel cercano al límite de seguridad (R9.2).
        float mpoLimitingFraction = 0.0f;
        /// true si el MPO estuvo limitando de forma SOSTENIDA (≥ ~200 ms
        /// cuasi-continuos) en el último bloque. Señal del aviso visible
        /// de R9.2 (audifono-v3).
        bool mpoLimitingSustained = false;
    };
    StageMetrics getStageMetrics() const;

    /// Habilita/deshabilita la clasificación automática de entorno.
    /// Cuando está habilitada, NR y WDRC se ajustan automáticamente.
    /// @param enabled true para habilitar, false para deshabilitar
    void setAutoClassifyEnabled(bool enabled);

    /// Configura los umbrales del clasificador de entorno (R4, tarea 3.3).
    /// Todos los parámetros son configurables desde Dart; defaults = valores
    /// previos si Dart no los envía (R6.5). Thread-safe (atómicos internos).
    /// @param speechEnterDb SNR (dB) para ENTRAR a SPEECH (default 6.0)
    /// @param speechExitDb  SNR (dB) para SALIR de SPEECH  (default 4.0)
    /// @param noiseSnrDb    SNR (dB) bajo el cual el entorno es NOISE (1.5)
    /// @param quietEnterDbSpl Nivel (dB SPL) para ENTRAR a QUIET (default 44)
    /// @param quietExitDbSpl  Nivel (dB SPL) para SALIR de QUIET  (default 49)
    void setClassifierThresholds(float speechEnterDb, float speechExitDb,
                                 float noiseSnrDb,
                                 float quietEnterDbSpl, float quietExitDbSpl) {
        envClassifier_.setSpeechSnrThresholds(speechEnterDb, speechExitDb);
        envClassifier_.setNoiseSnrThreshold(noiseSnrDb);
        envClassifier_.setQuietLevelThresholds(quietEnterDbSpl, quietExitDbSpl);
    }

    /// Pin del preset Smart Scene aplicado manualmente.
    ///
    /// Cuando el usuario aplica un preset Smart desde la UI, NR + WDRC + EQ
    /// quedan configurados con valores específicos para la escena detectada.
    /// Sin pin, el clasificador automático sigue corriendo y, en cada cambio
    /// de clase, machaca los targets del WDRC y NR — el preset queda "a
    /// medias" y la voz se desbalancea aleatoriamente (síntoma reportado en
    /// docs/smart-scene-diagnostico-chasquido.md, Causa C).
    ///
    /// Con `pinned=true`:
    ///   - El clasificador SIGUE corriendo y publica la clase actual en
    ///     `getCurrentEnvironmentClass()` (la UI puede mostrar "Aula",
    ///     "Calle", etc.).
    ///   - Los targets del WDRC + NR NO se actualizan al cambiar de clase
    ///     mientras el pin esté activo. El preset Smart que el usuario
    ///     aplicó manualmente se mantiene.
    ///
    /// Liberación esperada del pin desde Dart:
    ///   - Apagar Smart Scene desde la UI.
    ///   - Aplicar un preset distinto (custom, factory) que no provenga
    ///     de Smart Scene.
    ///   - Iniciar una nueva sesión de detección Smart Scene.
    ///
    /// Thread-safe: store atómico release.
    void setSmartPresetPinned(bool pinned) {
        smartPresetPinned_.store(pinned, std::memory_order_release);
    }

    /// True si actualmente hay un preset Smart Scene aplicado manualmente.
    bool isSmartPresetPinned() const {
        return smartPresetPinned_.load(std::memory_order_acquire);
    }

    /// Obtiene la clase de entorno actual (thread-safe).
    /// @return 0=QUIET, 1=SPEECH, 2=SPEECH_IN_NOISE, 3=NOISE
    int getCurrentEnvironmentClass() const;

    /// Aplica un preset completo del Smart Scene de forma atómica.
    ///
    /// Fase G — applyScenePreset único: reemplaza 4 llamadas separadas
    /// (setEqGains + setWdrcParams + setNrLevel + setTnrEnabled +
    /// setMpoThresholdDbSpl + setSmartPresetPinned) por una sola llamada
    /// que aplica todo en orden seguro (MPO → WDRC → EQ → NR → TNR → pin).
    ///
    /// Esto elimina la ventana de ~4-6 llamadas MethodChannel donde el
    /// clasificador automático podía pisar targets intermedios, y garantiza
    /// que el motor vea el preset completo de forma coherente.
    ///
    /// Thread-safe: todos los setters internos son atómicos. El pin se
    /// fija ANTES de los setters para que el clasificador no pise los
    /// targets durante la aplicación.
    ///
    /// @param preset Estructura con todos los parámetros del preset.
    void applyScenePreset(const ScenePreset& preset);

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

    /// Aplica al limitador MPO el threshold derivado de un valor en dB SPL,
    /// usando la calibración de SALIDA dedicada (kMpoSplOffset), NO el offset
    /// de entrada del micrófono (splOffset_).
    ///
    /// Reconciliación de la decisión B (audifono-v3): el MPO clínico (UCL del
    /// paciente, un SPL en el OÍDO) pertenece a la cadena de salida, no a la
    /// de entrada. Convertirlo con el offset de entrada (93) lo volvía no-op
    /// (todo MPO ≥ ~92 dB SPL saturaba en el techo digital 0.85). Con
    /// kMpoSplOffset=120, el MPO clínico [80, ~118.6] dB SPL mapea a
    /// thresholds lineales operativos y distinguibles; 0.85 queda como red
    /// de seguridad dura. Validado en tools/sim_v3/validate_mpo.py (Property 1).
    ///
    ///   linear     = 10^((dbSpl - kMpoSplOffset) / 20)
    ///   threshold  = min(linear, kMpoDigitalCeiling)
    ///
    /// Si @p dbSpl no es finito (MPO clínico no seteado), aplica el techo
    /// digital puro (kMpoDigitalCeiling) preservando el comportamiento legacy.
    /// @param dbSpl Threshold del MPO en dB SPL (o NaN para techo digital).
    void applyMpoThresholdFromDbSpl(float dbSpl);

    /// Offset de calibración acústica de SALIDA (oído) para convertir el MPO
    /// clínico (dB SPL) a amplitud lineal. DISTINTO de splOffset_ (93 dB,
    /// calibración del mic de ENTRADA que sirve a WDRC/escena). Referencia
    /// "mic real"/salida ya usada en mpo_limiter.h y spectrum_analyzer.h.
    static constexpr float kMpoSplOffset = 120.0f;

    /// Techo de seguridad digital del MPO (hard-clamp lineal, ≈ -1.4 dBFS).
    /// Red de seguridad dura anti-clipping: el threshold nunca lo supera.
    static constexpr float kMpoDigitalCeiling = 0.85f;

    /// Headroom del compresor de salida (OutputCompressor) respecto al techo
    /// del MPO. El threshold del OC = thresholdMpo × headroom, de modo que el
    /// freno suave (ShaMPO broadband único) empieza a actuar POR DEBAJO del
    /// hard-clamp del MPO. Así el MPO casi nunca recorta (menos THD) y sigue
    /// intacto como red de seguridad dura.
    ///
    /// ETAPA 1 v3 (headroom condicional según MPO clínico) — el v2 dejó un
    /// único headroom de 12 dB para todos los casos, pero con MHL Prescripción
    /// ON el techo MPO baja a ≈ 99 dB SPL. Anclar el OC 12 dB POR DEBAJO de un
    /// MPO ya conservador deja el threshold ≈ 87 dB SPL → atenúa voz
    /// conversacional con preset alto (gains 25-27 dB). Solución: HEADROOM
    /// CONDICIONAL al MPO clínico (en dB SPL), con plateaus + rampa suave para
    /// evitar "click" al activar/desactivar MHL.
    ///
    ///   MPO ≤ kSoftLimiterMpoLowDbSpl  (≈100 dB SPL) → kSoftLimiterHeadroomMhl
    ///                                                  (-6 dB)
    ///   MPO ≥ kSoftLimiterMpoHighDbSpl (≈110 dB SPL) → kSoftLimiterHeadroom
    ///                                                  (-12 dB)
    ///   Entre LOW y HIGH                              → interpolación lineal
    ///                                                  en dB (rampa suave).
    ///
    /// Justificación clínica:
    ///   - Con MHL Prescripción ON el MPO ya es per-band y conservador (UCL
    ///     menos margen): el OC sólo necesita ser red de seguridad final
    ///     contra picos extremos. -6 dB cubre el crest factor instantáneo
    ///     dejando el RMS de voz totalmente transparente.
    ///   - Con MHL OFF (UCL alto / techo digital) el OC es la primera
    ///     defensa contra suma multitono y transitorios fuertes: -12 dB
    ///     mantiene el headroom de Byrne et al. (+12 dB pico/RMS).
    ///
    /// Comportamiento esperado:
    ///   - MPO 98.75 dB SPL (MHL ON), voz 65 dB SPL → threshold OC ≈ 92.75
    ///     dB SPL, picos típicos < threshold → atenuación ~0 dB.
    ///   - MPO 115 dB SPL (MHL OFF), voz 65 dB SPL → threshold OC ≈ 103 dB
    ///     SPL, picos < threshold → atenuación ~0 dB.
    ///   - MPO 98.75 dB SPL + preset alto (output post-EQ ~92 dB SPL, picos
    ///     ~104 dB SPL) → ratio 4:1 atenúa ~9 dB → peak final ≈ 95 dB SPL,
    ///     ≥ 3 dB bajo el MPO clínico (no llega a hard-clamp).
    ///
    /// Validado en tools/sim_v3/validate_softlimiter.py (paridad con C++).
    static constexpr float kSoftLimiterHeadroom    = 0.2512f; ///< -12 dB (MHL OFF / MPO alto)
    static constexpr float kSoftLimiterHeadroomMhl = 0.5012f; ///< -6 dB  (MHL ON / MPO bajo)

    /// Ventana de transición (dB SPL) sobre la que el headroom interpola
    /// linealmente en dB entre kSoftLimiterHeadroomMhl (-6 dB) y
    /// kSoftLimiterHeadroom (-12 dB). Centrada en 105 dB SPL (≈ frontera
    /// MHL/normal) con ±5 dB de rampa → 10 dB de transición evita "click"
    /// al activar/desactivar MHL durante la fase de fitting.
    static constexpr float kSoftLimiterMpoLowDbSpl  = 100.0f;
    static constexpr float kSoftLimiterMpoHighDbSpl = 110.0f;

    /// Calcula el headroom lineal del OutputCompressor en función del MPO
    /// clínico (dB SPL). Implementa la lógica condicional + rampa documentada
    /// en kSoftLimiterHeadroom*. Si @p mpoDbSpl no es finito (NaN), devuelve
    /// kSoftLimiterHeadroom (modo "MPO no clínico" / techo digital alto).
    /// @param mpoDbSpl Threshold del MPO clínico en dB SPL (o NaN).
    /// @return Headroom lineal (∈ [kSoftLimiterHeadroom, kSoftLimiterHeadroomMhl]).
    static float computeSoftLimiterHeadroom(float mpoDbSpl) noexcept;

    // --- Módulos del pipeline ---
    AdaptiveFeedbackCanceller afc_; ///< AFC adaptativo (estima y resta feedback path)
    NoiseReduction nr_;       ///< Reducción de ruido (solo atenúa)
    SpectralContrastEnhancer sce_; ///< SCE: realza voz atenuando valles (solo atenúa)
    Expander expander_;       ///< Expansor de baja frecuencia ≤1kHz (R1, solo atenúa; default OFF)
    Equalizer eq_;            ///< EQ 12 bandas (AMPLIFICA según prescripción)
    AuditoryModel auditoryModel_; ///< Modelo auditivo humano (6 etapas cocleares, post-EQ pre-WDRC)
    WdrcProcessor wdrc_;      ///< WDRC 3 regiones (solo atenúa)
    MpoLimiter mpo_;          ///< Limitador de picos (solo atenúa)
    EnvironmentClassifier envClassifier_; ///< Clasificador automático de entorno
    TransientReducer tnr_;    ///< Transient Noise Reducer (impulsos abruptos)
    FeedbackSuppressor fbs_;  ///< Supresor de realimentación (anti-howling)
    OutputCompressor oc_;     ///< Compresor/soft-limiter de salida (freno pre-MPO)

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
    /// Pin del preset Smart Scene aplicado manualmente. Ver
    /// setSmartPresetPinned() para la semántica completa. Default false:
    /// retrocompat — si nadie llama al setter, el comportamiento es el
    /// mismo que antes de Fase B' (clasificador automático libre).
    std::atomic<bool> smartPresetPinned_{false};
    std::atomic<bool> nrBypassed_{false};     ///< true: saltear NR Wiener (un denoiser externo lo reemplaza)

    // --- Estado de salida (legible desde cualquier hilo) ---
    std::atomic<float> lastInputLevelDb_{0.0f}; ///< Último nivel PRE-EQ medido
    /// true si el último processBlock usó el nivel externo (pre-DNN) pasado
    /// por el AudioEngine; false si midió el RMS localmente desde el buffer.
    /// Tracking diagnóstico para verificar el origen del nivel WDRC en
    /// grabaciones diagnósticas y validar Property 2/8 del design document.
    std::atomic<bool> wdrcUsesExternalLevel_{false};

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
    int lastEnvClass_ = 0;  ///< Última clase de entorno (4 clases, solo métricas)
    int currentNrLevel_ = 0; ///< Nivel NR actual (transiciones graduales)

    /// Última SceneClass del SceneAnalyzer (8 clases). Actualizado por
    /// AudioEngine tras cada sceneAnalyzer_.process(). El pipeline lo lee
    /// para aplicar la tabla unificada (scene_policy.h).
    std::atomic<uint8_t> lastSceneClass_{0};  ///< 0=UNKNOWN

public:
    /// Setter llamado por AudioEngine tras sceneAnalyzer_.process().
    void setLastSceneClass(uint8_t sc) {
        lastSceneClass_.store(sc, std::memory_order_relaxed);
    }
private:

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

    /// Dwell time para cambio de escena (anti-chasquido por oscilación).
    /// La nueva SceneClass debe sostenerse kSceneDwellBlocks consecutivos
    /// antes de aplicarla. ~2 s a 4 ms/bloque (256 samples / 48 kHz ≈ 5.3 ms;
    /// ajustamos a 375 bloques ≈ 2.0 s). Phonak usa ~3-5 s; 2 s es reactivo
    /// pero suficiente para evitar oscilación en el subte.
    static constexpr int kSceneDwellBlocks = 375;

    /// Escena actualmente aplicada (tras cumplir el dwell).
    uint8_t currentAppliedScene_ = 0;  // UNKNOWN
    /// Escena pendiente (candidata, aún no cumplió dwell).
    uint8_t pendingScene_ = 0;
    /// Contador de bloques consecutivos con la escena pendiente.
    int pendingSceneCounter_ = 0;
    /// Bloques entre incrementos discretos del nrLevel (~300 ms a 4 ms/bloque).
    static constexpr int kNrLevelStepBlocks = 75;
    /// Bloques de “grace period” inicial al detectar cambio de clase (~200 ms)
    /// antes de empezar a mover el NR de nivel — evita aplicar el escalón
    /// del gainFloor justo en el frame de la transición.
    static constexpr int kNrLevelInitialDelayBlocks = 50;

    // --- Analizador de espectro ---
    SpectrumAnalyzer spectrumAnalyzer_;  ///< FFT 128-point para visualización

    // --- High-pass filter state (2nd order Butterworth @ 100 Hz) ---
    // NOTA: el cutoff real es 100 Hz (ver init() → computeHighPassCoeffs(.., 100.0f)).
    // El comentario decía 150 Hz por error histórico; corregido (auditoría sim_v3).
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

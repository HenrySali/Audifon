/// @file audio_engine.h
/// @brief Motor de audio de baja latencia usando Google Oboe (FullDuplexStream).

#ifndef HEARING_AID_AUDIO_ENGINE_H
#define HEARING_AID_AUDIO_ENGINE_H

#include <atomic>
#include <functional>
#include <memory>
#include <cstdint>

#include <oboe/Oboe.h>
#include "dsp_pipeline.h"
#include "diagnostic_recorder.h"
#include "smart_scene/scene_analyzer.h"
#include "calibration_spectrum/tone_analyzer.h"
#include "dnn_denoiser/dnn_denoiser.h"
#include "latency_loopback_tester.h"
#include "mvdr_beamformer.h"

// Forward decl from <android/asset_manager.h>
struct AAssetManager;

/// Configuración del motor de audio (updated for Oboe).
struct AudioEngineConfig {
    int sampleRate = 48000;              ///< Hz — native rate (was 44100)
    int bufferSize = 256;                ///< Hint only — Oboe manages actual size
    int channels = 1;                    ///< Mono
    float mpoThresholdDbSpl = 110.0f;   ///< Threshold del MPO en dB SPL (FDA OTC: 111)
    float splOffset = 93.0f;             ///< Offset dBFS → dB SPL (93 para mic celular con AGC)
    int builtInMicDeviceId = 0;          ///< Device ID for built-in mic (from Kotlin)
    /// Modo Conversación (SCO + baja latencia). Cuando es true, los streams
    /// Oboe se abren con Usage::VoiceCommunication + InputPreset::VoiceCommunication
    /// + SharingMode::Shared para que el sistema rutee el audio al canal SCO
    /// Bluetooth (que el lado Kotlin activó con MODE_IN_COMMUNICATION +
    /// setCommunicationDevice/startBluetoothSco). Sin esto, el output usa
    /// Usage::Media que se rutea a A2DP — y A2DP queda mudo cuando SCO toma
    /// el enlace BT (son perfiles mutuamente excluyentes). Spec:
    /// modo-conversacion-sco.
    bool conversationMode = false;
    bool beamformingEnabled = false;     ///< Habilitar captura estereo + MVDR beamformer
};

/// Snapshot de métricas de latencia del motor de audio.
///
/// Estructura POD-like que se rellena desde `AudioEngine::getLatencyMetrics()`
/// y se serializa a un Map vía JNI para consumo desde Kotlin/Dart. Todos los
/// campos son thread-safe-readable: el getter toma snapshots consistentes
/// usando atómicos relajados y getters de Oboe que no bloquean el callback.
///
/// Convenciones:
/// - Latencias en milisegundos (double).
/// - `inputLatencyMs` y `outputLatencyMs` valen `-1` cuando el timestamp de
///   Oboe no está disponible (stream sin getTimestamp() válido todavía).
/// - `inputAudioApi` / `outputAudioApi`: 0=Unspecified, 1=AAudio, 2=OpenSLES.
/// - `inputSharingMode` / `outputSharingMode`: 0=Exclusive, 1=Shared.
/// - `outputPerformanceMode`: 0=None, 1=PowerSaving, 2=LowLatency.
/// - `schemaVersion`: bump cuando cambien los campos de forma incompatible.
struct LatencyMetrics {
    // ─── Configuración del stream ──────────────────────────────────────
    int32_t sampleRate;              ///< Hz negociado por Oboe
    int32_t inputFramesPerBurst;     ///< frames por callback (input)
    int32_t outputFramesPerBurst;    ///< frames por callback (output)
    int32_t outputBufferSizeFrames;  ///< buffer size actual del output
    int32_t inputAudioApi;           ///< 0=Unspecified, 1=AAudio, 2=OpenSLES
    int32_t outputAudioApi;
    int32_t inputSharingMode;        ///< 0=Exclusive, 1=Shared
    int32_t outputSharingMode;
    int32_t outputPerformanceMode;   ///< 0=None, 1=PowerSaving, 2=LowLatency

    // ─── Latencias por etapa (todas en ms; -1 si no disponible) ────────
    double inputLatencyMs;           ///< Oboe input getTimestamp(), -1 si N/A
    double outputLatencyMs;          ///< Oboe output getTimestamp(), -1 si N/A
    double dspBlockMs;               ///< framesPerBlock / sampleRate * 1000
    double dspProcessingMsAvg;       ///< promedio móvil últimos 50 callbacks
    double dspProcessingMsMax;       ///< peor caso últimos 50 callbacks
    double dnnInferenceMs;           ///< dnnDenoiser.getLastInferenceUs() / 1000
    double dnnGroupDelayMs;          ///< dnnDenoiser.groupDelayMs(sampleRate)
    double tnrLookaheadMs;           ///< constante 5.0 ms

    // ─── Estado de salud ───────────────────────────────────────────────
    int32_t callbackUnderruns;       ///< outputStream.getXRunCount()
    bool    timestampsHealthy;       ///< false si getTimestamp() falló > 3s

    // ─── Versionado ────────────────────────────────────────────────────
    int32_t schemaVersion = 1;       ///< versión del esquema
};

/// Selector del motor de realce de voz (spec gtcrn-dual-channel, tarea 3.1).
///
/// Reemplaza el par de flags históricos `beamformingEnabled` + `dnnEnabled`
/// por un selector explícito de 3 estados mutuamente excluyentes. El default
/// de arranque es `kBypass` (R8.3). Cablea vía JNI → Kotlin → UI (tarea 4/5).
///
///   kBypass         -> ch0 passthrough, sin realce (default arranque).
///   kDualChannelDnn -> 2 mics -> WPE + GTCRN dual (ONNX) -> mono realzado.
///   kMvdrBackup     -> 2 mics -> MVDR beamformer -> mono realzado.
///
/// Los valores enteros (0/1/2) son parte del contrato JNI/Kotlin/Dart y no
/// deben reordenarse sin bumpear el mapeo del puente.
enum class EnhancementEngineMode {
    kBypass = 0,
    kDualChannelDnn = 1,
    kMvdrBackup = 2,
    kHybridMvdrDnn = 3   ///< MVDR crossover ≤1000 Hz + DualDNN (modo premium)
};

/// Motor de audio de baja latencia con procesamiento DSP integrado.
/// Usa Oboe FullDuplexStream para I/O sincronizado en un callback.
class AudioEngine : public oboe::FullDuplexStream,
                    public oboe::AudioStreamErrorCallback {
public:
    AudioEngine();
    ~AudioEngine();

    // No copiable ni movible
    AudioEngine(const AudioEngine&) = delete;
    AudioEngine& operator=(const AudioEngine&) = delete;

    /// Inicia captura y reproducción usando Oboe FullDuplexStream.
    bool start(const AudioEngineConfig& config);

    /// Detiene streams y libera recursos Oboe.
    /// Returns oboe::Result (overrides FullDuplexStream::stop()).
    oboe::Result stop() override;

    /// @return true si ambos streams están activos.
    bool isRunning() const;

    // ─── Actualizaciones de parámetros DSP (thread-safe, lock-free) ─────
    void setEqGains(const float gains[12]);
    void setVolume(float volumeDb);
    void setWdrcParams(const WdrcParams& params);
    void setNrLevel(int level);
    void setSplOffset(float offset);
    /// Actualiza el threshold del MPO en dB SPL en runtime sin reiniciar
    /// el motor de audio. Delega a DspPipeline::setMpoThresholdDbSpl(), que
    /// convierte el valor a lineal usando el splOffset actual. Thread-safe.
    void setMpoThresholdDbSpl(float thresholdDbSpl);
    float getLastInputLevel() const;

    // ─── DSP Stage Metrics (para diagnóstico) ────────────────────────────
    DspPipeline::StageMetrics getStageMetrics() const { return pipeline_.getStageMetrics(); }

    // ─── Transient Noise Reducer (TNR) ───────────────────────────────────
    void setTnrEnabled(bool enabled) { pipeline_.setTnrEnabled(enabled); }
    void setTnrThreshold(float ratio) { pipeline_.setTnrThreshold(ratio); }
    void setTnrAttenuationDb(float db) { pipeline_.setTnrAttenuationDb(db); }

    // ─── Modelo Auditivo Humano (6 etapas fisiológicas) ──────────────────
    void setAuditoryModelEnabled(bool enabled) { pipeline_.setAuditoryModelEnabled(enabled); }
    void setAuditoryModelAudiogram(const float* thresholds) { pipeline_.setAuditoryModelAudiogram(thresholds); }

    // ─── Expansor de baja frecuencia (R1, tarea 4.3) ─────────────────────
    /// Forward a DspPipeline::setExpanderParams. Default OFF/ratio 1.0 →
    /// passthrough (R6.3). Thread-safe.
    void setExpanderParams(bool enabled, float kneeDbSpl, float ratio,
                           float cutoffHz, float attackMs, float releaseMs) {
        pipeline_.setExpanderParams(enabled, kneeDbSpl, ratio, cutoffHz,
                                    attackMs, releaseMs);
    }

    // ─── Modelo Auditivo (simulación del sistema auditivo humano) ────────
    /// Habilita/deshabilita el modelo auditivo (6 etapas cocleares).
    /// Thread-safe (atómico en AuditoryModel).
    void setAuditoryModelEnabled(bool enabled) {
        pipeline_.setAuditoryModelEnabled(enabled);
    }
    bool isAuditoryModelEnabled() const {
        return pipeline_.isAuditoryModelEnabled();
    }
    /// Configura el audiograma del paciente para el modelo auditivo.
    /// @param thresholds Array de 12 valores en dB HL (0 = audición normal)
    void setAuditoryModelAudiogram(const float thresholds[12]) {
        pipeline_.setAuditoryModelAudiogram(thresholds);
    }
    /// Configura la ganancia del modelo auditivo avanzado (slider UI).
    void setAuditoryModelEarCanalGain(float gainDb) {
        pipeline_.setAuditoryModelEarCanalGain(gainDb);
    }

    // ─── Supresor de reverberacion (R5, tarea 5.2) ───────────────────────
    /// Forward a MvdrBeamformer. Los setters son no-op efectivos fuera del
    /// modo MVDR (el beamformer hace bypass), pero el estado queda guardado
    /// para cuando se active el modo MVDR. Default = comportamiento previo.
    void setDereverbParams(bool enabled, float strength, float floor,
                           float decay) {
        mvdrBeamformer_.setDereverbEnabled(enabled);
        mvdrBeamformer_.setDereverbStrength(strength);
        mvdrBeamformer_.setDereverbFloor(floor);
        mvdrBeamformer_.setDereverbDecay(decay);
    }

    // ─── Environment Classifier (thread-safe) ───────────────────────────
    void setAutoClassifyEnabled(bool enabled);

    /// Configura los umbrales del clasificador de entorno (R4, tarea 3.3).
    /// Forward a DspPipeline::setClassifierThresholds. Defaults = valores
    /// previos si Dart no envía (R6.5). Thread-safe.
    void setClassifierThresholds(float speechEnterDb, float speechExitDb,
                                 float noiseSnrDb,
                                 float quietEnterDbSpl, float quietExitDbSpl) {
        pipeline_.setClassifierThresholds(speechEnterDb, speechExitDb,
                                          noiseSnrDb, quietEnterDbSpl,
                                          quietExitDbSpl);
    }
    /// Pin del preset Smart Scene aplicado manualmente — ver
    /// DspPipeline::setSmartPresetPinned() para la semántica completa.
    /// Wrapper directo al pipeline subyacente.
    void setSmartPresetPinned(bool pinned);
    int getCurrentEnvironmentClass() const;

    /// Aplica un preset completo del Smart Scene de forma atómica.
    /// Fase G — delega a DspPipeline::applyScenePreset(). Thread-safe.
    void applyScenePreset(const ScenePreset& preset);

    // ─── Smart Scene Engine (Fase 1) ─────────────────────────────────────
    /// Devuelve el snapshot crudo del Smart Scene Engine (lock-free seqlock).
    smart_scene::SceneSnapshot getSceneSnapshot() const { return sceneAnalyzer_.getSnapshot(); }

    // ─── Calibration Spectrum Validator (Fase 2) ─────────────────────────
    /// Acceso directo al ToneAnalyzer del validador de calibración.
    /// El analyzer está siempre inicializado pero solo procesa cuando active=true.
    cal_spectrum::ToneAnalyzer& getToneAnalyzer() { return toneAnalyzer_; }
    cal_spectrum::ToneSnapshot getToneSnapshot() const { return toneAnalyzer_.getSnapshot(); }
    void setToneAnalyzerActive(bool active) { toneAnalyzer_.setActive(active); }
    void setToneAnalyzerExpectedFreq(float hz) { toneAnalyzer_.setExpectedFrequency(hz); }
    void setToneAnalyzerNoiseFloor(float lin, float dbfs) { toneAnalyzer_.setNoiseFloor(lin, dbfs); }
    void resetToneAnalyzer() { toneAnalyzer_.reset(); }
    bool configureToneAnalyzer(const cal_spectrum::ToneAnalyzerConfig& cfg) {
        return toneAnalyzer_.configure(cfg);
    }

    // ─── DNN Denoiser (GTCRN vía OnnxRuntime) ───────────────────────────
    /// Inicializa el DNN denoiser desde assets.
    /// Llamar UNA VEZ al startup (idempotente). Si falla, queda en bypass
    /// permanente y el resto del pipeline funciona sin DNN.
    /// Default: disabled (la app arranca igual que hoy).
    /// @param mgr AAssetManager pasado desde Kotlin
    /// @return true si el modelo cargó correctamente.
    bool initDnnDenoiser(AAssetManager* mgr);
    /// Habilita/deshabilita el DNN denoiser (con crossfade anti-clic).
    /// Cuando está habilitado, REEMPLAZA al NR Wiener clásico.
    void setDnnEnabled(bool enabled);
    /// Mezcla dry/wet del DNN denoiser (0..1).
    void setDnnIntensity(float intensity);
    /// @return true si el DNN denoiser está procesando audio (no en bypass por error).
    bool getDnnIsActive() const { return dnnDenoiser_.isActive(); }
    /// @return true si el flag de configuración enabled está en true.
    bool getDnnIsEnabled() const { return dnnDenoiser_.isEnabled(); }

    // ─── MVDR Beamformer (dual-mic) ─────────────────────────────────────
    /// Habilita/deshabilita el beamformer MVDR en runtime (thread-safe).
    /// COMPAT: mapea al selector `EnhancementEngineMode` — ver
    /// `setEnhancementEngineMode` y la doc de mapeo en el .cpp.
    ///   setBeamformingEnabled(true)  → setEnhancementEngineMode(kMvdrBackup)
    ///   setBeamformingEnabled(false) → setEnhancementEngineMode(kBypass)
    void setBeamformingEnabled(bool enabled);
    /// @return true si el beamformer MVDR esta activo y procesando.
    bool isBeamformingActive() const;

    // ─── Enhancement Engine selector (spec gtcrn-dual-channel, tarea 3) ──
    /// Selecciona el motor de realce en runtime (thread-safe, lock-free).
    /// No reinicia los streams salvo que el modo requiera cambiar la
    /// geometría de captura mono↔estéreo (Fix #3 reutilizado). Los modos
    /// kDualChannelDnn y kMvdrBackup requieren captura estéreo; kBypass
    /// corre sobre ch0 (o el mono capturado) sin reabrir el stream. La
    /// transición entre motores aplica un crossfade lineal corto anti-clic
    /// dentro del callback (R2.5).
    void setEnhancementEngineMode(EnhancementEngineMode mode);
    /// @return el modo de realce seleccionado actualmente (lock-free).
    EnhancementEngineMode getEnhancementEngineMode() const;

    // ─── Spectrum Analyzer forwarding ───────────────────────────────────
    void startSpectrumAnalysis() { pipeline_.getSpectrumAnalyzer().setActive(true); }
    void stopSpectrumAnalysis() { pipeline_.getSpectrumAnalyzer().setActive(false); }
    void startSpectrumRecording() { pipeline_.getSpectrumAnalyzer().startRecording(); }
    int stopSpectrumRecording() { pipeline_.getSpectrumAnalyzer().stopRecording(); return pipeline_.getSpectrumAnalyzer().getRecordedCount(); }
    SpectrumSnapshot getCurrentSpectrum() const { return pipeline_.getSpectrumAnalyzer().getCurrentSnapshot(); }
    const SpectrumSnapshot* getRecordedSnapshots() const { return pipeline_.getSpectrumAnalyzer().getRecordedSnapshots(); }
    int getRecordedSnapshotCount() const { return pipeline_.getSpectrumAnalyzer().getRecordedCount(); }
    int getRecordedDataSize() const { return pipeline_.getSpectrumAnalyzer().getRecordedSize(); }

    // ─── Diagnostic Recorder (dual-channel pre/post DSP) ────────────────
    bool startDiagnosticRecording(const std::string& filePath);
    bool stopDiagnosticRecording();
    /// Detiene y conserva el WAV parcial (para grabaciones cortas intencionales).
    bool stopDiagnosticRecordingKeep();
    double getDiagnosticRecordingProgress() const;

    // ─── Callback de nivel para UI ──────────────────────────────────────
    using LevelCallback = std::function<void(float levelDbSpl)>;
    void setLevelCallback(LevelCallback cb);

    // ─── Device info (for UI display) ───────────────────────────────────
    int32_t getInputDeviceId() const;
    int32_t getOutputDeviceId() const;

    /// Establece el micrófono preferido por device ID.
    /// -1 = restaurar al default del sistema (kUnspecified).
    void setPreferredInputDevice(int32_t deviceId);

    /// Retorna el audio session ID del input stream (para NoiseSuppressor Android).
    /// @return Session ID (>0 si válido), o -1 si el stream no está activo.
    int32_t getInputSessionId() const;

    // ─── Oboe FullDuplexStream override ─────────────────────────────────
    oboe::DataCallbackResult onBothStreamsReady(
        const void *inputData,
        int numInputFrames,
        void *outputData,
        int numOutputFrames) override;

    // ─── Oboe Error Callback ────────────────────────────────────────────
    void onErrorAfterClose(oboe::AudioStream *stream,
                           oboe::Result error) override;

    // ─── Latency Monitor (Requirements 2.x, 4.x del spec monitor-latencia) ─
    /// Obtiene un snapshot consistente de las métricas de latencia.
    /// Thread-safe y lock-free: usa atómicos relajados y getters de Oboe
    /// que NO bloquean el callback de audio. Se llama desde el lado de
    /// control (Kotlin/Dart vía JNI), nunca desde el callback.
    /// @return snapshot del estado actual; campos `inputLatencyMs` y
    ///         `outputLatencyMs` valen -1 si el timestamp no está disponible.
    LatencyMetrics getLatencyMetrics() const;

    /// Activa o desactiva el muteo del audio ambiente (mic) durante el
    /// test acústico de loopback. Cuando `muted=true`, el callback escribe
    /// silencio en el output en lugar de procesar el pipeline DSP, para no
    /// contaminar la grabación del chirp emitido por el LatencyLoopbackTester.
    /// Idempotente; thread-safe (atomic store relajado).
    void setAmbientMute(bool muted);

    /// @return true si los streams expusieron timestamps válidos en los
    ///         últimos 3 segundos. Se basa en `lastSuccessfulTimestampNs_`,
    ///         que se refresca desde el callback cuando getTimestamp() OK.
    bool areTimestampsHealthy() const;

    // ─── Loopback Test (Requirement 5.x del spec monitor-latencia-audio) ──
    // Wrappers públicos sobre `loopbackTester_` que coordinan el muteo de
    // ambiente (`setAmbientMute`) con el ciclo de vida del test acústico.
    // Implementación en task 4.3 (esta task 4.1 solo declara los métodos
    // y crea el miembro `loopbackTester_`).

    /// Prepara y arranca un test de loopback acústico. Internamente llama
    /// `loopbackTester_->prepare(params)`, después `setAmbientMute(true)`
    /// y finalmente `loopbackTester_->start()`. Si algo falla, revierte
    /// el muteo del ambiente.
    /// @return true si el test arrancó correctamente; false en caso de error.
    bool startLoopbackTest(const latency_monitor::LoopbackParams& params);

    /// @return true si hay un test de loopback en curso (delega al tester).
    bool isLoopbackTestActive() const;

    /// Obtiene el resultado del test de loopback. Solo válido cuando
    /// `isLoopbackTestActive() == false`. Restaura `setAmbientMute(false)`
    /// antes de devolver el resultado.
    /// @return resultado final del tester; si todavía está activo, retorna
    ///         un `LoopbackResult` con `success=false` y `errorMessage`
    ///         describiendo el motivo.
    latency_monitor::LoopbackResult getLoopbackTestResult();

    /// Cancela el test en curso (si lo hay) y restaura `setAmbientMute(false)`.
    /// Idempotente: llamarlo cuando no hay test en curso es no-op.
    void cancelLoopbackTest();

private:
    /// Creates and opens input stream (built-in mic).
    oboe::Result openInputStream();

    /// Creates and opens output stream (default device).
    oboe::Result openOutputStream();

    /// Attempts to reopen both streams after error.
    void attemptReconnection();

    /// Renderiza un chunk (≤ kMaxBeamBlockSize) del motor `mode` sobre `dst`.
    /// Llamado SOLO desde el audio thread (onBothStreamsReady). No alloc/lock.
    ///   kBypass         → dst = ch0 (copia).
    ///   kMvdrBackup     → mvdrBeamformer_.process(ch0, ch1, dst, chunk, vad).
    ///   kDualChannelDnn → dnnDenoiserDual_.processStereo(ch0, ch1, dst, chunk).
    /// @param ch0 canal 0 deinterleaveado (mic inferior), chunk samples.
    /// @param ch1 canal 1 deinterleaveado (mic superior), chunk samples.
    /// @param dst destino mono, chunk samples (puede aliasar ch0).
    /// @param chunk número de samples del chunk.
    /// @param vadActive flag VAD del SceneAnalyzer para el MVDR.
    void renderEngineChunk(EnhancementEngineMode mode,
                           const float* ch0, const float* ch1,
                           float* dst, int chunk, bool vadActive);

    // ─── Pipeline DSP ───────────────────────────────────────────────────
    DspPipeline pipeline_;

    // ─── Diagnostic Recorder ─────────────────────────────────────────────
    DiagnosticRecorder diagnosticRecorder_;

    // ─── Smart Scene Engine (Fase 1) ─────────────────────────────────────
    smart_scene::SceneAnalyzer sceneAnalyzer_;

    // ─── Calibration Spectrum Validator (Fase 2) ─────────────────────────
    /// ToneAnalyzer integrado al callback de audio. Siempre presente,
    /// sólo activo cuando el técnico inicia una secuencia de validación.
    cal_spectrum::ToneAnalyzer toneAnalyzer_;

    // ─── DNN Denoiser (GTCRN) ────────────────────────────────────────────
    /// SubVI estilo LabVIEW: cuando enabled=true REEMPLAZA al NR Wiener
    /// del DspPipeline. Por default desactivado para arrancar igual que hoy.
    /// El Impl interno tiene un worker thread propio y ring buffers SPSC.
    dnn_denoiser::DnnDenoiser dnnDenoiser_;

    // ─── DNN Denoiser dual-channel (GTCRN dual, ONNX + WPE) ───────────────
    /// SEGUNDA instancia de DnnDenoiser, dedicada al modo kDualChannelDnn.
    ///
    /// DECISION (spec gtcrn-dual-channel, tarea 3): se usan DOS instancias
    /// separadas de DnnDenoiser en lugar de una sola. El motivo es que en el
    /// wrapper `initialize()` (mono) e `initializeDual()` (dual) son
    /// mutuamente excluyentes: ambos setean `active_` y el channel mode,
    /// y cada uno arma su worker thread. Para tener AMBAS rutas disponibles
    /// a la vez (mono legacy como stage del chain post-realce, y dual como
    /// motor de realce seleccionable) hacen falta dos objetos independientes
    /// con sus propios worker/ring/resampler.
    ///
    ///   dnnDenoiser_     -> mono legacy (ONNX). Stage `process()` del chain,
    ///                      controlado por setDnnEnabled() (sin cambios).
    ///   dnnDenoiserDual_ -> dual (ONNX + WPE beamformer). Motor de realce
    ///                      invocado por `processStereo()` solo en modo
    ///                      kDualChannelDnn.
    ///
    /// Ambas se inicializan en `initDnnDenoiser()` con el mismo AAssetManager.
    /// Costo: un worker thread extra en idle (sin inferencias si el modo no es
    /// dual). Beneficio: cero acoplamiento entre modelos y coexistencia limpia.
    dnn_denoiser::DnnDenoiser dnnDenoiserDual_;

    // ─── MVDR Beamformer (dual-mic, pre-DNN) ─────────────────────────────
    /// Beamformer MVDR de 2 microfonos. Procesa antes de la DNN.
    MvdrBeamformer mvdrBeamformer_;
    /// Buffers temporales para deinterleave de estereo.
    /// Tamaño = MvdrBeamformer::kFftSize (256): el beamformer procesa en
    /// frames de kFftSize y su outputBuf_ interno solo garantiza kFftSize*2
    /// muestras. Procesar chunks > kFftSize provocaba overread de outputBuf_
    /// en MvdrBeamformer::process (Fix #2/#7 auditoría MVDR). El callback
    /// trocea numFrames en chunks de este tamaño.
    static constexpr int kMaxBeamBlockSize = MvdrBeamformer::kFftSize;
    float beamCh0_[kMaxBeamBlockSize] = {};
    float beamCh1_[kMaxBeamBlockSize] = {};
    /// Estado del filtro LP para el crossover del modo híbrido (MVDR ≤1000 Hz).
    float hybridLpState_ = 0.0f;
    float hybridLpStateDnn_ = 0.0f;
    /// Flag indicando si el stream de input es realmente estereo.
    /// Se setea en openInputStream() cuando se logra abrir con 2 canales.
    bool stereoInputAvailable_ = false;

    // ─── Enhancement Engine selector — estado (tarea 3.2/3.5) ────────────
    /// Modo de realce seleccionado (lado control → callback). Lock-free.
    /// Default kBypass (R8.3). Lo escribe setEnhancementEngineMode() y lo
    /// lee onBothStreamsReady() con acquire.
    std::atomic<EnhancementEngineMode> engineMode_{EnhancementEngineMode::kBypass};

    /// Motor que el callback está renderizando actualmente como "entrante".
    /// SÓLO tocado desde el audio thread (no atómico). Se sincroniza con
    /// `engineMode_` al inicio de cada callback; si difieren, arranca un
    /// crossfade entre `prevEngine_` (saliente) y `activeEngine_` (entrante).
    EnhancementEngineMode activeEngine_ = EnhancementEngineMode::kBypass;
    /// Motor saliente durante un crossfade entre motores. Audio-thread-only.
    EnhancementEngineMode prevEngine_ = EnhancementEngineMode::kBypass;
    /// Muestras restantes del crossfade entre motores (0 = sin crossfade).
    /// Audio-thread-only. Se recarga a `engineXfadeSamples_` al cambiar modo.
    int engineXfadeRemaining_ = 0;
    /// Duración del crossfade entre motores en samples (≈20 ms a la rate
    /// nativa). Se calcula en start() con el sampleRate efectivo. El
    /// DnnDenoiser tiene su propio crossfade dry/wet interno; ESTE es el
    /// crossfade ENTRE motores distintos (R2.5).
    int engineXfadeSamples_ = 960;
    /// false hasta el primer start() exitoso. En el PRIMER start() el motor
    /// arranca forzado en kBypass (R8.3); los re-open posteriores por cambio
    /// de geometría (Fix #3) preservan el modo seleccionado.
    bool firstStartDone_ = false;
    /// Buffer temporal para renderizar el motor SALIENTE durante el
    /// crossfade (se mezcla contra outPtr con ganancia rampeada). Miembro
    /// (no stack) para no allocar en el hot path. Se procesa por chunks de
    /// hasta kMaxBeamBlockSize, así que este tamaño alcanza.
    float engineXfadeBuf_[kMaxBeamBlockSize] = {};

    // ─── Pre-DNN Level + Headroom Stage (DSP chain optimization) ────────
    /// Nivel pre-DNN del último bloque (dB SPL). Medido en onBothStreamsReady
    /// antes de invocar la DNN y pasado a DspPipeline::processBlock para que
    /// el WDRC use el nivel real de entrada en lugar del nivel post-DNN.
    /// Expuesto al DiagnosticRecorder para verificación del compression ratio.
    float lastPreDnnLevelDb_ = 0.0f;
    /// Flag por-bloque: indica si el Headroom_Stage atenuó el bloque actual
    /// antes de la DNN. Si true, post-DNN se restaura el nivel multiplicando
    /// por kHeadroomRestoreLinear. NO es estado persistente entre bloques.
    bool  headroomApplied_ = false;

    // ─── Configuración ──────────────────────────────────────────────────
    AudioEngineConfig config_;

    // ─── Oboe Streams ───────────────────────────────────────────────────
    std::shared_ptr<oboe::AudioStream> inputStream_;
    std::shared_ptr<oboe::AudioStream> outputStream_;

    /// Device ID preferido para input (-1 = kUnspecified/default).
    int32_t preferredInputDeviceId_ = -1;

    // ─── Estado ─────────────────────────────────────────────────────────
    std::atomic<bool> running_{false};
    std::atomic<bool> reconnecting_{false};
    std::atomic<int> reconnectAttempts_{0};

    // ─── Level callback ─────────────────────────────────────────────────
    LevelCallback levelCallback_;
    int callbackCounter_ = 0;
    int callbacksPerLevelReport_ = 0;  ///< Calculated: ceil(100ms / blockTime)

    // ─── Constants ──────────────────────────────────────────────────────
    static constexpr int kMaxReconnectAttempts = 3;
    static constexpr int kReconnectDelayMs = 500;
    static constexpr float kLevelReportIntervalMs = 100.0f;

    // Headroom Stage thresholds (DSP chain optimization, Requirement 2)
    /// Peak threshold lineal equivalente a -3 dBFS: pow(10, -3/20) ≈ 0.7079.
    /// Si el peak |sample| del bloque supera este valor, se atenúa pre-DNN.
    static constexpr float kHeadroomThresholdLinear = 0.7079f;
    /// Atenuación pre-DNN: multiplicador lineal para -6 dB.
    static constexpr float kHeadroomAttenLinear     = 0.5f;
    /// Restauración post-DNN: multiplicador lineal para +6 dB.
    /// kHeadroomAttenLinear * kHeadroomRestoreLinear == 1.0 (round-trip 0 dB).
    static constexpr float kHeadroomRestoreLinear   = 2.0f;

    // ─── Latency Monitor — campos privados (spec monitor-latencia-audio) ──
    /// Tamaño del ring buffer de medidas DSP timing (50 callbacks ≈ 50 ms
    /// a 48 kHz / 48 frames-per-burst, suficiente para un promedio móvil
    /// estable sin invalidar cache lines).
    static constexpr int kDspTimingRingSize = 50;

    /// Ring buffer de duración del callback en microsegundos. Se actualiza
    /// desde `onBothStreamsReady()` con `store(relaxed)`; se lee desde
    /// `getLatencyMetrics()` con `load(relaxed)`. Sin locks, sin contention.
    std::atomic<uint32_t> dspTimingRing_[kDspTimingRingSize];

    /// Índice circular del próximo slot a escribir en `dspTimingRing_`.
    /// Se incrementa con `fetch_add(relaxed)` y se reduce módulo el tamaño.
    std::atomic<int> dspTimingIndex_{0};

    /// Timestamp `CLOCK_MONOTONIC` (en nanosegundos) del último intento
    /// exitoso de `getTimestamp()` desde el callback. Permite a
    /// `areTimestampsHealthy()` reportar `false` si pasaron más de 3 s
    /// sin un timestamp válido.
    std::atomic<int64_t> lastSuccessfulTimestampNs_{0};

    /// Flag para muteo del audio ambiente durante el test acústico de
    /// loopback. Cuando es true, el callback escribe silencio en el output
    /// en lugar de procesar el pipeline DSP. Lo controla `setAmbientMute()`
    /// y lo lee el callback con `load(relaxed)`.
    std::atomic<bool> ambientMuted_{false};

    /// Tester de loopback acústico (Requirement 5.x del spec
    /// monitor-latencia-audio). Se construye en el constructor de
    /// AudioEngine y vive todo el ciclo de vida del motor; los wrappers
    /// públicos `startLoopbackTest`/`getLoopbackTestResult`/`cancelLoopbackTest`
    /// delegan en él. El callback de audio (onBothStreamsReady) lo invoca
    /// vía `loopbackTester_->onAudioCallback(...)` cuando `isActive()` es true.
    std::unique_ptr<latency_monitor::LatencyLoopbackTester> loopbackTester_;
};

#endif // HEARING_AID_AUDIO_ENGINE_H

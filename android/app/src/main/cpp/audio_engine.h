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
#include "smart_scene/scene_analyzer.h"
#include "calibration_spectrum/tone_analyzer.h"
#include "dnn_denoiser/dnn_denoiser.h"
#include "diagnostic_recorder.h"

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

    // ─── Environment Classifier (thread-safe) ───────────────────────────
    void setAutoClassifyEnabled(bool enabled);
    int getCurrentEnvironmentClass() const;

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

    // ─── Spectrum Analyzer forwarding ───────────────────────────────────
    void startSpectrumAnalysis() { pipeline_.getSpectrumAnalyzer().setActive(true); }
    void stopSpectrumAnalysis() { pipeline_.getSpectrumAnalyzer().setActive(false); }
    void startSpectrumRecording() { pipeline_.getSpectrumAnalyzer().startRecording(); }
    int stopSpectrumRecording() { pipeline_.getSpectrumAnalyzer().stopRecording(); return pipeline_.getSpectrumAnalyzer().getRecordedCount(); }
    SpectrumSnapshot getCurrentSpectrum() const { return pipeline_.getSpectrumAnalyzer().getCurrentSnapshot(); }
    const SpectrumSnapshot* getRecordedSnapshots() const { return pipeline_.getSpectrumAnalyzer().getRecordedSnapshots(); }
    int getRecordedSnapshotCount() const { return pipeline_.getSpectrumAnalyzer().getRecordedCount(); }
    int getRecordedDataSize() const { return pipeline_.getSpectrumAnalyzer().getRecordedSize(); }

    // ─── Diagnostic Recording (DSP Verification) ────────────────────────
    /// Inicia grabación de diagnóstico DSP al path indicado.
    /// Captura pre-DSP (canal izq) y post-DSP (canal der) en WAV estéreo.
    /// @param filePath Ruta absoluta para el archivo WAV de salida.
    /// @return true si la grabación inició correctamente.
    bool startDiagnosticRecording(const std::string& filePath);

    /// Detiene la grabación de diagnóstico. Si no se completaron 60s, descarta.
    void stopDiagnosticRecording();

    /// Obtiene el tiempo transcurrido de grabación en milisegundos.
    /// @return ms transcurridos, o -1 si no hay grabación activa.
    int64_t getDiagnosticRecordingProgress() const;

    /// Obtiene el estado actual del grabador de diagnóstico.
    DiagRecorderState getDiagnosticRecordingState() const;

    // ─── Callback de nivel para UI ──────────────────────────────────────
    using LevelCallback = std::function<void(float levelDbSpl)>;
    void setLevelCallback(LevelCallback cb);

    // ─── Device info (for UI display) ───────────────────────────────────
    int32_t getInputDeviceId() const;
    int32_t getOutputDeviceId() const;

    // ─── Oboe FullDuplexStream override ─────────────────────────────────
    oboe::DataCallbackResult onBothStreamsReady(
        const void *inputData,
        int numInputFrames,
        void *outputData,
        int numOutputFrames) override;

    // ─── Oboe Error Callback ────────────────────────────────────────────
    void onErrorAfterClose(oboe::AudioStream *stream,
                           oboe::Result error) override;

private:
    /// Creates and opens input stream (built-in mic).
    oboe::Result openInputStream();

    /// Creates and opens output stream (default device).
    oboe::Result openOutputStream();

    /// Attempts to reopen both streams after error.
    void attemptReconnection();

    // ─── Pipeline DSP ───────────────────────────────────────────────────
    DspPipeline pipeline_;

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

    // ─── Diagnostic Recorder (DSP Verification) ─────────────────────────
    /// Captura simultánea pre/post DSP en WAV estéreo para verificación
    /// de función de transferencia. Ring buffer SPSC + hilo escritor dedicado.
    DiagnosticRecorder diagRecorder_;

    // ─── Configuración ──────────────────────────────────────────────────
    AudioEngineConfig config_;

    // ─── Oboe Streams ───────────────────────────────────────────────────
    std::shared_ptr<oboe::AudioStream> inputStream_;
    std::shared_ptr<oboe::AudioStream> outputStream_;

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
};

#endif // HEARING_AID_AUDIO_ENGINE_H

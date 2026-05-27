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

/// Configuración del motor de audio (updated for Oboe).
struct AudioEngineConfig {
    int sampleRate = 48000;              ///< Hz — native rate (was 44100)
    int bufferSize = 256;                ///< Hint only — Oboe manages actual size
    int channels = 1;                    ///< Mono
    float mpoThresholdDbSpl = 100.0f;   ///< Threshold del MPO en dB SPL
    float splOffset = 120.0f;            ///< Offset dBFS → dB SPL
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
    void stop();

    /// @return true si ambos streams están activos.
    bool isRunning() const;

    // ─── Actualizaciones de parámetros DSP (thread-safe, lock-free) ─────
    void setEqGains(const float gains[12]);
    void setVolume(float volumeDb);
    void setWdrcParams(const WdrcParams& params);
    void setNrLevel(int level);
    void setSplOffset(float offset);
    float getLastInputLevel() const;

    // ─── Callback de nivel para UI ──────────────────────────────────────
    using LevelCallback = std::function<void(float levelDbSpl)>;
    void setLevelCallback(LevelCallback cb);

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

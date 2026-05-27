/// @file audio_engine.h
/// @brief Motor de audio de baja latencia usando OpenSL ES.
///
/// Envuelve AudioRecord (entrada) y AudioTrack (salida) vía OpenSL ES
/// para captura y reproducción de audio en tiempo real.
///
/// Configuración: 16 kHz, mono, PCM16, buffer de 64 muestras (4 ms).
/// Usa SL_ANDROID_RECORDING_PRESET_VOICE_COMMUNICATION para baja latencia.
///
/// El hilo de audio ejecuta un bucle: leer → procesar → escribir.
/// Buffer underruns se manejan con log + continuar (sin crash).

#ifndef HEARING_AID_AUDIO_ENGINE_H
#define HEARING_AID_AUDIO_ENGINE_H

#include <atomic>
#include <thread>
#include <functional>
#include <cstdint>

#include <SLES/OpenSLES.h>
#include <SLES/OpenSLES_Android.h>

#include "dsp_pipeline.h"

/// Configuración del motor de audio.
struct AudioEngineConfig {
    int sampleRate = 44100;       ///< Hz — frecuencia de muestreo
    int bufferSize = 256;         ///< Muestras por bloque (~5.8 ms @ 44100 Hz)
    int channels = 1;             ///< Mono
    int bitsPerSample = 16;       ///< PCM16
    float mpoThresholdDbSpl = 100.0f;  ///< Threshold del MPO en dB SPL
    float splOffset = 120.0f;     ///< Offset dBFS → dB SPL
};

/// Motor de audio de baja latencia con procesamiento DSP integrado.
///
/// Uso típico:
/// @code
///   AudioEngine engine;
///   AudioEngineConfig config;
///   engine.setLevelCallback([](float level) { /* update UI */ });
///   engine.start(config);
///   // ... audio procesándose en tiempo real ...
///   engine.setEqGains(gains);
///   engine.setVolume(-5.0f);
///   // ...
///   engine.stop();
/// @endcode
class AudioEngine {
public:
    AudioEngine();
    ~AudioEngine();

    // No copiable ni movible (posee recursos de sistema)
    AudioEngine(const AudioEngine&) = delete;
    AudioEngine& operator=(const AudioEngine&) = delete;

    /// Inicia captura y reproducción de audio con la configuración dada.
    /// Crea los objetos OpenSL ES y lanza el hilo de procesamiento.
    /// @param config Configuración de audio (sample rate, buffer size, etc.)
    /// @return true si se inició correctamente, false si hubo error
    bool start(const AudioEngineConfig& config);

    /// Detiene el procesamiento de audio y libera recursos OpenSL ES.
    /// Bloquea hasta que el hilo de audio termina.
    void stop();

    /// @return true si el motor está activo y procesando audio.
    bool isRunning() const;

    // ─── Actualizaciones de parámetros DSP (thread-safe, lock-free) ─────

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

    /// Actualiza offset de calibración SPL.
    /// @param offset Offset en dB (120 para mic real, 76 para WAV)
    void setSplOffset(float offset);

    /// Obtiene el último nivel de entrada medido PRE-EQ (dB SPL).
    /// Thread-safe: lee un std::atomic<float> del pipeline interno.
    /// @return Nivel de entrada en dB SPL
    float getLastInputLevel() const;

    // ─── Callback de nivel para UI ──────────────────────────────────────

    /// Tipo de callback para reportar nivel de entrada (dB SPL).
    /// Se invoca ~10 Hz (cada 10 bloques de 4 ms = cada 100 ms).
    using LevelCallback = std::function<void(float levelDbSpl)>;

    /// Registra callback de nivel. Puede llamarse antes o después de start().
    /// @param cb Función callback (se invoca desde el hilo de audio)
    void setLevelCallback(LevelCallback cb);

private:
    /// Hilo de procesamiento de audio (bucle read → process → write).
    void audioThreadFunc();

    /// Inicializa el engine OpenSL ES y crea los objetos de audio.
    /// @return true si la inicialización fue exitosa
    bool initOpenSLES();

    /// Libera todos los recursos OpenSL ES.
    void destroyOpenSLES();

    // ─── Pipeline DSP ───────────────────────────────────────────────────
    DspPipeline pipeline_;

    // ─── Configuración ──────────────────────────────────────────────────
    AudioEngineConfig config_;

    // ─── Control del hilo de audio ──────────────────────────────────────
    std::thread audioThread_;
    std::atomic<bool> running_{false};

    // ─── Callback de nivel ──────────────────────────────────────────────
    LevelCallback levelCallback_;
    int blockCounter_ = 0;  ///< Contador para emitir nivel cada ~10 bloques

    // ─── OpenSL ES: Engine ──────────────────────────────────────────────
    SLObjectItf engineObject_ = nullptr;
    SLEngineItf engineInterface_ = nullptr;

    // ─── OpenSL ES: Recorder (entrada de micrófono) ─────────────────────
    SLObjectItf recorderObject_ = nullptr;
    SLRecordItf recorderInterface_ = nullptr;
    SLAndroidSimpleBufferQueueItf recorderBufferQueue_ = nullptr;

    // ─── OpenSL ES: Player (salida a auriculares) ───────────────────────
    SLObjectItf outputMixObject_ = nullptr;
    SLObjectItf playerObject_ = nullptr;
    SLPlayItf playerInterface_ = nullptr;
    SLAndroidSimpleBufferQueueItf playerBufferQueue_ = nullptr;

    // ─── Buffers de audio ───────────────────────────────────────────────
    /// Buffers dobles para recorder (ping-pong)
    int16_t* recBuffers_[2] = {nullptr, nullptr};
    /// Buffers dobles para player (ping-pong)
    int16_t* playBuffers_[2] = {nullptr, nullptr};
    /// Índice del buffer activo del recorder
    std::atomic<int> recBufIndex_{0};
    /// Índice del buffer activo del player
    std::atomic<int> playBufIndex_{0};
    /// Flag: nuevo buffer de recorder disponible
    std::atomic<bool> recBufferReady_{false};
    /// Flag: buffer de player fue consumido
    std::atomic<bool> playBufferConsumed_{true};

    // ─── Callbacks estáticos de OpenSL ES ───────────────────────────────
    static void recorderCallback(SLAndroidSimpleBufferQueueItf bq, void* context);
    static void playerCallback(SLAndroidSimpleBufferQueueItf bq, void* context);
};

#endif // HEARING_AID_AUDIO_ENGINE_H

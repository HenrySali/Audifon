/// @file audio_engine.cpp
/// @brief Implementación del motor de audio de baja latencia usando OpenSL ES.
///
/// Captura audio del micrófono a 16 kHz/PCM16 mono con buffer de 64 muestras
/// (4 ms de latencia por buffer), procesa a través del pipeline DSP, y reproduce
/// en auriculares vía OpenSL ES.
///
/// Arquitectura:
/// - OpenSL ES con buffer queue callbacks para I/O asíncrono
/// - Hilo de audio dedicado que ejecuta el bucle: leer → procesar → escribir
/// - Conversión PCM16 ↔ float32 en cada ciclo
/// - Buffer underruns se manejan con log + continuar (sin crash)
///
/// Usa SL_ANDROID_RECORDING_PRESET_VOICE_COMMUNICATION para ruta de baja latencia.

#include "audio_engine.h"

#include <android/log.h>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <chrono>

// ─────────────────────────────────────────────────────────────────────────────
// Logging
// ─────────────────────────────────────────────────────────────────────────────

#define LOG_TAG "AudioEngine"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ─────────────────────────────────────────────────────────────────────────────
// Constantes
// ─────────────────────────────────────────────────────────────────────────────

/// Número de buffers en el esquema ping-pong (doble buffer).
static constexpr int kNumBuffers = 2;

/// Cada cuántos bloques se emite el nivel de entrada (~10 Hz a 4 ms/bloque).
/// 10 bloques × 4 ms = 40 ms → ~25 Hz (más que suficiente para UI a 10 Hz).
/// Usamos 25 para ~100 ms entre emisiones = 10 Hz.
static constexpr int kLevelReportInterval = 25;

/// Factor de conversión PCM16 → float32.
static constexpr float kPcm16ToFloat = 1.0f / 32768.0f;

/// Factor de conversión float32 → PCM16.
static constexpr float kFloatToPcm16 = 32767.0f;

// ─────────────────────────────────────────────────────────────────────────────
// Constructor / Destructor
// ─────────────────────────────────────────────────────────────────────────────

AudioEngine::AudioEngine() = default;

AudioEngine::~AudioEngine() {
    stop();
}

// ─────────────────────────────────────────────────────────────────────────────
// Control de inicio/parada
// ─────────────────────────────────────────────────────────────────────────────

bool AudioEngine::start(const AudioEngineConfig& config) {
    if (running_.load(std::memory_order_acquire)) {
        LOGW("AudioEngine already running, ignoring start()");
        return true;
    }

    config_ = config;
    blockCounter_ = 0;

    // Inicializar pipeline DSP
    AudioConfig dspConfig;
    dspConfig.sampleRate = config.sampleRate;
    dspConfig.bufferSize = config.bufferSize;
    dspConfig.channels = config.channels;
    dspConfig.bitsPerSample = config.bitsPerSample;
    dspConfig.mpoThresholdDbSpl = config.mpoThresholdDbSpl;
    dspConfig.splOffset = config.splOffset;
    pipeline_.init(dspConfig);

    // Asignar buffers de audio
    const int bufferBytes = config.bufferSize * sizeof(int16_t);
    for (int i = 0; i < kNumBuffers; ++i) {
        recBuffers_[i] = new int16_t[config.bufferSize];
        playBuffers_[i] = new int16_t[config.bufferSize];
        std::memset(recBuffers_[i], 0, bufferBytes);
        std::memset(playBuffers_[i], 0, bufferBytes);
    }
    recBufIndex_.store(0, std::memory_order_relaxed);
    playBufIndex_.store(0, std::memory_order_relaxed);
    recBufferReady_.store(false, std::memory_order_relaxed);
    playBufferConsumed_.store(true, std::memory_order_relaxed);

    // Inicializar OpenSL ES
    if (!initOpenSLES()) {
        LOGE("Failed to initialize OpenSL ES");
        // Limpiar buffers
        for (int i = 0; i < kNumBuffers; ++i) {
            delete[] recBuffers_[i];
            recBuffers_[i] = nullptr;
            delete[] playBuffers_[i];
            playBuffers_[i] = nullptr;
        }
        return false;
    }

    // Lanzar hilo de procesamiento de audio
    running_.store(true, std::memory_order_release);
    audioThread_ = std::thread(&AudioEngine::audioThreadFunc, this);

    LOGI("AudioEngine started: %d Hz, %d samples/block, %d ch",
         config.sampleRate, config.bufferSize, config.channels);
    return true;
}

void AudioEngine::stop() {
    if (!running_.load(std::memory_order_acquire)) {
        return;
    }

    // Señalar al hilo que debe terminar
    running_.store(false, std::memory_order_release);

    // Esperar a que el hilo termine
    if (audioThread_.joinable()) {
        audioThread_.join();
    }

    // Liberar recursos OpenSL ES
    destroyOpenSLES();

    // Liberar buffers
    for (int i = 0; i < kNumBuffers; ++i) {
        delete[] recBuffers_[i];
        recBuffers_[i] = nullptr;
        delete[] playBuffers_[i];
        playBuffers_[i] = nullptr;
    }

    LOGI("AudioEngine stopped");
}

bool AudioEngine::isRunning() const {
    return running_.load(std::memory_order_acquire);
}

// ─────────────────────────────────────────────────────────────────────────────
// Actualizaciones de parámetros DSP (delegadas al pipeline)
// ─────────────────────────────────────────────────────────────────────────────

void AudioEngine::setEqGains(const float gains[12]) {
    pipeline_.setEqGains(gains);
}

void AudioEngine::setVolume(float volumeDb) {
    pipeline_.setVolume(volumeDb);
}

void AudioEngine::setWdrcParams(const WdrcParams& params) {
    pipeline_.setWdrcParams(params);
}

void AudioEngine::setNrLevel(int level) {
    pipeline_.setNrLevel(level);
}

void AudioEngine::setSplOffset(float offset) {
    pipeline_.setSplOffset(offset);
}

float AudioEngine::getLastInputLevel() const {
    return pipeline_.getLastInputLevelDb();
}

void AudioEngine::setLevelCallback(LevelCallback cb) {
    levelCallback_ = std::move(cb);
}

// ─────────────────────────────────────────────────────────────────────────────
// Hilo de procesamiento de audio
// ─────────────────────────────────────────────────────────────────────────────

void AudioEngine::audioThreadFunc() {
    LOGI("Audio thread started");

    // Buffer temporal float32 para procesamiento DSP
    const int blockSize = config_.bufferSize;
    float* floatBuffer = new float[blockSize];

    while (running_.load(std::memory_order_acquire)) {
        // ─── 1. Esperar buffer del recorder ─────────────────────────────
        // Polling con yield corto. En producción real se usaría un
        // semáforo o condvar, pero para 4 ms de latencia el spin es
        // aceptable y evita overhead de sincronización.
        int spinCount = 0;
        while (!recBufferReady_.load(std::memory_order_acquire)) {
            if (!running_.load(std::memory_order_relaxed)) {
                goto exit_thread;
            }
            // Yield breve para no quemar CPU innecesariamente
            if (++spinCount > 1000) {
                std::this_thread::sleep_for(std::chrono::microseconds(100));
                spinCount = 0;
            }
        }
        recBufferReady_.store(false, std::memory_order_release);

        {
            // ─── 2. Leer PCM16 del buffer del recorder ──────────────────
            int recIdx = recBufIndex_.load(std::memory_order_acquire);
            // Usar el buffer que NO está siendo llenado actualmente
            int readIdx = (recIdx + 1) % kNumBuffers;
            const int16_t* inputPcm = recBuffers_[readIdx];

            // ─── 3. Convertir PCM16 → float32 ──────────────────────────
            for (int i = 0; i < blockSize; ++i) {
                floatBuffer[i] = static_cast<float>(inputPcm[i]) * kPcm16ToFloat;
            }

            // ─── 4. Procesar a través del pipeline DSP con control de tiempo ─
            // Tiempo disponible por bloque = bufferSize / sampleRate.
            // Para 64 muestras @ 16 kHz = 4 ms. Usamos 3.5 ms como umbral
            // para dejar margen al enqueue y escritura de salida.
            auto processStart = std::chrono::high_resolution_clock::now();

            pipeline_.processBlock(floatBuffer, blockSize);

            auto processEnd = std::chrono::high_resolution_clock::now();
            auto elapsedUs = std::chrono::duration_cast<std::chrono::microseconds>(
                processEnd - processStart).count();

            // Umbral de descarte: 3500 µs (3.5 ms) — deja 0.5 ms para I/O
            static constexpr long kMaxProcessingTimeUs = 3500;

            if (elapsedUs > kMaxProcessingTimeUs) {
                // Bloque excedió tiempo disponible: descartar salida y continuar
                LOGW("Block processing overrun: %ld µs (limit %ld µs), discarding block",
                     elapsedUs, kMaxProcessingTimeUs);
                // No escribir salida — continuar con el siguiente bloque
                // Aún emitimos nivel para mantener UI actualizada
                blockCounter_++;
                if (blockCounter_ >= kLevelReportInterval) {
                    blockCounter_ = 0;
                    if (levelCallback_) {
                        float level = pipeline_.getLastInputLevelDb();
                        levelCallback_(level);
                    }
                }
                continue;
            }

            // ─── 5. Convertir float32 → PCM16 con clamping ─────────────
            int playIdx = playBufIndex_.load(std::memory_order_acquire);
            int16_t* outputPcm = playBuffers_[playIdx];
            for (int i = 0; i < blockSize; ++i) {
                // Clamp a [-1.0, +1.0] antes de convertir
                float sample = floatBuffer[i];
                sample = std::max(-1.0f, std::min(1.0f, sample));
                // Convertir a PCM16
                outputPcm[i] = static_cast<int16_t>(sample * kFloatToPcm16);
            }

            // ─── 6. Encolar buffer de salida al player ──────────────────
            if (playerBufferQueue_ != nullptr) {
                SLresult result = (*playerBufferQueue_)->Enqueue(
                    playerBufferQueue_,
                    outputPcm,
                    blockSize * sizeof(int16_t)
                );
                if (result != SL_RESULT_SUCCESS) {
                    LOGW("Player enqueue failed (underrun?), continuing...");
                }
            }

            // Alternar buffer de player para el próximo ciclo
            playBufIndex_.store((playIdx + 1) % kNumBuffers, std::memory_order_release);

            // ─── 7. Emitir nivel de entrada cada ~100 ms ────────────────
            blockCounter_++;
            if (blockCounter_ >= kLevelReportInterval) {
                blockCounter_ = 0;
                if (levelCallback_) {
                    float level = pipeline_.getLastInputLevelDb();
                    levelCallback_(level);
                }
            }
        }
    }

exit_thread:
    delete[] floatBuffer;
    LOGI("Audio thread exiting");
}

// ─────────────────────────────────────────────────────────────────────────────
// Callbacks estáticos de OpenSL ES
// ─────────────────────────────────────────────────────────────────────────────

void AudioEngine::recorderCallback(SLAndroidSimpleBufferQueueItf bq, void* context) {
    auto* engine = static_cast<AudioEngine*>(context);
    if (!engine || !engine->running_.load(std::memory_order_relaxed)) {
        return;
    }

    // Alternar al siguiente buffer para la próxima captura
    int currentIdx = engine->recBufIndex_.load(std::memory_order_relaxed);
    int nextIdx = (currentIdx + 1) % kNumBuffers;
    engine->recBufIndex_.store(nextIdx, std::memory_order_release);

    // Señalar que hay un buffer listo para procesar
    engine->recBufferReady_.store(true, std::memory_order_release);

    // Encolar el siguiente buffer para captura continua
    SLresult result = (*bq)->Enqueue(
        bq,
        engine->recBuffers_[nextIdx],
        engine->config_.bufferSize * sizeof(int16_t)
    );
    if (result != SL_RESULT_SUCCESS) {
        __android_log_print(ANDROID_LOG_WARN, LOG_TAG,
                            "Recorder re-enqueue failed, may lose audio");
    }
}

void AudioEngine::playerCallback(SLAndroidSimpleBufferQueueItf bq, void* context) {
    // El player callback se invoca cuando un buffer fue consumido.
    // En nuestra arquitectura, el hilo de audio encola proactivamente,
    // así que este callback solo sirve como señal de que el player
    // está listo para más datos (no se usa activamente).
    (void)bq;
    (void)context;
}

// ─────────────────────────────────────────────────────────────────────────────
// Inicialización de OpenSL ES
// ─────────────────────────────────────────────────────────────────────────────

bool AudioEngine::initOpenSLES() {
    SLresult result;

    // ─── Crear engine OpenSL ES ─────────────────────────────────────────
    result = slCreateEngine(&engineObject_, 0, nullptr, 0, nullptr, nullptr);
    if (result != SL_RESULT_SUCCESS) {
        LOGE("slCreateEngine failed: %d", (int)result);
        return false;
    }

    result = (*engineObject_)->Realize(engineObject_, SL_BOOLEAN_FALSE);
    if (result != SL_RESULT_SUCCESS) {
        LOGE("Engine Realize failed: %d", (int)result);
        return false;
    }

    result = (*engineObject_)->GetInterface(engineObject_, SL_IID_ENGINE, &engineInterface_);
    if (result != SL_RESULT_SUCCESS) {
        LOGE("GetInterface ENGINE failed: %d", (int)result);
        return false;
    }

    // ─── Crear Output Mix ───────────────────────────────────────────────
    result = (*engineInterface_)->CreateOutputMix(
        engineInterface_, &outputMixObject_, 0, nullptr, nullptr);
    if (result != SL_RESULT_SUCCESS) {
        LOGE("CreateOutputMix failed: %d", (int)result);
        return false;
    }

    result = (*outputMixObject_)->Realize(outputMixObject_, SL_BOOLEAN_FALSE);
    if (result != SL_RESULT_SUCCESS) {
        LOGE("OutputMix Realize failed: %d", (int)result);
        return false;
    }

    // ─── Configurar formato de audio ────────────────────────────────────
    SLDataFormat_PCM formatPcm;
    formatPcm.formatType = SL_DATAFORMAT_PCM;
    formatPcm.numChannels = static_cast<SLuint32>(config_.channels);
    // OpenSL ES usa milliHz para sample rate
    formatPcm.samplesPerSec = static_cast<SLuint32>(config_.sampleRate) * 1000u;
    formatPcm.bitsPerSample = SL_PCMSAMPLEFORMAT_FIXED_16;
    formatPcm.containerSize = SL_PCMSAMPLEFORMAT_FIXED_16;
    formatPcm.channelMask = SL_SPEAKER_FRONT_CENTER;
    formatPcm.endianness = SL_BYTEORDER_LITTLEENDIAN;

    // ─── Crear Recorder (entrada de micrófono) ──────────────────────────
    {
        // Fuente: micrófono del dispositivo
        SLDataLocator_IODevice locDevice;
        locDevice.locatorType = SL_DATALOCATOR_IODEVICE;
        locDevice.deviceType = SL_IODEVICE_AUDIOINPUT;
        locDevice.deviceID = SL_DEFAULTDEVICEID_AUDIOINPUT;
        locDevice.device = nullptr;

        SLDataSource audioSrc;
        audioSrc.pLocator = &locDevice;
        audioSrc.pFormat = nullptr;

        // Destino: buffer queue
        SLDataLocator_AndroidSimpleBufferQueue locBufQueue;
        locBufQueue.locatorType = SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE;
        locBufQueue.numBuffers = kNumBuffers;

        SLDataSink audioSnk;
        audioSnk.pLocator = &locBufQueue;
        audioSnk.pFormat = &formatPcm;

        // Interfaces requeridas: buffer queue + configuración Android
        const SLInterfaceID ids[] = {
            SL_IID_ANDROIDSIMPLEBUFFERQUEUE,
            SL_IID_ANDROIDCONFIGURATION
        };
        const SLboolean req[] = {SL_BOOLEAN_TRUE, SL_BOOLEAN_TRUE};

        result = (*engineInterface_)->CreateAudioRecorder(
            engineInterface_, &recorderObject_,
            &audioSrc, &audioSnk,
            2, ids, req
        );
        if (result != SL_RESULT_SUCCESS) {
            LOGE("CreateAudioRecorder failed: %d", (int)result);
            return false;
        }

        // Configurar preset de grabación para baja latencia
        SLAndroidConfigurationItf recConfig;
        result = (*recorderObject_)->GetInterface(
            recorderObject_, SL_IID_ANDROIDCONFIGURATION, &recConfig);
        if (result == SL_RESULT_SUCCESS) {
            // VOICE_COMMUNICATION activa la ruta de baja latencia del HAL
            SLint32 streamType = SL_ANDROID_RECORDING_PRESET_VOICE_COMMUNICATION;
            (*recConfig)->SetConfiguration(
                recConfig,
                SL_ANDROID_KEY_RECORDING_PRESET,
                &streamType,
                sizeof(SLint32)
            );
        }

        result = (*recorderObject_)->Realize(recorderObject_, SL_BOOLEAN_FALSE);
        if (result != SL_RESULT_SUCCESS) {
            LOGE("Recorder Realize failed: %d", (int)result);
            return false;
        }

        // Obtener interfaz de grabación
        result = (*recorderObject_)->GetInterface(
            recorderObject_, SL_IID_RECORD, &recorderInterface_);
        if (result != SL_RESULT_SUCCESS) {
            LOGE("GetInterface RECORD failed: %d", (int)result);
            return false;
        }

        // Obtener buffer queue del recorder
        result = (*recorderObject_)->GetInterface(
            recorderObject_, SL_IID_ANDROIDSIMPLEBUFFERQUEUE, &recorderBufferQueue_);
        if (result != SL_RESULT_SUCCESS) {
            LOGE("GetInterface BUFFERQUEUE (recorder) failed: %d", (int)result);
            return false;
        }

        // Registrar callback del recorder
        result = (*recorderBufferQueue_)->RegisterCallback(
            recorderBufferQueue_, recorderCallback, this);
        if (result != SL_RESULT_SUCCESS) {
            LOGE("RegisterCallback (recorder) failed: %d", (int)result);
            return false;
        }

        // Encolar buffers iniciales para captura
        for (int i = 0; i < kNumBuffers; ++i) {
            result = (*recorderBufferQueue_)->Enqueue(
                recorderBufferQueue_,
                recBuffers_[i],
                config_.bufferSize * sizeof(int16_t)
            );
            if (result != SL_RESULT_SUCCESS) {
                LOGE("Initial recorder enqueue failed: %d", (int)result);
                return false;
            }
        }

        // Iniciar grabación
        result = (*recorderInterface_)->SetRecordState(
            recorderInterface_, SL_RECORDSTATE_RECORDING);
        if (result != SL_RESULT_SUCCESS) {
            LOGE("SetRecordState RECORDING failed: %d", (int)result);
            return false;
        }
    }

    // ─── Crear Player (salida a auriculares) ────────────────────────────
    {
        // Fuente: buffer queue
        SLDataLocator_AndroidSimpleBufferQueue locBufQueue;
        locBufQueue.locatorType = SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE;
        locBufQueue.numBuffers = kNumBuffers;

        SLDataSource audioSrc;
        audioSrc.pLocator = &locBufQueue;
        audioSrc.pFormat = &formatPcm;

        // Destino: output mix
        SLDataLocator_OutputMix locOutMix;
        locOutMix.locatorType = SL_DATALOCATOR_OUTPUTMIX;
        locOutMix.outputMix = outputMixObject_;

        SLDataSink audioSnk;
        audioSnk.pLocator = &locOutMix;
        audioSnk.pFormat = nullptr;

        // Interfaces requeridas: buffer queue + configuración Android
        const SLInterfaceID ids[] = {
            SL_IID_ANDROIDSIMPLEBUFFERQUEUE,
            SL_IID_ANDROIDCONFIGURATION
        };
        const SLboolean req[] = {SL_BOOLEAN_TRUE, SL_BOOLEAN_TRUE};

        result = (*engineInterface_)->CreateAudioPlayer(
            engineInterface_, &playerObject_,
            &audioSrc, &audioSnk,
            2, ids, req
        );
        if (result != SL_RESULT_SUCCESS) {
            LOGE("CreateAudioPlayer failed: %d", (int)result);
            return false;
        }

        // Configurar stream type para comunicación (baja latencia)
        SLAndroidConfigurationItf playerConfig;
        result = (*playerObject_)->GetInterface(
            playerObject_, SL_IID_ANDROIDCONFIGURATION, &playerConfig);
        if (result == SL_RESULT_SUCCESS) {
            SLint32 streamType = SL_ANDROID_STREAM_VOICE;
            (*playerConfig)->SetConfiguration(
                playerConfig,
                SL_ANDROID_KEY_STREAM_TYPE,
                &streamType,
                sizeof(SLint32)
            );
        }

        result = (*playerObject_)->Realize(playerObject_, SL_BOOLEAN_FALSE);
        if (result != SL_RESULT_SUCCESS) {
            LOGE("Player Realize failed: %d", (int)result);
            return false;
        }

        // Obtener interfaz de reproducción
        result = (*playerObject_)->GetInterface(
            playerObject_, SL_IID_PLAY, &playerInterface_);
        if (result != SL_RESULT_SUCCESS) {
            LOGE("GetInterface PLAY failed: %d", (int)result);
            return false;
        }

        // Obtener buffer queue del player
        result = (*playerObject_)->GetInterface(
            playerObject_, SL_IID_ANDROIDSIMPLEBUFFERQUEUE, &playerBufferQueue_);
        if (result != SL_RESULT_SUCCESS) {
            LOGE("GetInterface BUFFERQUEUE (player) failed: %d", (int)result);
            return false;
        }

        // Registrar callback del player
        result = (*playerBufferQueue_)->RegisterCallback(
            playerBufferQueue_, playerCallback, this);
        if (result != SL_RESULT_SUCCESS) {
            LOGE("RegisterCallback (player) failed: %d", (int)result);
            return false;
        }

        // Encolar buffer de silencio inicial para que el player arranque
        result = (*playerBufferQueue_)->Enqueue(
            playerBufferQueue_,
            playBuffers_[0],
            config_.bufferSize * sizeof(int16_t)
        );
        if (result != SL_RESULT_SUCCESS) {
            LOGE("Initial player enqueue failed: %d", (int)result);
            return false;
        }

        // Iniciar reproducción
        result = (*playerInterface_)->SetPlayState(
            playerInterface_, SL_PLAYSTATE_PLAYING);
        if (result != SL_RESULT_SUCCESS) {
            LOGE("SetPlayState PLAYING failed: %d", (int)result);
            return false;
        }
    }

    LOGI("OpenSL ES initialized successfully");
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Liberación de recursos OpenSL ES
// ─────────────────────────────────────────────────────────────────────────────

void AudioEngine::destroyOpenSLES() {
    // Detener grabación
    if (recorderInterface_ != nullptr) {
        (*recorderInterface_)->SetRecordState(
            recorderInterface_, SL_RECORDSTATE_STOPPED);
    }

    // Detener reproducción
    if (playerInterface_ != nullptr) {
        (*playerInterface_)->SetPlayState(
            playerInterface_, SL_PLAYSTATE_STOPPED);
    }

    // Destruir objetos en orden inverso a la creación
    if (playerObject_ != nullptr) {
        (*playerObject_)->Destroy(playerObject_);
        playerObject_ = nullptr;
        playerInterface_ = nullptr;
        playerBufferQueue_ = nullptr;
    }

    if (recorderObject_ != nullptr) {
        (*recorderObject_)->Destroy(recorderObject_);
        recorderObject_ = nullptr;
        recorderInterface_ = nullptr;
        recorderBufferQueue_ = nullptr;
    }

    if (outputMixObject_ != nullptr) {
        (*outputMixObject_)->Destroy(outputMixObject_);
        outputMixObject_ = nullptr;
    }

    if (engineObject_ != nullptr) {
        (*engineObject_)->Destroy(engineObject_);
        engineObject_ = nullptr;
        engineInterface_ = nullptr;
    }

    LOGI("OpenSL ES resources released");
}

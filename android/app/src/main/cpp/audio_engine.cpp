/// @file audio_engine.cpp
/// @brief Implementación del motor de audio de baja latencia usando Google Oboe.
///
/// Usa Oboe FullDuplexStream para I/O sincronizado en un único callback
/// onBothStreamsReady. Captura del micrófono integrado (setDeviceId) y
/// reproduce al dispositivo por defecto (A2DP cuando BT conectado).
///
/// Arquitectura:
/// - Oboe FullDuplexStream con callback onBothStreamsReady
/// - Procesamiento DSP float32 directo en el callback (sin conversión PCM16)
/// - Sin hilo de audio dedicado ni buffers ping-pong
/// - Reconexión automática con 3 reintentos y 500ms entre intentos

#include "audio_engine.h"

#include <android/log.h>
#include <android/api-level.h>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <chrono>
#include <thread>

// ─────────────────────────────────────────────────────────────────────────────
// Logging
// ─────────────────────────────────────────────────────────────────────────────

#define LOG_TAG "OboeEngine"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ─────────────────────────────────────────────────────────────────────────────
// Constructor / Destructor
// ─────────────────────────────────────────────────────────────────────────────

AudioEngine::AudioEngine() = default;

AudioEngine::~AudioEngine() {
    (void)stop();
}

// ─────────────────────────────────────────────────────────────────────────────
// Stream Creation — Input (Built-in Mic)
// ─────────────────────────────────────────────────────────────────────────────

oboe::Result AudioEngine::openInputStream() {
    oboe::AudioStreamBuilder builder;

    builder.setDirection(oboe::Direction::Input);
    // Only set deviceId if explicitly provided (non-zero)
    // When 0, let Oboe use the system default input device (built-in mic)
    if (config_.builtInMicDeviceId != 0) {
        builder.setDeviceId(config_.builtInMicDeviceId);
    }
    builder.setSampleRate(config_.sampleRate);
    builder.setChannelCount(1);
    builder.setFormat(oboe::AudioFormat::Float);
    builder.setPerformanceMode(oboe::PerformanceMode::LowLatency);
    builder.setSharingMode(oboe::SharingMode::Exclusive);
    builder.setAudioApi(oboe::AudioApi::Unspecified);
    builder.setErrorCallback(this);

    // Use VoicePerformance on API 29+, fallback to Generic on older devices
    if (android_get_device_api_level() >= 29) {
        builder.setInputPreset(oboe::InputPreset::VoicePerformance);
    } else {
        builder.setInputPreset(oboe::InputPreset::Generic);
        LOGW("API < 29: using InputPreset::Generic (VoicePerformance unavailable)");
    }

    oboe::Result result = builder.openStream(inputStream_);

    if (result == oboe::Result::OK) {
        LOGI("Input stream opened — API: %s, sampleRate: %d, sharingMode: %s, deviceId: %d",
             oboe::convertToText(inputStream_->getAudioApi()),
             inputStream_->getSampleRate(),
             oboe::convertToText(inputStream_->getSharingMode()),
             inputStream_->getDeviceId());
    } else {
        LOGE("Failed to open input stream: %s", oboe::convertToText(result));
    }

    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// Stream Creation — Output (Default Device / A2DP)
// ─────────────────────────────────────────────────────────────────────────────

oboe::Result AudioEngine::openOutputStream() {
    oboe::AudioStreamBuilder builder;

    // Configure output stream — NO setDeviceId() so system routes to default
    // (A2DP when Bluetooth headphones are connected)
    builder.setDirection(oboe::Direction::Output);
    builder.setSampleRate(config_.sampleRate);
    builder.setChannelCount(1);
    builder.setFormat(oboe::AudioFormat::Float);
    builder.setPerformanceMode(oboe::PerformanceMode::LowLatency);
    builder.setSharingMode(oboe::SharingMode::Exclusive);
    builder.setUsage(oboe::Usage::Media);
    builder.setAudioApi(oboe::AudioApi::Unspecified);
    builder.setErrorCallback(this);

    // CRITICAL: Do NOT call setDataCallback(this) here!
    // FullDuplexStream::start() sets itself as the data callback on the output
    // stream. If we set it here, the output stream's onAudioReady fires directly
    // without going through FullDuplexStream's internal logic that reads from
    // the input stream and then calls onBothStreamsReady(). This was the root
    // cause of the microphone not delivering data to the callback.

    oboe::Result result = builder.openStream(outputStream_);

    if (result == oboe::Result::OK) {
        LOGI("Output stream opened — API: %s, sampleRate: %d, sharingMode: %s, deviceId: %d",
             oboe::convertToText(outputStream_->getAudioApi()),
             outputStream_->getSampleRate(),
             oboe::convertToText(outputStream_->getSharingMode()),
             outputStream_->getDeviceId());
    } else {
        LOGE("Failed to open output stream: %s", oboe::convertToText(result));
    }

    return result;
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

    // ─── Step 1: Open input stream (built-in mic) ────────────────────────
    oboe::Result inputResult = openInputStream();
    if (inputResult != oboe::Result::OK) {
        LOGE("start() failed: cannot open input stream (%s)",
             oboe::convertToText(inputResult));
        return false;
    }

    // ─── Step 2: Open output stream (default device / A2DP) ─────────────
    oboe::Result outputResult = openOutputStream();
    if (outputResult != oboe::Result::OK) {
        LOGE("start() failed: cannot open output stream (%s)",
             oboe::convertToText(outputResult));
        inputStream_->close();
        inputStream_.reset();
        return false;
    }

    // ─── Step 3: Check negotiated parameters ─────────────────────────────
    int32_t effectiveSampleRate = inputStream_->getSampleRate();
    int32_t outputSampleRate = outputStream_->getSampleRate();

    if (effectiveSampleRate != config_.sampleRate) {
        LOGW("Input stream negotiated sample rate %d Hz (requested %d Hz)",
             effectiveSampleRate, config_.sampleRate);
    }
    if (outputSampleRate != config_.sampleRate) {
        LOGW("Output stream negotiated sample rate %d Hz (requested %d Hz)",
             outputSampleRate, config_.sampleRate);
    }
    if (effectiveSampleRate != outputSampleRate) {
        LOGW("Sample rate mismatch: input=%d, output=%d — using input rate for DSP",
             effectiveSampleRate, outputSampleRate);
    }

    // Handle Exclusive→Shared fallback gracefully
    if (inputStream_->getSharingMode() != oboe::SharingMode::Exclusive) {
        LOGW("Input stream opened in Shared mode (Exclusive denied)");
    }
    if (outputStream_->getSharingMode() != oboe::SharingMode::Exclusive) {
        LOGW("Output stream opened in Shared mode (Exclusive denied)");
    }

    // ─── Step 4: Calculate callbacksPerLevelReport_ ──────────────────────
    int32_t framesPerBuffer = outputStream_->getFramesPerBurst();
    if (framesPerBuffer <= 0) {
        framesPerBuffer = config_.bufferSize;  // fallback to config hint
    }
    float blockTimeMs = (float)framesPerBuffer / (float)effectiveSampleRate * 1000.0f;
    callbacksPerLevelReport_ = (int)std::ceil(kLevelReportIntervalMs / blockTimeMs);
    if (callbacksPerLevelReport_ < 1) {
        callbacksPerLevelReport_ = 1;
    }
    LOGI("Level report every %d callbacks (blockTime=%.2fms, framesPerBurst=%d)",
         callbacksPerLevelReport_, blockTimeMs, framesPerBuffer);

    // ─── Step 5: Initialize DSP pipeline with effective sample rate ──────
    AudioConfig dspConfig;
    dspConfig.sampleRate = effectiveSampleRate;
    dspConfig.bufferSize = framesPerBuffer;
    dspConfig.channels = config_.channels;
    dspConfig.mpoThresholdDbSpl = config_.mpoThresholdDbSpl;
    dspConfig.splOffset = config_.splOffset;
    pipeline_.init(dspConfig);

    // ─── Step 6: Configure FullDuplexStream ──────────────────────────────
    setInputStream(inputStream_.get());
    setOutputStream(outputStream_.get());

    // ─── Step 7: Start the input stream first ────────────────────────────
    // FullDuplexStream reads from the input stream synchronously in the
    // output callback. The input stream must be started (recording) before
    // the output stream starts firing callbacks.
    oboe::Result inputStartResult = inputStream_->requestStart();
    if (inputStartResult != oboe::Result::OK) {
        LOGE("start() failed: input stream requestStart() returned %s",
             oboe::convertToText(inputStartResult));
        outputStream_->close();
        outputStream_.reset();
        inputStream_->close();
        inputStream_.reset();
        return false;
    }

    // ─── Step 8: Start the FullDuplexStream (starts output stream) ───────
    oboe::Result startResult = oboe::FullDuplexStream::start();
    if (startResult != oboe::Result::OK) {
        LOGE("start() failed: FullDuplexStream::start() returned %s",
             oboe::convertToText(startResult));
        inputStream_->requestStop();
        outputStream_->close();
        outputStream_.reset();
        inputStream_->close();
        inputStream_.reset();
        return false;
    }

    // ─── Step 9: Success ─────────────────────────────────────────────────
    running_.store(true, std::memory_order_release);
    callbackCounter_ = 0;

    LOGI("AudioEngine started — sampleRate=%d, framesPerBurst=%d, "
         "inputAPI=%s, outputAPI=%s",
         effectiveSampleRate, framesPerBuffer,
         oboe::convertToText(inputStream_->getAudioApi()),
         oboe::convertToText(outputStream_->getAudioApi()));

    return true;
}

oboe::Result AudioEngine::stop() {
    if (!running_.load(std::memory_order_acquire)) {
        return oboe::Result::OK;
    }

    // Set running_ to false first so the callback knows to stop processing
    running_.store(false, std::memory_order_release);

    // Stop the FullDuplexStream (base class) — stops the output stream's callbacks
    oboe::Result stopResult = FullDuplexStream::stop();
    if (stopResult != oboe::Result::OK) {
        LOGW("FullDuplexStream::stop() returned: %s", oboe::convertToText(stopResult));
    }

    // Stop and close input stream (we started it manually)
    if (inputStream_) {
        inputStream_->requestStop();
        inputStream_->close();
        inputStream_.reset();
    }

    // Close output stream if open
    if (outputStream_) {
        outputStream_->close();
        outputStream_.reset();
    }

    LOGI("AudioEngine stopped");
    return stopResult;
}

bool AudioEngine::isRunning() const {
    return running_.load(std::memory_order_acquire);
}

// ─────────────────────────────────────────────────────────────────────────────
// Actualizaciones de parámetros DSP (delegadas al pipeline, lock-free)
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

int32_t AudioEngine::getInputDeviceId() const {
    if (inputStream_) {
        return inputStream_->getDeviceId();
    }
    return -1;
}

int32_t AudioEngine::getOutputDeviceId() const {
    if (outputStream_) {
        return outputStream_->getDeviceId();
    }
    return -1;
}

// ─────────────────────────────────────────────────────────────────────────────
// Oboe FullDuplexStream Callback
// ─────────────────────────────────────────────────────────────────────────────

oboe::DataCallbackResult AudioEngine::onBothStreamsReady(
        const void *inputData,
        int numInputFrames,
        void *outputData,
        int numOutputFrames) {

    // ─── Guard: null buffer or zero frames → no-op ───────────────────────
    if (numInputFrames == 0 || inputData == nullptr) {
        if (outputData && numOutputFrames > 0) {
            std::memset(outputData, 0, numOutputFrames * sizeof(float));
        }
        return oboe::DataCallbackResult::Continue;
    }

    // ─── Guard: during reconnection → output silence ─────────────────────
    if (reconnecting_.load(std::memory_order_acquire)) {
        if (outputData && numOutputFrames > 0) {
            std::memset(outputData, 0, numOutputFrames * sizeof(float));
        }
        return oboe::DataCallbackResult::Continue;
    }

    // ─── Determine safe frame count ─────────────────────────────────────
    int numFrames = std::min(numInputFrames, numOutputFrames);

    // ─── Copy input to output buffer for in-place processing ─────────────
    std::memcpy(outputData, inputData, numFrames * sizeof(float));

    // ─── DSP processing in-place on output buffer ────────────────────────
    pipeline_.processBlock(static_cast<float*>(outputData), numFrames);

    // ─── Zero any remaining output frames beyond what we processed ───────
    if (numOutputFrames > numFrames) {
        float* outPtr = static_cast<float*>(outputData);
        std::memset(outPtr + numFrames, 0, (numOutputFrames - numFrames) * sizeof(float));
    }

    // ─── Level accumulation and callback emission (~100ms) ───────────────
    callbackCounter_++;
    if (callbackCounter_ >= callbacksPerLevelReport_) {
        float levelDb = pipeline_.getLastInputLevelDb();
        if (levelCallback_) {
            levelCallback_(levelDb);
        }
        callbackCounter_ = 0;
    }

    return oboe::DataCallbackResult::Continue;
}

// ─────────────────────────────────────────────────────────────────────────────
// Oboe Error Callback and Reconnection
// ─────────────────────────────────────────────────────────────────────────────

void AudioEngine::onErrorAfterClose(oboe::AudioStream *stream,
                                     oboe::Result error) {
    LOGE("Stream error: %s", oboe::convertToText(error));
    (void)stream;
    reconnecting_.store(true, std::memory_order_release);
    reconnectAttempts_.store(0, std::memory_order_release);
    attemptReconnection();
}

void AudioEngine::attemptReconnection() {
    for (int attempt = 0; attempt < kMaxReconnectAttempts; attempt++) {
        reconnectAttempts_.store(attempt + 1, std::memory_order_release);
        LOGI("Reconnection attempt %d/%d", attempt + 1, kMaxReconnectAttempts);

        // Close existing streams
        if (inputStream_) {
            inputStream_->close();
            inputStream_.reset();
        }
        if (outputStream_) {
            outputStream_->close();
            outputStream_.reset();
        }

        // Wait before retry
        std::this_thread::sleep_for(std::chrono::milliseconds(kReconnectDelayMs));

        // Attempt to reopen input stream
        auto inputResult = openInputStream();
        if (inputResult != oboe::Result::OK) {
            LOGW("Input stream reopen failed: %s", oboe::convertToText(inputResult));
            continue;
        }

        // Attempt to reopen output stream
        auto outputResult = openOutputStream();
        if (outputResult != oboe::Result::OK) {
            LOGW("Output stream reopen failed: %s", oboe::convertToText(outputResult));
            inputStream_->close();
            inputStream_.reset();
            continue;
        }

        // Success — start full-duplex
        setInputStream(inputStream_.get());
        setOutputStream(outputStream_.get());

        // Start input stream first (it must be recording for FullDuplexStream to read)
        auto inputStartResult = inputStream_->requestStart();
        if (inputStartResult != oboe::Result::OK) {
            LOGW("Input stream requestStart() failed on attempt %d: %s",
                 attempt + 1, oboe::convertToText(inputStartResult));
            outputStream_->close();
            outputStream_.reset();
            inputStream_->close();
            inputStream_.reset();
            continue;
        }

        auto startResult = FullDuplexStream::start();
        if (startResult == oboe::Result::OK) {
            reconnecting_.store(false, std::memory_order_release);
            LOGI("Reconnection successful on attempt %d", attempt + 1);
            return;
        }

        // FullDuplexStream::start() failed — clean up and try again
        LOGW("FullDuplexStream::start() failed on attempt %d: %s",
             attempt + 1, oboe::convertToText(startResult));
        inputStream_->requestStop();
        outputStream_->close();
        outputStream_.reset();
        inputStream_->close();
        inputStream_.reset();
    }

    // All attempts failed — stop engine, preserve DSP config
    reconnecting_.store(false, std::memory_order_release);
    running_.store(false, std::memory_order_release);
    LOGE("Reconnection failed after %d attempts — audio stopped", kMaxReconnectAttempts);
}

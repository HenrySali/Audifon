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
#include <android/asset_manager.h>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <chrono>
#include <thread>
#include <time.h>   // clock_gettime, CLOCK_MONOTONIC (latency monitor)

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

AudioEngine::AudioEngine()
    : loopbackTester_(std::make_unique<latency_monitor::LatencyLoopbackTester>()) {
    // El tester se crea siempre y vive todo el ciclo del motor; permanece
    // en estado IDLE hasta que `startLoopbackTest()` lo arme. La
    // implementación de los wrappers públicos llega en task 4.3.
}

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
    if (preferredInputDeviceId_ > 0) {
        // User selected a specific microphone via the UI.
        builder.setDeviceId(preferredInputDeviceId_);
    } else if (config_.builtInMicDeviceId != 0) {
        builder.setDeviceId(config_.builtInMicDeviceId);
    }
    builder.setSampleRate(config_.sampleRate);
    // Beamforming requiere 2 canales (estereo); legacy usa 1 (mono)
    int requestedChannels = 1;
    if (config_.beamformingEnabled) {
        requestedChannels = 2;
    }
    builder.setChannelCount(requestedChannels);
    builder.setFormat(oboe::AudioFormat::Float);
    builder.setPerformanceMode(oboe::PerformanceMode::LowLatency);
    // Use Shared mode for input — more compatible across devices.
    // Exclusive mode on input is often denied and some devices return
    // silence when it falls back silently.
    builder.setSharingMode(oboe::SharingMode::Shared);
    builder.setAudioApi(oboe::AudioApi::Unspecified);
    builder.setErrorCallback(this);
    // Pedir al HAL que asigne un audio session ID (para NoiseSuppressor Android).
    // Sin esto, getSessionId() devuelve 0 (None) y NoiseSuppressor no puede attachear.
    builder.setSessionId(oboe::SessionId::Allocate);
    // Allow format conversion so Oboe can handle int16→float if needed
    builder.setFormatConversionAllowed(true);
    builder.setSampleRateConversionQuality(oboe::SampleRateConversionQuality::Medium);

    // Input preset:
    //  - Modo Conversación (SCO): VoiceCommunication enruta al mic del canal
    //    de comunicación (SCO) y habilita el AEC/NS del modem para baja
    //    latencia. Es lo que usan las apps de llamada.
    //  - Modo normal: VoicePerformance (API 29+) prioriza fidelidad sobre
    //    procesamiento del modem, ideal para amplificación de ambiente.
    if (config_.conversationMode) {
        builder.setInputPreset(oboe::InputPreset::VoiceCommunication);
        // FIX "SCO mudo": forzar el backend legacy OpenSL ES + PerformanceMode::None.
        // El SCO ya queda activado por BluetoothScoController (setCommunicationDevice /
        // startBluetoothSco + MODE_IN_COMMUNICATION), que es el paso que la doc oficial
        // marca como obligatorio. Pero AAudio en LowLatency pide el fast/MMAP track
        // (AUDIO_INPUT_FLAG_FAST) y ese path NO se adjunta al endpoint de telefonía SCO,
        // así que el stream queda mudo aun con SCO conectado. OpenSL ES abre un AudioRecord
        // clásico con preset VoiceCommunication que SÍ respeta el ruteo a SCO.
        // Refs: Oboe wiki TechNote_BluetoothAudio (activación SCO) e issue google/oboe#155
        // (philburk/dturner: el MMAP no se soporta en BT y cae al path legacy).
        builder.setAudioApi(oboe::AudioApi::OpenSLES);
        builder.setPerformanceMode(oboe::PerformanceMode::None);
        LOGI("Input: VoiceCommunication + OpenSL ES + PerformanceMode::None (conversation mode / SCO)");
    } else if (android_get_device_api_level() >= 29) {
        builder.setInputPreset(oboe::InputPreset::VoicePerformance);
    } else {
        builder.setInputPreset(oboe::InputPreset::Generic);
        LOGW("API < 29: using InputPreset::Generic (VoicePerformance unavailable)");
    }

    oboe::Result result = builder.openStream(inputStream_);

    // Fallback: si se pidieron 2 canales y fallo, reintentar con 1 canal
    if (result != oboe::Result::OK && requestedChannels == 2) {
        LOGW("Stereo input failed (%s), falling back to mono",
             oboe::convertToText(result));
        builder.setChannelCount(1);
        result = builder.openStream(inputStream_);
        if (result == oboe::Result::OK) {
            stereoInputAvailable_ = false;
            LOGI("Input stream opened in MONO fallback mode");
        }
    } else if (result == oboe::Result::OK && requestedChannels == 2) {
        // Verificar que Oboe realmente abrio en estereo
        if (inputStream_->getChannelCount() == 2) {
            stereoInputAvailable_ = true;
            LOGI("Input stream opened in STEREO mode (beamforming ready)");
        } else {
            stereoInputAvailable_ = false;
            LOGW("Requested stereo but got %d channels — beamforming unavailable",
                 inputStream_->getChannelCount());
        }
    } else if (result == oboe::Result::OK) {
        stereoInputAvailable_ = false;
    }

    if (result == oboe::Result::OK) {
        LOGI("Input stream opened — API: %s, sampleRate: %d, format: %s, "
             "sharingMode: %s, deviceId: %d, framesPerBurst: %d, sessionId: %d",
             oboe::convertToText(inputStream_->getAudioApi()),
             inputStream_->getSampleRate(),
             oboe::convertToText(inputStream_->getFormat()),
             oboe::convertToText(inputStream_->getSharingMode()),
             inputStream_->getDeviceId(),
             inputStream_->getFramesPerBurst(),
             static_cast<int32_t>(inputStream_->getSessionId()));
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
    if (config_.conversationMode) {
        // Modo Conversación (SCO): el sistema sólo enruta al canal SCO los
        // streams con Usage::VoiceCommunication. Con Usage::Media el audio
        // iría a A2DP — que queda MUDO cuando SCO toma el enlace Bluetooth
        // (A2DP y SCO son mutuamente excluyentes). SharingMode::Shared
        // porque SCO no soporta Exclusive (devuelve silencio si se le pide).
        builder.setUsage(oboe::Usage::VoiceCommunication);
        builder.setContentType(oboe::ContentType::Speech);
        builder.setSharingMode(oboe::SharingMode::Shared);
        // FIX "SCO mudo": forzar OpenSL ES + PerformanceMode::None (mismo motivo que en
        // openInputStream). AAudio en LowLatency pide el fast track (AUDIO_OUTPUT_FLAG_FAST),
        // que se adjunta al mixer primario y NO al endpoint SCO de telefonía, por eso el
        // audio sale mudo aunque BluetoothScoController ya haya activado SCO y puesto
        // MODE_IN_COMMUNICATION. OpenSL ES abre un AudioTrack clásico que, con
        // Usage::VoiceCommunication, mapea a STREAM_VOICE_CALL → ruteo a SCO confiable.
        // Refs: Oboe wiki TechNote_BluetoothAudio; issue google/oboe#155 (philburk/dturner).
        builder.setAudioApi(oboe::AudioApi::OpenSLES);
        builder.setPerformanceMode(oboe::PerformanceMode::None);
        LOGI("Output: VoiceCommunication + OpenSL ES + PerformanceMode::None (conversation mode / SCO)");
    } else {
        // Modo normal: música/ambiente por A2DP a máxima calidad.
        builder.setUsage(oboe::Usage::Media);
        builder.setSharingMode(oboe::SharingMode::Exclusive);
        // Modo normal sin cambios: AAudio (Unspecified) para el fast-path de baja latencia.
        builder.setAudioApi(oboe::AudioApi::Unspecified);
    }
    // FullDuplexStream IS an AudioStreamDataCallback. Setting it as the
    // output stream's data callback means onAudioReady() fires on the output
    // stream, which internally reads from the input stream and calls
    // onBothStreamsReady(). This is the correct Oboe FullDuplexStream pattern.
    builder.setDataCallback(this);
    builder.setErrorCallback(this);

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

    // ─── Step 5a: Inform DNN denoiser of the native sample rate ──────────
    // El wrapper inserta un resampler interno (polyphase 3:1 si sr=48000,
    // bypass si sr=16000, lineal en otros casos) para que el modelo GTCRN
    // siga viendo audio a 16 kHz independientemente de lo que negocie Oboe.
    // Idempotente: si el sr no cambió respecto a la última llamada, es no-op.
    dnnDenoiser_.setInputSampleRate(effectiveSampleRate);
    // Misma rate nativa para la instancia dual-channel (ONNX). Su
    // resampler interno lleva ambos canales a 16 kHz. Idempotente.
    dnnDenoiserDual_.setInputSampleRate(effectiveSampleRate);

    // ─── Enhancement Engine: crossfade y estado inicial (tarea 3.5/3.7) ──
    // Crossfade entre motores ≈ 20 ms a la rate nativa (mínimo 1 sample).
    engineXfadeSamples_ = std::max(1, static_cast<int>(effectiveSampleRate * 0.02f));
    // Sin crossfade pendiente al arrancar; el callback lo dispara si el modo
    // seleccionado difiere de `activeEngine_`.
    engineXfadeRemaining_ = 0;
    if (!firstStartDone_) {
        // Tarea 3.7 / R8.3: el PRIMER arranque siempre es BYPASS, sin importar
        // los flags de config (beamformingEnabled). El usuario cambia de modo
        // desde la UI (tarea 5) vía setEnhancementEngineMode.
        engineMode_.store(EnhancementEngineMode::kBypass, std::memory_order_release);
        dnnDenoiserDual_.setEnabled(false);
    }
    // Sincronizar el motor "activo" del callback con el modo seleccionado
    // (sin crossfade: es un arranque/re-open de stream, no un toggle runtime).
    activeEngine_ = engineMode_.load(std::memory_order_acquire);
    prevEngine_ = activeEngine_;

    // ─── Step 5b: Initialize Smart Scene Engine analyzer (Fase 1) ────────
    sceneAnalyzer_.init(effectiveSampleRate, config_.splOffset);

    // ─── Step 5c: Initialize MVDR Beamformer ─────────────────────────────
    // El beamformer se habilita según el selector de motor (no ya según el
    // flag legacy config_.beamformingEnabled): sólo procesa cuando el modo
    // activo es kMvdrBackup y hay captura estéreo. renderEngineChunk() lo
    // invoca directamente; si estuviera deshabilitado haría bypass a ch0.
    mvdrBeamformer_.init(effectiveSampleRate);
    const bool mvdrWanted =
        (engineMode_.load(std::memory_order_acquire) == EnhancementEngineMode::kMvdrBackup);
    mvdrBeamformer_.setEnabled(mvdrWanted && stereoInputAvailable_);

    // ─── Step 6: Configure FullDuplexStream ──────────────────────────────
    setInputStream(inputStream_.get());
    setOutputStream(outputStream_.get());

    // ─── Step 7: Start the FullDuplexStream ──────────────────────────────
    // FullDuplexStream::start() will start the input stream for reading
    // and the output stream (which has this as data callback) for writing.
    // The output stream's onAudioReady triggers FullDuplexStream to read
    // from the input stream and call onBothStreamsReady().
    oboe::Result startResult = oboe::FullDuplexStream::start();
    if (startResult != oboe::Result::OK) {
        LOGE("start() failed: FullDuplexStream::start() returned %s",
             oboe::convertToText(startResult));
        outputStream_->close();
        outputStream_.reset();
        inputStream_->close();
        inputStream_.reset();
        return false;
    }

    // ─── Step 8: Success ─────────────────────────────────────────────────
    running_.store(true, std::memory_order_release);
    firstStartDone_ = true;
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

    // Stop the FullDuplexStream (base class) — stops both streams
    oboe::Result stopResult = FullDuplexStream::stop();
    if (stopResult != oboe::Result::OK) {
        LOGW("FullDuplexStream::stop() returned: %s", oboe::convertToText(stopResult));
    }

    // Close input stream
    if (inputStream_) {
        inputStream_->close();
        inputStream_.reset();
    }

    // Close output stream
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

void AudioEngine::setMpoThresholdDbSpl(float thresholdDbSpl) {
    pipeline_.setMpoThresholdDbSpl(thresholdDbSpl);
}

float AudioEngine::getLastInputLevel() const {
    return pipeline_.getLastInputLevelDb();
}

void AudioEngine::setAutoClassifyEnabled(bool enabled) {
    pipeline_.setAutoClassifyEnabled(enabled);
}

void AudioEngine::setSmartPresetPinned(bool pinned) {
    pipeline_.setSmartPresetPinned(pinned);
}

void AudioEngine::applyScenePreset(const ScenePreset& preset) {
    pipeline_.applyScenePreset(preset);
    // Aplicar también el modo de enhancement del preset (unificación
    // de clasificadores: ScenePolicy decide todo, incluyendo el motor).
    if (preset.enhancementMode >= 0 && preset.enhancementMode <= 3) {
        setEnhancementEngineMode(
            static_cast<EnhancementEngineMode>(preset.enhancementMode));
    }
}

int AudioEngine::getCurrentEnvironmentClass() const {
    return pipeline_.getCurrentEnvironmentClass();
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

void AudioEngine::setPreferredInputDevice(int32_t deviceId) {
    preferredInputDeviceId_ = deviceId;
    // Si el stream está corriendo, aplicar en caliente.
    if (inputStream_) {
        // Oboe no soporta cambiar deviceId en caliente sin re-abrir.
        // Guardamos el valor para el próximo restart. Si se necesita
        // efecto inmediato, el caller debe hacer stop/start.
    }
}

int32_t AudioEngine::getInputSessionId() const {
    if (inputStream_) {
        return static_cast<int32_t>(inputStream_->getSessionId());
    }
    return -1;
}

// ─────────────────────────────────────────────────────────────────────────────
// DNN Denoiser (GTCRN) — wrappers thin sobre dnnDenoiser_
// ─────────────────────────────────────────────────────────────────────────────

bool AudioEngine::initDnnDenoiser(AAssetManager* mgr) {
    LOGI("initDnnDenoiser: assetMgr=%p", mgr);

    // ─── Instancia mono legacy (GTCRN mono, ONNXRuntime) ────────────────
    // Stage `process()` del chain post-realce, controlado por setDnnEnabled().
    const bool okMono = dnnDenoiser_.initialize(mgr, "dnn_denoiser/gtcrn.onnx");
    if (!okMono) {
        LOGW("initDnnDenoiser[mono]: model not loaded — mono DNN permanently bypassed");
    } else {
        LOGI("initDnnDenoiser[mono]: model ready");
    }

    // ─── Instancia dual-channel (GTCRN dual, ONNX + WPE beamformer) ────
    // Motor de realce del modo kDualChannelDnn (spec gtcrn-dual-channel).
    // Se inicializa aparte porque initialize()/initializeDual() son
    // mutuamente excluyentes en el wrapper (cada uno arma UN worker para UN
    // runtime). Si el .onnx no carga o el shape no coincide, la instancia
    // queda en bypass seguro (processStereo -> ch0 passthrough) y el modo
    // kDualChannelDnn se degrada a passthrough sin cortar el audio (R4.x).
    const bool okDual =
        dnnDenoiserDual_.initializeDual(mgr, "dnn_denoiser/gtcrn_dual_core.onnx");
    if (!okDual) {
        LOGW("initDnnDenoiser[dual]: .onnx not loaded — kDualChannelDnn will bypass to ch0");
    } else {
        LOGI("initDnnDenoiser[dual]: model ready (inputChannels=%d)",
             static_cast<int>(dnnDenoiserDual_.inputChannels()));
    }

    // Retornamos el estado del mono para no romper el contrato JNI existente
    // (nativeInitDnnDenoiser). El estado del dual se consulta vía
    // getEnhancementEngineMode + isActive de la instancia dual (tarea 5).
    return okMono;
}

void AudioEngine::setDnnEnabled(bool enabled) {
    dnnDenoiser_.setEnabled(enabled);
    // Si activamos el DNN, deshabilitamos el NR Wiener clásico para
    // evitar doble denoising. Si desactivamos, restauramos el NR clásico.
    pipeline_.setNrBypassed(enabled);
    LOGI("setDnnEnabled: %d (active=%d) — NR Wiener bypassed: %d",
         enabled ? 1 : 0,
         dnnDenoiser_.isActive() ? 1 : 0,
         enabled ? 1 : 0);
}

void AudioEngine::setDnnIntensity(float intensity) {
    dnnDenoiser_.setIntensity(intensity);
}

// ─────────────────────────────────────────────────────────────────────────────
// MVDR Beamformer — wrappers thin sobre mvdrBeamformer_
// ─────────────────────────────────────────────────────────────────────────────

void AudioEngine::setBeamformingEnabled(bool enabled) {
    // COMPAT (tarea 3.6): el toggle binario histórico de beamforming ahora
    // mapea al selector de motor de 3 estados:
    //   setBeamformingEnabled(true)  → kMvdrBackup  (2 mics → MVDR → mono)
    //   setBeamformingEnabled(false) → kBypass      (ch0 passthrough)
    // Toda la lógica de re-open estéreo/mono (Fix #3) vive ahora en
    // setEnhancementEngineMode; este wrapper sólo traduce el bool al modo.
    setEnhancementEngineMode(enabled ? EnhancementEngineMode::kMvdrBackup
                                     : EnhancementEngineMode::kBypass);
}

bool AudioEngine::isBeamformingActive() const {
    return mvdrBeamformer_.isEnabled() && stereoInputAvailable_
        && engineMode_.load(std::memory_order_acquire)
               == EnhancementEngineMode::kMvdrBackup;
}

// ─────────────────────────────────────────────────────────────────────────────
// Enhancement Engine selector (spec gtcrn-dual-channel, tarea 3)
// ─────────────────────────────────────────────────────────────────────────────
//
// MAPEO DE SETTERS LEGACY (tarea 3.6) — documentado para no romper callers:
//
//   setBeamformingEnabled(true)   → setEnhancementEngineMode(kMvdrBackup)
//   setBeamformingEnabled(false)  → setEnhancementEngineMode(kBypass)
//
//   setDnnEnabled(true/false)     → SIN CAMBIOS. Controla la instancia MONO
//     legacy (dnnDenoiser_) que corre como stage `process()` del chain DSP,
//     independiente del selector de motor. El motor dual (dnnDenoiserDual_)
//     se selecciona SOLO via setEnhancementEngineMode(kDualChannelDnn).
//     Rationale: el diseno exige coexistencia mono(ONNX)+dual(ONNX+WPE); el
//     mono legacy es una etapa distinta del pipeline y no debe verse forzado
//     por el selector. Asi, los callers de setDnnEnabled siguen funcionando.

void AudioEngine::setEnhancementEngineMode(EnhancementEngineMode mode) {
    const EnhancementEngineMode prev =
        engineMode_.load(std::memory_order_acquire);

    // Publicar el nuevo modo (lock-free). El callback lo leerá y arrancará
    // el crossfade entre motores si difiere del `activeEngine_` corriente.
    engineMode_.store(mode, std::memory_order_release);

    // Mantener el flag del MVDR coherente con el modo (su process() hace
    // bypass a ch0 si no está enabled; renderEngineChunk lo invoca directo).
    mvdrBeamformer_.setEnabled((mode == EnhancementEngineMode::kMvdrBackup
                               || mode == EnhancementEngineMode::kHybridMvdrDnn)
                               && stereoInputAvailable_);

    // Habilitar/deshabilitar la instancia dual: processStereo() hace bypass a
    // ch0 salvo que enabled_==true (usa su propio crossfade dry/wet interno
    // de 50 ms, que complementa el crossfade ENTRE motores del callback).
    dnnDenoiserDual_.setEnabled(mode == EnhancementEngineMode::kDualChannelDnn
                                || mode == EnhancementEngineMode::kHybridMvdrDnn);

    // Los modos kDualChannelDnn, kMvdrBackup y kHybridMvdrDnn requieren captura estéreo.
    // Reutilizamos la lógica de re-open (Fix #3) SÓLO cuando cambia la
    // geometría de captura mono→estéreo (tarea 3.4). kBypass no fuerza
    // re-open: se queda en la geometría actual (lo más simple).
    const bool needStereo = (mode == EnhancementEngineMode::kDualChannelDnn
                             || mode == EnhancementEngineMode::kMvdrBackup
                             || mode == EnhancementEngineMode::kHybridMvdrDnn);

    if (needStereo && running_.load(std::memory_order_acquire)
        && !stereoInputAvailable_) {
        // Estamos en mono y el nuevo modo necesita 2 mics → re-open estéreo.
        config_.beamformingEnabled = true;
        stop();
        start(config_);
        // Tras el re-open, mvdrBeamformer_ ya quedó configurado por start()
        // según el modo (Step 5c). Sincronizamos enabled por las dudas.
        mvdrBeamformer_.setEnabled((mode == EnhancementEngineMode::kMvdrBackup
                                   || mode == EnhancementEngineMode::kHybridMvdrDnn)
                                   && stereoInputAvailable_);
    }

    LOGI("setEnhancementEngineMode: %d → %d (stereo=%d, running=%d)",
         static_cast<int>(prev), static_cast<int>(mode),
         stereoInputAvailable_ ? 1 : 0,
         running_.load(std::memory_order_acquire) ? 1 : 0);
}

EnhancementEngineMode AudioEngine::getEnhancementEngineMode() const {
    return engineMode_.load(std::memory_order_acquire);
}

// ─────────────────────────────────────────────────────────────────────────────
// Enhancement Engine — render de un chunk por modo (audio thread, no alloc)
// ─────────────────────────────────────────────────────────────────────────────

void AudioEngine::renderEngineChunk(EnhancementEngineMode mode,
                                    const float* ch0, const float* ch1,
                                    float* dst, int chunk, bool vadActive) {
    switch (mode) {
        case EnhancementEngineMode::kDualChannelDnn:
            // 2 mics -> GTCRN dual (ONNX + WPE beamformer). Bypass seguro
            // interno si el modelo no cargo o hay underrun (processStereo
            // copia ch0 a dst).
            dnnDenoiserDual_.processStereo(ch0, ch1, dst, chunk);
            break;
        case EnhancementEngineMode::kMvdrBackup:
            // 2 mics → MVDR → mono. Si el beamformer está deshabilitado,
            // process() ya hace bypass a ch0 internamente.
            mvdrBeamformer_.process(ch0, ch1, dst, chunk, vadActive);
            break;
        case EnhancementEngineMode::kHybridMvdrDnn:
            // Modo híbrido: MVDR crossover ≤1000 Hz + DualDNN completa.
            // El MVDR solo cancela ruido en graves (donde funciona sin
            // aliasing), y la DNN limpia todo el espectro.
            // Estrategia: DNN procesa primero (fullband), luego el MVDR
            // reemplaza las bajas frecuencias con su versión beamformed.
            {
                // DNN procesa fullband
                dnnDenoiserDual_.processStereo(ch0, ch1, dst, chunk);
                // MVDR procesa en paralelo (solo usamos ≤1000 Hz de su salida)
                float mvdrOut[kMaxBeamBlockSize];
                mvdrBeamformer_.process(ch0, ch1, mvdrOut, chunk, vadActive);
                // Crossover: mezclar MVDR en bajas frecuencias.
                // Filtro simple 1er orden LPF a 1000 Hz para la contribución MVDR.
                // alpha = 2*pi*fc / (2*pi*fc + SR) ≈ fc/(fc + SR/(2*pi))
                const float fc = 1000.0f;
                const float alpha = fc / (fc + static_cast<float>(config_.sampleRate) / 6.2832f);
                for (int i = 0; i < chunk; ++i) {
                    // Extraer componente grave del MVDR
                    hybridLpState_ = alpha * mvdrOut[i] + (1.0f - alpha) * hybridLpState_;
                    float mvdrLow = hybridLpState_;
                    // Extraer componente grave del DNN (para restarla)
                    hybridLpStateDnn_ = alpha * dst[i] + (1.0f - alpha) * hybridLpStateDnn_;
                    float dnnLow = hybridLpStateDnn_;
                    // Reemplazar graves de DNN con graves de MVDR
                    dst[i] = (dst[i] - dnnLow) + mvdrLow;
                }
            }
            break;
        case EnhancementEngineMode::kBypass:
        default:
            // ch0 passthrough (Property 2: identidad bit-exact sobre ch0).
            if (dst != ch0) {
                std::memcpy(dst, ch0, chunk * sizeof(float));
            }
            break;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Oboe FullDuplexStream Callback
// ─────────────────────────────────────────────────────────────────────────────

oboe::DataCallbackResult AudioEngine::onBothStreamsReady(
        const void *inputData,
        int numInputFrames,
        void *outputData,
        int numOutputFrames) {

    // ─── Latency monitor: marca de inicio del callback (task 2.3) ───────
    // Marcamos t_start lo más temprano posible para capturar el costo
    // total del callback (incluido el header y los guards). Si el callback
    // toma una rama de early-return, el ring buffer no se actualiza para
    // ese bloque (lo cual es correcto: no procesamos audio).
    const auto t_start = std::chrono::steady_clock::now();

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

    // ─── Ambient Mute Branch (spec monitor-latencia-audio, task 2.4) ────
    // Cuando el LatencyLoopbackTester corre el test acústico, llama
    // setAmbientMute(true) para que el pipeline DSP no procese ni emita
    // audio del mic ambiente — solo el chirp del tester ocupa el output.
    // El propio tester se encarga de:
    //   - Capturar el input crudo en su buffer de captura.
    //   - Sobrescribir el output con el chirp (overwrite, no mix).
    // Por eso acá solo silenciamos el output (ver hook del tester abajo) y
    // retornamos: no llamamos al pipeline DSP ni al diagnostic recorder.
    if (ambientMuted_.load(std::memory_order_relaxed)) {
        // Silencio por defecto del output. Si el tester está activo, el
        // memset sirve solo como "limpieza inicial": el hook de abajo
        // sobrescribe los samples del chirp encima de este silencio.
        // Si el tester NO está activo (caso defensivo, no debería ocurrir
        // en uso normal porque los wrappers públicos sincronizan ambos
        // flags), el output queda en silencio puro hasta que se desmutee.
        if (outputData && numOutputFrames > 0) {
            std::memset(outputData, 0, numOutputFrames * sizeof(float));
        }

        // Hook del LatencyLoopbackTester (spec monitor-latencia-audio,
        // task 4.2 — Requirements 5.2, 5.12, 8.6).
        //
        // Cuando el tester está activo, captura el input crudo en su
        // buffer interno y sobrescribe el output con el chirp pre-generado.
        // Esto reemplaza el silencio que acabamos de poner: el tester
        // hace overwrite (no mix) sobre `output` en los frames que
        // corresponden a la fase de emisión, y deja en silencio el
        // resto. El ambiente debe estar muteado durante el test para
        // evitar feedback (ver task 4.3 — los wrappers públicos
        // sincronizan ambos flags).
        if (loopbackTester_ && loopbackTester_->isActive()) {
            loopbackTester_->onAudioCallback(
                static_cast<const float*>(inputData), numInputFrames,
                static_cast<float*>(outputData), numOutputFrames);
        }

        // Mantenemos la medición del callback para diagnóstico (ring buffer)
        // pero no actualizamos health timestamps porque el output puede no
        // tener getTimestamp válido durante el mute. Es preferible que el
        // health monitor reporte degradado durante el test que romper el
        // valor previo conocido.
        const auto t_end = std::chrono::steady_clock::now();
        const auto dur_us = std::chrono::duration_cast<std::chrono::microseconds>(
            t_end - t_start).count();
        const int idx = dspTimingIndex_.fetch_add(
            1, std::memory_order_relaxed) % kDspTimingRingSize;
        dspTimingRing_[idx].store(
            static_cast<uint32_t>(dur_us), std::memory_order_relaxed);
        return oboe::DataCallbackResult::Continue;
    }

    // ─── Determine safe frame count ─────────────────────────────────────
    int numFrames = std::min(numInputFrames, numOutputFrames);

    // ─── Copy input to output buffer for in-place processing ─────────────
    const float* inPtr = static_cast<const float*>(inputData);
    float* outPtr = static_cast<float*>(outputData);

    // ─── Enhancement Engine stage (spec gtcrn-dual-channel, tarea 3.3) ──
    // Enruta el realce por EnhancementEngineMode y produce el mono `outPtr`:
    //   kDualChannelDnn → deinterleave ch0/ch1 → DnnDenoiser::processStereo
    //   kMvdrBackup     → deinterleave ch0/ch1 → MvdrBeamformer::process
    //   kBypass         → ch0 passthrough (o mono directo)
    // Se procesa en chunks de kMaxBeamBlockSize (contrato del MVDR: overread
    // de su outputBuf_ si chunk > kFftSize; el dual y el bypass también van
    // troceados para reutilizar los mismos buffers de deinterleave).
    //
    // Transición sin clic (R2.5, tarea 3.5): al cambiar de modo en runtime se
    // hace un crossfade lineal corto ENTRE motores (distinto del crossfade
    // dry/wet interno del DnnDenoiser). Durante la ventana se renderiza el
    // motor saliente en `engineXfadeBuf_` y se mezcla con el entrante.
    //
    // Captura mono o modo dual/MVDR sin estéreo disponible → BYPASS
    // (Property 5, R4.5).
    {
        EnhancementEngineMode target = engineMode_.load(std::memory_order_acquire);
        if (!stereoInputAvailable_
            && (target == EnhancementEngineMode::kDualChannelDnn
                || target == EnhancementEngineMode::kMvdrBackup)) {
            target = EnhancementEngineMode::kBypass;
        }

        // Disparar crossfade entre motores si cambió el modo activo.
        if (target != activeEngine_) {
            prevEngine_ = activeEngine_;
            activeEngine_ = target;
            engineXfadeRemaining_ = engineXfadeSamples_;
        }

        const float xfadeStepInv =
            1.0f / static_cast<float>(engineXfadeSamples_ > 0 ? engineXfadeSamples_ : 1);
        const bool vadActive = sceneAnalyzer_.getVad().isVoiceActive();

        int framesRemaining = numFrames;
        int offset = 0;
        while (framesRemaining > 0) {
            const int chunkSize = std::min(framesRemaining, kMaxBeamBlockSize);

            // Deinterleave a ch0/ch1 (mono → ch0 = ch1 = input directo).
            if (stereoInputAvailable_) {
                for (int i = 0; i < chunkSize; ++i) {
                    beamCh0_[i] = inPtr[(offset + i) * 2];      // mic inferior (ch0)
                    beamCh1_[i] = inPtr[(offset + i) * 2 + 1];  // mic superior (ch1)
                }
            } else {
                for (int i = 0; i < chunkSize; ++i) {
                    beamCh0_[i] = inPtr[offset + i];
                    beamCh1_[i] = beamCh0_[i];
                }
            }

            // Motor entrante → outPtr + offset.
            renderEngineChunk(activeEngine_, beamCh0_, beamCh1_,
                              outPtr + offset, chunkSize, vadActive);

            // Crossfade entre motores: renderizar el saliente y mezclar.
            if (engineXfadeRemaining_ > 0) {
                renderEngineChunk(prevEngine_, beamCh0_, beamCh1_,
                                  engineXfadeBuf_, chunkSize, vadActive);
                for (int i = 0; i < chunkSize; ++i) {
                    // g: 0 → 1 conforme remaining decrece (el entrante gana).
                    float g = 1.0f -
                        static_cast<float>(engineXfadeRemaining_) * xfadeStepInv;
                    if (g < 0.0f) g = 0.0f;
                    else if (g > 1.0f) g = 1.0f;
                    outPtr[offset + i] =
                        engineXfadeBuf_[i] * (1.0f - g) + outPtr[offset + i] * g;
                    if (engineXfadeRemaining_ > 0) --engineXfadeRemaining_;
                }
            }

            offset += chunkSize;
            framesRemaining -= chunkSize;
        }
    }

    // ─── Diagnostic: check if input has actual audio data ────────────────
    // Log once every ~2 seconds to avoid floodear logcat.
    // Spec dnn-voice-level-recovery R2.1, R2.2, R2.3:
    //   - userIntensity      : valor del slider (intensity_ del usuario).
    //   - effectiveIntensity : valor post-VAD-cap (lo que efectivamente se
    //                          aplica en la mezcla dry/wet).
    //   - vadActive          : flag del SceneAnalyzer del último bloque
    //                          (mismo getter que el cableo de notifyVoiceActive).
    // Reusamos el mismo `diagCounter` y la misma cadencia (~2 s) para no
    // floodear logcat ni introducir un contador nuevo.
    static int diagCounter = 0;
    if (++diagCounter >= callbacksPerLevelReport_ * 20) {
        diagCounter = 0;
        float maxSample = 0.0f;
        // Usar outPtr (ya es mono post-beamforming o post-memcpy)
        for (int i = 0; i < numFrames; ++i) {
            float absVal = std::fabs(outPtr[i]);
            if (absVal > maxSample) maxSample = absVal;
        }
        const float userIntensity      = dnnDenoiser_.getIntensity();
        const float effectiveIntensity = dnnDenoiser_.getEffectiveIntensity();
        const bool  vadActive          = sceneAnalyzer_.getVad().isVoiceActive();
        LOGI("Input diag: numFrames=%d, maxSample=%.6f, "
             "DNN[user=%.2f, eff=%.2f, vad=%d]",
             numFrames, maxSample,
             userIntensity, effectiveIntensity, vadActive ? 1 : 0);

        // VAD diagnostics — temporal para debug de ruido continuo
        const auto& vad = sceneAnalyzer_.getVad();
        LOGI("VAD diag: score=%.3f pitch=%.3f lrt=%.3f midSnr=%.1fdB "
             "ltsd=%.1fdB stat=%.3f zcr=%.3f density=%.2f hangover=%d",
             vad.getScore(),
             vad.getPitchStrength(),
             vad.getLrtScore(),
             vad.getMidSnrDb(),
             vad.getLtsdDb(),
             vad.getStationarity(),
             vad.getZcrRatio(),
             vad.getPitchDensity(),
             vad.isHangoverActive() ? 1 : 0);
    }

    // ─── Pre-DNN Level Measurement (DSP chain optimization, R1.1, R1.2) ─
    // Medimos RMS del buffer ANTES de la DNN para que el WDRC use el nivel
    // real de entrada. La DNN atenúa típicamente -6 a -10 dB, lo cual
    // empujaba al WDRC a operar en región de expansión cuando debería
    // estar comprimiendo. El valor se pasa luego a pipeline_.processBlock
    // como externalLevelDb (ver task 2.4).
    {
        float sumSq = 0.0f;
        for (int i = 0; i < numFrames; ++i) {
            sumSq += outPtr[i] * outPtr[i];
        }
        float rms = std::sqrt(sumSq / static_cast<float>(numFrames));
        if (rms < 1e-10f) rms = 1e-10f;  // piso para evitar log(0)
        lastPreDnnLevelDb_ = 20.0f * std::log10(rms) + config_.splOffset;
    }

    // ─── Headroom Stage — atenuación pre-DNN (R2.1, R2.2, R2.4) ──────────
    // Sólo atenuamos cuando el DNN está habilitado: señales near-full-scale
    // (peak > -3 dBFS ≈ 0.7079 lineal) saturan la representación interna
    // de GTCRN y producen THD excesiva. Atenuamos -6 dB (×0.5) antes del
    // modelo y restauramos +6 dB (×2.0) después. Si el DNN está off, no
    // hay riesgo de saturación interna y la señal pasa sin modificar
    // (Requirement 2.4).
    //
    // El flag `headroomApplied_` es por-bloque (no estado persistente):
    // se reinicia en cada callback y la restauración post-DNN sólo se
    // ejecuta si este mismo bloque fue atenuado.
    headroomApplied_ = false;
    if (dnnDenoiser_.isEnabled()) {
        float peakSample = 0.0f;
        for (int i = 0; i < numFrames; ++i) {
            float absVal = std::fabs(outPtr[i]);
            if (absVal > peakSample) peakSample = absVal;
        }
        if (peakSample > kHeadroomThresholdLinear) {
            for (int i = 0; i < numFrames; ++i) {
                outPtr[i] *= kHeadroomAttenLinear;
            }
            headroomApplied_ = true;
        }
    }

    // ─── DNN Denoiser (GTCRN) — REEMPLAZA al NR Wiener cuando enabled ────
    // Por contrato del wrapper:
    //   - Si dnnDenoiser_.isEnabled() == false y crossfadeGain == 0 →
    //     bypass bit-exact (sin tocar el buffer).
    //   - Si está enabled o haciendo crossfade out → procesa.
    // El DspPipeline ya está configurado (vía setNrBypassed) para no
    // ejecutar el NR Wiener cuando el DNN está activo.
    dnnDenoiser_.process(outPtr, numFrames);

    // ─── Headroom Stage — restauración post-DNN (R2.3) ───────────────────
    // Si este bloque fue atenuado pre-DNN, restauramos +6 dB para que el
    // resto del pipeline (HPF, EQ, WDRC, MPO) reciba la señal al mismo
    // nivel que tendría sin el headroom. Round-trip 0.5 × 2.0 == 1.0
    // (bit-exact en float32 para todos los samples representables).
    if (headroomApplied_) {
        for (int i = 0; i < numFrames; ++i) {
            outPtr[i] *= kHeadroomRestoreLinear;
        }
    }

    // ─── DSP processing in-place on output buffer ────────────────────────
    // Speech-aware level estimation para el WDRC:
    //
    // Caso A (silencio/voz limpia, DNN no atenúa o no está activo):
    //   pre-DNN ≈ post-DNN. Pasamos pre-DNN al WDRC para mantener el
    //   contrato de dsp-chain-optimization (Req 1.3) y evitar que opere
    //   en región de expansión.
    //
    // Caso B (ruido fuerte, DNN atenúa > 3 dB):
    //   pre-DNN refleja el nivel del RUIDO + voz; post-DNN refleja el
    //   nivel de la VOZ ya limpia. Si pasamos pre-DNN, el WDRC comprime
    //   fuerte y la voz sale apagada. Pasamos post-DNN para que el WDRC
    //   "vea" la voz target y le aplique la ganancia clínica correcta.
    //
    // Ref clínica: Phonak Sky/Oticon Velox utilizan estimación de nivel
    // post-NR para WDRC en escenarios ruidosos (speech-aware compression).
    float postDnnLevelDb;
    {
        float sumSq = 0.0f;
        for (int i = 0; i < numFrames; ++i) {
            sumSq += outPtr[i] * outPtr[i];
        }
        float rms = std::sqrt(sumSq / static_cast<float>(numFrames));
        if (rms < 1e-10f) rms = 1e-10f;
        postDnnLevelDb = 20.0f * std::log10(rms) + config_.splOffset;
    }
    const float dnnAttenDb = lastPreDnnLevelDb_ - postDnnLevelDb;
    const float wdrcInputLevelDb =
        (dnnDenoiser_.isEnabled() && dnnAttenDb > 3.0f)
            ? postDnnLevelDb
            : lastPreDnnLevelDb_;

    // Fase A — Causa B/E (smart-scene-diagnostico-chasquido.md):
    // Pasamos al pipeline el `voice_active` que el SceneAnalyzer publicó
    // tras procesar el bloque ANTERIOR. Es la última información de VAD
    // disponible en este punto del callback (el `sceneAnalyzer_.process()`
    // que cubre el bloque actual corre unas líneas más abajo). Latencia
    // de 1 bloque (≈5 ms a 48 kHz / 256 frames) — despreciable frente al
    // hold del clasificador (5 s) y a la memoria de voz (1.5 s).
    //
    // El clasificador usa este flag para evitar bajadas espurias a QUIET
    // por las pausas naturales del habla y para promover voz fuerte
    // (≤ 88 dB SPL) a SPEECH en lugar de NOISE.
    const bool vadFromLastBlock = sceneAnalyzer_.getVad().isVoiceActive();
    pipeline_.processBlock(outPtr, numFrames, wdrcInputLevelDb,
                           vadFromLastBlock);

    // ─── Smart Scene Engine analysis (Fase 1, read-only) ────────────────
    // Fix #5 (auditoría MVDR): alimentar el SceneAnalyzer con `outPtr`, que
    // ya es la señal mono resultante (beamformed en estéreo, o memcpy de ch0
    // en mono legacy). Antes se le pasaba `beamCh0_`, que en modo chunked
    // solo contenía el ÚLTIMO chunk deinterleaveado (datos stale para
    // numFrames > kMaxBeamBlockSize) y además ignoraba el beamforming. Usar
    // `outPtr` da al VAD la señal coherente con la que sale del beamformer.
    sceneAnalyzer_.process(outPtr, numFrames);

    // Propagar la SceneClass del SceneAnalyzer al pipeline para que la
    // tabla unificada (scene_policy.h) tome las decisiones de NR/WDRC/TNR.
    {
        auto snap = sceneAnalyzer_.getSnapshot();
        pipeline_.setLastSceneClass(snap.scene_class);
    }

    // ─── Cablear voice_active al DNN denoiser para el cap del Paso 1 ────
    // Spec dnn-voice-level-recovery R1.1, R1.2, R5.2:
    //
    // El SceneAnalyzer corre AHORA, sobre el input crudo del bloque actual,
    // pero `dnnDenoiser_.process()` del callback corriente ya consumió el
    // valor de `voice_active` del bloque ANTERIOR (lectura atomic en
    // `process()`).
    //
    // Por lo tanto, el flag que estamos guardando acá lo va a leer el
    // PRÓXIMO callback (latencia de 1 bloque ≈ 5 ms a 16 kHz), lo cual
    // es despreciable frente a la rampa asimétrica del cap (40 ms attack,
    // 300 ms release). Esto evita reordenar el callback para correr el
    // VAD antes del DNN.
    dnnDenoiser_.notifyVoiceActive(sceneAnalyzer_.getVad().isVoiceActive());

    // ─── Calibration Spectrum Validator (Fase 2, read-only on input) ─────
    // Sólo procesa si el técnico activó una secuencia de validación.
    // En modo estereo, alimentar con el canal de referencia (ch0, mono).
    // NOTA: beamCh0_ contiene el ÚLTIMO chunk deinterleaveado (igual que antes
    // en modo chunked); es el canal de referencia disponible sin recomputar.
    if (stereoInputAvailable_) {
        toneAnalyzer_.process(beamCh0_, numFrames);
    } else {
        toneAnalyzer_.process(inPtr, numFrames);
    }

    // ─── Zero any remaining output frames beyond what we processed ───────
    if (numOutputFrames > numFrames) {
        std::memset(outPtr + numFrames, 0, (numOutputFrames - numFrames) * sizeof(float));
    }

    // ─── Diagnostic Recorder: feed pre/post DSP ─────────────────────────
    // En modo estereo, el pre-DSP es el canal de referencia (ch0, mono).
    if (stereoInputAvailable_) {
        diagnosticRecorder_.feedPreDsp(beamCh0_, numFrames);
    } else {
        diagnosticRecorder_.feedPreDsp(inPtr, numFrames);
    }
    diagnosticRecorder_.feedPostDsp(outPtr, numFrames);

    // ─── Level accumulation and callback emission (~100ms) ───────────────
    callbackCounter_++;
    if (callbackCounter_ >= callbacksPerLevelReport_) {
        float levelDb = pipeline_.getLastInputLevelDb();
        if (levelCallback_) {
            levelCallback_(levelDb);
        }
        callbackCounter_ = 0;
    }

    // ─── Latency monitor: ring buffer DSP timing + timestamp health ────
    // (spec monitor-latencia-audio, task 2.3 — Requirements 4.4, 8.1, 8.2)
    //
    // Costo agregado al callback: dos `clock_gettime(CLOCK_MONOTONIC)` (vDSO
    // ~20-30 ns cada uno en hardware moderno) + un `fetch_add` y un `store`
    // relajados (~1-2 ns) ≈ < 1 µs total. Ningún lock, ninguna alocación.
    //
    // El ring de 50 slots a 48 kHz / 48 frames-per-burst cubre ~50 ms de
    // historia, suficiente para un promedio móvil estable que se lee
    // desde getLatencyMetrics() en el lado de control con load-relaxed.
    {
        const auto t_end = std::chrono::steady_clock::now();
        const auto dur_us = std::chrono::duration_cast<std::chrono::microseconds>(
            t_end - t_start).count();
        const int idx = dspTimingIndex_.fetch_add(
            1, std::memory_order_relaxed) % kDspTimingRingSize;
        dspTimingRing_[idx].store(
            static_cast<uint32_t>(dur_us), std::memory_order_relaxed);

        // Refresh timestamp health monitor: si getTimestamp() OK, guardamos
        // la marca CLOCK_MONOTONIC actual. `areTimestampsHealthy()` retorna
        // true mientras esa marca esté dentro de los últimos 3 segundos.
        // Usamos `clock_gettime` directo en lugar del helper anónimo
        // `readMonotonicNs()` porque vive en un namespace anónimo más abajo
        // del archivo (linkage interno → no se puede forward-declarar acá).
        if (outputStream_) {
            int64_t framePos = 0;
            int64_t timeNs   = 0;
            const auto tsResult = outputStream_->getTimestamp(
                CLOCK_MONOTONIC, &framePos, &timeNs);
            if (tsResult == oboe::Result::OK) {
                struct timespec ts {};
                clock_gettime(CLOCK_MONOTONIC, &ts);
                const int64_t nowNs =
                    static_cast<int64_t>(ts.tv_sec) * 1'000'000'000LL +
                    static_cast<int64_t>(ts.tv_nsec);
                lastSuccessfulTimestampNs_.store(
                    nowNs, std::memory_order_relaxed);
            }
        }
    }

    return oboe::DataCallbackResult::Continue;
}

// ─────────────────────────────────────────────────────────────────────────────
// Diagnostic Recorder
// ─────────────────────────────────────────────────────────────────────────────

bool AudioEngine::startDiagnosticRecording(const std::string& filePath) {
    DiagRecorderConfig cfg;
    cfg.sampleRate = config_.sampleRate;
    cfg.durationSeconds = 15;
    return diagnosticRecorder_.start(filePath);
}

bool AudioEngine::stopDiagnosticRecording() {
    diagnosticRecorder_.stop();
    return diagnosticRecorder_.getState() == DiagRecorderState::COMPLETED;
}

bool AudioEngine::stopDiagnosticRecordingKeep() {
    return diagnosticRecorder_.stopAndKeep();
}
}

double AudioEngine::getDiagnosticRecordingProgress() const {
    auto state = diagnosticRecorder_.getState();
    if (state == DiagRecorderState::COMPLETED || state == DiagRecorderState::FINALIZING) {
        // Recording finished — return full duration so Dart triggers completion
        return 15000.0;
    }
    if (state != DiagRecorderState::RECORDING) {
        return -1.0;
    }
    // Retornar milisegundos transcurridos (Dart espera int ms)
    return static_cast<double>(diagnosticRecorder_.getElapsedMs());
}

// ─────────────────────────────────────────────────────────────────────────────
// Oboe Error Callback and Reconnection
// ─────────────────────────────────────────────────────────────────────────────

void AudioEngine::onErrorAfterClose(oboe::AudioStream *stream,
                                     oboe::Result error) {
    LOGE("Stream error: %s", oboe::convertToText(error));
    (void)stream;

    // ─── PROTECCIÓN ANTI-SATURACIÓN AL PERDER EL STREAM ─────────────────
    // Cuando Oboe cierra el stream (BT desconectado, dispositivo removido),
    // NO reconectar automáticamente. Si reconectamos al speaker, el audio
    // amplificado (20-50 dB de EQ) sale a todo volumen y satura/distorsiona.
    // Mejor detener el motor y dejar que el usuario re-encienda manualmente
    // cuando reconecte el auricular.
    pipeline_.setVolume(-20.0f);  // Mute instantáneo (por si queda un bloque en cola)
    running_.store(false, std::memory_order_release);
    LOGW("Stream lost — engine STOPPED (no reconnection to prevent speaker saturation)");

    // NO llamar attemptReconnection() — dejamos el motor parado.
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

        auto startResult = FullDuplexStream::start();
        if (startResult == oboe::Result::OK) {
            reconnecting_.store(false, std::memory_order_release);
            LOGI("Reconnection successful on attempt %d", attempt + 1);
            return;
        }

        // FullDuplexStream::start() failed — clean up and try again
        LOGW("FullDuplexStream::start() failed on attempt %d: %s",
             attempt + 1, oboe::convertToText(startResult));
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

// ─────────────────────────────────────────────────────────────────────────────
// Latency Monitor (spec monitor-latencia-audio, task 2.2 / 2.4)
// ─────────────────────────────────────────────────────────────────────────────

namespace {

/// Lee CLOCK_MONOTONIC y devuelve nanosegundos desde el boot.
/// Mismo reloj que pasamos a `oboe::AudioStream::getTimestamp(CLOCK_MONOTONIC)`,
/// por lo que las restas (`now - presentationTime`) son válidas en ns.
inline int64_t readMonotonicNs() {
    struct timespec ts {};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1'000'000'000LL +
           static_cast<int64_t>(ts.tv_nsec);
}

/// Group delay aproximado del DNN denoiser (resampler 48 kHz → 16 kHz y
/// vuelta) cuando está activo. Documentado en el spec como ~1.5 ms con
/// polyphase 72-tap Kaiser β=8.5. La API pública de DnnDenoiser no expone
/// el valor exacto; usamos esta constante hasta que se agregue un getter.
constexpr double kDnnGroupDelayMsActive = 1.5;

/// Look-ahead del Transient Noise Reducer, fijo por configuración del DSP.
constexpr double kTnrLookaheadMs = 5.0;

/// Versión del esquema `LatencyMetrics` expuesto a Kotlin/Dart.
constexpr int32_t kLatencyMetricsSchemaVersion = 1;

} // namespace

LatencyMetrics AudioEngine::getLatencyMetrics() const {
    LatencyMetrics m{};
    m.schemaVersion    = kLatencyMetricsSchemaVersion;
    m.tnrLookaheadMs   = kTnrLookaheadMs;

    // ─── Engine no corriendo: snapshot vacío con latencias = -1 ────────
    if (!inputStream_ || !outputStream_) {
        m.sampleRate             = 0;
        m.inputFramesPerBurst    = 0;
        m.outputFramesPerBurst   = 0;
        m.outputBufferSizeFrames = 0;
        m.inputAudioApi          = 0;
        m.outputAudioApi         = 0;
        m.inputSharingMode       = 0;
        m.outputSharingMode      = 0;
        m.outputPerformanceMode  = 0;
        m.inputLatencyMs         = -1.0;
        m.outputLatencyMs        = -1.0;
        m.dspBlockMs             = 0.0;
        m.dspProcessingMsAvg     = 0.0;
        m.dspProcessingMsMax     = 0.0;
        m.dnnInferenceMs         = 0.0;
        m.dnnGroupDelayMs        = 0.0;
        m.callbackUnderruns      = 0;
        m.timestampsHealthy      = false;
        return m;
    }

    // ─── Configuración del stream ──────────────────────────────────────
    m.sampleRate             = inputStream_->getSampleRate();
    m.inputFramesPerBurst    = inputStream_->getFramesPerBurst();
    m.outputFramesPerBurst   = outputStream_->getFramesPerBurst();
    m.outputBufferSizeFrames = outputStream_->getBufferSizeInFrames();
    m.inputAudioApi          = static_cast<int32_t>(inputStream_->getAudioApi());
    m.outputAudioApi         = static_cast<int32_t>(outputStream_->getAudioApi());
    m.inputSharingMode       = static_cast<int32_t>(inputStream_->getSharingMode());
    m.outputSharingMode      = static_cast<int32_t>(outputStream_->getSharingMode());
    m.outputPerformanceMode  = static_cast<int32_t>(outputStream_->getPerformanceMode());

    // ─── Timestamps Oboe (CLOCK_MONOTONIC) ────────────────────────────
    // Para input:  latencia = now - presentationTime (cuán "viejo" es el
    //              último frame ya capturado por el HW).
    // Para output: latencia = presentationTime - now (cuándo se va a oír
    //              el frame que estamos por escribir).
    // Si Result != OK, asignamos -1 (Dart lo mapea a null).
    const int64_t nowNs = readMonotonicNs();

    int64_t inFramePos  = 0;
    int64_t inTimeNs    = 0;
    auto inResult = inputStream_->getTimestamp(
        CLOCK_MONOTONIC, &inFramePos, &inTimeNs);
    m.inputLatencyMs = (inResult == oboe::Result::OK)
        ? static_cast<double>(nowNs - inTimeNs) / 1.0e6
        : -1.0;

    int64_t outFramePos = 0;
    int64_t outTimeNs   = 0;
    auto outResult = outputStream_->getTimestamp(
        CLOCK_MONOTONIC, &outFramePos, &outTimeNs);
    m.outputLatencyMs = (outResult == oboe::Result::OK)
        ? static_cast<double>(outTimeNs - nowNs) / 1.0e6
        : -1.0;

    // ─── Latencia teórica del bloque DSP ───────────────────────────────
    // dspBlockMs = framesPerBlock / sampleRate * 1000.
    // Usamos el `outputFramesPerBurst` porque el callback en
    // FullDuplexStream es disparado por el output stream (mismo criterio
    // que el cálculo de `blockTimeMs` en `start()`).
    if (m.sampleRate > 0 && m.outputFramesPerBurst > 0) {
        m.dspBlockMs = static_cast<double>(m.outputFramesPerBurst) /
                       static_cast<double>(m.sampleRate) * 1000.0;
    } else {
        m.dspBlockMs = 0.0;
    }

    // ─── DSP processing ring buffer (avg + max, µs → ms) ───────────────
    // Ring de 50 slots; lectura relaxed de cada slot, suma y máximo,
    // conversión a ms al final. Si todos los slots son 0 (todavía no
    // hubo callbacks), avg = max = 0 ms.
    {
        uint64_t sumUs = 0;
        uint32_t maxUs = 0;
        for (int i = 0; i < kDspTimingRingSize; ++i) {
            uint32_t v = dspTimingRing_[i].load(std::memory_order_relaxed);
            sumUs += v;
            if (v > maxUs) maxUs = v;
        }
        m.dspProcessingMsAvg =
            static_cast<double>(sumUs) /
            static_cast<double>(kDspTimingRingSize) / 1000.0;
        m.dspProcessingMsMax = static_cast<double>(maxUs) / 1000.0;
    }

    // ─── DNN denoiser ───────────────────────────────────────────────────
    // Inferencia en µs → ms. Si el DNN está en bypass este valor refleja
    // la última inferencia válida o 0 si nunca corrió.
    m.dnnInferenceMs = static_cast<double>(dnnDenoiser_.getLastInferenceUs())
                       / 1000.0;
    // Group delay del resampler (~1.5 ms) sólo si el DNN procesa audio
    // (active=true). Si está en bypass, no introduce delay.
    m.dnnGroupDelayMs = dnnDenoiser_.isActive() ? kDnnGroupDelayMsActive : 0.0;

    // ─── Estado de salud ───────────────────────────────────────────────
    // `getXRunCount()` retorna `ResultWithValue<int32_t>`; si la API no
    // está disponible (OpenSL ES en algunos devices) tomamos 0.
    auto xrunRes = outputStream_->getXRunCount();
    m.callbackUnderruns = xrunRes ? xrunRes.value() : 0;
    m.timestampsHealthy = areTimestampsHealthy();

    return m;
}

void AudioEngine::setAmbientMute(bool muted) {
    // Idempotente y lock-free: el callback lee este flag con `load(relaxed)`
    // antes de procesar el pipeline DSP del audio ambiente (mic).
    ambientMuted_.store(muted, std::memory_order_relaxed);
}

bool AudioEngine::areTimestampsHealthy() const {
    // Se considera "saludable" si vimos un getTimestamp() OK en los
    // últimos 3 segundos. Si nunca se observó (lastNs == 0), reportamos
    // false: los streams todavía no se establecieron lo suficiente.
    const int64_t lastNs = lastSuccessfulTimestampNs_.load(
        std::memory_order_relaxed);
    if (lastNs == 0) return false;

    const int64_t nowNs = readMonotonicNs();
    constexpr int64_t kHealthyWindowNs = 3'000'000'000LL; // 3 s
    return (nowNs - lastNs) < kHealthyWindowNs;
}

// ─────────────────────────────────────────────────────────────────────────────
// Latency Loopback Test — wrappers públicos
// (spec monitor-latencia-audio, task 4.3 — Requirements 5.1, 5.12, 5.13,
//  8.5, 8.6)
//
// Estos wrappers son la API que ve `native_bridge.cpp` (JNI). Coordinan el
// `LatencyLoopbackTester` con el flag de mute ambiente del motor para que:
//   1. El pipeline DSP del mic NO contamine la captura del chirp
//      (`setAmbientMute(true)` antes de `start()`).
//   2. Cuando el test termina (o se cancela), el ambiente vuelva a oírse
//      automáticamente sin que el caller tenga que recordar el mute.
//
// Secuencia normal:
//   startLoopbackTest()  → prepare() → setAmbientMute(true) → start()
//   [callback de audio]  → onAudioCallback() emite chirp y captura
//   isLoopbackTestActive()  → polling desde Kotlin
//   getLoopbackTestResult() → setAmbientMute(false) y retorna LoopbackResult
//
// Secuencia con cancelación:
//   cancelLoopbackTest() → tester.cancel() + setAmbientMute(false)
// ─────────────────────────────────────────────────────────────────────────────

bool AudioEngine::startLoopbackTest(const latency_monitor::LoopbackParams& params) {
    if (!loopbackTester_) {
        LOGW("startLoopbackTest: tester not initialized");
        return false;
    }

    // ─── Prepare: genera chirp y aloca buffers ─────────────────────────
    if (!loopbackTester_->prepare(params)) {
        LOGW("startLoopbackTest: prepare() failed (params inválidos o "
             "captura > 10 s)");
        return false;
    }

    // ─── Mute ambiente ─────────────────────────────────────────────────
    // Detiene el pipeline DSP del mic para no contaminar la captura del
    // chirp. El tester se encarga de poblar input/output desde el callback
    // (vía el hook en onBothStreamsReady, task 4.2).
    setAmbientMute(true);

    // ─── Start: transición ARMED → EMITTING ────────────────────────────
    if (!loopbackTester_->start()) {
        // Revertir el mute si el start falló para no dejar al motor
        // "mudo" en caso de error de transición de estados.
        setAmbientMute(false);
        LOGW("startLoopbackTest: tester->start() failed; mute reverted");
        return false;
    }

    LOGI("startLoopbackTest: armed and emitting (sampleRate=%d, "
         "chirpDuration=%d samples, capture=%d samples)",
         params.sampleRate, params.chirpDurationSamples,
         params.captureDurationSamples);
    return true;
}

bool AudioEngine::isLoopbackTestActive() const {
    return loopbackTester_ && loopbackTester_->isActive();
}

latency_monitor::LoopbackResult AudioEngine::getLoopbackTestResult() {
    latency_monitor::LoopbackResult result{};

    // ─── Tester no inicializado ────────────────────────────────────────
    if (!loopbackTester_) {
        result.success       = false;
        result.lowConfidence = true;
        result.lagSamples    = -1;
        result.latencyMs     = std::nan("");
        std::strncpy(result.errorMessage, "tester not initialized",
                     sizeof(result.errorMessage) - 1);
        result.errorMessage[sizeof(result.errorMessage) - 1] = '\0';
        return result;
    }

    // ─── Test todavía corriendo ────────────────────────────────────────
    // El caller (Kotlin) hace polling con `isLoopbackTestActive()` y solo
    // debería invocar este getter cuando el polling devuelve false. Aún
    // así, defensivamente devolvemos un result con `errorMessage="not
    // finished"` en lugar de bloquear o devolver basura, y NO desmuteamos
    // el ambiente (el test sigue en curso).
    if (loopbackTester_->isActive()) {
        result.success       = false;
        result.lowConfidence = true;
        result.lagSamples    = -1;
        result.latencyMs     = std::nan("");
        std::strncpy(result.errorMessage, "not finished",
                     sizeof(result.errorMessage) - 1);
        result.errorMessage[sizeof(result.errorMessage) - 1] = '\0';
        return result;
    }

    // ─── Test terminó: restaurar audio ambiente y retornar resultado ──
    setAmbientMute(false);
    return loopbackTester_->getResult();
}

void AudioEngine::cancelLoopbackTest() {
    // Idempotente: si no hay tester o ya está IDLE, igual desmuteamos por
    // si quedó algún flag en true por una secuencia anómala.
    if (loopbackTester_) {
        loopbackTester_->cancel();
    }
    setAmbientMute(false);
}

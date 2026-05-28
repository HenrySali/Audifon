/// @file native_bridge.cpp
/// @brief Puente JNI entre Kotlin (NativeAudioBridge) y el AudioEngine C++.
///
/// Funciones expuestas:
/// - nativeStart: Inicializa el AudioEngine con configuración completa
/// - nativeStop: Detiene y libera recursos del AudioEngine
/// - nativeSetEqGains: Actualiza ganancias EQ (12 bandas, thread-safe)
/// - nativeSetVolume: Actualiza volumen maestro (thread-safe)
/// - nativeSetWdrcParams: Actualiza parámetros WDRC (thread-safe)
/// - nativeSetNrLevel: Actualiza nivel de reducción de ruido (thread-safe)
/// - nativeSetSplOffset: Actualiza offset de calibración SPL (thread-safe)
/// - nativeGetInputLevel: Lee último nivel de entrada PRE-EQ (polling ~10 Hz)
///
/// El AudioEngine encapsula Oboe FullDuplexStream (captura + reproducción) y el DspPipeline.
/// Todas las actualizaciones de parámetros son lock-free (atómicas).
/// El nivel de entrada se obtiene por polling desde Kotlin (no callback).

#include <jni.h>
#include <android/log.h>
#include <atomic>
#include <memory>

#include "audio_engine.h"

// ─────────────────────────────────────────────────────────────────────────────
// Logging
// ─────────────────────────────────────────────────────────────────────────────

#define LOG_TAG "NativeAudioBridge"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ─────────────────────────────────────────────────────────────────────────────
// Estado global del AudioEngine (singleton — una sola instancia de audio activa)
// ─────────────────────────────────────────────────────────────────────────────

namespace {

/// AudioEngine — propiedad del puente JNI.
/// Se crea en nativeStart y se destruye en nativeStop.
/// Encapsula Oboe FullDuplexStream (captura mic + reproducción auriculares) + DspPipeline.
std::unique_ptr<AudioEngine> g_engine;

/// Flag atómico que indica si el engine está activo.
std::atomic<bool> g_running{false};

} // namespace anónimo

// ─────────────────────────────────────────────────────────────────────────────
// Funciones JNI
// ─────────────────────────────────────────────────────────────────────────────

extern "C" {

/// Inicializa el AudioEngine (OpenSL ES + DSP pipeline) con la configuración completa.
///
/// @param sampleRate Frecuencia de muestreo (típicamente 16000 Hz)
/// @param bufferSize Tamaño de bloque en muestras (típicamente 64)
/// @param eqGains Array de 12 ganancias EQ en dB [0, 50]
/// @param volumeDb Volumen maestro en dB [-20, +10]
/// @param expansionKnee Knee de expansión WDRC en dB SPL
/// @param expansionRatio Ratio de expansión (input:output)
/// @param compressionKnee Knee de compresión WDRC en dB SPL
/// @param compressionRatio Ratio de compresión (input:output)
/// @param attackMs Tiempo de ataque WDRC en ms
/// @param releaseMs Tiempo de liberación WDRC en ms
/// @param nrLevel Nivel de reducción de ruido (0=off, 1=bajo, 2=medio, 3=alto)
/// @param mpoThresholdDbSpl Threshold del MPO en dB SPL
/// @param splOffset Offset de calibración dBFS → dB SPL
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeStart(
        JNIEnv* env,
        jobject /* thiz */,
        jint sampleRate,
        jint bufferSize,
        jfloatArray eqGains,
        jfloat volumeDb,
        jfloat expansionKnee,
        jfloat expansionRatio,
        jfloat compressionKnee,
        jfloat compressionRatio,
        jfloat attackMs,
        jfloat releaseMs,
        jint nrLevel,
        jfloat mpoThresholdDbSpl,
        jfloat splOffset) {

    // Evitar doble inicialización
    if (g_running.load(std::memory_order_acquire)) {
        LOGW("nativeStart called while already running — ignoring");
        return;
    }

    LOGI("nativeStart: sampleRate=%d, bufferSize=%d, volume=%.1f dB, NR=%d, MPO=%.1f dB SPL",
         sampleRate, bufferSize, volumeDb, nrLevel, mpoThresholdDbSpl);

    // Crear AudioEngine (encapsula OpenSL ES + DspPipeline)
    g_engine = std::make_unique<AudioEngine>();

    // Configurar AudioEngineConfig
    AudioEngineConfig engineConfig;
    engineConfig.sampleRate = sampleRate;
    engineConfig.bufferSize = bufferSize;
    engineConfig.channels = 1;
    engineConfig.mpoThresholdDbSpl = mpoThresholdDbSpl;
    engineConfig.splOffset = splOffset;

    // Iniciar el AudioEngine (crea Oboe streams + hilo de audio)
    if (!g_engine->start(engineConfig)) {
        LOGE("nativeStart: AudioEngine failed to start!");
        g_engine.reset();
        return;
    }

    // Aplicar ganancias EQ iniciales
    if (eqGains != nullptr) {
        jsize len = env->GetArrayLength(eqGains);
        if (len >= 12) {
            jfloat* gains = env->GetFloatArrayElements(eqGains, nullptr);
            if (gains != nullptr) {
                g_engine->setEqGains(gains);
                env->ReleaseFloatArrayElements(eqGains, gains, JNI_ABORT);
            }
        } else {
            LOGW("nativeStart: eqGains array length %d < 12, using defaults", len);
        }
    }

    // Aplicar volumen inicial
    g_engine->setVolume(volumeDb);

    // Aplicar parámetros WDRC iniciales
    WdrcParams wdrcParams;
    wdrcParams.expansionKnee = expansionKnee;
    wdrcParams.expansionRatio = expansionRatio;
    wdrcParams.compressionKnee = compressionKnee;
    wdrcParams.compressionRatio = compressionRatio;
    wdrcParams.attackMs = attackMs;
    wdrcParams.releaseMs = releaseMs;
    g_engine->setWdrcParams(wdrcParams);

    // Aplicar nivel de NR
    g_engine->setNrLevel(nrLevel);

    // Marcar como activo
    g_running.store(true, std::memory_order_release);

    LOGI("nativeStart: AudioEngine started successfully (Oboe active)");
}

/// Detiene el AudioEngine y libera recursos.
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeStop(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire)) {
        LOGW("nativeStop called while not running — ignoring");
        return;
    }

    LOGI("nativeStop: Stopping AudioEngine");

    // Marcar como inactivo primero
    g_running.store(false, std::memory_order_release);

    // Detener y destruir AudioEngine (para Oboe streams, pipeline)
    if (g_engine) {
        g_engine->stop();
        g_engine.reset();
    }

    LOGI("nativeStop: AudioEngine stopped and resources released");
}

/// Actualiza las ganancias del EQ (12 bandas, en dB, rango [0, 50]).
/// Thread-safe: usa intercambio atómico interno del Equalizer.
///
/// @param gains Array de 12 valores float (ganancias en dB por banda)
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetEqGains(
        JNIEnv* env,
        jobject /* thiz */,
        jfloatArray gains) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }

    if (gains == nullptr) {
        LOGW("nativeSetEqGains: null gains array");
        return;
    }

    jsize len = env->GetArrayLength(gains);
    if (len < 12) {
        LOGW("nativeSetEqGains: array length %d < 12", len);
        return;
    }

    jfloat* gainsPtr = env->GetFloatArrayElements(gains, nullptr);
    if (gainsPtr != nullptr) {
        g_engine->setEqGains(gainsPtr);
        env->ReleaseFloatArrayElements(gains, gainsPtr, JNI_ABORT);
    }
}

/// Actualiza el volumen maestro en dB (rango [-20, +10]).
/// Thread-safe: usa std::atomic internamente.
///
/// @param volumeDb Volumen en dB
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetVolume(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jfloat volumeDb) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }

    g_engine->setVolume(volumeDb);
}

/// Actualiza parámetros del WDRC (Wide Dynamic Range Compression).
/// Thread-safe: cada parámetro usa std::atomic internamente.
///
/// @param expKnee Knee de expansión (dB SPL)
/// @param expRatio Ratio de expansión (input:output)
/// @param compKnee Knee de compresión (dB SPL)
/// @param compRatio Ratio de compresión (input:output)
/// @param attackMs Tiempo de ataque (ms)
/// @param releaseMs Tiempo de liberación (ms)
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetWdrcParams(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jfloat expKnee,
        jfloat expRatio,
        jfloat compKnee,
        jfloat compRatio,
        jfloat attackMs,
        jfloat releaseMs) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }

    WdrcParams params;
    params.expansionKnee = expKnee;
    params.expansionRatio = expRatio;
    params.compressionKnee = compKnee;
    params.compressionRatio = compRatio;
    params.attackMs = attackMs;
    params.releaseMs = releaseMs;

    g_engine->setWdrcParams(params);
}

/// Actualiza el nivel de reducción de ruido.
/// Thread-safe: usa std::atomic internamente.
///
/// @param level 0=off, 1=bajo, 2=medio, 3=alto
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetNrLevel(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jint level) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }

    g_engine->setNrLevel(level);
}

/// Actualiza el offset de calibración SPL (dBFS → dB SPL).
/// Thread-safe: usa std::atomic internamente.
///
/// @param offset Offset en dB (120 para mic real, 76 para WAV)
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetSplOffset(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jfloat offset) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }

    g_engine->setSplOffset(offset);
}

/// Obtiene el último nivel de entrada medido PRE-EQ (dB SPL).
/// Diseñado para ser llamado por polling desde Kotlin (~10 Hz).
/// Thread-safe: lee un std::atomic<float>.
///
/// @return Nivel de entrada en dB SPL, o 0.0 si el engine no está activo
JNIEXPORT jfloat JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetInputLevel(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return 0.0f;
    }

    return g_engine->getLastInputLevel();
}

/// Obtiene el device ID del stream de entrada (micrófono).
/// @return Device ID del input stream, o -1 si no está activo
JNIEXPORT jint JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetInputDeviceId(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return -1;
    }

    return g_engine->getInputDeviceId();
}

/// Obtiene el device ID del stream de salida (auricular/parlante).
/// @return Device ID del output stream, o -1 si no está activo
JNIEXPORT jint JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetOutputDeviceId(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return -1;
    }

    return g_engine->getOutputDeviceId();
}

/// Habilita/deshabilita la clasificación automática de entorno.
/// Cuando está habilitada, NR y WDRC se ajustan automáticamente según el entorno.
/// Habilitado por defecto (crítico para usuarios pediátricos).
///
/// @param enabled true para habilitar, false para deshabilitar
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetAutoClassifyEnabled(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jboolean enabled) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }

    g_engine->setAutoClassifyEnabled(static_cast<bool>(enabled));
}

/// Obtiene la clase de entorno actual detectada por el clasificador automático.
/// Thread-safe: lee un std::atomic<int>.
///
/// @return 0=QUIET, 1=SPEECH, 2=SPEECH_IN_NOISE, 3=NOISE, o -1 si no activo
JNIEXPORT jint JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetCurrentEnvironmentClass(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return -1;
    }

    return g_engine->getCurrentEnvironmentClass();
}

// ─────────────────────────────────────────────────────────────────────────────
// Spectrum Analyzer JNI Functions
// ─────────────────────────────────────────────────────────────────────────────

/// Inicia el análisis de espectro (activa computación FFT en cada bloque).
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeStartSpectrumAnalysis(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }

    g_engine->startSpectrumAnalysis();
}

/// Detiene el análisis de espectro (ahorra CPU cuando la pantalla no es visible).
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeStopSpectrumAnalysis(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }

    g_engine->stopSpectrumAnalysis();
}

/// Inicia la grabación de snapshots de espectro (máximo 3 minutos / 1800 snapshots).
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeStartSpectrumRecording(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }

    g_engine->startSpectrumRecording();
}

/// Detiene la grabación de espectro y retorna el número de snapshots capturados.
JNIEXPORT jint JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeStopSpectrumRecording(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return 0;
    }

    return g_engine->stopSpectrumRecording();
}

/// Retorna todos los snapshots grabados como byte array.
/// El tamaño es count * sizeof(SpectrumSnapshot).
JNIEXPORT jbyteArray JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetRecordingData(
        JNIEnv* env,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return env->NewByteArray(0);
    }

    const SpectrumSnapshot* snapshots = g_engine->getRecordedSnapshots();
    int size = g_engine->getRecordedDataSize();

    if (snapshots == nullptr || size <= 0) {
        return env->NewByteArray(0);
    }

    jbyteArray result = env->NewByteArray(size);
    if (result != nullptr) {
        env->SetByteArrayRegion(result, 0, size,
                                reinterpret_cast<const jbyte*>(snapshots));
    }
    return result;
}

/// Retorna el snapshot de espectro actual como byte array (para polling a 10 Hz).
JNIEXPORT jbyteArray JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetCurrentSpectrum(
        JNIEnv* env,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return env->NewByteArray(0);
    }

    SpectrumSnapshot snapshot = g_engine->getCurrentSpectrum();
    int size = static_cast<int>(sizeof(SpectrumSnapshot));

    jbyteArray result = env->NewByteArray(size);
    if (result != nullptr) {
        env->SetByteArrayRegion(result, 0, size,
                                reinterpret_cast<const jbyte*>(&snapshot));
    }
    return result;
}

} // extern "C"

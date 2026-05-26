/// @file native_bridge.cpp
/// @brief Puente JNI entre Kotlin (NativeAudioBridge) y el pipeline DSP C++.
///
/// Funciones expuestas:
/// - nativeStart: Inicializa el pipeline con configuración completa
/// - nativeStop: Detiene y libera recursos del pipeline
/// - nativeSetEqGains: Actualiza ganancias EQ (12 bandas, thread-safe)
/// - nativeSetVolume: Actualiza volumen maestro (thread-safe)
/// - nativeSetWdrcParams: Actualiza parámetros WDRC (thread-safe)
/// - nativeSetNrLevel: Actualiza nivel de reducción de ruido (thread-safe)
/// - nativeSetSplOffset: Actualiza offset de calibración SPL (thread-safe)
/// - nativeGetInputLevel: Lee último nivel de entrada PRE-EQ (polling ~10 Hz)
///
/// Todas las actualizaciones de parámetros son lock-free (atómicas).
/// El nivel de entrada se obtiene por polling desde Kotlin (no callback).

#include <jni.h>
#include <android/log.h>
#include <atomic>
#include <memory>

#include "dsp_pipeline.h"

// ─────────────────────────────────────────────────────────────────────────────
// Logging
// ─────────────────────────────────────────────────────────────────────────────

#define LOG_TAG "NativeAudioBridge"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ─────────────────────────────────────────────────────────────────────────────
// Estado global del pipeline (singleton — una sola instancia de audio activa)
// ─────────────────────────────────────────────────────────────────────────────

namespace {

/// Pipeline DSP — propiedad del puente JNI.
/// Se crea en nativeStart y se destruye en nativeStop.
std::unique_ptr<DspPipeline> g_pipeline;

/// Flag atómico que indica si el pipeline está activo.
std::atomic<bool> g_running{false};

} // namespace anónimo

// ─────────────────────────────────────────────────────────────────────────────
// Funciones JNI
// ─────────────────────────────────────────────────────────────────────────────

extern "C" {

/// Inicializa el pipeline DSP con la configuración completa.
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

    // Crear pipeline
    g_pipeline = std::make_unique<DspPipeline>();

    // Configurar AudioConfig
    AudioConfig config;
    config.sampleRate = sampleRate;
    config.bufferSize = bufferSize;
    config.channels = 1;
    config.bitsPerSample = 16;
    config.mpoThresholdDbSpl = mpoThresholdDbSpl;
    config.splOffset = splOffset;

    // Inicializar pipeline
    g_pipeline->init(config);

    // Aplicar ganancias EQ iniciales
    if (eqGains != nullptr) {
        jsize len = env->GetArrayLength(eqGains);
        if (len >= 12) {
            jfloat* gains = env->GetFloatArrayElements(eqGains, nullptr);
            if (gains != nullptr) {
                g_pipeline->setEqGains(gains);
                env->ReleaseFloatArrayElements(eqGains, gains, JNI_ABORT);
            }
        } else {
            LOGW("nativeStart: eqGains array length %d < 12, using defaults", len);
        }
    }

    // Aplicar volumen inicial
    g_pipeline->setVolume(volumeDb);

    // Aplicar parámetros WDRC iniciales
    WdrcParams wdrcParams;
    wdrcParams.expansionKnee = expansionKnee;
    wdrcParams.expansionRatio = expansionRatio;
    wdrcParams.compressionKnee = compressionKnee;
    wdrcParams.compressionRatio = compressionRatio;
    wdrcParams.attackMs = attackMs;
    wdrcParams.releaseMs = releaseMs;
    g_pipeline->setWdrcParams(wdrcParams);

    // Aplicar nivel de NR
    g_pipeline->setNrLevel(nrLevel);

    // Marcar como activo
    g_running.store(true, std::memory_order_release);

    LOGI("nativeStart: Pipeline initialized successfully");
}

/// Detiene el pipeline y libera recursos.
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeStop(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire)) {
        LOGW("nativeStop called while not running — ignoring");
        return;
    }

    LOGI("nativeStop: Stopping pipeline");

    // Marcar como inactivo primero (el hilo de audio dejará de procesar)
    g_running.store(false, std::memory_order_release);

    // Destruir pipeline
    g_pipeline.reset();

    LOGI("nativeStop: Pipeline stopped and resources released");
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

    if (!g_running.load(std::memory_order_acquire) || g_pipeline == nullptr) {
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
        g_pipeline->setEqGains(gainsPtr);
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

    if (!g_running.load(std::memory_order_acquire) || g_pipeline == nullptr) {
        return;
    }

    g_pipeline->setVolume(volumeDb);
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

    if (!g_running.load(std::memory_order_acquire) || g_pipeline == nullptr) {
        return;
    }

    WdrcParams params;
    params.expansionKnee = expKnee;
    params.expansionRatio = expRatio;
    params.compressionKnee = compKnee;
    params.compressionRatio = compRatio;
    params.attackMs = attackMs;
    params.releaseMs = releaseMs;

    g_pipeline->setWdrcParams(params);
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

    if (!g_running.load(std::memory_order_acquire) || g_pipeline == nullptr) {
        return;
    }

    g_pipeline->setNrLevel(level);
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

    if (!g_running.load(std::memory_order_acquire) || g_pipeline == nullptr) {
        return;
    }

    g_pipeline->setSplOffset(offset);
}

/// Obtiene el último nivel de entrada medido PRE-EQ (dB SPL).
/// Diseñado para ser llamado por polling desde Kotlin (~10 Hz).
/// Thread-safe: lee un std::atomic<float>.
///
/// @return Nivel de entrada en dB SPL, o 0.0 si el pipeline no está activo
JNIEXPORT jfloat JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetInputLevel(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_pipeline == nullptr) {
        return 0.0f;
    }

    return g_pipeline->getLastInputLevelDb();
}

// ─────────────────────────────────────────────────────────────────────────────
// Funciones auxiliares para el AudioEngine (usadas por tarea 5.1)
// ─────────────────────────────────────────────────────────────────────────────

/// Verifica si el pipeline está activo (para uso del hilo de audio).
/// @return true si el pipeline está inicializado y corriendo
bool nativeBridge_isRunning() {
    return g_running.load(std::memory_order_acquire);
}

/// Obtiene puntero al pipeline para procesamiento de audio.
/// Solo debe llamarse desde el hilo de audio cuando isRunning() == true.
/// @return Puntero al DspPipeline activo, o nullptr si no está corriendo
DspPipeline* nativeBridge_getPipeline() {
    if (!g_running.load(std::memory_order_acquire)) {
        return nullptr;
    }
    return g_pipeline.get();
}

} // extern "C"

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
#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <atomic>
#include <cmath>
#include <memory>

#include "audio_engine.h"
#include "calibration_spectrum/tone_types.h"
#include "latency_loopback_tester.h"

#include <string>

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

/// Flag del "Modo Conversación" (SCO + baja latencia). Lo setea
/// `nativeSetConversationMode` ANTES de `nativeStart`, y `nativeStart` lo
/// copia a `AudioEngineConfig.conversationMode` para que los streams Oboe
/// se abran con Usage::VoiceCommunication (ruteo al canal SCO). Spec:
/// modo-conversacion-sco.
std::atomic<bool> g_conversationMode{false};

/// Flag de beamforming dual-mic. Lo setea `nativeSetBeamformingMode`
/// ANTES de `nativeStart`, y `nativeStart` lo copia a
/// `AudioEngineConfig.beamformingEnabled` para que el input stream se
/// abra en estéreo (2 canales) y el MVDR beamformer se active.
std::atomic<bool> g_beamformingEnabled{false};

} // namespace anónimo

// ─────────────────────────────────────────────────────────────────────────────
// JNI helpers — conversiones de structs C++ a java.util.HashMap<String, Object>
// ─────────────────────────────────────────────────────────────────────────────
//
// Estos helpers se usan desde las funciones JNI nativeGetLatencyMetrics y
// nativeGetLoopbackTestResult para construir el Map que MethodChannel
// transporta al lado Dart. Las claves siguen los nombres documentados en
// `design.md` sección "Modelo de datos cruzando capas" y deben coincidir
// EXACTAMENTE con los nombres consumidos por LatencyMetrics.fromMap y
// LoopbackResult.fromMap del lado Dart.
//
// Sentinelas:
// - LatencyMetrics: inputLatencyMs/outputLatencyMs == -1 → null Java
//   (significa "Oboe getTimestamp() todavía no disponible")
// - LoopbackResult: latencyMs == NaN → null Java
//   (significa "test no detectó el chirp con confianza suficiente")

namespace {

/// Boxea un int32_t en java.lang.Integer.
[[maybe_unused]] jobject boxInt(JNIEnv* env, int32_t v) {
    jclass cls = env->FindClass("java/lang/Integer");
    jmethodID ctor = env->GetMethodID(cls, "<init>", "(I)V");
    jobject obj = env->NewObject(cls, ctor, static_cast<jint>(v));
    env->DeleteLocalRef(cls);
    return obj;
}

/// Boxea un int64_t en java.lang.Long.
[[maybe_unused]] jobject boxLong(JNIEnv* env, int64_t v) {
    jclass cls = env->FindClass("java/lang/Long");
    jmethodID ctor = env->GetMethodID(cls, "<init>", "(J)V");
    jobject obj = env->NewObject(cls, ctor, static_cast<jlong>(v));
    env->DeleteLocalRef(cls);
    return obj;
}

/// Boxea un double en java.lang.Double.
[[maybe_unused]] jobject boxDouble(JNIEnv* env, double v) {
    jclass cls = env->FindClass("java/lang/Double");
    jmethodID ctor = env->GetMethodID(cls, "<init>", "(D)V");
    jobject obj = env->NewObject(cls, ctor, static_cast<jdouble>(v));
    env->DeleteLocalRef(cls);
    return obj;
}

/// Boxea un bool en java.lang.Boolean.
[[maybe_unused]] jobject boxBool(JNIEnv* env, bool v) {
    jclass cls = env->FindClass("java/lang/Boolean");
    jmethodID ctor = env->GetMethodID(cls, "<init>", "(Z)V");
    jobject obj = env->NewObject(cls, ctor, v ? JNI_TRUE : JNI_FALSE);
    env->DeleteLocalRef(cls);
    return obj;
}

/// Inserta (key, value) en un HashMap. `value` puede ser nullptr (representa
/// null Java). Libera las referencias locales de la key y del value tras
/// la inserción para evitar agotar la tabla local de referencias JNI.
[[maybe_unused]] void putKv(JNIEnv* env, jobject map, jmethodID putMethod,
                            const char* key, jobject value) {
    jstring jkey = env->NewStringUTF(key);
    env->CallObjectMethod(map, putMethod, jkey, value);
    env->DeleteLocalRef(jkey);
    if (value != nullptr) {
        env->DeleteLocalRef(value);
    }
}

/// Construye un java.util.HashMap a partir de LatencyMetrics.
///
/// Las claves siguen los nombres documentados en design.md:
///   sampleRate, inputFramesPerBurst, outputFramesPerBurst,
///   outputBufferSizeFrames, inputAudioApi, outputAudioApi,
///   inputSharingMode, outputSharingMode, outputPerformanceMode,
///   inputLatencyMs, outputLatencyMs, dspBlockMs, dspProcessingMsAvg,
///   dspProcessingMsMax, dnnInferenceMs, dnnGroupDelayMs, tnrLookaheadMs,
///   callbackUnderruns, timestampsHealthy, schemaVersion.
///
/// Convierte `inputLatencyMs == -1` y `outputLatencyMs == -1` en null Java
/// (no en Double(-1.0)). El resto de los floating-points siempre se boxean
/// como Double para que Dart vea `Double` consistentemente.
[[maybe_unused]] jobject latencyMetricsToJavaMap(JNIEnv* env,
                                                 const LatencyMetrics& m) {
    jclass hashMapCls = env->FindClass("java/util/HashMap");
    jmethodID ctor = env->GetMethodID(hashMapCls, "<init>", "()V");
    jmethodID put  = env->GetMethodID(hashMapCls, "put",
        "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
    jobject map = env->NewObject(hashMapCls, ctor);

    // Configuración del stream
    putKv(env, map, put, "sampleRate",             boxInt(env, m.sampleRate));
    putKv(env, map, put, "inputFramesPerBurst",    boxInt(env, m.inputFramesPerBurst));
    putKv(env, map, put, "outputFramesPerBurst",   boxInt(env, m.outputFramesPerBurst));
    putKv(env, map, put, "outputBufferSizeFrames", boxInt(env, m.outputBufferSizeFrames));
    putKv(env, map, put, "inputAudioApi",          boxInt(env, m.inputAudioApi));
    putKv(env, map, put, "outputAudioApi",         boxInt(env, m.outputAudioApi));
    putKv(env, map, put, "inputSharingMode",       boxInt(env, m.inputSharingMode));
    putKv(env, map, put, "outputSharingMode",      boxInt(env, m.outputSharingMode));
    putKv(env, map, put, "outputPerformanceMode",  boxInt(env, m.outputPerformanceMode));

    // Latencias por etapa: -1 → null, resto → Double
    jobject inputLat  = (m.inputLatencyMs  == -1.0) ? nullptr : boxDouble(env, m.inputLatencyMs);
    jobject outputLat = (m.outputLatencyMs == -1.0) ? nullptr : boxDouble(env, m.outputLatencyMs);
    putKv(env, map, put, "inputLatencyMs",  inputLat);
    putKv(env, map, put, "outputLatencyMs", outputLat);
    putKv(env, map, put, "dspBlockMs",         boxDouble(env, m.dspBlockMs));
    putKv(env, map, put, "dspProcessingMsAvg", boxDouble(env, m.dspProcessingMsAvg));
    putKv(env, map, put, "dspProcessingMsMax", boxDouble(env, m.dspProcessingMsMax));
    putKv(env, map, put, "dnnInferenceMs",     boxDouble(env, m.dnnInferenceMs));
    putKv(env, map, put, "dnnGroupDelayMs",    boxDouble(env, m.dnnGroupDelayMs));
    putKv(env, map, put, "tnrLookaheadMs",     boxDouble(env, m.tnrLookaheadMs));

    // Estado de salud + versionado
    putKv(env, map, put, "callbackUnderruns", boxInt(env, m.callbackUnderruns));
    putKv(env, map, put, "timestampsHealthy", boxBool(env, m.timestampsHealthy));
    putKv(env, map, put, "schemaVersion",     boxInt(env, m.schemaVersion));

    env->DeleteLocalRef(hashMapCls);
    return map;
}

/// Construye un java.util.HashMap a partir de LoopbackResult.
///
/// Las claves siguen los nombres documentados en design.md:
///   success, lowConfidence, lagSamples, latencyMs, normalizedPeak,
///   emissionTimestampNs, completionTimestampNs, errorMessage, schemaVersion.
///
/// Convierte `latencyMs == NaN` en null Java (caso lowConfidence=true). El
/// struct C++ no tiene `schemaVersion`; se asigna fijo a 1 en este helper
/// para mantener la convención de versionado del Map en Dart.
[[maybe_unused]] jobject loopbackResultToJavaMap(JNIEnv* env,
                                                 const latency_monitor::LoopbackResult& r) {
    jclass hashMapCls = env->FindClass("java/util/HashMap");
    jmethodID ctor = env->GetMethodID(hashMapCls, "<init>", "()V");
    jmethodID put  = env->GetMethodID(hashMapCls, "put",
        "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
    jobject map = env->NewObject(hashMapCls, ctor);

    putKv(env, map, put, "success",       boxBool(env, r.success));
    putKv(env, map, put, "lowConfidence", boxBool(env, r.lowConfidence));
    putKv(env, map, put, "lagSamples",    boxInt(env, r.lagSamples));

    // latencyMs: NaN → null (lowConfidence), resto → Double
    jobject lat = std::isnan(r.latencyMs) ? nullptr : boxDouble(env, r.latencyMs);
    putKv(env, map, put, "latencyMs", lat);

    putKv(env, map, put, "normalizedPeak",        boxDouble(env, r.normalizedPeak));
    putKv(env, map, put, "emissionTimestampNs",   boxLong(env, r.emissionTimestampNs));
    putKv(env, map, put, "completionTimestampNs", boxLong(env, r.completionTimestampNs));

    // errorMessage: char[128] → String Java (NewStringUTF acepta C-string).
    // Se rutea por putKv usando jstring como jobject; putKv libera la ref local.
    putKv(env, map, put, "errorMessage", env->NewStringUTF(r.errorMessage));

    // schemaVersion no existe en el struct C++; lo asignamos fijo a 1 acá.
    putKv(env, map, put, "schemaVersion", boxInt(env, 1));

    env->DeleteLocalRef(hashMapCls);
    return map;
}

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
    // Modo Conversación: leído del flag global que setea
    // nativeSetConversationMode() antes de este start.
    engineConfig.conversationMode = g_conversationMode.load(std::memory_order_acquire);
    // Beamforming: leído del flag global que setea
    // nativeSetBeamformingMode() antes de este start.
    engineConfig.beamformingEnabled = g_beamformingEnabled.load(std::memory_order_acquire);

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

/// Configura el Expansor de baja frecuencia ≤1000 Hz (R1, tarea 4.3).
/// Downward expansion band-limitada. Default OFF/ratio 1.0 → passthrough
/// (R6.3). Thread-safe (atómicos internos).
///
/// @param enabled Toggle de activación (AC5).
/// @param kneeDbSpl Knee de expansión en dB SPL (AC1).
/// @param ratio Ratio de expansión, 1.0 = passthrough (AC4).
/// @param cutoffHz Frecuencia de corte superior (AC2).
/// @param attackMs Ataque (recuperación de ganancia) en ms (AC6, ≤50).
/// @param releaseMs Liberación (atenuación) en ms (AC4a).
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetExpander(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jboolean enabled,
        jfloat kneeDbSpl,
        jfloat ratio,
        jfloat cutoffHz,
        jfloat attackMs,
        jfloat releaseMs) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }

    g_engine->setExpanderParams(enabled == JNI_TRUE, kneeDbSpl, ratio,
                                cutoffHz, attackMs, releaseMs);
}

/// Configura el Supresor de reverberación tardía del MVDR (R5, tarea 5.2).
/// Los setters son no-op efectivos fuera del modo MVDR (el beamformer hace
/// bypass), pero el estado queda guardado. Default = comportamiento previo
/// (enabled=true, strength=1.6, floor=0.30, decay=0.80). Thread-safe.
///
/// @param enabled Toggle del dereverb (AC3).
/// @param strength Over-subtraction factor (AC2).
/// @param floor Suelo espectral (AC2/AC4).
/// @param decay Factor de decaimiento / RT60 proxy (AC1).
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetDereverb(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jboolean enabled,
        jfloat strength,
        jfloat floor,
        jfloat decay) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }

    g_engine->setDereverbParams(enabled == JNI_TRUE, strength, floor, decay);
}

/// Configura los umbrales del clasificador de entorno (R4, tarea 3.3).
/// Defaults = valores previos si Dart no envía (R6.5). Thread-safe.
///
/// @param speechEnterDb SNR (dB) para ENTRAR a SPEECH (default 6.0).
/// @param speechExitDb  SNR (dB) para SALIR de SPEECH  (default 4.0).
/// @param noiseSnrDb    SNR (dB) bajo el cual el entorno es NOISE (default 1.5).
/// @param quietEnterDbSpl Nivel (dB SPL) para ENTRAR a QUIET (default 44).
/// @param quietExitDbSpl  Nivel (dB SPL) para SALIR de QUIET  (default 49).
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetClassifierThresholds(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jfloat speechEnterDb,
        jfloat speechExitDb,
        jfloat noiseSnrDb,
        jfloat quietEnterDbSpl,
        jfloat quietExitDbSpl) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }

    g_engine->setClassifierThresholds(speechEnterDb, speechExitDb, noiseSnrDb,
                                      quietEnterDbSpl, quietExitDbSpl);
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

/// Habilita/deshabilita la clasificación automática de entorno.
/// Thread-safe: usa std::atomic internamente.
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

    g_engine->setAutoClassifyEnabled(enabled);
}

/// Aplica un preset completo del Smart Scene de forma atómica.
///
/// Fase G — applyScenePreset único: reemplaza 4+ llamadas separadas
/// (setEqGains + setWdrcParams + setNrLevel + setTnrEnabled +
/// setMpoThresholdDbSpl + setSmartPresetPinned) por una sola llamada
/// JNI. Esto elimina la ventana de ~6 callbacks MethodChannel donde
/// el clasificador automático podía pisar targets intermedios.
///
/// Args (como float array de 20 valores + 2 ints + 1 bool):
///   gains[0..11] → 12 ganancias EQ en dB
///   gains[12]    → expansionKnee
///   gains[13]    → expansionRatio
///   gains[14]    → compressionKnee
///   gains[15]    → compressionRatio
///   gains[16]    → attackMs
///   gains[17]    → releaseMs
///   gains[18]    → mpoThresholdDbSpl
/// @param nrLevel Nivel de NR [0, 3]
/// @param tnrEnabled 1=TNR ON, 0=TNR OFF
/// @param pinPreset 1=pin ON, 0=pin OFF
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeApplyScenePreset(
        JNIEnv* env,
        jobject /* thiz */,
        jfloatArray params,
        jint nrLevel,
        jboolean tnrEnabled,
        jboolean pinPreset) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }
    if (params == nullptr) {
        LOGW("nativeApplyScenePreset: null params array");
        return;
    }
    jsize len = env->GetArrayLength(params);
    if (len < 19) {
        LOGW("nativeApplyScenePreset: array length %d < 19", len);
        return;
    }

    jfloat* p = env->GetFloatArrayElements(params, nullptr);
    if (p == nullptr) return;

    ScenePreset preset;
    // gains[0..11]
    for (int i = 0; i < 12; ++i) {
        float g = p[i];
        if (g < 0.0f) g = 0.0f;
        if (g > 50.0f) g = 50.0f;
        preset.gains[i] = g;
    }
    preset.wdrc.expansionKnee     = p[12];
    preset.wdrc.expansionRatio    = p[13];
    preset.wdrc.compressionKnee   = p[14];
    preset.wdrc.compressionRatio  = p[15];
    preset.wdrc.attackMs          = p[16];
    preset.wdrc.releaseMs         = p[17];
    preset.mpoThresholdDbSpl      = p[18];
    preset.nrLevel                = nrLevel;
    preset.tnrEnabled             = (tnrEnabled == JNI_TRUE);
    preset.pinPreset              = (pinPreset == JNI_TRUE);

    env->ReleaseFloatArrayElements(params, p, JNI_ABORT);

    g_engine->applyScenePreset(preset);
    LOGI("nativeApplyScenePreset: applied (nrLevel=%d, tnr=%d, pin=%d)",
         nrLevel, tnrEnabled, pinPreset);
}

/// Pin del preset Smart Scene aplicado manualmente.
///
/// Cuando es true, el clasificador automático sigue corriendo y publica
/// la clase actual en `nativeGetCurrentEnvironmentClass()`, pero NO
/// machaca los targets del WDRC + NR cuando cambia la escena. El preset
/// Smart manual (NR + WDRC + EQ) se mantiene vigente hasta que la UI
/// libere el pin (false). Esto resuelve la Causa C documentada en
/// docs/smart-scene-diagnostico-chasquido.md.
///
/// Thread-safe: store atómico release en DspPipeline::smartPresetPinned_.
/// Si el motor no está activo (g_running=false) la llamada se ignora —
/// el siguiente nativeStart inicia con pin=false, y la UI puede volver a
/// llamar este setter después del start.
///
/// @param pinned true para fijar el preset manual, false para que el
///               clasificador automático vuelva a controlar WDRC + NR.
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetSmartPresetPinned(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jboolean pinned) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }

    g_engine->setSmartPresetPinned(pinned);
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

/// Actualiza el threshold del MPO (Maximum Power Output) en dB SPL.
/// Thread-safe: lock-free (usa std::atomic dentro del pipeline).
///
/// El motor convierte dB SPL → lineal usando el splOffset de calibración:
///   linear = pow(10, (thresholdDbSpl - splOffset) / 20)
/// y aplica el resultado al limitador MPO sin reiniciar el AudioEngine.
///
/// La validación clínica del rango [80, 132] dB SPL la hace el caller Dart
/// (AudioBridgeImpl). Aquí solo se filtran valores no-finitos.
///
/// Implementa Requirement 3 de la spec audiogram-driven-presets.
///
/// @param thresholdDbSpl Threshold en dB SPL (rango clínico [80, 132])
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetMpoThresholdDbSpl(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jfloat thresholdDbSpl) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }

    g_engine->setMpoThresholdDbSpl(thresholdDbSpl);
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

/// Establece el micrófono preferido para el stream de entrada.
/// Si deviceId == -1, restaura al default del sistema.
/// El cambio se aplica en caliente si el motor está corriendo (Oboe
/// setDeviceId on the fly); si no, se guarda para el próximo start.
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetPreferredInputDevice(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jint deviceId) {

    if (g_engine != nullptr) {
        g_engine->setPreferredInputDevice(deviceId);
    }
}

/// Obtiene el audio session ID del stream de entrada (para NoiseSuppressor Android).
/// Kotlin lo usa para crear NoiseSuppressor.create(sessionId).
/// @return Session ID (>0 si válido), o -1 si no está activo.
JNIEXPORT jint JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetInputSessionId(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return -1;
    }

    return g_engine->getInputSessionId();
}

/// Setea el flag del "Modo Conversación" (SCO + baja latencia).
///
/// IMPORTANTE: debe llamarse ANTES de `nativeStart` (o antes de reiniciar
/// el motor con stop+start). `nativeStart` copia este flag a
/// `AudioEngineConfig.conversationMode`, que decide si los streams Oboe se
/// abren con Usage::VoiceCommunication (ruteo SCO) o Usage::Media (A2DP).
///
/// Llamarlo con el motor ya corriendo NO cambia los streams en caliente:
/// el caller (handler Kotlin) debe hacer stop → setConversationMode → start.
///
/// Spec: modo-conversacion-sco.
///
/// @param enabled true para Modo Conversación (SCO), false para normal (A2DP).
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetConversationMode(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jboolean enabled) {

    g_conversationMode.store(enabled == JNI_TRUE, std::memory_order_release);
    LOGI("nativeSetConversationMode: %s", (enabled == JNI_TRUE) ? "ON" : "OFF");
}

/// Setea el flag de beamforming dual-mic (captura estéreo + MVDR).
///
/// IMPORTANTE: debe llamarse ANTES de `nativeStart` (o antes de reiniciar
/// el motor con stop+start). `nativeStart` copia este flag a
/// `AudioEngineConfig.beamformingEnabled`, que decide si el input stream
/// se abre con 2 canales (estéreo) o 1 canal (mono).
///
/// Llamarlo con el motor ya corriendo NO cambia el channelCount en caliente:
/// el caller (handler Kotlin) debe hacer stop → setBeamformingMode → start.
///
/// @param enabled true para captura estéreo + MVDR beamformer.
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetBeamformingMode(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jboolean enabled) {

    g_beamformingEnabled.store(enabled == JNI_TRUE, std::memory_order_release);
    LOGI("nativeSetBeamformingMode: %s", (enabled == JNI_TRUE) ? "ON" : "OFF");
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

/// Retorna métricas de todas las etapas del pipeline DSP como float array.
/// Orden: [inputLevel, postNrLevel, postEqLevel, postWdrcLevel, postVolumeLevel,
///         outputLevel, peakSample, clipCount, wdrcGainFactor, wdrcRegion,
///         eqMaxGain, environmentClass, preDnnLevelDb, wdrcUsesExternalLevel,
///         mpoLimitingFraction, mpoLimitingSustained]
/// Total: 16 floats.
///
/// Los dos últimos campos (mpoLimitingFraction, mpoLimitingSustained) se
/// agregaron en la spec audifono-v3 (task 10.2, decisión B — MPO clínico real)
/// para exponer a la app el aviso de limitación sostenida (Requirement 9.2):
///
///   - mpoLimitingFraction: fracción [0,1] de muestras del último bloque en
///     las que el MPO estuvo limitando.
///   - mpoLimitingSustained: 1.0f si la limitación fue sostenida (≥ ~200 ms
///     cuasi-continuos) en el último bloque, 0.0f si no.
///
/// Los campos previos (preDnnLevelDb, wdrcUsesExternalLevel) vienen de la spec
/// dsp-chain-optimization (task 4.4) para registrar el origen del nivel WDRC
/// y verificar el ratio efectivo de compresión (Property 8 del design).
///
///   - preDnnLevelDb: nivel pre-DNN en dB SPL pasado al WDRC (-1.0f si no
///     hay nivel externo y se midió localmente).
///   - wdrcUsesExternalLevel: 1.0f si el último processBlock usó nivel
///     externo (pre-DNN), 0.0f si midió RMS localmente.
JNIEXPORT jfloatArray JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetDspStageMetrics(
        JNIEnv* env,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return env->NewFloatArray(0);
    }

    auto m = g_engine->getStageMetrics();

    jfloatArray result = env->NewFloatArray(16);
    if (result != nullptr) {
        float data[16] = {
            m.inputLevel,
            m.postNrLevel,
            m.postEqLevel,
            m.postWdrcLevel,
            m.postVolumeLevel,
            m.outputLevel,
            m.peakSample,
            static_cast<float>(m.clipCount),
            m.wdrcGainFactor,
            static_cast<float>(m.wdrcRegion),
            m.eqMaxGain,
            static_cast<float>(m.environmentClass),
            m.preDnnLevelDb,
            m.wdrcUsesExternalLevel ? 1.0f : 0.0f,
            m.mpoLimitingFraction,
            m.mpoLimitingSustained ? 1.0f : 0.0f,
        };
        env->SetFloatArrayRegion(result, 0, 16, data);
    }
    return result;
}

/// Habilita/deshabilita el Transient Noise Reducer (TNR).
/// El TNR atenúa impulsos abruptos como timbre del subte, puertas, bocinas.
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetTnrEnabled(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jboolean enabled) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }

    g_engine->setTnrEnabled(enabled == JNI_TRUE);
}

// ─────────────────────────────────────────────────────────────────────────────
// Auditory Model (simulación del sistema auditivo humano)
// ─────────────────────────────────────────────────────────────────────────────

/// Habilita/deshabilita el Modelo Auditivo (6 etapas cocleares).
/// Cuando habilitado, simula la cadena auditiva humana y aplica compensaciones
/// personalizadas según el audiograma del paciente. Se inserta después del EQ,
/// antes del WDRC en el pipeline.
/// Thread-safe: usa std::atomic internamente.
///
/// @param enabled true para activar, false para bypass (passthrough)
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetAuditoryModelEnabled(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jboolean enabled) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }

    g_engine->setAuditoryModelEnabled(enabled == JNI_TRUE);
    LOGI("nativeSetAuditoryModelEnabled: %s", (enabled == JNI_TRUE) ? "ON" : "OFF");
}

/// Configura el audiograma del paciente para el modelo auditivo.
/// Los umbrales en dB HL (12 bandas) determinan la compensación OHC por banda.
/// Thread-safe: la copia interna es segura para el hilo de audio.
///
/// @param thresholds FloatArray de 12 valores en dB HL (0 = audición normal)
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetAuditoryModelAudiogram(
        JNIEnv* env,
        jobject /* thiz */,
        jfloatArray thresholds) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }
    if (thresholds == nullptr) {
        LOGW("nativeSetAuditoryModelAudiogram: null thresholds array");
        return;
    }
    jsize len = env->GetArrayLength(thresholds);
    if (len < 12) {
        LOGW("nativeSetAuditoryModelAudiogram: array length %d < 12", len);
        return;
    }

    jfloat* data = env->GetFloatArrayElements(thresholds, nullptr);
    if (data != nullptr) {
        g_engine->setAuditoryModelAudiogram(data);
        env->ReleaseFloatArrayElements(thresholds, data, JNI_ABORT);
        LOGI("nativeSetAuditoryModelAudiogram: applied (HL[0]=%.0f, HL[5]=%.0f, HL[11]=%.0f)",
             data[0], data[5], data[11]);
    }
}

/// Configura la ganancia del modelo auditivo avanzado (slider UI).
/// Rango: 0 (mínimo) a 18 (máximo). Default: 12 (normal).
/// Thread-safe.
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetAuditoryModelEarCanalGain(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jfloat gainDb) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }
    g_engine->setAuditoryModelEarCanalGain(gainDb);
    LOGI("nativeSetAuditoryModelEarCanalGain: %.1f dB", gainDb);
}

// ─────────────────────────────────────────────────────────────────────────────
// Smart Scene Engine — Fase 1
// ─────────────────────────────────────────────────────────────────────────────

/// Devuelve el último SceneSnapshot del Smart Scene Engine como ByteArray
/// crudo (memcpy del struct POD). Dart parsea con `ByteData` siguiendo el
/// layout definido en `scene_types.h` y `lib/scene/scene_snapshot.dart`.
///
/// @return ByteArray con sizeof(smart_scene::SceneSnapshot) bytes,
///         o array vacío si el engine no está activo.
JNIEXPORT jbyteArray JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetSceneSnapshot(
        JNIEnv* env,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return env->NewByteArray(0);
    }

    smart_scene::SceneSnapshot snap = g_engine->getSceneSnapshot();
    const jint size = static_cast<jint>(sizeof(smart_scene::SceneSnapshot));

    jbyteArray result = env->NewByteArray(size);
    if (result != nullptr) {
        env->SetByteArrayRegion(result, 0, size,
                                reinterpret_cast<const jbyte*>(&snap));
    }
    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// Calibration Spectrum Validator — Fase 2
// ─────────────────────────────────────────────────────────────────────────────

namespace {

/// Serializa un ToneSnapshot a un buffer plano de 92 bytes (sin padding del compilador).
/// Layout:
///   [0..7]   timestamp_us (uint64)
///   [8..11]  sample_rate_hz (float)
///   [12..13] fft_size (uint16)
///   [14]     window_type (uint8)
///   [15]     reserved0 (uint8)
///   [16..19] expected_freq_hz (float)
///   [20..23] peak_freq_hz (float)
///   [24..27] peak_magnitude_dbfs (float)
///   [28..31] peak_magnitude_dbspl (float)
///   [32..35] noise_floor_dbfs (float)
///   [36..39] snr_db (float)
///   [40..43] thd_percent (float)
///   [44..75] harmonics_dbfs[8] (8 × float = 32 bytes)
///   [76]     harmonics_count (uint8)
///   [77..79] reserved1 (3 bytes)
///   [80]     verdict (uint8)
///   [81]     failure_mask (uint8)
///   [82..83] reserved2 (2 bytes)
constexpr int kToneSnapshotWireSize = 84;

void writeUInt64Le(uint8_t* dst, uint64_t v) {
    for (int i = 0; i < 8; ++i) dst[i] = static_cast<uint8_t>((v >> (8 * i)) & 0xFF);
}
void writeFloatLe(uint8_t* dst, float v) {
    uint32_t bits;
    std::memcpy(&bits, &v, sizeof(float));
    for (int i = 0; i < 4; ++i) dst[i] = static_cast<uint8_t>((bits >> (8 * i)) & 0xFF);
}
void writeUInt16Le(uint8_t* dst, uint16_t v) {
    dst[0] = static_cast<uint8_t>(v & 0xFF);
    dst[1] = static_cast<uint8_t>((v >> 8) & 0xFF);
}

void serializeToneSnapshot(const cal_spectrum::ToneSnapshot& s, uint8_t* out) {
    std::memset(out, 0, kToneSnapshotWireSize);
    writeUInt64Le(out + 0, s.timestamp_us);
    writeFloatLe (out + 8, s.sample_rate_hz);
    writeUInt16Le(out + 12, s.fft_size);
    out[14] = s.window_type;
    out[15] = 0;
    writeFloatLe(out + 16, s.expected_freq_hz);
    writeFloatLe(out + 20, s.peak_freq_hz);
    writeFloatLe(out + 24, s.peak_magnitude_dbfs);
    writeFloatLe(out + 28, s.peak_magnitude_dbspl);
    writeFloatLe(out + 32, s.noise_floor_dbfs);
    writeFloatLe(out + 36, s.snr_db);
    writeFloatLe(out + 40, s.thd_percent);
    for (int i = 0; i < 8; ++i) {
        writeFloatLe(out + 44 + i * 4, s.harmonics_dbfs[i]);
    }
    out[76] = s.harmonics_count;
    out[80] = s.verdict;
    out[81] = s.failure_mask;
}

}  // namespace anónimo

/// Configura el ToneAnalyzer para una sesión de validación.
/// @param sampleRate Sample rate del audio (16000 o 48000).
/// @param fftSize Tamaño de FFT (1024, 4096, 8192).
/// @param windowType 0=Hann, 1=BlackmanHarris.
/// @param harmonicsCount 4 (clínico H2-H5) o 7 (premium H2-H8).
/// @param dbfsToDbsplOffset Offset dBFS → dB SPL (76 WAV, 120 mic real).
/// @return true si configuró correctamente.
JNIEXPORT jboolean JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeConfigureToneAnalyzer(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jint sampleRate,
        jint fftSize,
        jint windowType,
        jint harmonicsCount,
        jfloat dbfsToDbsplOffset) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return JNI_FALSE;
    }

    cal_spectrum::ToneAnalyzerConfig cfg;
    cfg.sample_rate_hz       = static_cast<float>(sampleRate);
    cfg.fft_size             = fftSize;
    cfg.window               = (windowType == 1) ? cal_spectrum::WindowType::BlackmanHarris
                                                  : cal_spectrum::WindowType::Hann;
    cfg.harmonics_count      = harmonicsCount;
    cfg.dbfs_to_dbspl_offset = dbfsToDbsplOffset;

    bool ok = g_engine->configureToneAnalyzer(cfg);
    return ok ? JNI_TRUE : JNI_FALSE;
}

/// Activa o desactiva el procesamiento del ToneAnalyzer.
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetToneAnalyzerActive(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jboolean active) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }
    g_engine->setToneAnalyzerActive(active == JNI_TRUE);
}

/// Establece la frecuencia esperada del tono actual (Hz).
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetToneExpectedFrequency(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jfloat freqHz) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }
    g_engine->setToneAnalyzerExpectedFreq(freqHz);
}

/// Establece el piso de ruido medido pre-secuencia.
/// @param amplitudeLin Amplitud lineal RMS (0..1).
/// @param dbfs Mismo valor expresado en dB FS.
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetToneNoiseFloor(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jfloat amplitudeLin,
        jfloat dbfs) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }
    g_engine->setToneAnalyzerNoiseFloor(amplitudeLin, dbfs);
}

/// Resetea el ToneAnalyzer (limpia buffer de acumulación y snapshot).
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeResetToneAnalyzer(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }
    g_engine->resetToneAnalyzer();
}

/// Devuelve el último ToneSnapshot serializado (84 bytes, little-endian).
/// Layout documentado en `serializeToneSnapshot()`.
JNIEXPORT jbyteArray JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetToneSnapshot(
        JNIEnv* env,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return env->NewByteArray(0);
    }

    cal_spectrum::ToneSnapshot snap = g_engine->getToneSnapshot();

    uint8_t buffer[kToneSnapshotWireSize];
    serializeToneSnapshot(snap, buffer);

    jbyteArray result = env->NewByteArray(kToneSnapshotWireSize);
    if (result != nullptr) {
        env->SetByteArrayRegion(result, 0, kToneSnapshotWireSize,
                                reinterpret_cast<const jbyte*>(buffer));
    }
    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// DNN Denoiser (GTCRN vía OnnxRuntime) — Fase 3 del plan DNN
// ─────────────────────────────────────────────────────────────────────────────

/// Inicializa el modelo DNN desde assets. Llamar UNA VEZ al startup.
/// Idempotente: si ya está inicializado, retorna true.
/// @param assetMgr AssetManager Java (java.lang.Object → AAssetManager)
/// @return true si el modelo se cargó correctamente.
JNIEXPORT jboolean JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeInitDnnDenoiser(
        JNIEnv* env,
        jobject /* thiz */,
        jobject assetMgrJava) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        LOGW("nativeInitDnnDenoiser: engine not running, ignoring");
        return JNI_FALSE;
    }

    AAssetManager* mgr = (assetMgrJava != nullptr)
                         ? AAssetManager_fromJava(env, assetMgrJava)
                         : nullptr;

    const bool ok = g_engine->initDnnDenoiser(mgr);
    return ok ? JNI_TRUE : JNI_FALSE;
}

/// Habilita/deshabilita el DNN denoiser. Cuando ON reemplaza al NR Wiener.
/// Por defecto: OFF (la app arranca sin DNN).
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetDnnEnabled(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jboolean enabled) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }
    g_engine->setDnnEnabled(enabled == JNI_TRUE);
}

/// Mezcla dry/wet del DNN denoiser (0..1).
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetDnnIntensity(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jfloat intensity) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }
    g_engine->setDnnIntensity(intensity);
}

/// @return true si el DNN está actualmente procesando audio (modelo cargado,
///         worker corriendo, sin errores). false en bypass por config o error.
JNIEXPORT jboolean JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetDnnIsActive(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return JNI_FALSE;
    }
    return g_engine->getDnnIsActive() ? JNI_TRUE : JNI_FALSE;
}

/// Retorna diagnósticos en tiempo real del DNN denoiser como HashMap.
/// Claves:
///   isActive (bool), isEnabled (bool), processedFrames (long),
///   droppedFrames (long), lastInferenceUs (int), effectiveIntensity (double),
///   userIntensity (double), inputChannels (int).
JNIEXPORT jobject JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetDnnDiagnostics(
        JNIEnv* env,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return nullptr;
    }

    jclass hashMapCls = env->FindClass("java/util/HashMap");
    jmethodID ctor = env->GetMethodID(hashMapCls, "<init>", "()V");
    jmethodID put  = env->GetMethodID(hashMapCls, "put",
        "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
    jobject map = env->NewObject(hashMapCls, ctor);

    putKv(env, map, put, "isActive",            boxBool(env, g_engine->getDnnIsActive()));
    putKv(env, map, put, "isEnabled",           boxBool(env, g_engine->getDnnIsEnabled()));
    putKv(env, map, put, "processedFrames",     boxLong(env, static_cast<int64_t>(g_engine->getDnnProcessedFrames())));
    putKv(env, map, put, "droppedFrames",       boxLong(env, static_cast<int64_t>(g_engine->getDnnDroppedFrames())));
    putKv(env, map, put, "lastInferenceUs",     boxInt(env, static_cast<int32_t>(g_engine->getDnnLastInferenceUs())));
    putKv(env, map, put, "effectiveIntensity",  boxDouble(env, static_cast<double>(g_engine->getDnnEffectiveIntensity())));
    putKv(env, map, put, "userIntensity",       boxDouble(env, static_cast<double>(g_engine->getDnnUserIntensity())));
    putKv(env, map, put, "inputChannels",       boxInt(env, g_engine->getDnnInputChannels()));

    env->DeleteLocalRef(hashMapCls);
    return map;
}

// ─────────────────────────────────────────────────────────────────────────────
// DenoiserSelector — Toggle exclusivo (spec ruidolimpio.md § Fase 3)
// ─────────────────────────────────────────────────────────────────────────────

/// Selecciona el motor de denoising activo (toggle exclusivo).
/// @param type 0=RNNoise, 1=DFN3, 2=GTCRN
extern "C" JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSelectDenoiser(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jint type) {
    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) return;
    g_engine->getDenoiserSelector().select(static_cast<DenoiserType>(type));
}

/// @return tipo del motor de denoising actualmente activo (con fallback resuelto).
/// 0=RNNoise, 1=DFN3, 2=GTCRN
extern "C" JNIEXPORT jint JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetActiveDenoiser(
        JNIEnv* /* env */,
        jobject /* thiz */) {
    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) return 0;
    return static_cast<jint>(g_engine->getDenoiserSelector().getActive());
}

/// @return tipo del motor seleccionado por el usuario (puede diferir del activo por fallback).
/// 0=RNNoise, 1=DFN3, 2=GTCRN
extern "C" JNIEXPORT jint JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetSelectedDenoiser(
        JNIEnv* /* env */,
        jobject /* thiz */) {
    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) return 0;
    return static_cast<jint>(g_engine->getDenoiserSelector().getSelected());
}

// ─────────────────────────────────────────────────────────────────────────────
// MVDR Dual-Mic Beamforming — Phase 3 (JNI bridge)
// ─────────────────────────────────────────────────────────────────────────────

/// Habilita/deshabilita el MVDR dual-mic beamformer.
/// Thread-safe: delega a AudioEngine::setBeamformingEnabled (std::atomic).
///
/// @param enabled true para activar beamforming, false para bypass (mono passthrough).
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetBeamformingEnabled(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jboolean enabled) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return;
    }
    g_engine->setBeamformingEnabled(enabled == JNI_TRUE);
}

/// Setea el flag de "beamforming solicitado" que consume `nativeStart`.
///
/// IMPORTANTE: debe llamarse ANTES de `nativeStart` (o antes de un
/// stop→start) para que el motor abra el stream de entrada en estéreo
/// (2 canales) y el MVDR beamformer reciba ambos micrófonos. A diferencia
/// de `nativeSetBeamformingEnabled` (que solo togglea el flag del beamformer
/// ya corriendo), este flag decide la geometría de captura en el próximo
/// start. Thread-safe (std::atomic). Spec: dual-mic-mvdr-beamforming.
///
/// @param enabled true → próximo start abre estéreo + beamforming.
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetBeamformingRequested(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jboolean enabled) {

    g_beamformingEnabled.store(enabled == JNI_TRUE, std::memory_order_release);
    LOGI("nativeSetBeamformingRequested: %s", (enabled == JNI_TRUE) ? "ON" : "OFF");
}

/// Consulta si el MVDR beamformer esta activo (enabled + procesando).
/// Thread-safe: lee std::atomic<bool> interno.
///
/// @return true si el beamformer esta habilitado y procesando, false en caso contrario.
JNIEXPORT jboolean JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetBeamformingActive(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return JNI_FALSE;
    }
    return g_engine->isBeamformingActive() ? JNI_TRUE : JNI_FALSE;
}

// ─────────────────────────────────────────────────────────────────────────────
// Enhancement Engine selector — spec gtcrn-dual-channel (tarea 4.1, JNI bridge)
// ─────────────────────────────────────────────────────────────────────────────

/// Selecciona el motor de realce de voz (BYPASS / DUAL-DNN / MVDR).
///
/// Contrato JNI (NO reordenar — mapea al enum `EnhancementEngineMode`):
///   0 → kBypass         (ch0 passthrough, sin realce; default de arranque)
///   1 → kDualChannelDnn (2 mics → GTCRN dual → mono realzado)
///   2 → kMvdrBackup     (2 mics → MVDR beamformer → mono realzado)
///
/// Los enteros fuera de [0, 2] se rechazan (no-op + LOGW) para no construir
/// un `EnhancementEngineMode` inválido vía static_cast.
///
/// Geometría de captura: los modos DUAL y MVDR necesitan captura estéreo
/// (2 canales) para recibir ch0/ch1. Reutilizamos el flag global
/// `g_beamformingEnabled` (el mismo que consume `nativeStart` para abrir el
/// stream estéreo) y lo actualizamos según el modo:
///   - DUAL o MVDR → g_beamformingEnabled = true  (próximo start abre estéreo)
///   - BYPASS      → g_beamformingEnabled = false (próximo start abre mono)
/// Así, si el usuario elige DUAL/MVDR ANTES del start, `nativeStart` ya abre
/// estéreo. Si el motor YA está corriendo, `AudioEngine::setEnhancementEngineMode`
/// se encarga del re-open mono↔estéreo en caliente (Fix #3, tarea 3.4). El flag
/// mantiene la geometría correcta para cualquier stop→start posterior.
///
/// @param mode 0=Bypass, 1=DualChannelDnn, 2=MvdrBackup.
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetEnhancementEngineMode(
        JNIEnv* /* env */,
        jobject /* thiz */,
        jint mode) {

    // Validación de rango del contrato JNI antes del static_cast.
    if (mode < 0 || mode > 2) {
        LOGW("nativeSetEnhancementEngineMode: invalid mode %d (esperado 0..2) — ignorado", mode);
        return;
    }

    // Actualizar la geometría de captura solicitada para el próximo start.
    // DUAL (1) y MVDR (2) requieren estéreo; BYPASS (0) corre mono.
    const bool needsStereo = (mode != 0);
    g_beamformingEnabled.store(needsStereo, std::memory_order_release);

    // Si el motor está corriendo, aplicar el modo en caliente. El AudioEngine
    // maneja internamente el crossfade anti-clic y el re-open estéreo/mono si
    // cambia la geometría. Si el motor está idle, el flag de arriba asegura
    // que el próximo nativeStart abra con la geometría correcta.
    if (g_running.load(std::memory_order_acquire) && g_engine != nullptr) {
        g_engine->setEnhancementEngineMode(static_cast<EnhancementEngineMode>(mode));
    }
    LOGI("nativeSetEnhancementEngineMode: mode=%d (stereo=%s)",
         mode, needsStereo ? "yes" : "no");
}

/// Consulta el motor de realce seleccionado actualmente.
/// Thread-safe: lee el std::atomic<EnhancementEngineMode> interno del engine.
///
/// @return 0=Bypass, 1=DualChannelDnn, 2=MvdrBackup. Si el motor no está
///         activo devuelve 0 (kBypass), coherente con el default de arranque.
JNIEXPORT jint JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetEnhancementEngineMode(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return 0;  // kBypass
    }
    return static_cast<jint>(g_engine->getEnhancementEngineMode());
}

// ─────────────────────────────────────────────────────────────────────────────
// Diagnostic Recorder JNI Functions
// ─────────────────────────────────────────────────────────────────────────────

/// Inicia grabación diagnóstica dual-channel.
/// @param filePath Ruta absoluta del archivo WAV de salida.
/// @return true si la grabación inició correctamente.
JNIEXPORT jboolean JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeStartDiagnosticRecording(
        JNIEnv* env,
        jobject /* thiz */,
        jstring filePath) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return JNI_FALSE;
    }

    const char* path = env->GetStringUTFChars(filePath, nullptr);
    if (path == nullptr) return JNI_FALSE;

    bool ok = g_engine->startDiagnosticRecording(std::string(path));
    env->ReleaseStringUTFChars(filePath, path);

    LOGI("nativeStartDiagnosticRecording: %s → %s", path, ok ? "OK" : "FAILED");
    return ok ? JNI_TRUE : JNI_FALSE;
}

/// Detiene la grabación diagnóstica.
/// @return true si se completó correctamente.
JNIEXPORT jboolean JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeStopDiagnosticRecording(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return JNI_FALSE;
    }

    bool ok = g_engine->stopDiagnosticRecording();
    LOGI("nativeStopDiagnosticRecording: %s", ok ? "COMPLETED" : "STOPPED");
    return ok ? JNI_TRUE : JNI_FALSE;
}

/// Detiene la grabación diagnóstica y CONSERVA el archivo WAV parcial.
/// Finaliza el encabezado WAV con la duración real alcanzada.
/// Diseñado para grabaciones intencionalmente cortas (test A/B, 5s por modo).
/// @return true si el archivo se conservó correctamente.
JNIEXPORT jboolean JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeStopDiagnosticRecordingKeep(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return JNI_FALSE;
    }

    bool ok = g_engine->stopDiagnosticRecordingKeep();
    LOGI("nativeStopDiagnosticRecordingKeep: %s", ok ? "KEPT" : "DISCARDED");
    return ok ? JNI_TRUE : JNI_FALSE;
}

/// Obtiene el progreso de la grabación diagnóstica.
/// @return Progreso [0.0, 1.0], o -1.0 si no hay grabación activa.
JNIEXPORT jdouble JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetDiagnosticRecordingProgress(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_running.load(std::memory_order_acquire) || g_engine == nullptr) {
        return -1.0;
    }

    return g_engine->getDiagnosticRecordingProgress();
}

// ─────────────────────────────────────────────────────────────────────────────
// Latency Monitor & Loopback Test JNI Functions
// ─────────────────────────────────────────────────────────────────────────────
//
// Las cinco funciones a continuación exponen al lado Kotlin/Dart el monitor
// de latencia y el test de loopback acústico documentados en el spec
// `monitor-latencia-audio`. Convención de retorno:
//
//   nativeGetLatencyMetrics:
//     - Si `g_engine == nullptr` → null (Dart lo trata como "no hay datos").
//     - Si hay engine → java.util.HashMap construido por `latencyMetricsToJavaMap`.
//
//   nativeStartLoopbackTest:
//     - Usa `LoopbackParams{}` (defaults: 48 kHz, chirp 200→8000 Hz, 50 ms).
//     - Retorna jboolean: true si el test arrancó, false si engine null o falló.
//
//   nativeIsLoopbackTestActive:
//     - Delegación pura a `g_engine->isLoopbackTestActive()`.
//
//   nativeGetLoopbackTestResult:
//     - Si todavía está activo → null (Dart sigue polleando).
//     - Si terminó → java.util.HashMap construido por `loopbackResultToJavaMap`.
//     - Si engine null → null.
//
//   nativeCancelLoopbackTest:
//     - Idempotente: si engine null o no hay test, no-op.
//
// Nombres JNI: paquete Kotlin `com.psk.hearing_aid_app` → mangling con
// underscores escapados como `_1` → `Java_com_psk_hearing_1aid_1app_...`.

/// Devuelve un snapshot de las métricas de latencia del motor de audio.
/// @return java.util.HashMap<String,Object> con las claves documentadas en
///         `latencyMetricsToJavaMap`, o null si el engine no está creado.
JNIEXPORT jobject JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetLatencyMetrics(
        JNIEnv* env,
        jobject /* thiz */) {

    if (!g_engine) return nullptr;
    LatencyMetrics m = g_engine->getLatencyMetrics();
    return latencyMetricsToJavaMap(env, m);
}

/// Inicia el test de loopback acústico con parámetros por defecto
/// (48 kHz, chirp 200→8000 Hz, ventana de medición de 500 ms).
/// @return true si el tester arrancó correctamente; false si el engine no
///         está creado o si el tester rechazó los parámetros.
JNIEXPORT jboolean JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeStartLoopbackTest(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_engine) return JNI_FALSE;
    latency_monitor::LoopbackParams params;  // defaults
    bool ok = g_engine->startLoopbackTest(params);
    return ok ? JNI_TRUE : JNI_FALSE;
}

/// @return true si hay un test de loopback en curso, false si no o si el
///         engine no está creado.
JNIEXPORT jboolean JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeIsLoopbackTestActive(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (!g_engine) return JNI_FALSE;
    return g_engine->isLoopbackTestActive() ? JNI_TRUE : JNI_FALSE;
}

/// Obtiene el resultado del test de loopback.
/// @return - null si todavía está activo (Dart debe seguir polleando).
///         - null si el engine no está creado.
///         - java.util.HashMap<String,Object> con las claves documentadas en
///           `loopbackResultToJavaMap` cuando el test terminó.
JNIEXPORT jobject JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetLoopbackTestResult(
        JNIEnv* env,
        jobject /* thiz */) {

    if (!g_engine) return nullptr;
    // Si todavía está activo, retornar null para que Dart sepa que debe
    // seguir polleando hasta que el tester complete la medición.
    if (g_engine->isLoopbackTestActive()) return nullptr;
    latency_monitor::LoopbackResult r = g_engine->getLoopbackTestResult();
    return loopbackResultToJavaMap(env, r);
}

/// Cancela el test de loopback en curso (si lo hay) y restaura el muteo
/// del audio ambiente. Idempotente.
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeCancelLoopbackTest(
        JNIEnv* /* env */,
        jobject /* thiz */) {

    if (g_engine) {
        g_engine->cancelLoopbackTest();
    }
}

} // extern "C"

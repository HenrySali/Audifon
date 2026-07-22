package com.psk.hearing_aid_app

import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Puente de comunicación entre Flutter y el motor de audio nativo.
 *
 * Registra un [MethodChannel] para recibir comandos de Flutter (start, stop,
 * updateEqGains, updateVolume, updateWdrcParams, updateNrLevel) y los delega
 * al [NativeAudioBridge].
 *
 * Registra dos [EventChannel] para enviar datos a Flutter:
 * - 'com.psk.hearing_aid/level': nivel de entrada PRE-EQ en dB SPL (~10 Hz)
 * - 'com.psk.hearing_aid/state': estado del motor de audio (idle, active, paused, error)
 *
 * Requisitos: 1.3, 5.4, 5.5
 */
class AudioMethodChannel(
    private val flutterEngine: FlutterEngine,
    private val context: Context
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "AudioMethodChannel"

        /** Canal de métodos para comandos Flutter → Native. */
        const val METHOD_CHANNEL = "com.psk.hearing_aid/audio"

        /** Canal de eventos para nivel de entrada (~10 Hz). */
        const val LEVEL_EVENT_CHANNEL = "com.psk.hearing_aid/level"

        /** Canal de eventos para estado del motor de audio. */
        const val STATE_EVENT_CHANNEL = "com.psk.hearing_aid/state"
    }

    // ─────────────────────────────────────────────────────────────────────
    // Canales de plataforma
    // ─────────────────────────────────────────────────────────────────────

    private val methodChannel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        METHOD_CHANNEL
    )

    private val levelEventChannel = EventChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        LEVEL_EVENT_CHANNEL
    )

    private val stateEventChannel = EventChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        STATE_EVENT_CHANNEL
    )

    // ─────────────────────────────────────────────────────────────────────
    // Puente nativo y sinks de eventos
    // ─────────────────────────────────────────────────────────────────────

    private val nativeBridge = NativeAudioBridge()

    // ─── Modo Conversación (SCO + 16 kHz) ─────────────────────────────────
    // Si el toggle está ON, el motor arranca a 16 kHz / 64 frames y el audio
    // se rutea por SCO (BT) o builtin con MODE_IN_COMMUNICATION. Si está OFF
    // (default), se mantiene el comportamiento histórico: A2DP @ 48 kHz.
    private val scoController = BluetoothScoController(context)
    @Volatile private var conversationMode: Boolean = false

    /** NoiseSuppressor del sistema Android (Fase 1 noise gate HW). */
    private var noiseSuppressor: NoiseSuppressor? = null

    /** Monitor de ruta de audio: detecta caída a speaker al desconectar BT. */
    private val routeMonitor = AudioRouteMonitor(context).apply {
        onRoutedToSpeaker = {
            Log.w(TAG, "Audio routed to speaker — STOPPING engine to prevent saturation")
            // DETENER el motor completamente. Bajar el volumen no alcanza
            // porque el re-ruteo puede ser instantáneo y el audio amplificado
            // (20-50 dB) sale por el speaker antes de que setVolume surta efecto.
            // Parar el motor garantiza silencio absoluto inmediato.
            nativeBridge.stop()
            // Parar el foreground service también.
            val serviceIntent = Intent(context, AudioForegroundService::class.java).apply {
                action = AudioForegroundService.ACTION_STOP
            }
            context.startService(serviceIntent)
            // Notificar a Dart para que la UI refleje que se apagó.
            emitState("stopped_bt_disconnect")
        }
    }

    /** Sink para emitir nivel de entrada a Flutter. */
    private var levelEventSink: EventChannel.EventSink? = null

    /** Sink para emitir estado del engine a Flutter. */
    private var stateEventSink: EventChannel.EventSink? = null

    /** Estado actual del motor de audio. */
    private var currentState: String = "idle"

    // ─────────────────────────────────────────────────────────────────────
    // Caches del último estado aplicado al motor.
    //
    // Espejo exacto de `AudioMethodChannelPatient.kt` (tecnico-paciente-feature-parity
    // task 1.6): los handlers `setMhlPrescriptionEnabled` y `setMusicModeEnabled`
    // necesitan re-aplicar EQ/WDRC con los valores previos al activar/desactivar
    // los modos. Se populan desde los handlers existentes (`handleStartAudio`,
    // `handleUpdateEqGains`, `handleUpdateWdrcParams`, `handleSetMpoThresholdDbSpl`).
    // ─────────────────────────────────────────────────────────────────────

    private var lastEqGains: FloatArray = FloatArray(12) { 0f }
    private var lastVolumeDb: Float = 0f
    private var lastMpoDbSpl: Float = 100f
    private var lastExpKnee: Float = 35f
    private var lastExpRatio: Float = 2f
    private var lastCompKnee: Float = 55f
    private var lastCompRatio: Float = 2f
    private var lastAttackMs: Float = 5f
    private var lastReleaseMs: Float = 100f
    private var lastDnnEnabled: Boolean = true
    private var lastDnnIntensity: Float = 0.6f

    // ─────────────────────────────────────────────────────────────────────
    // Inicialización
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Registra los canales de plataforma con el FlutterEngine.
     * Debe llamarse desde [MainActivity.configureFlutterEngine].
     */
    fun register() {
        Log.i(TAG, "Registering platform channels")

        // Registrar handler de MethodChannel
        methodChannel.setMethodCallHandler(this)

        // Registrar StreamHandler para nivel de entrada
        levelEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                Log.d(TAG, "Level EventChannel: onListen")
                levelEventSink = events
                startLevelUpdates()
            }

            override fun onCancel(arguments: Any?) {
                Log.d(TAG, "Level EventChannel: onCancel")
                stopLevelUpdates()
                levelEventSink = null
            }
        })

        // Registrar StreamHandler para estado del engine
        stateEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                Log.d(TAG, "State EventChannel: onListen")
                stateEventSink = events
                // Emitir estado actual inmediatamente al suscribirse
                events?.success(currentState)
            }

            override fun onCancel(arguments: Any?) {
                Log.d(TAG, "State EventChannel: onCancel")
                stateEventSink = null
            }
        })

        Log.i(TAG, "Platform channels registered successfully")
    }

    /**
     * Desregistra los canales y libera recursos.
     * Debe llamarse desde [MainActivity.cleanUpFlutterEngine].
     */
    fun unregister() {
        Log.i(TAG, "Unregistering platform channels")
        stopLevelUpdates()
        methodChannel.setMethodCallHandler(null)
        levelEventChannel.setStreamHandler(null)
        stateEventChannel.setStreamHandler(null)
        levelEventSink = null
        stateEventSink = null
    }

    // ─────────────────────────────────────────────────────────────────────
    // MethodChannel.MethodCallHandler
    // ─────────────────────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "onMethodCall: ${call.method}")

        try {
            when (call.method) {
                "startAudio" -> handleStartAudio(call, result)
                "stopAudio" -> handleStopAudio(result)
                "updateEqGains" -> handleUpdateEqGains(call, result)
                "updateVolume" -> handleUpdateVolume(call, result)
                "updateWdrcParams" -> handleUpdateWdrcParams(call, result)
                "updateNrLevel" -> handleUpdateNrLevel(call, result)
                // ─── mvdr-noise-clarity-tuning ──────────────────────────
                "setExpander" -> handleSetExpander(call, result)
                "setDereverb" -> handleSetDereverb(call, result)
                "setClassifierThresholds" -> handleSetClassifierThresholds(call, result)
                "updateAutoClassify" -> handleUpdateAutoClassify(call, result)
                "setSmartPresetPinned" -> handleSetSmartPresetPinned(call, result)
                "applyCalibration" -> handleApplyCalibration(call, result)
                "setMpoThresholdDbSpl" -> handleSetMpoThresholdDbSpl(call, result)
                "getDebugInfo" -> handleGetDebugInfo(result)
                "getDeviceInfo" -> handleGetDeviceInfo(result)
                "hasExternalOutput" -> {
                    val monitor = AudioRouteMonitor(context)
                    result.success(monitor.hasHeadsetOutput())
                }
                "setPreferredInputDevice" -> {
                    val deviceId = call.argument<Int>("deviceId") ?: -1
                    val success = nativeBridge.setPreferredInputDevice(deviceId)
                    result.success(success)
                }
                // Spectrum Analyzer
                "startSpectrumAnalysis" -> { nativeBridge.nativeStartSpectrumAnalysis(); result.success(null) }
                "stopSpectrumAnalysis" -> { nativeBridge.nativeStopSpectrumAnalysis(); result.success(null) }
                "startSpectrumRecording" -> { nativeBridge.nativeStartSpectrumRecording(); result.success(null) }
                "stopSpectrumRecording" -> { val count = nativeBridge.nativeStopSpectrumRecording(); result.success(count) }
                "getRecordingData" -> { val data = nativeBridge.nativeGetRecordingData(); result.success(data) }
                "getCurrentSpectrum" -> { val data = nativeBridge.nativeGetCurrentSpectrum(); result.success(data) }
                // DSP Stage Metrics (para diagnóstico del pipeline)
                "getDspStageMetrics" -> { val metrics = nativeBridge.getDspStageMetrics(); result.success(metrics) }
                // Latency Metrics (spec monitor-latencia-audio)
                "getLatencyMetrics" -> {
                    val metrics = nativeBridge.getLatencyMetrics()
                    result.success(metrics)
                }
                // Transient Noise Reducer (TNR)
                "updateTnrEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    nativeBridge.nativeSetTnrEnabled(enabled)
                    result.success(null)
                }
                // Auditory Model (simulación del sistema auditivo humano)
                "setAuditoryModelEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    nativeBridge.nativeSetAuditoryModelEnabled(enabled)
                    result.success(null)
                }
                "setAuditoryModelAudiogram" -> {
                    val thresholdsList = call.argument<List<Double>>("thresholds") ?: List(12) { 0.0 }
                    val thresholds = FloatArray(12) { i ->
                        if (i < thresholdsList.size) thresholdsList[i].toFloat() else 0f
                    }
                    nativeBridge.nativeSetAuditoryModelAudiogram(thresholds)
                    result.success(null)
                }
                "setAuditoryModelEarCanalGain" -> {
                    val gainDb = (call.argument<Double>("gainDb") ?: 12.0).toFloat()
                    nativeBridge.nativeSetAuditoryModelEarCanalGain(gainDb)
                    result.success(null)
                }
                // Smart Scene Engine (Fase 1)
                "getSceneSnapshot" -> {
                    val data = nativeBridge.nativeGetSceneSnapshot()
                    result.success(data)
                }
                // Fase G — applyScenePreset único
                "applyScenePreset" -> {
                    val gains = call.argument<List<Double>>("gains") ?: List(12) { 0.0 }
                    val expKnee = call.argument<Double>("expansionKnee") ?: 35.0
                    val expRatio = call.argument<Double>("expansionRatio") ?: 2.0
                    val compKnee = call.argument<Double>("compressionKnee") ?: 55.0
                    val compRatio = call.argument<Double>("compressionRatio") ?: 2.0
                    val attackMs = call.argument<Double>("attackMs") ?: 5.0
                    val releaseMs = call.argument<Double>("releaseMs") ?: 100.0
                    val mpoDbSpl = call.argument<Double>("mpoThresholdDbSpl") ?: 110.0
                    val nrLevel = call.argument<Int>("nrLevel") ?: 0
                    val tnrEnabled = call.argument<Boolean>("tnrEnabled") ?: false
                    val pinPreset = call.argument<Boolean>("pinPreset") ?: true

                    val params = FloatArray(19) { i ->
                        when {
                            i < 12 -> gains.getOrElse(i) { 0.0 }.toFloat()
                            i == 12 -> expKnee.toFloat()
                            i == 13 -> expRatio.toFloat()
                            i == 14 -> compKnee.toFloat()
                            i == 15 -> compRatio.toFloat()
                            i == 16 -> attackMs.toFloat()
                            i == 17 -> releaseMs.toFloat()
                            i == 18 -> mpoDbSpl.toFloat()
                            else -> 0f
                        }
                    }
                    nativeBridge.nativeApplyScenePreset(params, nrLevel, tnrEnabled, pinPreset)
                    result.success(null)
                }
                // Calibration Spectrum Validator (Fase 2)
                "configureToneAnalyzer" -> {
                    val sr = call.argument<Int>("sampleRate") ?: 48000
                    val fft = call.argument<Int>("fftSize") ?: 4096
                    val wt = call.argument<Int>("windowType") ?: 0
                    val hc = call.argument<Int>("harmonicsCount") ?: 4
                    val off = (call.argument<Double>("dbfsToDbsplOffset") ?: 76.0).toFloat()
                    val ok = nativeBridge.nativeConfigureToneAnalyzer(sr, fft, wt, hc, off)
                    result.success(ok)
                }
                "setToneAnalyzerActive" -> {
                    val active = call.argument<Boolean>("active") ?: false
                    nativeBridge.nativeSetToneAnalyzerActive(active)
                    result.success(null)
                }
                "setToneExpectedFrequency" -> {
                    val hz = (call.argument<Double>("freqHz") ?: 1000.0).toFloat()
                    nativeBridge.nativeSetToneExpectedFrequency(hz)
                    result.success(null)
                }
                "setToneNoiseFloor" -> {
                    val lin = (call.argument<Double>("amplitudeLin") ?: 0.0).toFloat()
                    val dbfs = (call.argument<Double>("dbfs") ?: -120.0).toFloat()
                    nativeBridge.nativeSetToneNoiseFloor(lin, dbfs)
                    result.success(null)
                }
                "resetToneAnalyzer" -> {
                    nativeBridge.nativeResetToneAnalyzer()
                    result.success(null)
                }
                "getToneSnapshot" -> {
                    val data = nativeBridge.nativeGetToneSnapshot()
                    result.success(data)
                }
                // DNN Denoiser (GTCRN vía OnnxRuntime) — Fase 3
                "initDnnDenoiser" -> {
                    // Inicialización lazy: pasamos AAssetManager al nativo
                    // para que cargue gtcrn.onnx desde assets/.
                    val ok = try {
                        nativeBridge.nativeInitDnnDenoiser(context.assets)
                    } catch (t: Throwable) {
                        Log.w(TAG, "initDnnDenoiser failed", t)
                        false
                    }
                    result.success(ok)
                }
                "setDnnEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    lastDnnEnabled = enabled
                    nativeBridge.nativeSetDnnEnabled(enabled)
                    result.success(null)
                }
                "setDnnIntensity" -> {
                    val intensity = (call.argument<Double>("intensity") ?: 1.0).toFloat()
                    lastDnnIntensity = intensity
                    nativeBridge.nativeSetDnnIntensity(intensity)
                    result.success(null)
                }
                "getDnnIsActive" -> {
                    val active = nativeBridge.nativeGetDnnIsActive()
                    result.success(active)
                }
                "getDnnDiagnostics" -> {
                    val diag = nativeBridge.nativeGetDnnDiagnostics()
                    result.success(diag)
                }
                // ─── DenoiserSelector Toggle (spec ruidolimpio.md) ──────
                "selectDenoiser" -> {
                    val type = call.argument<Int>("type") ?: 0
                    nativeBridge.nativeSelectDenoiser(type)
                    result.success(null)
                }
                "getActiveDenoiser" -> {
                    result.success(nativeBridge.nativeGetActiveDenoiser())
                }
                "getSelectedDenoiser" -> {
                    result.success(nativeBridge.nativeGetSelectedDenoiser())
                }
                // ─── Registro de matraca/calidad de los 3 sistemas ──────
                "getDenoiserArtifactReport" -> {
                    val report = try {
                        nativeBridge.nativeGetDenoiserArtifactReport()
                    } catch (t: Throwable) {
                        Log.w(TAG, "getDenoiserArtifactReport failed", t); ""
                    }
                    result.success(report)
                }
                "resetDenoiserArtifactLog" -> {
                    try { nativeBridge.nativeResetDenoiserArtifactLog() }
                    catch (t: Throwable) { Log.w(TAG, "resetDenoiserArtifactLog failed", t) }
                    result.success(null)
                }
                "getDenoiserArtifactSummary" -> {
                    val summary = try {
                        nativeBridge.nativeGetDenoiserArtifactSummary()
                    } catch (t: Throwable) {
                        Log.w(TAG, "getDenoiserArtifactSummary failed", t); null
                    }
                    result.success(summary)
                }
                // ─── MVDR Dual-Mic Beamforming ──────────────────────────
                "setBeamformingEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    handleSetBeamformingMode(enabled, result)
                }
                "getBeamformingActive" -> {
                    val active = nativeBridge.nativeGetBeamformingActive()
                    result.success(active)
                }
                // ─── Enhancement Engine selector (spec gtcrn-dual-channel) ─
                // Selector de 3 estados: 0=Bypass, 1=DualChannelDnn, 2=MvdrBackup.
                // El lado nativo valida el rango [0,2], actualiza la geometría
                // de captura estéreo solicitada (flag que consume nativeStart)
                // y hace el re-open en caliente si el motor ya corre.
                "setEnhancementEngineMode" -> {
                    val mode = call.argument<Int>("mode") ?: 0
                    nativeBridge.nativeSetEnhancementEngineMode(mode)
                    result.success(null)
                }
                "getEnhancementEngineMode" -> {
                    val mode = nativeBridge.nativeGetEnhancementEngineMode()
                    result.success(mode)
                }
                // ─── MHL Prescripción / Modo Música ─────────────────────
                // Espejo bit-a-bit de AudioMethodChannelPatient.kt
                // (tecnico-paciente-feature-parity, Requirements 1.1 y 1.2).
                "setMhlPrescriptionEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    applyMhlPrescription(enabled)
                    result.success(null)
                }
                "setMusicModeEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    applyMusicMode(enabled)
                    result.success(null)
                }
                // ─── Diagnostic Recording (DSP Verification) ────────────
                // Requirements 6.2, 6.3, 6.4. Misma firma que el paciente:
                // - startDiagnosticRecording: arg `filePath` (String relativo al
                //   external files dir), retorna Boolean.
                // - stopDiagnosticRecording: sin args, retorna Int (0=ok, -1=error).
                // - getDiagnosticRecordingProgress: sin args, retorna Int
                //   (progress.toInt() del Double JNI; -1 si no hay grabación).
                "startDiagnosticRecording" -> {
                    val filePath = call.argument<String>("filePath")
                        ?: return result.error("INVALID_ARGS", "Missing 'filePath'", null)
                    val dir = context.getExternalFilesDir(null)
                        ?: return result.error(
                            "STORAGE_ERROR",
                            "External storage not available",
                            null,
                        )
                    val fullPath = "${dir.absolutePath}/$filePath"
                    val ok = nativeBridge.nativeStartDiagnosticRecording(fullPath)
                    // Devolver el fullPath real para que Dart no tenga que reconstruirlo.
                    // Si ok=false, devolver null para indicar fallo.
                    result.success(if (ok) fullPath else null)
                }
                "stopDiagnosticRecording" -> {
                    val ok = nativeBridge.nativeStopDiagnosticRecording()
                    // Dart espera: 0=completado, 1=descartado, -1=error.
                    // El nativo solo distingue ok/err, así que mapeamos
                    // exactamente como el paciente: ok→0, err→-1.
                    result.success(if (ok) 0 else -1)
                }
                "stopDiagnosticRecordingKeep" -> {
                    val ok = nativeBridge.nativeStopDiagnosticRecordingKeep()
                    // ok=true → WAV parcial conservado exitosamente (0)
                    // ok=false → sin datos o error de finalización (-1)
                    result.success(if (ok) 0 else -1)
                }
                "getDiagnosticRecordingProgress" -> {
                    val progress = nativeBridge.nativeGetDiagnosticRecordingProgress()
                    result.success(progress.toInt())
                }
                // ─── Calibración de hardware (C-3, native-calibration-handlers) ─
                // Implementación real de los 3 handlers con AudioRecord directo
                // (no pasa por el pipeline DSP del proyecto). Persistencia +
                // audit trail SHA-256 ocurren en el lado Dart.
                "getInputLevel" -> handleGetInputLevel(call, result)
                "calibrateMicrophone" -> handleCalibrateMicrophone(call, result)
                "calibrateHeadphones" -> handleCalibrateHeadphones(call, result)
                "setConversationMode" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    handleSetConversationMode(enabled, result)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error handling method ${call.method}", e)
            result.error("NATIVE_ERROR", e.message, e.stackTraceToString())
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Handlers de métodos individuales
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Inicia el pipeline de audio con la configuración proporcionada.
     *
     * Argumentos esperados del MethodChannel:
     * - sampleRate: Int (default 16000)
     * - bufferSize: Int (default 64)
     * - eqGains: List<Double> (12 valores)
     * - volumeDb: Double
     * - expansionKnee: Double
     * - expansionRatio: Double
     * - compressionKnee: Double
     * - compressionRatio: Double
     * - attackMs: Double
     * - releaseMs: Double
     * - nrLevel: Int
     * - mpoThresholdDbSpl: Double (default 100)
     */
    /**
     * Inicia el pipeline de audio con la configuración proporcionada.
     * Inicia el foreground service para mantener el audio en segundo plano.
     */
    private fun handleStartAudio(call: MethodCall, result: MethodChannel.Result) {
        val argSampleRate = call.argument<Int>("sampleRate") ?: 48000
        val argBufferSize = call.argument<Int>("bufferSize") ?: 256

        // Si el toggle "Modo Conversación" está ON, ignoramos los valores
        // que pasó Dart y forzamos 16 kHz / 64 frames para correr el pipeline
        // en modo voz a baja latencia. Si está OFF, respetamos el SR/buffer
        // que viene en los args (default 48 kHz / 256).
        val sampleRate = if (conversationMode) 16_000 else argSampleRate
        val bufferSize = if (conversationMode) 64 else argBufferSize

        val eqGainsList = call.argument<List<Double>>("eqGains") ?: List(12) { 0.0 }
        val volumeDb = call.argument<Double>("volumeDb") ?: 0.0
        val expansionKnee = call.argument<Double>("expansionKnee") ?: 35.0
        val expansionRatio = call.argument<Double>("expansionRatio") ?: 2.0
        val compressionKnee = call.argument<Double>("compressionKnee") ?: 55.0
        val compressionRatio = call.argument<Double>("compressionRatio") ?: 2.0
        val attackMs = call.argument<Double>("attackMs") ?: 5.0
        val releaseMs = call.argument<Double>("releaseMs") ?: 100.0
        val nrLevel = call.argument<Int>("nrLevel") ?: 0
        val mpoThresholdDbSpl = call.argument<Double>("mpoThresholdDbSpl") ?: 100.0

        // Convertir ganancias a FloatArray
        val eqGains = FloatArray(12) { i ->
            if (i < eqGainsList.size) eqGainsList[i].toFloat() else 0f
        }

        // Cache para handlers de MHL Prescripción / Modo Música (espejo paciente).
        lastEqGains = eqGains.copyOf()
        lastVolumeDb = volumeDb.toFloat()
        lastExpKnee = expansionKnee.toFloat()
        lastExpRatio = expansionRatio.toFloat()
        lastCompKnee = compressionKnee.toFloat()
        lastCompRatio = compressionRatio.toFloat()
        lastAttackMs = attackMs.toFloat()
        lastReleaseMs = releaseMs.toFloat()
        lastMpoDbSpl = mpoThresholdDbSpl.toFloat()

        emitState("starting")

        // Si Modo Conversación está activo, levantar SCO + MODE_IN_COMMUNICATION
        // ANTES de abrir los streams Oboe.
        if (conversationMode && !scoController.isActive()) {
            val r = scoController.start()
            Log.i(TAG, "handleStartAudio: conversationMode=true → SCO start=$r")
        }

        // Start the foreground service to keep audio alive in background
        val serviceIntent = Intent(context, AudioForegroundService::class.java).apply {
            action = AudioForegroundService.ACTION_START
            putExtra(AudioForegroundService.EXTRA_SAMPLE_RATE, sampleRate)
            putExtra(AudioForegroundService.EXTRA_BUFFER_SIZE, bufferSize)
            putExtra(AudioForegroundService.EXTRA_EQ_GAINS, eqGains)
            putExtra(AudioForegroundService.EXTRA_VOLUME_DB, volumeDb.toFloat())
            putExtra(AudioForegroundService.EXTRA_EXPANSION_KNEE, expansionKnee.toFloat())
            putExtra(AudioForegroundService.EXTRA_EXPANSION_RATIO, expansionRatio.toFloat())
            putExtra(AudioForegroundService.EXTRA_COMPRESSION_KNEE, compressionKnee.toFloat())
            putExtra(AudioForegroundService.EXTRA_COMPRESSION_RATIO, compressionRatio.toFloat())
            putExtra(AudioForegroundService.EXTRA_ATTACK_MS, attackMs.toFloat())
            putExtra(AudioForegroundService.EXTRA_RELEASE_MS, releaseMs.toFloat())
            putExtra(AudioForegroundService.EXTRA_NR_LEVEL, nrLevel)
            putExtra(AudioForegroundService.EXTRA_MPO_THRESHOLD, mpoThresholdDbSpl.toFloat())
            putExtra(AudioForegroundService.EXTRA_SPL_OFFSET, 120f)
        }
        context.startForegroundService(serviceIntent)

        // Also start via the direct bridge for level polling
        // CRÍTICO: setear el flag de Modo Conversación ANTES de start() para
        // que el motor abra los streams con Usage::VoiceCommunication (SCO).
        nativeBridge.nativeSetConversationMode(conversationMode)
        // CRÍTICO: setear el flag de beamforming ANTES de start() para que
        // el motor abra el input stream con 2 canales (estéreo).
        val beamformingEnabled = call.argument<Boolean>("beamformingEnabled") ?: false
        nativeBridge.nativeSetBeamformingMode(beamformingEnabled)
        nativeBridge.start(
            sampleRate = sampleRate,
            bufferSize = bufferSize,
            eqGains = eqGains,
            volumeDb = volumeDb.toFloat(),
            expansionKnee = expansionKnee.toFloat(),
            expansionRatio = expansionRatio.toFloat(),
            compressionKnee = compressionKnee.toFloat(),
            compressionRatio = compressionRatio.toFloat(),
            attackMs = attackMs.toFloat(),
            releaseMs = releaseMs.toFloat(),
            nrLevel = nrLevel,
            mpoThresholdDbSpl = mpoThresholdDbSpl.toFloat()
        )

        emitState("active")

        // ─── Route monitor: detectar caída a speaker al desconectar BT ───
        routeMonitor.start()
        // Usa el audio session ID del input stream Oboe para attachear el
        // efecto del framework Android. No requiere MODE_IN_COMMUNICATION.
        // Si no está disponible (dispositivo viejo o HAL sin soporte), se
        // continúa sin él — no es bloqueante.
        try {
            val sessionId = nativeBridge.nativeGetInputSessionId()
            if (sessionId > 0 && NoiseSuppressor.isAvailable()) {
                noiseSuppressor = NoiseSuppressor.create(sessionId)
                noiseSuppressor?.enabled = true
                Log.i(TAG, "NoiseSuppressor attached to session $sessionId")
            } else {
                Log.w(TAG, "NoiseSuppressor not available (sessionId=$sessionId, " +
                        "isAvailable=${NoiseSuppressor.isAvailable()})")
            }
        } catch (e: Exception) {
            Log.w(TAG, "NoiseSuppressor attach failed: ${e.message}")
            noiseSuppressor = null
        }

        result.success(null)
    }

    /**
     * Detiene el pipeline de audio y libera recursos.
     * También detiene el foreground service.
     */
    private fun handleStopAudio(result: MethodChannel.Result) {
        // ─── Detener el monitor de ruta de audio ─────────────────────────
        routeMonitor.stop()

        // ─── Release NoiseSuppressor ANTES de detener el engine ──────────
        noiseSuppressor?.release()
        noiseSuppressor = null

        nativeBridge.stop()

        // Si el modo conversación estaba ON, liberar SCO también para no
        // dejar el sistema en MODE_IN_COMMUNICATION sin streams encima.
        if (conversationMode) {
            scoController.stop()
        }

        // Stop the foreground service
        val serviceIntent = Intent(context, AudioForegroundService::class.java).apply {
            action = AudioForegroundService.ACTION_STOP
        }
        context.startService(serviceIntent)

        emitState("idle")
        result.success(null)
    }

    /**
     * Activa o desactiva el "Modo Conversación".
     *
     * ON  → si el motor está corriendo, lo detiene, levanta SCO con
     *       [BluetoothScoController] y vuelve a iniciar a 16 kHz / 64
     *       frames con MODE_IN_COMMUNICATION. Si el motor no está
     *       corriendo, sólo guarda el flag y el próximo `startAudio`
     *       arrancará con el SR adecuado.
     * OFF → libera SCO + restaura modo NORMAL. Si el motor está corriendo,
     *       lo reinicia a 48 kHz / 256 frames (A2DP por default).
     *
     * Devuelve un string al lado Dart con el resultado del SCO:
     *   - "connected" / "fallback_builtin" / "failed" / "engine_idle" /
     *     "disabled".
     */
    private fun handleSetConversationMode(
        enabled: Boolean,
        result: MethodChannel.Result
    ) {
        if (conversationMode == enabled) {
            result.success(if (scoController.isActive()) "connected" else "engine_idle")
            return
        }
        conversationMode = enabled

        val engineRunning = nativeBridge.getOutputDeviceId() >= 0
        if (!engineRunning) {
            if (!enabled) {
                scoController.stop()
            }
            Log.i(TAG, "setConversationMode($enabled) — engine idle, flag stored")
            result.success("engine_idle")
            return
        }

        // Engine corriendo → reiniciar.
        // Release NoiseSuppressor antes de destruir el engine.
        noiseSuppressor?.release()
        noiseSuppressor = null

        nativeBridge.stop()

        val scoStatus: String
        if (enabled) {
            val r = scoController.start()
            scoStatus = when (r) {
                BluetoothScoController.Result.Connected -> "connected"
                BluetoothScoController.Result.NoBtFallbackBuiltin -> "fallback_builtin"
                BluetoothScoController.Result.Failed -> "failed"
            }
            Log.i(TAG, "setConversationMode(true) → SCO start result=$scoStatus")
            
            // FIX: Si SCO falló completamente, revertir a modo normal
            if (scoStatus == "failed") {
                Log.e(TAG, "SCO failed, reverting to normal mode")
                conversationMode = false
                // Reiniciar en modo normal (48 kHz)
                val sampleRate = 48_000
                val bufferSize = 256
                nativeBridge.nativeSetConversationMode(false)
                
                nativeBridge.start(
                    sampleRate = sampleRate,
                    bufferSize = bufferSize,
                    eqGains = lastEqGains,
                    volumeDb = lastVolumeDb,
                    expansionKnee = lastExpKnee,
                    expansionRatio = lastExpRatio,
                    compressionKnee = lastCompKnee,
                    compressionRatio = lastCompRatio,
                    attackMs = lastAttackMs,
                    releaseMs = lastReleaseMs,
                    nrLevel = 0,
                    mpoThresholdDbSpl = lastMpoDbSpl,
                    splOffset = 120f
                )
                
                // Re-init DNN
                try {
                    nativeBridge.nativeInitDnnDenoiser(context.assets)
                    nativeBridge.nativeSetDnnEnabled(lastDnnEnabled)
                    nativeBridge.nativeSetDnnIntensity(lastDnnIntensity)
                } catch (e: Exception) {
                    Log.w(TAG, "DNN re-init failed after SCO failure: ${e.message}")
                }
                
                result.success("failed")
                return
            }
        } else {
            scoController.stop()
            scoStatus = "disabled"
        }

        // Restart con SR/buffer adecuados al modo actual.
        val sampleRate = if (conversationMode) 16_000 else 48_000
        val bufferSize = if (conversationMode) 64 else 256
        // CRÍTICO: flag de Modo Conversación ANTES de start() (ruteo SCO).
        nativeBridge.nativeSetConversationMode(conversationMode)

        // FIX bug #2 (auditoría bioingeniero): a 16 kHz las bandas 10 (6 kHz)
        // y 11 (8 kHz) del EQ degeneran (8 kHz = Nyquist exacto → sin(π)=0 →
        // filtro inestable; 6 kHz con Q warping severo). Poner 0 dB en esas
        // bandas evita amplificación degenerada que oscurece la voz.
        // Al volver a 48 kHz se restauran las gains originales.
        val eqForMode = if (conversationMode) {
            lastEqGains.copyOf().also { gains ->
                if (gains.size >= 12) {
                    gains[10] = 0f  // 6000 Hz → 0 dB (evitar Q warping)
                    gains[11] = 0f  // 8000 Hz → 0 dB (Nyquist exacto)
                }
            }
        } else {
            lastEqGains
        }

        // FIX bug #5: restaurar nrLevel del usuario (no hardcodear 0).
        // En modo conversación NR=2 permite que el denoiser limpie ruido
        // ambiente mientras preserva la voz cercana.
        val nrForMode = if (conversationMode) 2 else 0

        nativeBridge.start(
            sampleRate = sampleRate,
            bufferSize = bufferSize,
            eqGains = eqForMode,
            volumeDb = if (conversationMode) lastVolumeDb + 10f else lastVolumeDb,
            expansionKnee = lastExpKnee,
            expansionRatio = lastExpRatio,
            compressionKnee = lastCompKnee,
            compressionRatio = lastCompRatio,
            attackMs = lastAttackMs,
            releaseMs = lastReleaseMs,
            nrLevel = nrForMode,
            mpoThresholdDbSpl = lastMpoDbSpl,
            // FIX: el mic SCO (VoiceCommunication 16 kHz) captura con ~15 dB
            // menos de nivel que el mic normal (VoicePerformance 48 kHz).
            // Sin recalibrar, el WDRC "cree" que la señal es más fuerte de lo
            // que realmente es → comprime la voz → sale inaudible.
            // splOffset 105 = calibración para mic SCO (vs 120 para mic normal).
            splOffset = if (conversationMode) 105f else 120f
        )

        // Re-attach NoiseSuppressor al nuevo engine.
        // DESHABILITADO: el NoiseSuppressor de Android es demasiado agresivo
        // para conversación con audífono — corta la voz débil junto al ruido.
        // Nuestro DNN GTCRN es más selectivo (VAD-driven) y preserva la voz.
        // El InputPreset VoiceCommunication ya activa el AEC del HAL (que sí
        // es útil para cancelar eco del parlante), pero NO activamos el NS
        // adicional encima.
        // Ref: auditoría bioingeniero 2026-06-18, bug #3 (doble denoising).

        // Re-init DNN: el motor anterior se destruyó, así que el .onnx hay
        // que cargarlo en el nuevo `g_engine`.
        try {
            nativeBridge.nativeInitDnnDenoiser(context.assets)
            // FIX bug #1 (auditoría bioingeniero 2026-06-18): re-habilitar el
            // DNN con la intensidad que el usuario tenía ANTES del restart.
            // Sin esto, el DNN queda en enabled_=false y el paciente pierde
            // la reducción de ruido silenciosamente.
            nativeBridge.nativeSetDnnEnabled(lastDnnEnabled)
            nativeBridge.nativeSetDnnIntensity(lastDnnIntensity)
            Log.i(TAG, "setConversationMode: DNN re-enabled=$lastDnnEnabled intensity=$lastDnnIntensity")
        } catch (t: Throwable) {
            Log.w(TAG, "setConversationMode: re-initDnnDenoiser failed: ${t.message}")
        }

        result.success(scoStatus)
    }

    /**
     * Habilita/deshabilita el beamforming MVDR dual-mic.
     *
     * En la nueva arquitectura (spec gtcrn-dual-channel), el toggle binario
     * de beamforming mapea al selector de motor de 3 estados:
     *   enabled=true  → kMvdrBackup  (mode=2)
     *   enabled=false → kBypass      (mode=0)
     *
     * El engine maneja internamente el re-open estéreo/mono en caliente
     * (crossfade anti-clic + geometría de captura). NO se necesita restart.
     */
    private fun handleSetBeamformingMode(
        enabled: Boolean,
        result: MethodChannel.Result
    ) {
        val mode = if (enabled) 2 else 0  // 2=kMvdrBackup, 0=kBypass
        nativeBridge.nativeSetEnhancementEngineMode(mode)
        result.success(null)
    }

    /**
     * Actualiza las ganancias del EQ (12 bandas).
     *
     * Argumentos: { "gains": List<Double> }
     */
    private fun handleUpdateEqGains(call: MethodCall, result: MethodChannel.Result) {
        val gainsList = call.argument<List<Double>>("gains")
            ?: return result.error("INVALID_ARGS", "Missing 'gains' argument", null)

        if (gainsList.size < 12) {
            return result.error("INVALID_ARGS", "EQ gains must have 12 values, got ${gainsList.size}", null)
        }

        val gains = FloatArray(12) { i -> gainsList[i].toFloat() }
        lastEqGains = gains.copyOf()
        nativeBridge.setEqGains(gains)
        result.success(null)
    }

    /**
     * Actualiza el volumen maestro.
     *
     * Argumentos: { "volumeDb": Double }
     */
    private fun handleUpdateVolume(call: MethodCall, result: MethodChannel.Result) {
        val volumeDb = call.argument<Double>("volumeDb")
            ?: return result.error("INVALID_ARGS", "Missing 'volumeDb' argument", null)

        lastVolumeDb = volumeDb.toFloat()
        nativeBridge.setVolume(volumeDb.toFloat())
        result.success(null)
    }

    /**
     * Actualiza parámetros del WDRC.
     *
     * Argumentos: { expansionKnee, expansionRatio, compressionKnee,
     *               compressionRatio, attackMs, releaseMs }
     */
    private fun handleUpdateWdrcParams(call: MethodCall, result: MethodChannel.Result) {
        val expKnee = call.argument<Double>("expansionKnee") ?: 35.0
        val expRatio = call.argument<Double>("expansionRatio") ?: 2.0
        val compKnee = call.argument<Double>("compressionKnee") ?: 55.0
        val compRatio = call.argument<Double>("compressionRatio") ?: 2.0
        val attackMs = call.argument<Double>("attackMs") ?: 5.0
        val releaseMs = call.argument<Double>("releaseMs") ?: 100.0

        lastExpKnee = expKnee.toFloat()
        lastExpRatio = expRatio.toFloat()
        lastCompKnee = compKnee.toFloat()
        lastCompRatio = compRatio.toFloat()
        lastAttackMs = attackMs.toFloat()
        lastReleaseMs = releaseMs.toFloat()

        nativeBridge.setWdrcParams(
            expKnee = expKnee.toFloat(),
            expRatio = expRatio.toFloat(),
            compKnee = compKnee.toFloat(),
            compRatio = compRatio.toFloat(),
            attackMs = attackMs.toFloat(),
            releaseMs = releaseMs.toFloat()
        )
        result.success(null)
    }

    /**
     * Configura el Expansor de baja frecuencia ≤1000 Hz (R1, spec
     * mvdr-noise-clarity-tuning). Default OFF/ratio 1.0 → passthrough (R6.5).
     *
     * Argumentos: { enabled: Boolean, kneeDbSpl, ratio, cutoffHz, attackMs,
     *               releaseMs } (todos opcionales; ausencia → default seguro).
     */
    private fun handleSetExpander(call: MethodCall, result: MethodChannel.Result) {
        val enabled = call.argument<Boolean>("enabled") ?: false
        val kneeDbSpl = (call.argument<Double>("kneeDbSpl") ?: 45.0).toFloat()
        val ratio = (call.argument<Double>("ratio") ?: 1.0).toFloat()
        val cutoffHz = (call.argument<Double>("cutoffHz") ?: 1000.0).toFloat()
        val attackMs = (call.argument<Double>("attackMs") ?: 30.0).toFloat()
        val releaseMs = (call.argument<Double>("releaseMs") ?: 400.0).toFloat()
        nativeBridge.setExpander(enabled, kneeDbSpl, ratio, cutoffHz, attackMs, releaseMs)
        result.success(null)
    }

    /**
     * Configura el Supresor de reverberación tardía del MVDR (R5, spec
     * mvdr-noise-clarity-tuning). Default = comportamiento previo (R6.5).
     *
     * Argumentos: { enabled: Boolean, strength, floor, decay } (opcionales).
     */
    private fun handleSetDereverb(call: MethodCall, result: MethodChannel.Result) {
        val enabled = call.argument<Boolean>("enabled") ?: true
        val strength = (call.argument<Double>("strength") ?: 1.6).toFloat()
        val floor = (call.argument<Double>("floor") ?: 0.30).toFloat()
        val decay = (call.argument<Double>("decay") ?: 0.80).toFloat()
        nativeBridge.setDereverb(enabled, strength, floor, decay)
        result.success(null)
    }

    /**
     * Configura los umbrales del clasificador de entorno (R4, spec
     * mvdr-noise-clarity-tuning). Default = valores previos (R6.5).
     *
     * Argumentos: { speechEnterDb, speechExitDb, noiseSnrDb, quietEnterDbSpl,
     *               quietExitDbSpl } (opcionales; ausencia → default previo).
     */
    private fun handleSetClassifierThresholds(call: MethodCall, result: MethodChannel.Result) {
        val speechEnterDb = (call.argument<Double>("speechEnterDb") ?: 6.0).toFloat()
        val speechExitDb = (call.argument<Double>("speechExitDb") ?: 4.0).toFloat()
        val noiseSnrDb = (call.argument<Double>("noiseSnrDb") ?: 1.5).toFloat()
        val quietEnterDbSpl = (call.argument<Double>("quietEnterDbSpl") ?: 44.0).toFloat()
        val quietExitDbSpl = (call.argument<Double>("quietExitDbSpl") ?: 49.0).toFloat()
        nativeBridge.setClassifierThresholds(
            speechEnterDb, speechExitDb, noiseSnrDb, quietEnterDbSpl, quietExitDbSpl
        )
        result.success(null)
    }

    /**
     * Actualiza el nivel de reducción de ruido.
     *
     * Argumentos: { "level": Int } (0=off, 1=bajo, 2=medio, 3=alto)
     */
    private fun handleUpdateNrLevel(call: MethodCall, result: MethodChannel.Result) {
        val level = call.argument<Int>("level")
            ?: return result.error("INVALID_ARGS", "Missing 'level' argument", null)

        if (level !in 0..3) {
            return result.error("INVALID_ARGS", "NR level must be 0-3, got $level", null)
        }

        nativeBridge.setNrLevel(level)
        result.success(null)
    }

    /**
     * Habilita/deshabilita la clasificación automática de entorno.
     *
     * Argumentos: { "enabled": Boolean }
     */
    private fun handleUpdateAutoClassify(call: MethodCall, result: MethodChannel.Result) {
        val enabled = call.argument<Boolean>("enabled")
            ?: return result.error("INVALID_ARGS", "Missing 'enabled' argument", null)

        nativeBridge.setAutoClassifyEnabled(enabled)
        result.success(null)
    }

    /**
     * Pin del preset Smart Scene aplicado manualmente.
     *
     * Cuando es true, el clasificador automático sigue corriendo y publica
     * la clase actual en `getCurrentEnvironmentClass()`, pero NO machaca
     * los targets del WDRC + NR cuando cambia la escena. El preset Smart
     * manual (NR + WDRC + EQ) se mantiene vigente hasta que la UI libere
     * el pin (false). Resuelve la Causa C documentada en
     * docs/smart-scene-diagnostico-chasquido.md.
     *
     * Argumentos: { "pinned": Boolean }
     */
    private fun handleSetSmartPresetPinned(call: MethodCall, result: MethodChannel.Result) {
        val pinned = call.argument<Boolean>("pinned")
            ?: return result.error("INVALID_ARGS", "Missing 'pinned' argument", null)

        nativeBridge.setSmartPresetPinned(pinned)
        result.success(null)
    }

    /**
     * Aplica datos de calibración (offset de micrófono y compensación de auricular).
     *
     * Argumentos: { "micSplOffset": Double, "headphoneCompensations": Map }
     */
    private fun handleApplyCalibration(call: MethodCall, result: MethodChannel.Result) {
        val micSplOffset = call.argument<Double>("micSplOffset") ?: 120.0
        nativeBridge.setSplOffset(micSplOffset.toFloat())

        // Si hay compensación de auricular, aplicar al EQ
        // (La compensación se suma a las ganancias prescritas en el lado Dart,
        //  pero el offset SPL se aplica directamente al engine nativo)
        result.success(null)
    }

    /**
     * Actualiza el threshold del MPO en dB SPL en runtime sin reiniciar el motor.
     *
     * El motor nativo convierte dB SPL → lineal usando el splOffset actual:
     *   linear = pow(10, (thresholdDbSpl - splOffset) / 20)
     * y lo aplica al MpoLimiter del DspPipeline.
     *
     * Argumentos: { "thresholdDbSpl": Double } (rango clínico [80.0, 132.0])
     *
     * La validación clínica del rango se hace en el lado Dart (AudioBridgeImpl).
     * Aquí solo se verifica la presencia y finitud del argumento.
     *
     * Implementa Requirement 3 de la spec `audiogram-driven-presets`.
     */
    private fun handleSetMpoThresholdDbSpl(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val thresholdDbSpl = call.argument<Double>("thresholdDbSpl")
            ?: return result.error(
                "INVALID_ARGS",
                "Missing 'thresholdDbSpl' argument",
                null,
            )

        if (thresholdDbSpl.isNaN() || thresholdDbSpl.isInfinite()) {
            return result.error(
                "INVALID_ARGS",
                "thresholdDbSpl must be finite, got $thresholdDbSpl",
                null,
            )
        }

        lastMpoDbSpl = thresholdDbSpl.toFloat()
        nativeBridge.setMpoThresholdDbSpl(thresholdDbSpl.toFloat())
        result.success(null)
    }

    /**
     * Devuelve información de diagnóstico del engine nativo.
     * Se muestra en la UI para debugging sin ADB.
     */
    private fun handleGetDebugInfo(result: MethodChannel.Result) {
        val level = nativeBridge.getInputLevel()
        val inputDeviceId = nativeBridge.getInputDeviceId()
        val outputDeviceId = nativeBridge.getOutputDeviceId()
        val info = buildString {
            appendLine("=== Debug Info ===")
            appendLine("State: $currentState")
            appendLine("NativeBridge level: $level dB SPL")
            appendLine("Input device ID: $inputDeviceId")
            appendLine("Output device ID: $outputDeviceId")
            appendLine("LevelListener active: ${nativeBridge.getInputLevel() != 0f}")
            appendLine("LevelEventSink: ${if (levelEventSink != null) "connected" else "null"}")
            appendLine("StateEventSink: ${if (stateEventSink != null) "connected" else "null"}")
            appendLine("==================")
        }
        result.success(info)
    }

    /**
     * Devuelve información de dispositivos de audio conectados.
     * Incluye: micrófono activo, auricular BT conectado, device IDs.
     */
    private fun handleGetDeviceInfo(result: MethodChannel.Result) {
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // Get input devices (microphones)
        val inputDevices = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
        val builtInMic = inputDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_MIC }

        // Get output devices
        val outputDevices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val btA2dp = outputDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP }
        val btSco = outputDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
        val btDevice = btA2dp ?: btSco

        // Get active device IDs from native engine
        val activeInputDeviceId = nativeBridge.getInputDeviceId()
        val activeOutputDeviceId = nativeBridge.getOutputDeviceId()

        // Find the active input device name
        val activeInputDevice = inputDevices.firstOrNull { it.id == activeInputDeviceId }
        val inputDeviceName = activeInputDevice?.productName?.toString()
            ?: builtInMic?.productName?.toString()
            ?: "Micrófono integrado"

        // Find the active output device name
        val activeOutputDevice = outputDevices.firstOrNull { it.id == activeOutputDeviceId }
        val outputDeviceName = activeOutputDevice?.productName?.toString()
            ?: btDevice?.productName?.toString()
            ?: "Parlante del dispositivo"

        val deviceInfo = mapOf(
            "inputDeviceId" to activeInputDeviceId,
            "inputDeviceName" to inputDeviceName,
            "inputDeviceType" to (activeInputDevice?.type ?: builtInMic?.type ?: -1),
            "outputDeviceId" to activeOutputDeviceId,
            "outputDeviceName" to outputDeviceName,
            "outputDeviceType" to (activeOutputDevice?.type ?: btDevice?.type ?: -1),
            "bluetoothConnected" to (btDevice != null),
            "bluetoothName" to (btDevice?.productName?.toString() ?: ""),
            "bluetoothIsA2dp" to (btA2dp != null),
            "availableInputDevices" to inputDevices.map { mapOf(
                "id" to it.id,
                "name" to (it.productName?.toString() ?: "Unknown"),
                "type" to it.type
            ) },
            "availableOutputDevices" to outputDevices.map { mapOf(
                "id" to it.id,
                "name" to (it.productName?.toString() ?: "Unknown"),
                "type" to it.type
            ) }
        )

        result.success(deviceInfo)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Emisión de eventos a Flutter
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Inicia las actualizaciones de nivel de entrada hacia Flutter (~10 Hz).
     * Usa el LevelListener del NativeAudioBridge.
     */
    private fun startLevelUpdates() {
        nativeBridge.setLevelListener { levelDbSpl ->
            levelEventSink?.success(levelDbSpl.toDouble())
        }
    }

    /**
     * Detiene las actualizaciones de nivel de entrada.
     */
    private fun stopLevelUpdates() {
        nativeBridge.setLevelListener(null)
    }

    /**
     * Emite un cambio de estado del motor de audio a Flutter.
     *
     * @param state Uno de: "idle", "starting", "active", "paused", "error"
     */
    fun emitState(state: String) {
        currentState = state
        stateEventSink?.success(state)
        Log.d(TAG, "State emitted: $state")
    }

    // ─────────────────────────────────────────────────────────────────────
    // Handlers de calibración nativa (spec: native-calibration-handlers)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Spec: native-calibration-handlers, Requirement 1.
     *
     * Lee 100 ms de audio del [AudioRecord] PRE-EQ (no pasa por el pipeline
     * DSP del proyecto), calcula RMS dBFS, opcionalmente suma `micOffsetDb`
     * recibido como argumento desde Dart para reportar dB SPL.
     */
    private fun handleGetInputLevel(call: MethodCall, result: MethodChannel.Result) {
        Log.i(TAG, "getInputLevel: START")
        val micOffsetDb = call.argument<Double>("micOffsetDb")
        val capture = CalibrationAudioCapture.create(context)
        if (capture == null) {
            Log.e(TAG, "getInputLevel: AUDIO_RECORD_FAILED")
            result.error(
                "AUDIO_RECORD_FAILED",
                "No se pudo abrir AudioRecord. Verificá permiso RECORD_AUDIO " +
                    "y que el micrófono no esté ocupado por otra app.",
                null,
            )
            return
        }
        try {
            val dbfs = capture.readWindowRmsDbfs(durationMs = 100)
            val response = mutableMapOf<String, Any?>(
                "dbfs" to dbfs,
                "durationMs" to 100,
                "sampleRate" to CalibrationAudioCapture.SAMPLE_RATE_HZ,
                "calibrated" to (micOffsetDb != null),
                "micOffsetDb" to micOffsetDb,
                "dbSpl" to micOffsetDb?.let { it + dbfs },
            )
            Log.i(
                TAG,
                "getInputLevel: END dbfs=$dbfs " +
                    "calibrated=${micOffsetDb != null} dbSpl=${response["dbSpl"]}"
            )
            result.success(response)
        } catch (e: Throwable) {
            Log.e(TAG, "getInputLevel: AUDIO_RECORD_READ_FAILED", e)
            result.error(
                "AUDIO_RECORD_READ_FAILED",
                e.message ?: "AudioRecord.read falló",
                e.stackTraceToString(),
            )
        } finally {
            capture.release()
        }
    }

    /**
     * Spec: native-calibration-handlers, Requirement 2.
     *
     * Captura 5 segundos (50 ventanas de 100 ms, descarta primeras 5),
     * valida estabilidad (`std ≤ 1.0`) y rango (`avg ∈ [-40, -10]`),
     * calcula `mic_offset_db = referenceSplLevel − avg_dbfs`.
     */
    private fun handleCalibrateMicrophone(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        Log.i(TAG, "calibrateMicrophone: START")
        val refSpl = call.argument<Double>("referenceSplLevel") ?: 94.0
        val calibratorModel = call.argument<String>("calibratorModel") ?: "unknown"
        val operatorId = call.argument<String>("operatorId") ?: "unknown"
        val expectedFreq = call.argument<Double>("expectedFreqHz") ?: 1000.0

        val capture = CalibrationAudioCapture.create(context)
        if (capture == null) {
            Log.e(TAG, "calibrateMicrophone: AUDIO_RECORD_FAILED")
            result.error(
                "AUDIO_RECORD_FAILED",
                "No se pudo abrir AudioRecord para calibración.",
                null,
            )
            return
        }
        try {
            Log.i(TAG, "calibrateMicrophone: AUDIO_RECORD_OPENED")
            Log.i(TAG, "calibrateMicrophone: CAPTURE_BEGIN (50 windows × 100 ms)")
            val windows = capture.readManyWindowsRmsDbfs(
                durationMs = 100,
                count = 50,
                dropFirst = 5,
            )
            val rmsAvg = windows.average()
            val rmsStd = windows.populationStandardDeviation()
            Log.i(
                TAG,
                "calibrateMicrophone: CAPTURE_END rmsAvg=$rmsAvg rmsStd=$rmsStd " +
                    "windows=${windows.size}"
            )

            if (rmsStd > 1.0) {
                Log.e(
                    TAG,
                    "calibrateMicrophone: VALIDATION_FAIL UNSTABLE_SIGNAL " +
                        "(rmsStd=$rmsStd > 1.0)",
                )
                result.error(
                    "UNSTABLE_SIGNAL",
                    "Señal inestable: desviación estándar de ${"%.3f".format(rmsStd)} " +
                        "dB excede el límite de 1.0 dB. " +
                        "Verificá que el calibrador esté firme contra el micrófono " +
                        "y que no haya ruido ambiental excesivo.",
                    null,
                )
                return
            }
            if (rmsAvg !in -40.0..-10.0) {
                Log.e(
                    TAG,
                    "calibrateMicrophone: VALIDATION_FAIL LEVEL_OUT_OF_RANGE " +
                        "(rmsAvg=$rmsAvg ∉ [-40, -10])",
                )
                result.error(
                    "LEVEL_OUT_OF_RANGE",
                    "Nivel fuera de rango: ${"%.2f".format(rmsAvg)} dBFS no está " +
                        "en [-40, -10]. Verificá que el calibrador esté encendido " +
                        "y produciendo el tono de referencia (1 kHz @ 94 dB SPL).",
                    null,
                )
                return
            }

            val micOffset = refSpl - rmsAvg
            val confidence = if (rmsStd < 0.5) 1.0 else 0.7
            Log.i(
                TAG,
                "calibrateMicrophone: VALIDATION_PASS OFFSET_COMPUTED " +
                    "($micOffset dB, confidence=$confidence)"
            )

            val response = mapOf<String, Any?>(
                "splOffset" to micOffset,
                "confidenceLevel" to confidence,
                "method" to "external_ref",
                "calibratedAtMs" to System.currentTimeMillis(),
                "deviceModel" to Build.MODEL,
                "rmsAvgDbfs" to rmsAvg,
                "rmsStdDbfs" to rmsStd,
                "referenceSplLevel" to refSpl,
                "calibratorModel" to calibratorModel,
                "operatorId" to operatorId,
                "expectedFreqHz" to expectedFreq,
                "windowsUsed" to windows.size,
            )
            Log.i(TAG, "calibrateMicrophone: END")
            result.success(response)
        } catch (e: Throwable) {
            Log.e(TAG, "calibrateMicrophone: AUDIO_RECORD_READ_FAILED", e)
            result.error(
                "AUDIO_RECORD_READ_FAILED",
                e.message ?: "AudioRecord.read falló durante calibración",
                e.stackTraceToString(),
            )
        } finally {
            capture.release()
        }
    }

    /**
     * Spec: native-calibration-handlers, Requirement 3.
     *
     * Reproduce 12 tonos puros a -20 dBFS por el auricular (vía AudioTrack)
     * y captura simultáneamente con AudioRecord; calcula tabla de offsets
     * por banda. Requiere `mic_offset_db` previamente computado y pasado
     * como argumento desde Dart.
     */
    private fun handleCalibrateHeadphones(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        Log.i(TAG, "calibrateHeadphones: START")
        val headphoneId = call.argument<String>("headphoneId")
            ?: return result.error(
                "INVALID_ARGS",
                "Falta argumento 'headphoneId'.",
                null,
            )
        val headphoneName = call.argument<String>("headphoneName") ?: headphoneId
        val couplerModel = call.argument<String>("couplerModel") ?: "HA-2"
        val operatorId = call.argument<String>("operatorId") ?: "unknown"
        val micOffsetDb = call.argument<Double>("micOffsetDb")
        if (micOffsetDb == null) {
            Log.e(TAG, "calibrateHeadphones: MIC_NOT_CALIBRATED")
            result.error(
                "MIC_NOT_CALIBRATED",
                "El micrófono no está calibrado. Calibrá el micrófono " +
                    "primero antes de calibrar el auricular.",
                null,
            )
            return
        }
        val toneLevelDbfs = call.argument<Double>("toneLevelDbfs") ?: -20.0
        val toneDurationMs = call.argument<Int>("toneDurationMs") ?: 1500
        val silenceMs = call.argument<Int>("silenceMs") ?: 500

        val frequencies = listOf(
            250, 500, 750, 1000, 1500, 2000,
            2500, 3000, 3500, 4000, 6000, 8000,
        )

        val capture = CalibrationAudioCapture.create(context)
        if (capture == null) {
            Log.e(TAG, "calibrateHeadphones: AUDIO_RECORD_FAILED")
            result.error(
                "AUDIO_RECORD_FAILED",
                "No se pudo abrir AudioRecord para calibración hp.",
                null,
            )
            return
        }
        Log.i(TAG, "calibrateHeadphones: AUDIO_RECORD_OPENED")
        val emitter = CalibrationToneEmitter()
        Log.i(TAG, "calibrateHeadphones: AUDIO_TRACK_OPENED")

        try {
            val targetDbspl = toneLevelDbfs + micOffsetDb
            val splDbsplList = ArrayList<Double>(frequencies.size)
            val hpOffsetList = ArrayList<Double>(frequencies.size)

            for ((index, freq) in frequencies.withIndex()) {
                Log.i(
                    TAG,
                    "calibrateHeadphones: TONE_BEGIN freq=$freq " +
                        "expectedDbfs=$toneLevelDbfs"
                )
                // Lanzar tono en thread paralelo y capturar simultáneamente.
                val playerThread = Thread {
                    emitter.playTone(
                        freqHz = freq.toDouble(),
                        levelDbfs = toneLevelDbfs,
                        durationMs = toneDurationMs,
                    )
                }
                playerThread.start()
                // Descartar 200 ms iniciales (estabilización del DAC).
                Thread.sleep(200)
                // Capturar 1300 ms restantes.
                val measureMs = toneDurationMs - 200
                val rmsDbfs = capture.readWindowRmsDbfs(durationMs = measureMs)
                playerThread.join()
                if (rmsDbfs.isNaN() || rmsDbfs.isInfinite()) {
                    capture.release()
                    Log.e(
                        TAG,
                        "calibrateHeadphones: BAND_OUT_OF_RANGE freq=$freq " +
                            "rmsDbfs=$rmsDbfs (NaN/Inf)"
                    )
                    result.error(
                        "BAND_OUT_OF_RANGE",
                        "Banda $freq Hz produjo medición inválida (NaN/Inf). " +
                            "Verificá la conexión del auricular.",
                        null,
                    )
                    return
                }
                val splDbspl = rmsDbfs + micOffsetDb
                val hpOffset = splDbspl - targetDbspl
                Log.i(
                    TAG,
                    "calibrateHeadphones: TONE_END freq=$freq " +
                        "rmsDbfs=$rmsDbfs spl=$splDbspl offset=$hpOffset"
                )
                if (hpOffset !in -30.0..30.0) {
                    Log.e(
                        TAG,
                        "calibrateHeadphones: BAND_OUT_OF_RANGE freq=$freq " +
                            "hpOffset=$hpOffset"
                    )
                    val msg = if (hpOffset < -30.0) {
                        "Banda $freq Hz fuera de rango (offset=${"%.2f".format(hpOffset)} dB). " +
                            "El auricular podría estar desconectado o el acoplador " +
                            "mal puesto."
                    } else {
                        "Banda $freq Hz fuera de rango (offset=${"%.2f".format(hpOffset)} dB). " +
                            "Posible feedback del altavoz del celular hacia su " +
                            "propio micrófono — conectá el auricular."
                    }
                    result.error("BAND_OUT_OF_RANGE", msg, null)
                    return
                }

                splDbsplList.add(splDbspl)
                hpOffsetList.add(hpOffset)

                // Pausa entre tonos.
                if (index < frequencies.size - 1) {
                    Thread.sleep(silenceMs.toLong())
                }
            }

            // Validación de discontinuidad entre bandas adyacentes.
            for (i in 0 until hpOffsetList.size - 1) {
                val diff = kotlin.math.abs(hpOffsetList[i + 1] - hpOffsetList[i])
                if (diff > 15.0) {
                    Log.e(
                        TAG,
                        "calibrateHeadphones: BAND_DISCONTINUITY entre " +
                            "${frequencies[i]}-${frequencies[i + 1]} Hz (diff=$diff dB)"
                    )
                    result.error(
                        "BAND_DISCONTINUITY",
                        "Discontinuidad entre bandas ${frequencies[i]} Hz " +
                            "(offset=${"%.2f".format(hpOffsetList[i])} dB) y " +
                            "${frequencies[i + 1]} Hz (offset=${"%.2f".format(hpOffsetList[i + 1])} dB). " +
                            "Diferencia de ${"%.2f".format(diff)} dB excede 15 dB. " +
                            "El acoplador probablemente está mal puesto.",
                        null,
                    )
                    return
                }
            }

            val isBluetooth = headphoneId.matches(
                Regex("^[0-9A-F]{2}(:[0-9A-F]{2}){5}$", RegexOption.IGNORE_CASE),
            )

            val frequencyResponse = mutableMapOf<String, Double>()
            val compensation = mutableMapOf<String, Double>()
            for ((idx, freq) in frequencies.withIndex()) {
                frequencyResponse[freq.toString()] = splDbsplList[idx]
                compensation[freq.toString()] = -hpOffsetList[idx]
            }

            val response = mapOf<String, Any?>(
                "frequencyResponse" to frequencyResponse,
                "compensation" to compensation,
                "headphoneId" to headphoneId,
                "headphoneName" to headphoneName,
                "calibratedAtMs" to System.currentTimeMillis(),
                "isBluetooth" to isBluetooth,
                "couplerModel" to couplerModel,
                "operatorId" to operatorId,
                "deviceModel" to Build.MODEL,
                "micOffsetDb" to micOffsetDb,
                "targetDbspl" to targetDbspl,
                "frequenciesHz" to frequencies,
                "splDbspl" to splDbsplList,
                "hpOffsetDb" to hpOffsetList,
            )
            Log.i(TAG, "calibrateHeadphones: END (12 bandas medidas con éxito)")
            result.success(response)
        } catch (e: Throwable) {
            Log.e(TAG, "calibrateHeadphones: NATIVE_ERROR", e)
            result.error(
                "NATIVE_ERROR",
                e.message ?: "Error en calibración de auriculares",
                e.stackTraceToString(),
            )
        } finally {
            capture.release()
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // MHL Prescripción / Modo Música — espejo de AudioMethodChannelPatient.kt
    // (tecnico-paciente-feature-parity, task 1.6).
    //
    // Estos helpers reproducen bit-a-bit la lógica del paciente:
    //   - applyMhlPrescription(true): EQ flat 8 dB en las 12 bandas + WDRC
    //     con `compRatio = 1.0` (preservando knees/expansion/attack/release del
    //     preset activo, tomados del cache last*) + setAutoClassifyEnabled(false).
    //   - applyMhlPrescription(false): restaura EQ y WDRC desde el cache last*.
    //   - applyMusicMode(true): nrLevel=0 + dnnIntensity=0.0 + setAutoClassifyEnabled(false).
    //     EQ y WDRC quedan como están (el preset sigue aplicándose).
    //   - applyMusicMode(false): no-op a nivel motor — Dart reaplica nrLevel y
    //     dnnIntensity desde Settings.
    //
    // El lado Dart (AmplificationBloc) además gestiona el snapshot/restore del
    // toggle Smart y reaplica el preset al desactivar; este nivel solo replica
    // las llamadas JNI que el paciente hace.
    //
    // ⚠️ NOTA (patient-dsp-controls-fix — Tarea 4): el `setAutoClassifyEnabled(false)`
    // que estos helpers invocan es REDUNDANTE / DEFENSIVO, NO la fuente del
    // alivio sonoro. Desde la Tarea 1, el clasificador automático ya queda
    // apagado en el modo normal del Técnico (`updateAutoClassify(false)` al
    // boot), así que MHL/Música YA NO son lo que estabiliza el sonido. La
    // estabilización real viene de la cadena coherente MPO→WDRC→EQ con clamp
    // de headroom (Tareas 1-3). Se conserva la llamada porque no hace daño
    // (idempotente) y cubre el caso borde de un polling viejo que reactive el
    // clasificador, pero MHL volvió a ser lo que clínicamente representa: un
    // modo de prescripción selectivo, no un "botón de pánico".
    // ─────────────────────────────────────────────────────────────────────

    /**
     * MHL — Prescripción mínima.
     *
     * ON  → gains flat de 8 dB en las 12 bandas + compresión 1.0:1 (lineal)
     *       preservando el resto de los WDRC params del preset (knees,
     *       attack, release, expansion). Apaga el clasificador automático
     *       a nivel motor.
     * OFF → restaura el último EQ y WDRC guardados (los del preset activo,
     *       cacheados en lastEqGains / last*Knee / last*Ratio).
     */
    private fun applyMhlPrescription(enabled: Boolean) {
        if (enabled) {
            val flatGains = FloatArray(12) { 8f }
            nativeBridge.setEqGains(flatGains)
            // Compresión MUY suave 1.5:1 (etapa 2 — saturación residual).
            //
            // Cambio respecto del 1.0:1 anterior: ningún fabricante grande
            // (Phonak/Oticon/Widex/GN/Starkey/Signia) corre CR=1.0 broadband
            // con gains altos en MHL/Mild HL — Phonak APD 2.0 linealiza
            // selectivamente por nivel/banda, nunca todo plano. CR=1.5
            // mantiene la idea de "Minimal Hearing Loss = compresión muy
            // suave" pero protege transitorios de voz fuerte sin sacrificar
            // timbre conversacional. Ver Hearing Review MPO whitepaper y
            // Phonak APD 2.0 (notas técnicas Sonova).
            //
            // Resto de WDRC params (knees, attack, release, expansion) se
            // preserva del preset activo.
            nativeBridge.setWdrcParams(
                expKnee = lastExpKnee,
                expRatio = lastExpRatio,
                compKnee = lastCompKnee,
                compRatio = 1.5f,
                attackMs = lastAttackMs,
                releaseMs = lastReleaseMs
            )
            // Apagar el clasificador automático.
            // ⚠️ REDUNDANTE / DEFENSIVO (patient-dsp-controls-fix — Tarea 4):
            // desde la Tarea 1 el clasificador ya queda OFF en el modo normal
            // del Técnico, así que esta llamada NO es lo que estabiliza el
            // sonido — el alivio viene de la cadena coherente MPO→WDRC→EQ. Se
            // mantiene porque es idempotente y cubre el borde de un polling
            // viejo que lo reactive; MHL ya no es la muleta de estabilización.
            nativeBridge.setAutoClassifyEnabled(false)
        } else {
            // Restaurar EQ y WDRC originales del preset activo.
            nativeBridge.setEqGains(lastEqGains)
            nativeBridge.setWdrcParams(
                expKnee = lastExpKnee,
                expRatio = lastExpRatio,
                compKnee = lastCompKnee,
                compRatio = lastCompRatio,
                attackMs = lastAttackMs,
                releaseMs = lastReleaseMs
            )
        }
    }

    /**
     * Modo Música.
     *
     * ON  → NR=0 (Off) + DNN intensity 0.0 para preservar timbres y dinámicas.
     *       EQ y WDRC quedan como están (el preset sigue aplicándose).
     * OFF → restauración la hace Dart leyendo SettingsRepository.nrLevel y
     *       SettingsRepository.dnnIntensity (los settings persisten el valor
     *       que el técnico eligió antes de activar Modo Música).
     */
    private fun applyMusicMode(enabled: Boolean) {
        if (enabled) {
            nativeBridge.setNrLevel(0)
            nativeBridge.nativeSetDnnIntensity(0.0f)
            // ⚠️ REDUNDANTE / DEFENSIVO (patient-dsp-controls-fix — Tarea 4):
            // el clasificador ya queda OFF en el modo normal del Técnico desde
            // la Tarea 1. Modo Música no estabiliza por apagar el clasificador;
            // solo preserva timbres/dinámicas (NR=0 + DNN=0). Se conserva la
            // llamada por ser idempotente y defensiva.
            nativeBridge.setAutoClassifyEnabled(false)
        }
        // OFF: el lado Dart reaplica nrLevel + dnnIntensity desde Settings.
    }
}

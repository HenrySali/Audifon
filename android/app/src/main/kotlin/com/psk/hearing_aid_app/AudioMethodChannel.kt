package com.psk.hearing_aid_app

import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
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

    /** Sink para emitir nivel de entrada a Flutter. */
    private var levelEventSink: EventChannel.EventSink? = null

    /** Sink para emitir estado del engine a Flutter. */
    private var stateEventSink: EventChannel.EventSink? = null

    /** Estado actual del motor de audio. */
    private var currentState: String = "idle"

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
                "updateAutoClassify" -> handleUpdateAutoClassify(call, result)
                "applyCalibration" -> handleApplyCalibration(call, result)
                "setMpoThresholdDbSpl" -> handleSetMpoThresholdDbSpl(call, result)
                "getDebugInfo" -> handleGetDebugInfo(result)
                "getDeviceInfo" -> handleGetDeviceInfo(result)
                // Spectrum Analyzer
                "startSpectrumAnalysis" -> { nativeBridge.nativeStartSpectrumAnalysis(); result.success(null) }
                "stopSpectrumAnalysis" -> { nativeBridge.nativeStopSpectrumAnalysis(); result.success(null) }
                "startSpectrumRecording" -> { nativeBridge.nativeStartSpectrumRecording(); result.success(null) }
                "stopSpectrumRecording" -> { val count = nativeBridge.nativeStopSpectrumRecording(); result.success(count) }
                "getRecordingData" -> { val data = nativeBridge.nativeGetRecordingData(); result.success(data) }
                "getCurrentSpectrum" -> { val data = nativeBridge.nativeGetCurrentSpectrum(); result.success(data) }
                // DSP Stage Metrics (para diagnóstico del pipeline)
                "getDspStageMetrics" -> { val metrics = nativeBridge.getDspStageMetrics(); result.success(metrics) }
                // Transient Noise Reducer (TNR)
                "updateTnrEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    nativeBridge.nativeSetTnrEnabled(enabled)
                    result.success(null)
                }
                // Smart Scene Engine (Fase 1)
                "getSceneSnapshot" -> {
                    val data = nativeBridge.nativeGetSceneSnapshot()
                    result.success(data)
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
                    nativeBridge.nativeSetDnnEnabled(enabled)
                    result.success(null)
                }
                "setDnnIntensity" -> {
                    val intensity = (call.argument<Double>("intensity") ?: 1.0).toFloat()
                    nativeBridge.nativeSetDnnIntensity(intensity)
                    result.success(null)
                }
                "getDnnIsActive" -> {
                    val active = nativeBridge.nativeGetDnnIsActive()
                    result.success(active)
                }
                // Diagnostic Recording (DSP Verification)
                "startDiagnosticRecording" -> handleStartDiagnosticRecording(call, result)
                "stopDiagnosticRecording" -> handleStopDiagnosticRecording(result)
                "getDiagnosticRecordingProgress" -> handleGetDiagnosticRecordingProgress(result)
                // ─── Calibración de hardware (C-3, native-calibration-handlers) ─
                // Implementación real de los 3 handlers con AudioRecord directo
                // (no pasa por el pipeline DSP del proyecto). Persistencia +
                // audit trail SHA-256 ocurren en el lado Dart.
                "getInputLevel" -> handleGetInputLevel(call, result)
                "calibrateMicrophone" -> handleCalibrateMicrophone(call, result)
                "calibrateHeadphones" -> handleCalibrateHeadphones(call, result)
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
        val sampleRate = call.argument<Int>("sampleRate") ?: 48000
        val bufferSize = call.argument<Int>("bufferSize") ?: 256
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

        emitState("starting")

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
        result.success(null)
    }

    /**
     * Detiene el pipeline de audio y libera recursos.
     * También detiene el foreground service.
     */
    private fun handleStopAudio(result: MethodChannel.Result) {
        nativeBridge.stop()

        // Stop the foreground service
        val serviceIntent = Intent(context, AudioForegroundService::class.java).apply {
            action = AudioForegroundService.ACTION_STOP
        }
        context.startService(serviceIntent)

        emitState("idle")
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
    // Handlers de Diagnostic Recording (DSP Verification)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Inicia grabación de diagnóstico DSP.
     * Construye la ruta usando getExternalFilesDir + filename recibido de Flutter.
     * Argumentos: { "filePath": String }
     */
    private fun handleStartDiagnosticRecording(call: MethodCall, result: MethodChannel.Result) {
        val filePath = call.argument<String>("filePath")
            ?: return result.error("INVALID_ARGS", "Missing 'filePath' argument", null)

        // Construct full path using app-specific external storage
        val dir = context.getExternalFilesDir(null)
            ?: return result.error("STORAGE_ERROR", "External storage not available", null)

        val fullPath = "${dir.absolutePath}/$filePath"

        val ok = nativeBridge.nativeStartDiagnosticRecording(fullPath)
        result.success(ok)
    }

    /**
     * Detiene la grabación de diagnóstico.
     * @return 0=success, 1=discarded, -1=error
     */
    private fun handleStopDiagnosticRecording(result: MethodChannel.Result) {
        val status = nativeBridge.nativeStopDiagnosticRecording()
        result.success(status)
    }

    /**
     * Obtiene el progreso de la grabación de diagnóstico en milisegundos.
     */
    private fun handleGetDiagnosticRecordingProgress(result: MethodChannel.Result) {
        val progress = nativeBridge.nativeGetDiagnosticRecordingProgress()
        result.success(progress)
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
}

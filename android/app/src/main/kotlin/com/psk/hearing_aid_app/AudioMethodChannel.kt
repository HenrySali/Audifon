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
                "applyCalibration" -> handleApplyCalibration(call, result)
                "getDebugInfo" -> handleGetDebugInfo(result)
                "getDeviceInfo" -> handleGetDeviceInfo(result)
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
}

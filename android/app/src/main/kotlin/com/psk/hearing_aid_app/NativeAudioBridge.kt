package com.psk.hearing_aid_app

import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Puente JNI entre Kotlin y el pipeline DSP C++.
 *
 * Esta clase declara los métodos nativos implementados en `native_bridge.cpp`
 * y proporciona una API Kotlin-friendly para controlar el pipeline de audio.
 *
 * Todas las actualizaciones de parámetros son thread-safe (lock-free, atómicas).
 * El nivel de entrada se obtiene por polling a ~10 Hz usando un Handler.
 *
 * Uso típico:
 * ```kotlin
 * val bridge = NativeAudioBridge()
 * bridge.setLevelListener { levelDbSpl -> updateUI(levelDbSpl) }
 * bridge.start(config)
 * // ... actualizar parámetros en tiempo real ...
 * bridge.stop()
 * ```
 */
class NativeAudioBridge {

    companion object {
        private const val TAG = "NativeAudioBridge"

        /** Intervalo de polling del nivel de entrada (~10 Hz = 100 ms). */
        private const val LEVEL_POLL_INTERVAL_MS = 100L

        init {
            System.loadLibrary("hearing_aid_dsp")
            Log.i(TAG, "Native library 'hearing_aid_dsp' loaded")
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Listener de nivel de entrada
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Callback invocado ~10 Hz con el nivel de entrada PRE-EQ en dB SPL.
     */
    fun interface LevelListener {
        fun onLevel(levelDbSpl: Float)
    }

    private var levelListener: LevelListener? = null
    private val handler = Handler(Looper.getMainLooper())
    private var isPolling = false

    private val levelPollRunnable = object : Runnable {
        override fun run() {
            if (!isPolling) return
            val level = nativeGetInputLevel()
            levelListener?.onLevel(level)
            handler.postDelayed(this, LEVEL_POLL_INTERVAL_MS)
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // API pública
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Registra un listener para recibir actualizaciones del nivel de entrada.
     * El listener se invoca en el hilo principal (~10 Hz).
     */
    fun setLevelListener(listener: LevelListener?) {
        this.levelListener = listener
    }

    /**
     * Inicia el pipeline DSP con la configuración completa.
     *
     * @param sampleRate Frecuencia de muestreo (típicamente 16000 Hz)
     * @param bufferSize Tamaño de bloque en muestras (típicamente 64)
     * @param eqGains Array de 12 ganancias EQ en dB [0, 50]
     * @param volumeDb Volumen maestro en dB [-20, +10]
     * @param expansionKnee Knee de expansión WDRC en dB SPL
     * @param expansionRatio Ratio de expansión (input:output)
     * @param compressionKnee Knee de compresión WDRC en dB SPL
     * @param compressionRatio Ratio de compresión (input:output)
     * @param attackMs Tiempo de ataque WDRC en ms
     * @param releaseMs Tiempo de liberación WDRC en ms
     * @param nrLevel Nivel de reducción de ruido (0=off, 1=bajo, 2=medio, 3=alto)
     * @param mpoThresholdDbSpl Threshold del MPO en dB SPL (default: 100)
     * @param splOffset Offset de calibración dBFS → dB SPL (default: 120)
     */
    fun start(
        sampleRate: Int = 48000,
        bufferSize: Int = 256,
        eqGains: FloatArray = FloatArray(12) { 0f },
        volumeDb: Float = 0f,
        expansionKnee: Float = 35f,
        expansionRatio: Float = 2f,
        compressionKnee: Float = 55f,
        compressionRatio: Float = 2f,
        attackMs: Float = 5f,
        releaseMs: Float = 100f,
        nrLevel: Int = 0,
        mpoThresholdDbSpl: Float = 100f,
        splOffset: Float = 120f
    ) {
        Log.i(TAG, "start: sampleRate=$sampleRate, bufferSize=$bufferSize, " +
                "volume=${volumeDb}dB, NR=$nrLevel")

        nativeStart(
            sampleRate, bufferSize, eqGains, volumeDb,
            expansionKnee, expansionRatio, compressionKnee, compressionRatio,
            attackMs, releaseMs, nrLevel, mpoThresholdDbSpl, splOffset
        )

        // Iniciar polling de nivel
        startLevelPolling()
    }

    /**
     * Detiene el pipeline y libera recursos nativos.
     */
    fun stop() {
        Log.i(TAG, "stop")
        stopLevelPolling()
        nativeStop()
    }

    /**
     * Actualiza las ganancias del EQ (12 bandas, en dB).
     * Thread-safe, puede llamarse desde cualquier hilo.
     *
     * @param gains Array de 12 valores de ganancia en dB [0, 50]
     */
    fun setEqGains(gains: FloatArray) {
        require(gains.size >= 12) { "EQ gains array must have at least 12 elements" }
        nativeSetEqGains(gains)
    }

    /**
     * Actualiza el volumen maestro.
     * Thread-safe, puede llamarse desde cualquier hilo.
     *
     * @param volumeDb Volumen en dB [-20, +10]
     */
    fun setVolume(volumeDb: Float) {
        nativeSetVolume(volumeDb)
    }

    /**
     * Actualiza parámetros del WDRC.
     * Thread-safe, puede llamarse desde cualquier hilo.
     *
     * @param expKnee Knee de expansión (dB SPL)
     * @param expRatio Ratio de expansión (input:output)
     * @param compKnee Knee de compresión (dB SPL)
     * @param compRatio Ratio de compresión (input:output)
     * @param attackMs Tiempo de ataque (ms)
     * @param releaseMs Tiempo de liberación (ms)
     */
    fun setWdrcParams(
        expKnee: Float = 35f,
        expRatio: Float = 2f,
        compKnee: Float = 55f,
        compRatio: Float = 2f,
        attackMs: Float = 5f,
        releaseMs: Float = 100f
    ) {
        nativeSetWdrcParams(expKnee, expRatio, compKnee, compRatio, attackMs, releaseMs)
    }

    /**
     * Actualiza el nivel de reducción de ruido.
     * Thread-safe, puede llamarse desde cualquier hilo.
     *
     * @param level 0=off, 1=bajo, 2=medio, 3=alto
     */
    fun setNrLevel(level: Int) {
        require(level in 0..3) { "NR level must be 0-3, got $level" }
        nativeSetNrLevel(level)
    }

    /**
     * Actualiza el offset de calibración SPL.
     * Thread-safe, puede llamarse desde cualquier hilo.
     *
     * @param offset Offset en dB (120 para mic real, 76 para WAV)
     */
    fun setSplOffset(offset: Float) {
        nativeSetSplOffset(offset)
    }

    /**
     * Obtiene el último nivel de entrada medido PRE-EQ.
     * Puede llamarse desde cualquier hilo.
     *
     * @return Nivel de entrada en dB SPL
     */
    fun getInputLevel(): Float = nativeGetInputLevel()

    /**
     * Obtiene el device ID del stream de entrada (micrófono).
     * @return Device ID, o -1 si no está activo
     */
    fun getInputDeviceId(): Int = nativeGetInputDeviceId()

    /**
     * Obtiene el device ID del stream de salida (auricular/parlante).
     * @return Device ID, o -1 si no está activo
     */
    fun getOutputDeviceId(): Int = nativeGetOutputDeviceId()

    // ─────────────────────────────────────────────────────────────────────
    // Polling de nivel
    // ─────────────────────────────────────────────────────────────────────

    private fun startLevelPolling() {
        if (isPolling) return
        isPolling = true
        handler.postDelayed(levelPollRunnable, LEVEL_POLL_INTERVAL_MS)
    }

    private fun stopLevelPolling() {
        isPolling = false
        handler.removeCallbacks(levelPollRunnable)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Métodos nativos (implementados en native_bridge.cpp)
    // ─────────────────────────────────────────────────────────────────────

    private external fun nativeStart(
        sampleRate: Int,
        bufferSize: Int,
        eqGains: FloatArray,
        volumeDb: Float,
        expansionKnee: Float,
        expansionRatio: Float,
        compressionKnee: Float,
        compressionRatio: Float,
        attackMs: Float,
        releaseMs: Float,
        nrLevel: Int,
        mpoThresholdDbSpl: Float,
        splOffset: Float
    )

    private external fun nativeStop()

    private external fun nativeSetEqGains(gains: FloatArray)

    private external fun nativeSetVolume(volumeDb: Float)

    private external fun nativeSetWdrcParams(
        expKnee: Float,
        expRatio: Float,
        compKnee: Float,
        compRatio: Float,
        attackMs: Float,
        releaseMs: Float
    )

    private external fun nativeSetNrLevel(level: Int)

    private external fun nativeSetSplOffset(offset: Float)

    private external fun nativeGetInputLevel(): Float

    private external fun nativeGetInputDeviceId(): Int

    private external fun nativeGetOutputDeviceId(): Int

    // ─── Spectrum Analyzer (implementados en native_bridge.cpp) ──────────

    external fun nativeStartSpectrumAnalysis()

    external fun nativeStopSpectrumAnalysis()

    external fun nativeStartSpectrumRecording()

    external fun nativeStopSpectrumRecording(): Int

    external fun nativeGetRecordingData(): ByteArray

    external fun nativeGetCurrentSpectrum(): ByteArray
}

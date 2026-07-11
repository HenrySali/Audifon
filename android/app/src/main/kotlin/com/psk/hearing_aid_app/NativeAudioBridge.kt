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
            System.loadLibrary("oboe")
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
     * Configura el Expansor de baja frecuencia ≤1000 Hz (R1, spec
     * mvdr-noise-clarity-tuning). Downward expansion band-limitada para
     * eliminar el hiss del mic en silencios sin tocar consonantes.
     * Default OFF / ratio 1.0 → passthrough (comportamiento previo, R6.3).
     * Thread-safe.
     *
     * @param enabled Toggle de activación (AC5). Default false.
     * @param kneeDbSpl Knee de expansión en dB SPL (AC1). Default 45.
     * @param ratio Ratio de expansión, 1.0 = passthrough (AC4). Default 1.0.
     * @param cutoffHz Frecuencia de corte superior (AC2). Default 1000.
     * @param attackMs Ataque (recuperación de ganancia) en ms (AC6, ≤50).
     * @param releaseMs Liberación (atenuación) en ms (AC4a). Default 400.
     */
    fun setExpander(
        enabled: Boolean = false,
        kneeDbSpl: Float = 45f,
        ratio: Float = 1f,
        cutoffHz: Float = 1000f,
        attackMs: Float = 30f,
        releaseMs: Float = 400f
    ) {
        nativeSetExpander(enabled, kneeDbSpl, ratio, cutoffHz, attackMs, releaseMs)
    }

    /**
     * Configura el Supresor de reverberación tardía del MVDR (R5, spec
     * mvdr-noise-clarity-tuning). Efectivo solo en modo MVDR; fuera de él
     * el beamformer hace bypass. Default = comportamiento previo
     * (enabled=true, strength=1.6, floor=0.30, decay=0.80). Thread-safe.
     *
     * @param enabled Toggle del dereverb (AC3). Default true.
     * @param strength Over-subtraction factor (AC2). Default 1.6.
     * @param floor Suelo espectral (AC2/AC4). Default 0.30.
     * @param decay Factor de decaimiento / RT60 proxy (AC1). Default 0.80.
     */
    fun setDereverb(
        enabled: Boolean = true,
        strength: Float = 1.6f,
        floor: Float = 0.30f,
        decay: Float = 0.80f
    ) {
        nativeSetDereverb(enabled, strength, floor, decay)
    }

    /**
     * Configura los umbrales del clasificador de entorno (R4, spec
     * mvdr-noise-clarity-tuning). Defaults = valores previos si no se envían
     * (R6.5). Thread-safe.
     *
     * @param speechEnterDb SNR (dB) para ENTRAR a SPEECH. Default 6.0.
     * @param speechExitDb SNR (dB) para SALIR de SPEECH. Default 4.0.
     * @param noiseSnrDb SNR (dB) bajo el cual el entorno es NOISE. Default 1.5.
     * @param quietEnterDbSpl Nivel (dB SPL) para ENTRAR a QUIET. Default 44.
     * @param quietExitDbSpl Nivel (dB SPL) para SALIR de QUIET. Default 49.
     */
    fun setClassifierThresholds(
        speechEnterDb: Float = 6f,
        speechExitDb: Float = 4f,
        noiseSnrDb: Float = 1.5f,
        quietEnterDbSpl: Float = 44f,
        quietExitDbSpl: Float = 49f
    ) {
        nativeSetClassifierThresholds(
            speechEnterDb, speechExitDb, noiseSnrDb, quietEnterDbSpl, quietExitDbSpl
        )
    }

    /**
     * Habilita/deshabilita la clasificación automática de entorno.
     * Thread-safe, puede llamarse desde cualquier hilo.
     *
     * @param enabled true para habilitar, false para deshabilitar
     */
    fun setAutoClassifyEnabled(enabled: Boolean) {
        nativeSetAutoClassifyEnabled(enabled)
    }

    /**
     * Pin del preset Smart Scene aplicado manualmente.
     *
     * Cuando es true, el clasificador automático sigue corriendo y
     * publica la clase actual en `getCurrentEnvironmentClass()`, pero
     * NO machaca los targets del WDRC + NR cuando cambia la escena.
     * El preset Smart manual (NR + WDRC + EQ) se mantiene vigente
     * hasta que la UI libere el pin (false). Resuelve la Causa C
     * documentada en docs/smart-scene-diagnostico-chasquido.md.
     *
     * Thread-safe, puede llamarse desde cualquier hilo. Si el motor
     * no está activo, la llamada se ignora silenciosamente.
     *
     * @param pinned true para fijar el preset manual, false para que
     *               el clasificador automático vuelva a controlar
     *               WDRC + NR.
     */
    fun setSmartPresetPinned(pinned: Boolean) {
        nativeSetSmartPresetPinned(pinned)
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
     * Actualiza el threshold del MPO (Maximum Power Output) en dB SPL en
     * runtime, sin reiniciar el motor de audio.
     *
     * El motor nativo convierte dB SPL → lineal usando el splOffset actual:
     *   linear = pow(10, (thresholdDbSpl - splOffset) / 20)
     * y lo aplica al [MpoLimiter] del [DspPipeline].
     *
     * Thread-safe (lock-free vía std::atomic dentro del pipeline).
     * La validación de rango clínico [80, 132] dB SPL la hace el caller Dart.
     *
     * Implementa Requirement 3 de la spec `audiogram-driven-presets`.
     *
     * @param thresholdDbSpl Threshold en dB SPL (rango clínico [80, 132])
     */
    fun setMpoThresholdDbSpl(thresholdDbSpl: Float) {
        nativeSetMpoThresholdDbSpl(thresholdDbSpl)
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

    /**
     * Establece el micrófono preferido para el input stream.
     *
     * Si [deviceId] == -1, restaura el micrófono por defecto del sistema.
     * Si el motor está corriendo, intenta aplicar el cambio en caliente
     * vía el setter nativo. Si no está corriendo, guarda el ID para
     * aplicarlo en el próximo `start()`.
     *
     * @return true si el cambio se aplicó o se guardó exitosamente.
     */
    fun setPreferredInputDevice(deviceId: Int): Boolean {
        preferredInputDeviceId = deviceId
        return try {
            nativeSetPreferredInputDevice(deviceId)
            true
        } catch (e: Exception) {
            Log.w("NativeAudioBridge", "setPreferredInputDevice failed: $e")
            // Guardar para aplicar en próximo start — no es error fatal.
            true
        }
    }

    /** Device ID preferido para input (-1 = default del sistema). */
    @Volatile
    var preferredInputDeviceId: Int = -1
        private set

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

    /** Expansor de baja frecuencia ≤1000 Hz (R1). Ver [setExpander]. */
    private external fun nativeSetExpander(
        enabled: Boolean,
        kneeDbSpl: Float,
        ratio: Float,
        cutoffHz: Float,
        attackMs: Float,
        releaseMs: Float
    )

    /** Supresor de reverberación tardía del MVDR (R5). Ver [setDereverb]. */
    private external fun nativeSetDereverb(
        enabled: Boolean,
        strength: Float,
        floor: Float,
        decay: Float
    )

    /** Umbrales del clasificador de entorno (R4). Ver [setClassifierThresholds]. */
    private external fun nativeSetClassifierThresholds(
        speechEnterDb: Float,
        speechExitDb: Float,
        noiseSnrDb: Float,
        quietEnterDbSpl: Float,
        quietExitDbSpl: Float
    )

    private external fun nativeSetAutoClassifyEnabled(enabled: Boolean)

    private external fun nativeSetSmartPresetPinned(pinned: Boolean)

    private external fun nativeSetSplOffset(offset: Float)

    private external fun nativeSetMpoThresholdDbSpl(thresholdDbSpl: Float)

    private external fun nativeGetInputLevel(): Float

    private external fun nativeGetInputDeviceId(): Int

    private external fun nativeGetOutputDeviceId(): Int

    /** Setter nativo del preferred input device (Oboe setPreferredDevice). */
    private external fun nativeSetPreferredInputDevice(deviceId: Int)

    /** Retorna el audio session ID del input stream (para NoiseSuppressor Android). */
    external fun nativeGetInputSessionId(): Int

    /**
     * Setea el flag del "Modo Conversación" (SCO + baja latencia). Debe
     * llamarse ANTES de [start] (o antes de un stop→start) para que el
     * motor abra los streams Oboe con Usage::VoiceCommunication y rutee el
     * audio al canal SCO Bluetooth. Spec: modo-conversacion-sco.
     */
    external fun nativeSetConversationMode(enabled: Boolean)

    /**
     * Setea el flag de beamforming dual-mic (captura estéreo + MVDR).
     * Debe llamarse ANTES de [start] (o antes de un stop→start) para que
     * el motor abra el input stream con 2 canales y active el MVDR.
     *
     * @param enabled true para captura estéreo + MVDR beamformer.
     */
    external fun nativeSetBeamformingMode(enabled: Boolean)

    // ─── Spectrum Analyzer (implementados en native_bridge.cpp) ──────────

    external fun nativeStartSpectrumAnalysis()

    external fun nativeStopSpectrumAnalysis()

    external fun nativeStartSpectrumRecording()

    external fun nativeStopSpectrumRecording(): Int

    external fun nativeGetRecordingData(): ByteArray

    external fun nativeGetCurrentSpectrum(): ByteArray

    // ─── DSP Stage Metrics (para diagnóstico del pipeline) ───────────────

    external fun nativeGetDspStageMetrics(): FloatArray

    // ─── Transient Noise Reducer (TNR) ──────────────────────────────────

    external fun nativeSetTnrEnabled(enabled: Boolean)

    // ─── Auditory Model (simulación del sistema auditivo humano) ─────────

    /**
     * Habilita/deshabilita el Modelo Auditivo (6 etapas cocleares).
     * Cuando habilitado, simula la cadena auditiva humana y aplica
     * compensaciones personalizadas según el audiograma del paciente.
     * Se inserta después del EQ, antes del WDRC en el pipeline.
     * Thread-safe (std::atomic interno). Default: OFF.
     *
     * @param enabled true para activar, false para bypass (passthrough)
     */
    external fun nativeSetAuditoryModelEnabled(enabled: Boolean)

    /**
     * Configura el audiograma del paciente para el modelo auditivo.
     * Los umbrales en dB HL (12 bandas) determinan la compensación OHC
     * por banda. Frecuencias: 250, 500, 750, 1000, 1500, 2000, 2500,
     * 3000, 3500, 4000, 6000, 8000 Hz.
     *
     * @param thresholds FloatArray de 12 valores en dB HL (0 = audición normal)
     */
    external fun nativeSetAuditoryModelAudiogram(thresholds: FloatArray)

    /**
     * Configura la ganancia del modelo auditivo avanzado (slider UI).
     * Rango: 0 (mínimo) a 18 (máximo). Default: 12 (normal).
     * Controla la intensidad del procesamiento multicanal.
     */
    external fun nativeSetAuditoryModelEarCanalGain(gainDb: Float)

    // ─── Smart Scene Engine (Fase 1) ────────────────────────────────────

    /**
     * Retorna el último snapshot del Smart Scene Engine (~10 Hz).
     * Layout binario definido en `cpp/smart_scene/scene_types.h`.
     * Dart parsea con `SceneSnapshot.fromBytes`.
     */
    external fun nativeGetSceneSnapshot(): ByteArray

    // ─── Fase G — applyScenePreset único ────────────────────────────────

    /**
     * Aplica un preset completo del Smart Scene de forma atómica.
     * Reemplaza 4+ llamadas separadas (EqGains + WdrcParams + NrLevel +
     * TnrEnabled + MpoThreshold + SmartPresetPinned) por una sola.
     *
     * @param params FloatArray[19]: [0..11]=gains EQ, [12]=expKnee,
     *        [13]=expRatio, [14]=compKnee, [15]=compRatio,
     *        [16]=attackMs, [17]=releaseMs, [18]=mpoDbSpl.
     * @param nrLevel Nivel de NR [0, 3].
     * @param tnrEnabled true=TNR ON.
     * @param pinPreset true=fijar pin del preset Smart.
     */
    external fun nativeApplyScenePreset(
        params: FloatArray,
        nrLevel: Int,
        tnrEnabled: Boolean,
        pinPreset: Boolean
    )

    // ─── Calibration Spectrum Validator (Fase 2) ────────────────────────

    /**
     * Configura el ToneAnalyzer para una sesión de validación.
     * @return true si configuró correctamente.
     */
    external fun nativeConfigureToneAnalyzer(
        sampleRate: Int,
        fftSize: Int,
        windowType: Int,        // 0=Hann, 1=BlackmanHarris
        harmonicsCount: Int,    // 4 o 7
        dbfsToDbsplOffset: Float
    ): Boolean

    /** Activa o desactiva el procesamiento del ToneAnalyzer. */
    external fun nativeSetToneAnalyzerActive(active: Boolean)

    /** Establece la frecuencia esperada del tono actual (Hz). */
    external fun nativeSetToneExpectedFrequency(freqHz: Float)

    /** Establece el piso de ruido medido pre-secuencia. */
    external fun nativeSetToneNoiseFloor(amplitudeLin: Float, dbfs: Float)

    /** Resetea el ToneAnalyzer entre tonos. */
    external fun nativeResetToneAnalyzer()

    /**
     * Retorna el último ToneSnapshot serializado (84 bytes, little-endian).
     * Layout documentado en `cpp/native_bridge.cpp::serializeToneSnapshot`.
     * Dart parsea con `ToneSnapshot.fromBytes`.
     */
    external fun nativeGetToneSnapshot(): ByteArray

    // ─── DNN Denoiser (GTCRN vía OnnxRuntime) ───────────────────────────

    // ─── Diagnostic Recorder (grabación dual-channel pre/post DSP) ──────

    /**
     * Inicia grabación diagnóstica dual-channel (pre-DSP + post-DSP).
     * @param filePath Ruta absoluta del archivo WAV de salida.
     * @return true si la grabación inició correctamente.
     */
    external fun nativeStartDiagnosticRecording(filePath: String): Boolean

    /**
     * Detiene la grabación diagnóstica.
     * @return true si se detuvo correctamente.
     */
    external fun nativeStopDiagnosticRecording(): Boolean

    /**
     * Detiene la grabación diagnóstica y CONSERVA el archivo WAV parcial.
     * Finaliza el encabezado WAV con la duración real alcanzada.
     * Diseñado para grabaciones intencionalmente cortas (test A/B, 5s por modo).
     * @return true si el archivo se conservó correctamente.
     */
    external fun nativeStopDiagnosticRecordingKeep(): Boolean

    /**
     * Obtiene el progreso de la grabación diagnóstica.
     * @return Progreso como fracción [0.0, 1.0], o -1 si no hay grabación activa.
     */
    external fun nativeGetDiagnosticRecordingProgress(): Double

    // ─── DNN Denoiser (GTCRN vía OnnxRuntime) ───────────────────────────

    /**
     * Inicializa el modelo DNN GTCRN desde assets. Llamar UNA VEZ al startup,
     * después de `nativeStart()`. Idempotente.
     *
     * @param assetMgr AssetManager Java obtenido vía `context.assets`
     * @return true si el modelo cargó correctamente. false → DNN queda en
     *         bypass permanente (la app sigue funcionando sin DNN).
     */
    external fun nativeInitDnnDenoiser(assetMgr: android.content.res.AssetManager?): Boolean

    /**
     * Habilita/deshabilita el DNN denoiser.
     * Cuando ON reemplaza al NR Wiener clásico (no se ejecutan ambos).
     * Por defecto: OFF — la app arranca igual que antes del DNN.
     *
     * @param enabled true para activar, false para volver al NR Wiener
     */
    external fun nativeSetDnnEnabled(enabled: Boolean)

    /**
     * Mezcla dry/wet del DNN denoiser. 0.0 = sólo señal original,
     * 1.0 = sólo denoised. Valores intermedios = mezcla lineal.
     * Valores fuera de [0,1] se clampean en el lado nativo.
     */
    external fun nativeSetDnnIntensity(intensity: Float)

    /**
     * @return true si el DNN denoiser está procesando audio en este momento
     *         (modelo cargado, worker corriendo, sin errores).
     *         false si está en bypass (por config o por error de inicialización).
     */
    external fun nativeGetDnnIsActive(): Boolean

    // ─── MVDR Dual-Mic Beamforming ─────────────────────────────────────

    /**
     * Habilita/deshabilita el MVDR dual-mic beamformer.
     * Thread-safe (std::atomic interno). Si el motor no está activo, la
     * llamada se ignora silenciosamente.
     *
     * @param enabled true para activar beamforming, false para bypass mono.
     */
    external fun nativeSetBeamformingEnabled(enabled: Boolean)

    /**
     * Setea el flag de "beamforming solicitado" que consume [nativeStart].
     *
     * Debe llamarse ANTES de [start] (o antes de un stop→start) para que el
     * motor abra el stream de entrada en estéreo (2 canales) y el MVDR
     * beamformer reciba ambos micrófonos. A diferencia de
     * [nativeSetBeamformingEnabled] (que togglea el beamformer ya corriendo),
     * este flag decide la geometría de captura del próximo start.
     * Thread-safe (std::atomic). Spec: dual-mic-mvdr-beamforming.
     */
    external fun nativeSetBeamformingRequested(enabled: Boolean)

    /**
     * Consulta si el MVDR beamformer está activo (enabled + procesando).
     * Thread-safe (lee std::atomic<bool> interno).
     *
     * @return true si el beamformer está habilitado y procesando audio.
     */
    external fun nativeGetBeamformingActive(): Boolean

    // ─── Enhancement Engine selector (spec gtcrn-dual-channel) ──────────

    /**
     * Selecciona el motor de realce de voz.
     *
     * Contrato del entero (mapea al enum C++ `EnhancementEngineMode`):
     *   0 = Bypass (ch0 passthrough, default de arranque),
     *   1 = DualChannelDnn (GTCRN dual → mono realzado),
     *   2 = MvdrBackup (MVDR beamformer → mono realzado).
     *
     * Los modos 1 y 2 necesitan captura estéreo. El lado nativo actualiza
     * el flag de captura estéreo solicitada (el mismo que consume
     * `nativeStart`) según el modo, y hace el re-open en caliente si el
     * motor ya está corriendo. Thread-safe. Valores fuera de [0,2] se
     * ignoran en el lado nativo.
     */
    external fun nativeSetEnhancementEngineMode(mode: Int)

    /**
     * Consulta el motor de realce seleccionado actualmente.
     * @return 0=Bypass, 1=DualChannelDnn, 2=MvdrBackup. Devuelve 0 si el
     *         motor nativo no está activo (coherente con el default).
     */
    external fun nativeGetEnhancementEngineMode(): Int

    /**
     * Retorna métricas de todas las etapas del pipeline DSP como Map.
     * Útil para la pantalla de diagnóstico DSP.
     *
     * Campos extra (spec dsp-chain-optimization task 4.4):
     *   - `preDnnLevelDb`: nivel pre-DNN en dB SPL pasado al WDRC. -1.0
     *     indica "no hay nivel externo" (medición local).
     *   - `wdrcLevelSource`: "pre-dnn" si el WDRC usó el nivel externo
     *     pre-DNN del AudioEngine, "local" si midió RMS desde el buffer.
     *
     * Campos extra (spec audifono-v3 task 10.2 — MPO clínico real, decisión B):
     *   - `mpoLimitingFraction`: fracción [0,1] de muestras del último bloque
     *     en las que el MPO estuvo limitando.
     *   - `mpoLimitingSustained`: true si la limitación fue sostenida
     *     (≥ ~200 ms cuasi-continuos). Señal del aviso visible R9.2.
     */
    fun getDspStageMetrics(): Map<String, Any>? {
        val data = try { nativeGetDspStageMetrics() } catch (_: Exception) { return null }
        if (data.isEmpty()) return null
        val regions = arrayOf("expansion", "linear", "compression")
        // Compatibilidad: si el .so es de una versión vieja que devuelve
        // 12 floats (sin preDnnLevelDb / wdrcUsesExternalLevel), exponer
        // valores por defecto para no romper a los callers.
        val preDnnLevelDb = if (data.size >= 13) data[12] else -1.0f
        val wdrcUsesExternal = if (data.size >= 14) data[13] != 0.0f else false
        // Aviso de limitación sostenida del MPO (spec audifono-v3 task 10.2,
        // decisión B). Compatibilidad: un .so viejo (≤14 floats) no expone
        // estos campos → defaults seguros (sin aviso).
        val mpoLimitingFraction = if (data.size >= 15) data[14] else 0.0f
        val mpoLimitingSustained = if (data.size >= 16) data[15] != 0.0f else false
        return mapOf(
            "inputLevel" to data[0],
            "postNrLevel" to data[1],
            "postEqLevel" to data[2],
            "postWdrcLevel" to data[3],
            "postVolumeLevel" to data[4],
            "outputLevel" to data[5],
            "peakSample" to data[6],
            "clipCount" to data[7].toInt(),
            "wdrcGainFactor" to data[8],
            "wdrcRegion" to (regions.getOrNull(data[9].toInt()) ?: "unknown"),
            "eqMaxGain" to data[10],
            "environmentClass" to data[11].toInt(),
            "preDnnLevelDb" to preDnnLevelDb,
            "wdrcLevelSource" to if (wdrcUsesExternal) "pre-dnn" else "local",
            "mpoLimitingFraction" to mpoLimitingFraction,
            "mpoLimitingSustained" to mpoLimitingSustained,
        )
    }

    // ─── Latency Monitor & Loopback Test (spec monitor-latencia-audio) ───

    /**
     * Wrapper público de [nativeGetLatencyMetrics] con protección de
     * excepción JNI (engine nulo → null).
     *
     * @return Map con métricas del struct C++ [LatencyMetrics]:
     *   schemaVersion, sampleRate, inputFramesPerBurst, outputFramesPerBurst,
     *   outputBufferSizeFrames, inputAudioApi, outputAudioApi,
     *   inputSharingMode, outputSharingMode, outputPerformanceMode,
     *   inputLatencyMs, outputLatencyMs, dspBlockMs, dspProcessingMsAvg,
     *   dspProcessingMsMax, dnnInferenceMs, dnnGroupDelayMs, tnrLookaheadMs,
     *   callbackUnderruns, timestampsHealthy.
     *   Null si el engine no está creado o el JNI falla.
     */
    fun getLatencyMetrics(): Map<String, Any?>? {
        return try { nativeGetLatencyMetrics() } catch (_: Exception) { null }
    }

    /**
     * Retorna métricas de latencia del pipeline DSP como Map.
     *
     * Campos esperados (poblados por el lado nativo desde
     * [AudioEngine::getLatencyMetrics] vía `latencyMetricsToJavaMap`):
     *   - `inputLatencyMs`: latencia del stream de entrada en ms.
     *   - `outputLatencyMs`: latencia del stream de salida en ms.
     *   - `bufferLatencyMs`: latencia de buffering del DSP en ms.
     *   - `totalLatencyMs`: suma de las anteriores.
     *   - `samplesProcessed`: muestras procesadas en la ventana actual.
     *   - `xrunCount`: cantidad de under/over-runs detectados.
     *   - `timestampValid`: true si los timestamps de AAudio son válidos.
     *
     * @return Map con las métricas, o null si el engine nativo no está creado.
     */
    private external fun nativeGetLatencyMetrics(): Map<String, Any?>?

    /**
     * Inicia un test de loopback (medición end-to-end de latencia mediante
     * tono de prueba inyectado en el output y detectado en el input).
     *
     * Idempotente: si ya hay un test activo, simplemente lo continúa.
     *
     * @return true si el test inició correctamente; false si el engine nativo
     *         no está creado o si el tester rechazó los parámetros.
     */
    external fun nativeStartLoopbackTest(): Boolean

    /**
     * Indica si actualmente hay un test de loopback en curso.
     *
     * @return true si el tester está en estado activo; false en caso contrario
     *         o si el engine nativo no está creado.
     */
    external fun nativeIsLoopbackTestActive(): Boolean

    /**
     * Retorna el resultado del último test de loopback como Map.
     *
     * Campos esperados (poblados desde `loopbackResultToJavaMap`):
     *   - `roundTripLatencyMs`: latencia round-trip medida en ms.
     *   - `confidence`: confianza de la medición [0.0, 1.0].
     *   - `success`: true si el test completó con resultado válido.
     *   - `errorMessage`: descripción del error si `success == false`.
     *
     * @return Map con el resultado mientras el test sigue activo o cuando
     *         terminó; null si nunca se ejecutó o el engine no está creado.
     */
    external fun nativeGetLoopbackTestResult(): Map<String, Any?>?

    /**
     * Cancela un test de loopback en curso y restaura el procesamiento
     * normal del audio ambiente. Idempotente: si no hay test activo, no-op.
     */
    external fun nativeCancelLoopbackTest()
}

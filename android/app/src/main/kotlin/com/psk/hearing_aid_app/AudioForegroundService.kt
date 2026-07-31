package com.psk.hearing_aid_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Servicio en primer plano para procesamiento de audio DSP continuo.
 *
 * Este servicio mantiene el pipeline de audio activo incluso cuando la app
 * pasa a segundo plano, mostrando una notificación persistente al usuario.
 *
 * Responsabilidades:
 * - Mantener notificación persistente ("Amplificación activa")
 * - Gestionar el foco de audio (MODE_IN_COMMUNICATION)
 * - Detectar conexión/desconexión de auriculares (BT y cable)
 * - Enviar eventos al lado Flutter vía EventChannel
 * - Controlar el NativeAudioBridge (start/stop)
 *
 * Requisitos: 6.1, 6.2, 6.3, 7.5, 3.3, 3.4
 */
class AudioForegroundService : Service() {

    companion object {
        private const val TAG = "AudioForegroundService"

        /** ID de la notificación persistente del servicio. */
        const val NOTIFICATION_ID = 1001

        /** ID del canal de notificación (Android O+). */
        const val CHANNEL_ID = "psk_audio_channel"

        // Intent extras para configuración inicial
        const val EXTRA_SAMPLE_RATE = "sample_rate"
        const val EXTRA_BUFFER_SIZE = "buffer_size"
        const val EXTRA_EQ_GAINS = "eq_gains"
        const val EXTRA_VOLUME_DB = "volume_db"
        const val EXTRA_EXPANSION_KNEE = "expansion_knee"
        const val EXTRA_EXPANSION_RATIO = "expansion_ratio"
        const val EXTRA_COMPRESSION_KNEE = "compression_knee"
        const val EXTRA_COMPRESSION_RATIO = "compression_ratio"
        const val EXTRA_ATTACK_MS = "attack_ms"
        const val EXTRA_RELEASE_MS = "release_ms"
        const val EXTRA_NR_LEVEL = "nr_level"
        const val EXTRA_MPO_THRESHOLD = "mpo_threshold"
        const val EXTRA_SPL_OFFSET = "spl_offset"

        // Acciones de intent para control del servicio
        const val ACTION_START = "com.psk.hearing_aid_app.ACTION_START"
        const val ACTION_STOP = "com.psk.hearing_aid_app.ACTION_STOP"

        // Eventos enviados a Flutter vía broadcast local
        const val EVENT_HEADPHONES_DISCONNECTED = "headphones_disconnected"
        const val EVENT_HEADPHONES_CONNECTED = "headphones_connected"
        const val EVENT_AUDIO_FOCUS_LOST = "audio_focus_lost"
        const val EVENT_AUDIO_FOCUS_GAINED = "audio_focus_gained"
        const val EVENT_AUDIO_FOCUS_DUCK = "audio_focus_duck"
    }

    // ─────────────────────────────────────────────────────────────────────
    // Componentes del servicio
    // ─────────────────────────────────────────────────────────────────────

    private lateinit var audioManager: AudioManager
    private lateinit var notificationManager: NotificationManager
    private var audioEngine: NativeAudioBridge? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var hasAudioFocus = false
    private var isRunning = false

    /**
     * Listener para eventos del servicio (headphones, audio focus).
     * Se registra desde AudioMethodChannel para enviar eventos a Flutter.
     */
    interface ServiceEventListener {
        fun onHeadphonesStateChanged(connected: Boolean)
        fun onAudioFocusChanged(state: String)
    }

    private var eventListener: ServiceEventListener? = null

    /**
     * Registra un listener para recibir eventos del servicio.
     */
    fun setEventListener(listener: ServiceEventListener?) {
        eventListener = listener
    }

    /**
     * Obtiene la instancia del NativeAudioBridge para control directo.
     */
    fun getAudioEngine(): NativeAudioBridge? = audioEngine

    // ─────────────────────────────────────────────────────────────────────
    // Ciclo de vida del servicio
    // ─────────────────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "onCreate")

        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        createNotificationChannel()
        registerHeadphoneReceiver()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(TAG, "onStartCommand: action=${intent?.action}")

        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                // Iniciar servicio en primer plano con notificación
                startForeground(NOTIFICATION_ID, createNotification())

                // Do NOT request audio focus or change audio mode here.
                // The Oboe output stream uses Usage::Media which routes to A2DP
                // (Bluetooth headphone speaker). Requesting VOICE_COMMUNICATION
                // focus would switch to SCO profile (low quality, wrong routing).
                // The foreground service only keeps the process alive.

                isRunning = true
            }
        }

        return START_STICKY
    }

    override fun onDestroy() {
        Log.i(TAG, "onDestroy")

        // Desregistrar receivers
        unregisterHeadphoneReceiver()

        isRunning = false
        eventListener = null

        super.onDestroy()
    }

    /**
     * Llamado cuando el usuario desliza la app de recientes.
     * NO detenemos el servicio — el audio debe seguir vivo.
     * El servicio solo se detiene con ACTION_STOP explícito ("Apagar").
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "onTaskRemoved — keeping audio alive (service continues)")
        // No llamar a stopSelf(). El servicio sigue corriendo con la
        // notificación y el proceso se mantiene vivo → g_engine sigue activo.
    }

    // ─────────────────────────────────────────────────────────────────────
    // Notificación persistente
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Crea el canal de notificación para Android O+ (API 26+).
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "PSK Audio Amplificación",
                NotificationManager.IMPORTANCE_LOW // Sin sonido, sin vibración
            ).apply {
                description = "Notificación del servicio de amplificación de audio activo"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            notificationManager.createNotificationChannel(channel)
            Log.d(TAG, "Notification channel created: $CHANNEL_ID")
        }
    }

    /**
     * Crea la notificación persistente del servicio en primer plano.
     */
    private fun createNotification(): Notification {
        // Intent para abrir la app al tocar la notificación
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingOpenApp = PendingIntent.getActivity(
            this, 0, openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Intent para detener el servicio desde la notificación
        val stopIntent = Intent(this, AudioForegroundService::class.java).apply {
            action = ACTION_STOP
        }
        val pendingStop = PendingIntent.getService(
            this, 1, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("PSK Hearing Aid")
            .setContentText("Amplificación activa")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setContentIntent(pendingOpenApp)
            .addAction(
                android.R.drawable.ic_media_pause,
                "Detener",
                pendingStop
            )
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
    }

    // ─────────────────────────────────────────────────────────────────────
    // Audio Engine (NativeAudioBridge)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Inicia el engine de audio nativo con la configuración del intent.
     */
    private fun startAudioEngine(intent: Intent?) {
        if (audioEngine != null) {
            Log.w(TAG, "Audio engine already running, stopping first")
            audioEngine?.stop()
        }

        audioEngine = NativeAudioBridge()

        val sampleRate = intent?.getIntExtra(EXTRA_SAMPLE_RATE, 48000) ?: 48000
        val bufferSize = intent?.getIntExtra(EXTRA_BUFFER_SIZE, 256) ?: 256
        val eqGains = intent?.getFloatArrayExtra(EXTRA_EQ_GAINS) ?: FloatArray(12) { 0f }
        val volumeDb = intent?.getFloatExtra(EXTRA_VOLUME_DB, 0f) ?: 0f
        val expansionKnee = intent?.getFloatExtra(EXTRA_EXPANSION_KNEE, 35f) ?: 35f
        val expansionRatio = intent?.getFloatExtra(EXTRA_EXPANSION_RATIO, 2f) ?: 2f
        val compressionKnee = intent?.getFloatExtra(EXTRA_COMPRESSION_KNEE, 55f) ?: 55f
        val compressionRatio = intent?.getFloatExtra(EXTRA_COMPRESSION_RATIO, 2f) ?: 2f
        val attackMs = intent?.getFloatExtra(EXTRA_ATTACK_MS, 5f) ?: 5f
        val releaseMs = intent?.getFloatExtra(EXTRA_RELEASE_MS, 100f) ?: 100f
        val nrLevel = intent?.getIntExtra(EXTRA_NR_LEVEL, 0) ?: 0
        val mpoThreshold = intent?.getFloatExtra(EXTRA_MPO_THRESHOLD, 100f) ?: 100f
        val splOffset = intent?.getFloatExtra(EXTRA_SPL_OFFSET, 120f) ?: 120f

        audioEngine?.start(
            sampleRate = sampleRate,
            bufferSize = bufferSize,
            eqGains = eqGains,
            volumeDb = volumeDb,
            expansionKnee = expansionKnee,
            expansionRatio = expansionRatio,
            compressionKnee = compressionKnee,
            compressionRatio = compressionRatio,
            attackMs = attackMs,
            releaseMs = releaseMs,
            nrLevel = nrLevel,
            mpoThresholdDbSpl = mpoThreshold,
            splOffset = splOffset
        )

        Log.i(TAG, "Audio engine started: ${sampleRate}Hz, buffer=$bufferSize, NR=$nrLevel")
    }

    /**
     * Detiene el engine de audio nativo y libera recursos.
     */
    private fun stopAudioEngine() {
        audioEngine?.stop()
        audioEngine = null
        Log.i(TAG, "Audio engine stopped")
    }

    // ─────────────────────────────────────────────────────────────────────
    // Gestión de foco de audio
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Listener de cambios de foco de audio del sistema.
     * Maneja pérdida/ganancia de foco y ducking.
     */
    private val audioFocusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        when (focusChange) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                Log.i(TAG, "Audio focus gained")
                hasAudioFocus = true
                // Reanudar audio si estaba pausado
                if (isRunning && audioEngine == null) {
                    // El engine fue detenido por pérdida de foco, reiniciar
                    Log.i(TAG, "Resuming audio engine after focus gain")
                }
                eventListener?.onAudioFocusChanged(EVENT_AUDIO_FOCUS_GAINED)
            }

            AudioManager.AUDIOFOCUS_LOSS -> {
                Log.i(TAG, "Audio focus lost permanently")
                hasAudioFocus = false
                // Pérdida permanente: detener el engine
                stopAudioEngine()
                eventListener?.onAudioFocusChanged(EVENT_AUDIO_FOCUS_LOST)
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                Log.i(TAG, "Audio focus lost transiently")
                hasAudioFocus = false
                // Pérdida temporal (ej: llamada entrante): pausar
                stopAudioEngine()
                eventListener?.onAudioFocusChanged(EVENT_AUDIO_FOCUS_LOST)
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                Log.i(TAG, "Audio focus: should duck")
                // Podemos reducir volumen en lugar de pausar
                audioEngine?.setVolume(-10f)
                eventListener?.onAudioFocusChanged(EVENT_AUDIO_FOCUS_DUCK)
            }
        }
    }

    /**
     * Solicita foco de audio exclusivo con modo de comunicación.
     * Req 6.1: Audio_Session exclusiva con MODE_IN_COMMUNICATION.
     *
     * @return true si se obtuvo el foco, false en caso contrario
     */
    private fun requestAudioFocus(): Boolean {
        val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setOnAudioFocusChangeListener(audioFocusChangeListener)
            .setAcceptsDelayedFocusGain(true)
            .build()

        audioFocusRequest = focusRequest

        val result = audioManager.requestAudioFocus(focusRequest)
        hasAudioFocus = (result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)

        Log.i(TAG, "requestAudioFocus: result=$result, granted=$hasAudioFocus")
        return hasAudioFocus
    }

    /**
     * Libera el foco de audio.
     */
    private fun abandonAudioFocus() {
        audioFocusRequest?.let { request ->
            audioManager.abandonAudioFocusRequest(request)
            Log.d(TAG, "Audio focus abandoned")
        }
        audioFocusRequest = null
        hasAudioFocus = false
    }

    // ─────────────────────────────────────────────────────────────────────
    // Detección de auriculares (BT y cable)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * BroadcastReceiver para detectar conexión/desconexión de auriculares.
     *
     * Escucha:
     * - ACTION_HEADSET_PLUG: auriculares con cable
     * - BluetoothDevice.ACTION_ACL_DISCONNECTED: auriculares BT desconectados
     * - BluetoothDevice.ACTION_ACL_CONNECTED: auriculares BT conectados
     *
     * Req 3.3: Pausar al desconectar BT
     * Req 3.4: Ofrecer reanudar al reconectar BT
     */
    private val headphoneReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                AudioManager.ACTION_HEADSET_PLUG -> {
                    val state = intent.getIntExtra("state", -1)
                    when (state) {
                        0 -> {
                            // Auriculares con cable desconectados
                            Log.i(TAG, "Wired headphones disconnected")
                            handleHeadphonesDisconnected()
                        }
                        1 -> {
                            // Auriculares con cable conectados
                            Log.i(TAG, "Wired headphones connected")
                            handleHeadphonesConnected()
                        }
                    }
                }

                BluetoothDevice.ACTION_ACL_DISCONNECTED -> {
                    Log.i(TAG, "Bluetooth device disconnected")
                    handleHeadphonesDisconnected()
                }

                BluetoothDevice.ACTION_ACL_CONNECTED -> {
                    Log.i(TAG, "Bluetooth device connected")
                    handleHeadphonesConnected()
                }
            }
        }
    }

    private var isReceiverRegistered = false

    /**
     * Registra el BroadcastReceiver para eventos de auriculares.
     */
    private fun registerHeadphoneReceiver() {
        val filter = IntentFilter().apply {
            addAction(AudioManager.ACTION_HEADSET_PLUG)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(headphoneReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(headphoneReceiver, filter)
        }
        isReceiverRegistered = true
        Log.d(TAG, "Headphone receiver registered")
    }

    /**
     * Desregistra el BroadcastReceiver de auriculares.
     */
    private fun unregisterHeadphoneReceiver() {
        if (isReceiverRegistered) {
            try {
                unregisterReceiver(headphoneReceiver)
                isReceiverRegistered = false
                Log.d(TAG, "Headphone receiver unregistered")
            } catch (e: IllegalArgumentException) {
                Log.w(TAG, "Receiver already unregistered: ${e.message}")
            }
        }
    }

    /**
     * Maneja la desconexión de auriculares.
     * Pausa la amplificación y notifica a Flutter.
     */
    private fun handleHeadphonesDisconnected() {
        if (isRunning) {
            Log.i(TAG, "Pausing audio due to headphone disconnection")
            stopAudioEngine()
            eventListener?.onHeadphonesStateChanged(false)
        }
    }

    /**
     * Maneja la conexión de auriculares.
     * Notifica a Flutter para ofrecer reanudar.
     */
    private fun handleHeadphonesConnected() {
        eventListener?.onHeadphonesStateChanged(true)
    }
}

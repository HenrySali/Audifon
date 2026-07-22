package com.psk.hearing_aid_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.util.Log
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit

/**
 * Encapsula la activación / desactivación del audio por SCO Bluetooth para
 * el "Modo Conversación".
 *
 * - API 31+ (Android 12+): usa `AudioManager.setCommunicationDevice()` con
 *   el `AudioDeviceInfo` del SCO output, según la guía oficial de Oboe
 *   ([Oboe wiki — TechNote_BluetoothAudio]).
 * - API 24-30: usa el flujo legacy `AudioManager.startBluetoothSco()` +
 *   `setBluetoothScoOn(true)` y un [BroadcastReceiver] que escucha
 *   `ACTION_SCO_AUDIO_STATE_UPDATED` para confirmar la conexión SCO.
 *
 * En ambos caminos pone `audioManager.mode = MODE_IN_COMMUNICATION` para
 * que Oboe negocie un buffer de baja latencia con el stack de telefonía.
 *
 * Si el SCO no se establece dentro de [DEFAULT_TIMEOUT_MS] o si no hay
 * auricular BT enlazado, devuelve `Result.NoBtFallbackBuiltin` para que el
 * caller arranque el motor a 16 kHz por mic/speaker builtin (igual queda
 * en MODE_IN_COMMUNICATION → buffers más chicos).
 *
 * Esta clase NO toca el motor nativo. El caller (handler del MethodChannel)
 * debe hacer stop → start del motor con el sampleRate adecuado.
 */
class BluetoothScoController(private val context: Context) {

    enum class Result { Connected, NoBtFallbackBuiltin, Failed }

    private val audioManager: AudioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private var scoReceiver: BroadcastReceiver? = null
    private var scoConnectedLatch: CountDownLatch? = null
    private var lastModeBeforeStart: Int = AudioManager.MODE_NORMAL
    @Volatile private var active: Boolean = false
    @Volatile private var activeScoDeviceId: Int = -1

    companion object {
        private const val TAG = "BtScoCtrlTec"
        const val DEFAULT_TIMEOUT_MS = 3_000L
    }

    /**
     * Activa SCO + MODE_IN_COMMUNICATION. Bloquea hasta que el SCO esté
     * conectado o se agote [timeoutMs].
     */
    fun start(timeoutMs: Long = DEFAULT_TIMEOUT_MS): Result {
        if (active) {
            Log.i(TAG, "start: already active, skipping")
            return Result.Connected
        }
        lastModeBeforeStart = audioManager.mode

        try {
            @Suppress("DEPRECATION")
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        } catch (e: SecurityException) {
            Log.w(TAG, "start: cannot set MODE_IN_COMMUNICATION: ${e.message}")
            return Result.Failed
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return startWithCommunicationDevice(timeoutMs)
        }
        return startLegacySco(timeoutMs)
    }

    private fun startWithCommunicationDevice(timeoutMs: Long): Result {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return Result.Failed

        val devices = audioManager.availableCommunicationDevices
        val candidate = devices.firstOrNull {
            it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    it.type == AudioDeviceInfo.TYPE_BLE_HEADSET)
        }

        if (candidate == null) {
            Log.i(TAG, "startWithCommunicationDevice: no BT SCO/BLE device — fallback builtin")
            active = true
            activeScoDeviceId = -1
            return Result.NoBtFallbackBuiltin
        }

        // FIX bug "Modo Conversación engancha a veces sí, a veces no":
        // setCommunicationDevice() devolver `true` solo significa que el PEDIDO
        // de ruteo fue ACEPTADO. El enlace SCO/BLE real se aplica de forma
        // ASÍNCRONA (~1-2 s después). Si el caller arranca el motor antes de que
        // el ruteo esté vivo, a veces toma el SCO y a veces queda en builtin/mute.
        // Por eso esperamos la confirmación con un OnCommunicationDeviceChangedListener
        // + CountDownLatch (timeout = timeoutMs), igual que el camino legacy espera
        // SCO_AUDIO_STATE_CONNECTED, antes de devolver Connected.
        // Fuente: developer.android.com — "Audio Manager self-managed call guide"
        // (escuchar el cambio de communication device permite saber cuándo el
        // ruteo fue aplicado y el device elegido está activo) +
        // AudioManager.OnCommunicationDeviceChangedListener (API 31+, API pública).
        val confirmLatch = CountDownLatch(1)
        val listener = AudioManager.OnCommunicationDeviceChangedListener { device ->
            if (device != null && device.id == candidate.id) {
                confirmLatch.countDown()
            }
        }
        // Direct executor: el callback solo hace countDown, no requiere hilo propio.
        val directExecutor = Executor { it.run() }
        audioManager.addOnCommunicationDeviceChangedListener(directExecutor, listener)

        val ok = try {
            audioManager.setCommunicationDevice(candidate)
        } catch (e: Exception) {
            Log.w(TAG, "setCommunicationDevice threw: ${e.message}")
            false
        }

        if (!ok) {
            Log.w(TAG, "setCommunicationDevice returned false — fallback builtin")
            audioManager.removeOnCommunicationDeviceChangedListener(listener)
            try { audioManager.clearCommunicationDevice() } catch (_: Exception) { /* ignore */ }
            active = true
            activeScoDeviceId = -1
            return Result.NoBtFallbackBuiltin
        }

        // Evitar perder el evento si el ruteo ya quedó aplicado antes de que el
        // listener estuviera escuchando (race): chequear el estado actual.
        if (audioManager.communicationDevice?.id == candidate.id) {
            confirmLatch.countDown()
        }

        val confirmed = try {
            confirmLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            false
        }
        audioManager.removeOnCommunicationDeviceChangedListener(listener)

        // Doble chequeo final por si el listener no disparó pero el ruteo ya está vivo.
        val routed = confirmed || audioManager.communicationDevice?.id == candidate.id

        return if (routed) {
            active = true
            activeScoDeviceId = candidate.id
            Log.i(TAG, "setCommunicationDevice CONFIRMED — device=${candidate.productName} id=${candidate.id}")
            Result.Connected
        } else {
            Log.w(TAG, "setCommunicationDevice: timeout (${timeoutMs}ms) sin confirmar ruteo — liberando, fallback builtin")
            try { audioManager.clearCommunicationDevice() } catch (_: Exception) { /* ignore */ }
            active = true
            activeScoDeviceId = -1
            Result.NoBtFallbackBuiltin
        }
    }

    @Suppress("DEPRECATION")
    private fun startLegacySco(timeoutMs: Long): Result {
        if (!audioManager.isBluetoothScoAvailableOffCall) {
            Log.i(TAG, "startLegacySco: SCO not available off-call — fallback builtin")
            active = true
            activeScoDeviceId = -1
            return Result.NoBtFallbackBuiltin
        }
        val latch = CountDownLatch(1)
        scoConnectedLatch = latch
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                if (intent?.action != AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED) return
                val state = intent.getIntExtra(
                    AudioManager.EXTRA_SCO_AUDIO_STATE,
                    AudioManager.SCO_AUDIO_STATE_ERROR
                )
                Log.i(TAG, "scoReceiver: state=$state")
                if (state == AudioManager.SCO_AUDIO_STATE_CONNECTED) {
                    latch.countDown()
                }
            }
        }
        scoReceiver = receiver
        val filter = IntentFilter(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }

        try {
            audioManager.startBluetoothSco()
            audioManager.isBluetoothScoOn = true
        } catch (e: Exception) {
            Log.w(TAG, "startBluetoothSco threw: ${e.message}")
            unregisterSafely()
            active = true
            activeScoDeviceId = -1
            return Result.NoBtFallbackBuiltin
        }

        val connected = try {
            latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            false
        }

        if (!connected) {
            Log.w(TAG, "startLegacySco: timeout waiting SCO_CONNECTED — fallback builtin")
            try {
                audioManager.stopBluetoothSco()
                audioManager.isBluetoothScoOn = false
            } catch (_: Exception) { /* ignore */ }
            unregisterSafely()
            active = true
            activeScoDeviceId = -1
            return Result.NoBtFallbackBuiltin
        }

        val outputs = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val scoOut = outputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
        active = true
        activeScoDeviceId = scoOut?.id ?: -1
        Log.i(TAG, "startLegacySco OK — scoDeviceId=$activeScoDeviceId")
        return Result.Connected
    }

    fun stop() {
        if (!active) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                audioManager.clearCommunicationDevice()
            } catch (e: Exception) {
                Log.w(TAG, "clearCommunicationDevice threw: ${e.message}")
            }
        } else {
            @Suppress("DEPRECATION")
            try {
                audioManager.stopBluetoothSco()
                audioManager.isBluetoothScoOn = false
            } catch (e: Exception) {
                Log.w(TAG, "stopBluetoothSco threw: ${e.message}")
            }
            unregisterSafely()
        }

        try {
            @Suppress("DEPRECATION")
            audioManager.mode = lastModeBeforeStart
        } catch (e: SecurityException) {
            Log.w(TAG, "stop: cannot restore mode: ${e.message}")
        }

        active = false
        activeScoDeviceId = -1
        Log.i(TAG, "stop: SCO released, mode restored to $lastModeBeforeStart")
    }

    fun isActive(): Boolean = active
    fun getActiveScoDeviceId(): Int = activeScoDeviceId

    private fun unregisterSafely() {
        val r = scoReceiver
        if (r != null) {
            try {
                context.unregisterReceiver(r)
            } catch (_: IllegalArgumentException) { /* not registered */ }
            scoReceiver = null
        }
        scoConnectedLatch = null
    }
}

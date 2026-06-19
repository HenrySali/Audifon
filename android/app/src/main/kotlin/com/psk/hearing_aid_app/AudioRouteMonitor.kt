package com.psk.hearing_aid_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi

/**
 * Monitorea cambios de ruta de audio y dispara [onRoutedToSpeaker] cuando
 * la salida deja de ser un auricular (BT o cableado) y cae al parlante
 * del celular.
 *
 * Previene saturación/distorsión en el speaker al desconectarse un audífono
 * BT: el motor DSP sigue procesando con ganancias EQ de 20-50 dB diseñadas
 * para un auricular, que son extremas para un speaker a 5 cm del oído.
 *
 * Mecanismo dual:
 *   - ACTION_AUDIO_BECOMING_NOISY (todas las APIs): el sistema lo manda
 *     cuando un auricular se desconecta y la salida va a caer al speaker.
 *   - AudioDeviceCallback (API 23+): detecta cualquier cambio de output
 *     (incluyendo reconexiones) con granularidad de device ID.
 *
 * THREAD SAFETY: el BroadcastReceiver corre en el main thread. El callback
 * de AudioManager también se registra en el main thread (Looper.getMainLooper).
 * El [onRoutedToSpeaker] se invoca siempre en el main thread.
 */
class AudioRouteMonitor(private val context: Context) {

    companion object {
        private const val TAG = "AudioRouteMonitor"

        /** Volumen "seguro" en dB para speaker: -15 dB (muy bajo). */
        const val SAFE_SPEAKER_VOLUME_DB = -15f

        /** Volumen normalizado (mapeo Dart): v = (db + 20) / 26. -15 dB → 0.192 */
        const val SAFE_SPEAKER_VOLUME_NORMALIZED = (-15f + 20f) / 26f
    }

    /**
     * Callback invocado cuando la salida de audio cae al parlante del
     * dispositivo (sin auricular BT ni cableado). El caller debe bajar
     * el volumen/mutear el motor y avisar al usuario.
     */
    var onRoutedToSpeaker: (() -> Unit)? = null

    private val audioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private var registered = false

    // ─── BroadcastReceiver para ACTION_AUDIO_BECOMING_NOISY ──────────────

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                Log.w(TAG, "ACTION_AUDIO_BECOMING_NOISY received — headset disconnected")
                onRoutedToSpeaker?.invoke()
            }
        }
    }

    // ─── AudioDeviceCallback (API 23+) ───────────────────────────────────

    private var deviceCallback: Any? = null // typed as Any to compile on API < 23

    // ─── Lifecycle ───────────────────────────────────────────────────────

    /**
     * Comienza a monitorear la ruta de audio. Debe llamarse después de
     * arrancar el motor (sólo tiene sentido con streams abiertos).
     */
    fun start() {
        if (registered) return
        registered = true

        // 1) BroadcastReceiver (todas las APIs).
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(noisyReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(noisyReceiver, filter)
        }
        Log.i(TAG, "Registered AUDIO_BECOMING_NOISY receiver")

        // 2) AudioDeviceCallback (API 23+): detecta desconexiones y también
        //    re-conexiones (útil para restaurar volumen cuando vuelve el BT).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            registerDeviceCallback()
        }
    }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun registerDeviceCallback() {
        val cb = object : AudioManager.AudioDeviceCallback() {
            override fun onAudioDevicesRemoved(devices: Array<out AudioDeviceInfo>?) {
                devices?.forEach { dev ->
                    if (dev.isSink && isHeadsetType(dev.type)) {
                        Log.w(TAG, "Output headset removed: ${dev.productName} (type=${dev.type})")
                        if (!hasHeadsetOutput()) {
                            onRoutedToSpeaker?.invoke()
                        }
                    }
                }
            }
        }
        audioManager.registerAudioDeviceCallback(cb, null)
        deviceCallback = cb
        Log.i(TAG, "Registered AudioDeviceCallback (API ${Build.VERSION.SDK_INT})")
    }

    /**
     * Deja de monitorear la ruta de audio. Llamar al detener el motor.
     */
    fun stop() {
        if (!registered) return
        registered = false

        try {
            context.unregisterReceiver(noisyReceiver)
        } catch (_: IllegalArgumentException) {
            // Ya desregistrado.
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            unregisterDeviceCallback()
        }

        Log.i(TAG, "Route monitor stopped")
    }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun unregisterDeviceCallback() {
        (deviceCallback as? AudioManager.AudioDeviceCallback)?.let {
            audioManager.unregisterAudioDeviceCallback(it)
        }
        deviceCallback = null
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    /** `true` si el tipo de dispositivo es un auricular/headset (BT o cable). */
    private fun isHeadsetType(type: Int): Boolean = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET -> true
        else -> {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                    type == AudioDeviceInfo.TYPE_BLE_SPEAKER
            } else false
        }
    }

    /** `true` si hay al menos un dispositivo de salida tipo auricular activo. */
    fun hasHeadsetOutput(): Boolean {
        val outputs = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        return outputs.any { isHeadsetType(it.type) }
    }
}

package com.psk.hearing_aid_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.util.Log

/**
 * Monitorea cambios de ruta de audio y dispara [onRoutedToSpeaker] cuando
 * la salida deja de ser un auricular (BT o cableado) y cae al parlante
 * del celular.
 *
 * Previene saturación/distorsión en el speaker al desconectarse un audífono
 * BT: el motor DSP sigue procesando con ganancias EQ de 20-50 dB diseñadas
 * para un auricular, que son extremas para un speaker a 5 cm del oído.
 *
 * Usa ACTION_AUDIO_BECOMING_NOISY (disponible en todas las APIs desde 3):
 * el sistema lo manda cuando un auricular se desconecta y la salida va a
 * caer al speaker. Es el mismo mecanismo que usan los reproductores de
 * música para pausar al desconectar auriculares.
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

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                Log.w(TAG, "ACTION_AUDIO_BECOMING_NOISY — headset disconnected")
                onRoutedToSpeaker?.invoke()
            }
        }
    }

    /**
     * Comienza a monitorear la ruta de audio.
     */
    fun start() {
        if (registered) return
        registered = true

        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(noisyReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(noisyReceiver, filter)
        }
        Log.i(TAG, "Route monitor started (AUDIO_BECOMING_NOISY)")
    }

    /**
     * Deja de monitorear la ruta de audio.
     */
    fun stop() {
        if (!registered) return
        registered = false
        try {
            context.unregisterReceiver(noisyReceiver)
        } catch (_: IllegalArgumentException) {}
        Log.i(TAG, "Route monitor stopped")
    }

    /** `true` si hay al menos un dispositivo de salida tipo auricular. */
    fun hasHeadsetOutput(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val outputs = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        return outputs.any { isHeadsetType(it.type) }
    }

    private fun isHeadsetType(type: Int): Boolean = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET -> true
        else -> false
    }
}

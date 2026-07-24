package com.psk.hearing_aid_app

import android.content.Context
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Log
import android.os.Build
import androidx.annotation.RequiresApi

/**
 * Monitor de estado de llamadas telefónicas.
 *
 * Detecta cuándo entra/sale una llamada para pausar/reanudar el motor DSP
 * y evitar conflicto de recursos (AudioRecord compartido entre el motor
 * Oboe y el sistema telefónico).
 *
 * Solución al bug: "micrófono no funciona en llamadas con Modo Conversación".
 * Durante una llamada, detenemos el motor DSP completamente para liberar
 * el micrófono. El SCO permanece activo para la llamada.
 */
class CallStateMonitor(private val context: Context) {

    companion object {
        private const val TAG = "CallStateMonitor"
    }

    private val telephonyManager = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager

    /** Callback que se invoca cuando entra/sale una llamada. */
    var onCallStateChanged: ((inCall: Boolean) -> Unit)? = null

    // Android 12+ (API 31+) usa TelephonyCallback, versiones anteriores PhoneStateListener
    @RequiresApi(Build.VERSION_CODES.S)
    private val telephonyCallback = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
        override fun onCallStateChanged(state: Int) {
            handleCallStateChange(state)
        }
    }

    @Suppress("DEPRECATION")
    private val phoneStateListener = object : PhoneStateListener() {
        override fun onCallStateChanged(state: Int, phoneNumber: String?) {
            handleCallStateChange(state)
        }
    }

    /**
     * Inicia el monitoreo de llamadas.
     * Debe llamarse después de `register()` en AudioMethodChannel.
     */
    fun start() {
        telephonyManager?.let { tm ->
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    tm.registerTelephonyCallback(context.mainExecutor, telephonyCallback)
                    Log.i(TAG, "TelephonyCallback registered (API 31+)")
                } else {
                    @Suppress("DEPRECATION")
                    tm.listen(phoneStateListener, PhoneStateListener.LISTEN_CALL_STATE)
                    Log.i(TAG, "PhoneStateListener registered (API <31)")
                }
            } catch (e: SecurityException) {
                Log.e(TAG, "Permission denied for phone state monitoring", e)
            }
        } ?: Log.w(TAG, "TelephonyManager not available")
    }

    /**
     * Detiene el monitoreo de llamadas.
     * Debe llamarse en `unregister()` en AudioMethodChannel.
     */
    fun stop() {
        telephonyManager?.let { tm ->
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    tm.unregisterTelephonyCallback(telephonyCallback)
                    Log.i(TAG, "TelephonyCallback unregistered")
                } else {
                    @Suppress("DEPRECATION")
                    tm.listen(phoneStateListener, PhoneStateListener.LISTEN_NONE)
                    Log.i(TAG, "PhoneStateListener unregistered")
                }
            } catch (e: Exception) {
                Log.w(TAG, "Error unregistering call state listener", e)
            }
        }
    }

    private fun handleCallStateChange(state: Int) {
        when (state) {
            TelephonyManager.CALL_STATE_IDLE -> {
                // No hay llamadas activas
                Log.i(TAG, "Call state: IDLE")
                onCallStateChanged?.invoke(false)
            }
            TelephonyManager.CALL_STATE_RINGING -> {
                // Llamada entrante (sonando pero no contestada)
                Log.i(TAG, "Call state: RINGING")
                onCallStateChanged?.invoke(true)
            }
            TelephonyManager.CALL_STATE_OFFHOOK -> {
                // Llamada activa (contestada o saliente)
                Log.i(TAG, "Call state: OFFHOOK (in call)")
                onCallStateChanged?.invoke(true)
            }
        }
    }
}

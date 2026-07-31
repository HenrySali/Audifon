package com.psk.hearing_aid_app

import android.content.Context
import android.media.AudioManager
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Plugin nativo Android para controlar el volumen del sistema durante la
 * calibración biológica.
 *
 * Expone un [MethodChannel] llamado `biological_calibration/volume` con
 * tres métodos:
 *
 * - `setMaxVolume`: fija `STREAM_MUSIC` al volumen máximo.
 *   El volumen del sistema debe estar al 100 % durante la calibración para
 *   garantizar que la conversión `dB HL → dBFS` sea estable y reproducible
 *   entre sesiones (cualquier cambio en el volumen rompería la calibración).
 *
 * - `getCurrentVolume`: devuelve el nivel de volumen actual de
 *   `STREAM_MUSIC` como `Int` en el rango `[0, max]`.
 *
 * - `getMaxVolume`: devuelve el nivel máximo soportado por el dispositivo
 *   para `STREAM_MUSIC` como `Int`.
 *
 * El plugin usa `AudioManager.setStreamVolume` con `flags = 0` para no
 * mostrar la UI de volumen del sistema durante el ajuste (la pantalla de
 * calibración informa al usuario por su cuenta).
 *
 * Patrón de uso:
 * ```
 * // En MainActivity.configureFlutterEngine
 * volumePlugin = BiologicalCalibrationVolumePlugin(flutterEngine, this).also {
 *     it.register()
 * }
 * ```
 *
 * Tarea relacionada: `tasks.md` ítem 5 — "Implementar plugin Android para
 * volumen del sistema".
 */
class BiologicalCalibrationVolumePlugin(
    private val flutterEngine: FlutterEngine,
    private val context: Context
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "BioCalVolumePlugin"

        /** Nombre del canal de métodos compartido con Dart. */
        const val METHOD_CHANNEL = "biological_calibration/volume"
    }

    private val methodChannel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        METHOD_CHANNEL
    )

    private val audioManager: AudioManager
        get() = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    /**
     * Registra el handler del MethodChannel.
     * Debe llamarse desde [MainActivity.configureFlutterEngine].
     */
    fun register() {
        Log.i(TAG, "Registering biological calibration volume channel")
        methodChannel.setMethodCallHandler(this)
    }

    /**
     * Desregistra el handler y libera recursos.
     * Debe llamarse desde [MainActivity.cleanUpFlutterEngine].
     */
    fun unregister() {
        Log.i(TAG, "Unregistering biological calibration volume channel")
        methodChannel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "onMethodCall: ${call.method}")

        try {
            when (call.method) {
                "setMaxVolume" -> handleSetMaxVolume(result)
                "getCurrentVolume" -> handleGetCurrentVolume(result)
                "getMaxVolume" -> handleGetMaxVolume(result)
                else -> result.notImplemented()
            }
        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException in ${call.method}", e)
            result.error(
                "VOLUME_SECURITY",
                "No se pudo modificar el volumen: ${e.message}",
                e.stackTraceToString()
            )
        } catch (e: Exception) {
            Log.e(TAG, "Error in ${call.method}", e)
            result.error(
                "VOLUME_ERROR",
                e.message ?: "Error desconocido en plugin de volumen",
                e.stackTraceToString()
            )
        }
    }

    /**
     * Fija `STREAM_MUSIC` al volumen máximo del dispositivo.
     * Devuelve el nivel máximo aplicado como `Int`.
     */
    private fun handleSetMaxVolume(result: MethodChannel.Result) {
        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        // flags = 0 → no mostrar la UI de volumen del sistema
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, max, 0)
        Log.i(TAG, "Volumen STREAM_MUSIC fijado a máximo ($max)")
        result.success(max)
    }

    /**
     * Devuelve el volumen actual de `STREAM_MUSIC` como `Int`.
     */
    private fun handleGetCurrentVolume(result: MethodChannel.Result) {
        val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        result.success(current)
    }

    /**
     * Devuelve el volumen máximo soportado para `STREAM_MUSIC` como `Int`.
     */
    private fun handleGetMaxVolume(result: MethodChannel.Result) {
        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        result.success(max)
    }
}

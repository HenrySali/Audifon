package com.psk.hearing_aid_app

import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Actividad principal de Flutter — punto de entrada de la app Android.
 *
 * Registra los canales de plataforma (MethodChannel y EventChannel) para
 * la comunicación bidireccional entre Flutter y el motor de audio nativo.
 *
 * Canales registrados:
 * - MethodChannel 'com.psk.hearing_aid/audio': comandos de control
 * - EventChannel 'com.psk.hearing_aid/level': nivel de entrada (~10 Hz)
 * - EventChannel 'com.psk.hearing_aid/state': estado del engine
 *
 * Nota Fase 3 (spec oir-pro-rebrand-harden-and-remote-config):
 * extiende FlutterFragmentActivity (no FlutterActivity) porque local_auth
 * monta su diálogo nativo de huella sobre la BiometricPrompt API que
 * requiere un FragmentActivity de AndroidX. Sin esto, la primera llamada
 * a authenticate() crashea con ClassCastException.
 */
class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val TAG = "MainActivity"
    }

    /** Puente de comunicación con Flutter vía platform channels. */
    private var audioMethodChannel: AudioMethodChannel? = null

    /** Plugin nativo para volumen del sistema durante la calibración biológica. */
    private var biologicalVolumePlugin: BiologicalCalibrationVolumePlugin? = null

    /** Canal nativo para guardar archivos en Downloads sin pasar por share sheet. */
    private var localDownloadsChannel: LocalDownloadsChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.i(TAG, "Configuring Flutter engine and platform channels")

        audioMethodChannel = AudioMethodChannel(flutterEngine, this).also {
            it.register()
        }

        biologicalVolumePlugin = BiologicalCalibrationVolumePlugin(flutterEngine, this).also {
            it.register()
        }

        localDownloadsChannel = LocalDownloadsChannel(flutterEngine, this).also {
            it.register()
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        Log.i(TAG, "Cleaning up Flutter engine and platform channels")
        audioMethodChannel?.unregister()
        audioMethodChannel = null
        biologicalVolumePlugin?.unregister()
        biologicalVolumePlugin = null
        localDownloadsChannel?.unregister()
        localDownloadsChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

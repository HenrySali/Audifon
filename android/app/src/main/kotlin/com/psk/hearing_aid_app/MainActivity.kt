package com.psk.hearing_aid_app

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
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
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "MainActivity"
    }

    /** Puente de comunicación con Flutter vía platform channels. */
    private var audioMethodChannel: AudioMethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.i(TAG, "Configuring Flutter engine and platform channels")

        audioMethodChannel = AudioMethodChannel(flutterEngine, this).also {
            it.register()
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        Log.i(TAG, "Cleaning up Flutter engine and platform channels")
        audioMethodChannel?.unregister()
        audioMethodChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

package com.psk.hearing_aid_app

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.util.Log
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Emisor de tonos puros para calibración de auriculares.
 *
 * Genera samples sintéticos PCM_16 a 48 kHz mono, los escribe en un
 * [AudioTrack] en modo [AudioTrack.MODE_STATIC] y reproduce.
 *
 * Spec: `native-calibration-handlers`, Requirement 3.3 + 3.4.
 */
class CalibrationToneEmitter {
    companion object {
        private const val TAG = "CalibrationToneEmitter"
        const val SAMPLE_RATE_HZ = 48000
        const val FADE_MS = 20
    }

    /**
     * Genera y reproduce un tono puro bloqueante. Retorna cuando el
     * tono terminó (incluye un buffer de 50 ms para asegurar que el
     * acoplador captura los últimos samples).
     *
     * @param freqHz Frecuencia del tono en Hz (250–8000 típico).
     * @param levelDbfs Nivel RMS objetivo en dBFS (-20.0 default).
     * @param durationMs Duración del tono en ms (incluye fade in/out).
     */
    fun playTone(freqHz: Double, levelDbfs: Double, durationMs: Int) {
        val nSamples = SAMPLE_RATE_HZ * durationMs / 1000
        // Para una senoide pura: peak = rms * sqrt(2). Escalamos a PCM_16.
        val peakAmplitude = 10.0.pow(levelDbfs / 20.0) * 32767.0 * sqrt(2.0)
        val fadeSamples = SAMPLE_RATE_HZ * FADE_MS / 1000
        val data = ShortArray(nSamples)
        for (i in 0 until nSamples) {
            val t = i.toDouble() / SAMPLE_RATE_HZ
            var s = sin(2.0 * PI * freqHz * t) * peakAmplitude
            // Cosine ramp para evitar clicks audibles.
            if (i < fadeSamples) {
                val r = (1.0 - cos(PI * i / fadeSamples)) * 0.5
                s *= r
            } else if (i > nSamples - fadeSamples) {
                val r = (1.0 - cos(PI * (nSamples - i) / fadeSamples)) * 0.5
                s *= r
            }
            data[i] = s.toInt().coerceIn(
                Short.MIN_VALUE.toInt(),
                Short.MAX_VALUE.toInt(),
            ).toShort()
        }
        Log.i(
            TAG,
            "playTone: freq=$freqHz Hz, levelDbfs=$levelDbfs, " +
                "durationMs=$durationMs, peakAmp=${peakAmplitude.toInt()}",
        )
        val track = AudioTrack(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build(),
            AudioFormat.Builder()
                .setSampleRate(SAMPLE_RATE_HZ)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build(),
            data.size * 2,
            AudioTrack.MODE_STATIC,
            AudioManager.AUDIO_SESSION_ID_GENERATE,
        )
        try {
            track.write(data, 0, data.size)
            track.play()
            Thread.sleep(durationMs.toLong() + 50)
        } finally {
            try { track.stop() } catch (_: Throwable) {}
            try { track.release() } catch (_: Throwable) {}
        }
    }
}

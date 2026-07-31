package com.psk.hearing_aid_app

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.util.Log
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Wrapper de [AudioRecord] dedicado a calibración acústica.
 *
 * Configuración fija:
 *   - 48000 Hz mono PCM_16.
 *   - Source: [MediaRecorder.AudioSource.UNPROCESSED] cuando está disponible
 *     (Android 24+) para bypass del DSP del fabricante (NS, AGC, AEC).
 *     Fallback a [MediaRecorder.AudioSource.MIC] en versiones anteriores.
 *   - Buffer interno: max(min, 4096) samples × 2 bytes.
 *
 * Uso típico:
 * ```kotlin
 * val capture = CalibrationAudioCapture.create(context)
 *     ?: return result.error("AUDIO_RECORD_FAILED", ...)
 * try {
 *     val window = capture.readWindowRmsDbfs(durationMs = 100)
 *     // ...
 * } finally {
 *     capture.release()
 * }
 * ```
 *
 * Spec: `native-calibration-handlers`, Requirements 1.1, 1.2, 2.2.
 */
class CalibrationAudioCapture private constructor(
    private val record: AudioRecord,
) {
    companion object {
        private const val TAG = "CalibrationAudioCapture"

        /** Sample rate fijo a 48 kHz (estándar audio profesional). */
        const val SAMPLE_RATE_HZ = 48000

        /** Buffer interno mínimo en samples. 4096 = ~85 ms de audio. */
        const val BUFFER_SAMPLES = 4096

        /** Tamaño de ventana RMS (samples para 100 ms a 48 kHz). */
        const val FRAME_SAMPLES_100MS = 4800

        /**
         * Crea una instancia inicializada y lista para leer.
         * @return null si el [AudioRecord] no pudo inicializarse
         *         (permiso faltante, hardware ocupado, sample rate
         *         no soportado).
         */
        fun create(context: Context): CalibrationAudioCapture? {
            val audioSource = if (Build.VERSION.SDK_INT >= 24) {
                MediaRecorder.AudioSource.UNPROCESSED
            } else {
                MediaRecorder.AudioSource.MIC
            }
            val minBuffer = AudioRecord.getMinBufferSize(
                SAMPLE_RATE_HZ,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minBuffer <= 0) {
                Log.e(TAG, "create: getMinBufferSize returned $minBuffer")
                return null
            }
            val bufferBytes = max(minBuffer, BUFFER_SAMPLES * 2)
            val record = try {
                AudioRecord(
                    audioSource,
                    SAMPLE_RATE_HZ,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    bufferBytes,
                )
            } catch (t: Throwable) {
                Log.e(TAG, "create: AudioRecord constructor failed", t)
                return null
            }
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                Log.e(TAG, "create: AudioRecord state=${record.state} (expected STATE_INITIALIZED)")
                try { record.release() } catch (_: Throwable) {}
                return null
            }
            try {
                record.startRecording()
            } catch (t: Throwable) {
                Log.e(TAG, "create: startRecording failed", t)
                try { record.release() } catch (_: Throwable) {}
                return null
            }
            Log.i(
                TAG,
                "create: ok (source=$audioSource, sr=$SAMPLE_RATE_HZ, " +
                    "bufferBytes=$bufferBytes)"
            )
            return CalibrationAudioCapture(record)
        }

        /**
         * Calcula el RMS dBFS de un buffer ShortArray con `count` samples válidos.
         * Fórmula: `dbfs = 20 * log10(max(rms, 1.0) / 32767.0)`, clamp a [-120, 0].
         */
        fun computeRmsDbfs(buffer: ShortArray, count: Int): Double {
            if (count <= 0) return -120.0
            var sumSq = 0.0
            for (i in 0 until count) {
                val v = buffer[i].toDouble()
                sumSq += v * v
            }
            val rms = sqrt(sumSq / count)
            val safeRms = max(rms, 1.0)  // floor para evitar -∞
            val dbfs = 20.0 * log10(safeRms / 32767.0)
            return max(dbfs, -120.0)
        }
    }

    /**
     * Lee una ventana de [durationMs] ms y retorna el RMS dBFS calculado.
     * @throws IllegalStateException si [AudioRecord.read] retorna error.
     */
    fun readWindowRmsDbfs(durationMs: Int = 100): Double {
        val samplesNeeded = SAMPLE_RATE_HZ * durationMs / 1000
        val buffer = ShortArray(samplesNeeded)
        var read = 0
        while (read < samplesNeeded) {
            val n = record.read(buffer, read, samplesNeeded - read)
            if (n < 0) {
                throw IllegalStateException(
                    "AudioRecord.read returned error code $n " +
                        "(samplesNeeded=$samplesNeeded, read=$read)"
                )
            }
            if (n == 0) {
                // En la práctica AudioRecord no debería retornar 0 cuando está
                // recording, pero por las dudas evitamos un loop infinito.
                Thread.sleep(1)
            }
            read += n
        }
        return computeRmsDbfs(buffer, read)
    }

    /**
     * Lee `count` ventanas consecutivas de [durationMs] ms y retorna los
     * RMS dBFS por ventana, descartando las primeras [dropFirst] (para
     * permitir estabilización del calibrador / DAC).
     *
     * Para mic calibration: count=50, durationMs=100, dropFirst=5 →
     * 50 ventanas × 100 ms = 5 segundos, las primeras 500 ms se descartan,
     * quedan 45 ventanas válidas para promediar.
     */
    fun readManyWindowsRmsDbfs(
        durationMs: Int = 100,
        count: Int = 50,
        dropFirst: Int = 0,
    ): List<Double> {
        require(count >= dropFirst) {
            "count ($count) debe ser >= dropFirst ($dropFirst)"
        }
        val out = ArrayList<Double>(count - dropFirst)
        for (i in 0 until count) {
            val w = readWindowRmsDbfs(durationMs)
            if (i >= dropFirst) out.add(w)
        }
        return out
    }

    /** Libera recursos del AudioRecord. Idempotente. */
    fun release() {
        try { record.stop() } catch (_: Throwable) {}
        try { record.release() } catch (_: Throwable) {}
        Log.i(TAG, "release: ok")
    }
}

/**
 * Desviación estándar de población (denominador = N).
 *
 * Se usa "población" en lugar de "muestral" porque el set de ventanas de
 * 100 ms es la población completa de la sesión de medición de 5 segundos,
 * no una muestra de una distribución más amplia.
 */
fun List<Double>.populationStandardDeviation(): Double {
    if (this.isEmpty()) return 0.0
    val mean = this.average()
    val variance = this.sumOf { (it - mean) * (it - mean) } / this.size
    return sqrt(variance)
}

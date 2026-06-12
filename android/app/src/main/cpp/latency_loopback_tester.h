/// @file latency_loopback_tester.h
/// @brief Tester de loopback acústico para medir latencia round-trip real (mic → DSP → auricular → mic).
///
/// Genera un chirp lineal corto, lo emite por el output stream y captura el audio
/// del input para luego correlacionar y obtener el lag (round-trip). El lag dividido
/// por el sample rate da la latencia end-to-end medida físicamente, incluyendo el
/// codec del enlace inalámbrico (que ninguna API de Android expone directamente).
///
/// Diseño:
/// - Generación del chirp: sweep lineal 200 Hz → 4 kHz, 20 ms, ventaneado Hann en bordes.
/// - Emisión sincronizada con el callback de Oboe (programada para el segundo 1 del test).
/// - Captura de 5 segundos en buffer dedicado.
/// - Cross-correlación normalizada en rango [0, 500 ms] al terminar la captura.
/// - Estado interno con atomics, sin locks; el callback de audio nunca bloquea.
///
/// Referencias:
/// - Android CTS audio loopback latency test
/// - OboeTester round-trip latency methodology (Google)

#ifndef HEARING_AID_LATENCY_LOOPBACK_TESTER_H
#define HEARING_AID_LATENCY_LOOPBACK_TESTER_H

#include <atomic>
#include <cstdint>
#include <vector>

namespace latency_monitor {

/// Parámetros del test de loopback acústico.
///
/// Los defaults están calibrados para 48 kHz y un round-trip esperado de 0–500 ms
/// (cubre desde cable directo hasta los peores codecs Bluetooth como LDAC ~300 ms).
struct LoopbackParams {
    int   sampleRate                = 48000;   ///< Hz
    float chirpStartHz              = 200.0f;  ///< Frecuencia inicial del sweep
    float chirpEndHz                = 4000.0f; ///< Frecuencia final del sweep
    int   chirpDurationSamples      = 960;     ///< 20 ms @ 48 kHz
    int   hannEdgeSamples           = 96;      ///< 2 ms @ 48 kHz, fade-in/out Hann
    int   chirpStartOffsetSamples   = 48000;   ///< 1 s tras start() antes de emitir
    int   captureDurationSamples    = 240000;  ///< 5 s @ 48 kHz
    int   searchRangeSamples        = 24000;   ///< 500 ms @ 48 kHz, ventana de búsqueda
    float minNormalizedPeak         = 0.1f;    ///< Umbral de confianza del pico
};

/// Resultado del test de loopback acústico.
///
/// POD con `errorMessage` como C-array para evitar alocaciones al cruzar
/// el boundary JNI. Los timestamps están en `CLOCK_MONOTONIC` (nanosegundos).
struct LoopbackResult {
    bool    success;                ///< true si el test completó con alta confianza
    bool    lowConfidence;          ///< true si el pico normalizado < minNormalizedPeak
    int     lagSamples;             ///< Round-trip en samples; -1 si lowConfidence
    double  latencyMs;              ///< lagSamples * 1000 / sampleRate; NaN si lowConfidence
    double  normalizedPeak;         ///< Magnitud del mejor pico de cross-correlación [0, 1]
    int64_t emissionTimestampNs;    ///< Instante CLOCK_MONOTONIC del primer sample emitido
    int64_t completionTimestampNs;  ///< Instante CLOCK_MONOTONIC al terminar la captura
    char    errorMessage[128];      ///< Cadena vacía si OK; descripción del fallo si !success
};

/// Tester de loopback acústico end-to-end.
///
/// Ciclo de vida:
///
///   IDLE  ──prepare()──▶  ARMED  ──start()──▶  EMITTING
///                                                  │
///                                                  ▼
///                                              CAPTURING
///                                                  │
///                                                  ▼
///                                              ANALYZING
///                                                  │
///                                                  ▼
///                                                DONE  ──getResult()──▶  IDLE
///
/// Se invoca `onAudioCallback()` desde `AudioEngine::onBothStreamsReady()` en cada
/// bloque cuando `isActive() == true`. El método sobrescribe el output con el chirp
/// (overwrite, no mix) y guarda el input en el buffer de captura.
class LatencyLoopbackTester {
public:
    /// Estados del ciclo de vida del tester. Codificados como int para usarse
    /// como valor del `std::atomic<int> state_`.
    enum State : int {
        IDLE      = 0,  ///< Sin test programado
        ARMED     = 1,  ///< prepare() OK; esperando start()
        EMITTING  = 2,  ///< Esperando offset de emisión o emitiendo chirp
        CAPTURING = 3,  ///< Chirp emitido, capturando input
        ANALYZING = 4,  ///< Captura completa, ejecutando cross-correlación
        DONE      = 5   ///< Resultado disponible vía getResult()
    };

    LatencyLoopbackTester() = default;
    ~LatencyLoopbackTester() = default;

    // No copiable ni movible (atómicos no son copiables y el tester es único).
    LatencyLoopbackTester(const LatencyLoopbackTester&)            = delete;
    LatencyLoopbackTester& operator=(const LatencyLoopbackTester&) = delete;

    /// Configura un nuevo test. Genera el chirp interno, asigna el buffer de
    /// captura y deja el estado en ARMED. Reset interno; no arranca todavía.
    /// @param params Parámetros del test (defaults razonables para 48 kHz).
    /// @return true si la configuración es válida y los buffers se asignaron.
    bool prepare(const LoopbackParams& params);

    /// Arranca el test. El primer sample del chirp se emitirá
    /// `params.chirpStartOffsetSamples` frames después de la próxima entrada
    /// al callback. Retorna inmediatamente; la emisión y captura ocurren
    /// dentro del callback de audio.
    /// @return true si el estado era ARMED y se transicionó a EMITTING.
    bool start();

    /// @return true si hay un test en curso (entre start() y la finalización
    ///         implícita después de captureDurationSamples).
    bool isActive() const;

    /// Hook llamado desde el callback de audio en cada bloque procesado.
    /// Sobrescribe `output[]` con el chirp en el momento programado y copia
    /// `input[]` al buffer de captura interno.
    /// @param input          Buffer de entrada (mic crudo, mono float32).
    /// @param numInputFrames Cantidad de frames en `input`.
    /// @param output         Buffer de salida (mono float32, in-place writable).
    /// @param numOutputFrames Cantidad de frames en `output`.
    void onAudioCallback(const float* input, int numInputFrames,
                         float*       output, int numOutputFrames);

    /// Detiene el test prematuramente. Descarta el resultado y vuelve a IDLE.
    void cancel();

    /// @return Copia del resultado final. Solo es válido cuando isActive() es false
    ///         y el estado interno es DONE; en otros estados retorna un resultado
    ///         con `success = false` y `errorMessage` describiendo el motivo.
    LoopbackResult getResult() const;

private:
    LoopbackParams params_{};

    /// Buffer del chirp pre-generado (size = chirpDurationSamples).
    std::vector<float> chirpBuffer_;

    /// Buffer de captura del input (size = captureDurationSamples).
    std::vector<float> captureBuffer_;

    /// Estado actual de la máquina (ver enum State).
    std::atomic<int> state_{IDLE};

    /// Cantidad de frames procesados desde start() — sirve para sincronizar
    /// la emisión del chirp y detectar el fin de la captura.
    std::atomic<int64_t> framesSinceStart_{0};

    /// Resultado final; lo escribe `runCrossCorrelation()` y lo lee `getResult()`.
    LoopbackResult result_{};

    /// Genera el chirp lineal en `chirpBuffer_` con ventana Hann en los bordes.
    void generateChirp();

    /// Ejecuta la cross-correlación normalizada entre `chirpBuffer_` y
    /// `captureBuffer_` en el rango [chirpStartOffset, chirpStartOffset + searchRange].
    /// Llena `result_` con el mejor lag y peak encontrados.
    void runCrossCorrelation();
};

} // namespace latency_monitor

#endif // HEARING_AID_LATENCY_LOOPBACK_TESTER_H

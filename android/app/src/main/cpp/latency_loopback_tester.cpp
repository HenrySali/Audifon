/// @file latency_loopback_tester.cpp
/// @brief Implementación del tester de loopback acústico.
///
/// Este archivo implementa:
///   - Generación del chirp lineal con ventana Hann (tarea 3.2).
///   - `prepare()`, `start()`, `isActive()` (tarea 3.2).
///   - Máquina de estados en el callback de audio: `onAudioCallback` (tarea 3.3).
///   - `runCrossCorrelation()` (correlación normalizada), `cancel()` y
///     `getResult()` (tarea 3.4).
///
/// Algoritmo del chirp (sweep lineal):
///   phase(n) = 2π · (f0·t + 0.5·k·t²)
///   donde t = n/sampleRate y k = (f1 - f0) / duracion
/// Ventana Hann en los primeros y últimos `hannEdgeSamples` para suprimir
/// transitorios espectrales en los bordes que podrían contaminar la
/// cross-correlación posterior.
///
/// Amplitud lineal 0.5 (≈ -6 dBFS) deja headroom para no clipear si el
/// master volume del sistema está alto.
///
/// Requisitos validados: 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 5.12, 5.13, 9.5

#include "latency_loopback_tester.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <time.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace latency_monitor {

// ─── Límites duros ────────────────────────────────────────────────────────────
// 480000 samples @ 48 kHz = 10 s. Por encima de eso el buffer de captura crece
// más allá de 1.9 MB y el test pierde sentido (los codecs BT más lentos están
// muy por debajo de 500 ms de round-trip).
static constexpr int kMaxCaptureDurationSamples = 480000;

// =============================================================================
//  generateChirp — sweep lineal 200 Hz → 4 kHz con ventana Hann en bordes
// =============================================================================
void LatencyLoopbackTester::generateChirp() {
    const int   N            = params_.chirpDurationSamples;
    const int   hannEdge     = params_.hannEdgeSamples;
    const float sampleRateF  = static_cast<float>(params_.sampleRate);
    const float dt           = 1.0f / sampleRateF;
    const float duration     = N * dt;
    // Pendiente del sweep lineal (Hz / segundo)
    const float k            = (params_.chirpEndHz - params_.chirpStartHz) / duration;

    chirpBuffer_.assign(N, 0.0f);

    for (int n = 0; n < N; ++n) {
        const float t = n * dt;

        // Fase instantánea del sweep lineal en frecuencia.
        const float phase = 2.0f * static_cast<float>(M_PI) *
                            (params_.chirpStartHz * t + 0.5f * k * t * t);
        float sample = sinf(phase);

        // Ventana Hann en el fade-in (primeros hannEdge samples).
        if (hannEdge > 0 && n < hannEdge) {
            const float w = 0.5f * (1.0f - cosf(static_cast<float>(M_PI) *
                                                static_cast<float>(n) /
                                                static_cast<float>(hannEdge)));
            sample *= w;
        }
        // Ventana Hann en el fade-out (últimos hannEdge samples).
        else if (hannEdge > 0 && n >= N - hannEdge) {
            const int   k2 = N - 1 - n;
            const float w  = 0.5f * (1.0f - cosf(static_cast<float>(M_PI) *
                                                 static_cast<float>(k2) /
                                                 static_cast<float>(hannEdge)));
            sample *= w;
        }

        // Amplitud lineal 0.5 → ≈ -6 dBFS, deja headroom contra clipping.
        chirpBuffer_[n] = sample * 0.5f;
    }
}

// =============================================================================
//  prepare — valida params, genera chirp, asigna captura, queda en ARMED
// =============================================================================
bool LatencyLoopbackTester::prepare(const LoopbackParams& params) {
    // ─── Validaciones de entrada ────────────────────────────────────────────
    if (params.sampleRate <= 0) {
        return false;
    }
    if (params.chirpDurationSamples <= 0) {
        return false;
    }
    if (params.captureDurationSamples <= 0) {
        return false;
    }
    if (params.captureDurationSamples > kMaxCaptureDurationSamples) {
        // Tope de 10 s @ 48 kHz para acotar el uso de memoria.
        return false;
    }
    if (params.hannEdgeSamples < 0 ||
        params.hannEdgeSamples * 2 > params.chirpDurationSamples) {
        // Las dos ventanas Hann no pueden solaparse.
        return false;
    }
    if (params.chirpStartOffsetSamples < 0) {
        return false;
    }
    if (params.searchRangeSamples <= 0) {
        return false;
    }
    // El chirp tiene que caber íntegramente dentro del buffer de captura
    // a partir de chirpStartOffsetSamples (sino la cross-correlación no
    // tiene material que correlacionar).
    if (params.chirpStartOffsetSamples + params.chirpDurationSamples >
        params.captureDurationSamples) {
        return false;
    }

    // ─── Copia de parámetros y reset de estado ─────────────────────────────
    params_ = params;
    framesSinceStart_.store(0, std::memory_order_relaxed);

    // Resultado limpio para que un consumidor que lea result_ antes de tiempo
    // no encuentre datos basura.
    std::memset(&result_, 0, sizeof(result_));
    result_.lagSamples = -1;

    // ─── Genera el chirp y asigna el buffer de captura ──────────────────────
    generateChirp();
    captureBuffer_.assign(params_.captureDurationSamples, 0.0f);

    // Listo para start().
    state_.store(ARMED, std::memory_order_release);
    return true;
}

// =============================================================================
//  start — pasa de ARMED a EMITTING
// =============================================================================
bool LatencyLoopbackTester::start() {
    int expected = ARMED;
    // CAS: solo arrancamos si veníamos de ARMED. Si está en cualquier otro
    // estado (IDLE, EMITTING, etc.), retornamos false sin modificar nada.
    if (!state_.compare_exchange_strong(expected, EMITTING,
                                        std::memory_order_acq_rel,
                                        std::memory_order_acquire)) {
        return false;
    }

    framesSinceStart_.store(0, std::memory_order_release);
    return true;
}

// =============================================================================
//  isActive — true mientras el tester no está en IDLE ni en DONE
// =============================================================================
bool LatencyLoopbackTester::isActive() const {
    const int s = state_.load(std::memory_order_acquire);
    return s != IDLE && s != DONE;
}

// =============================================================================
//  Stubs para tarea 3.4 — implementación pendiente
// =============================================================================

// =============================================================================
//  onAudioCallback — máquina de estados que corre dentro del callback de Oboe
// =============================================================================
//
// Llamado en cada bloque procesado por el AudioEngine cuando isActive() == true.
// Tres responsabilidades en este orden:
//
//   1) Capturar `input[]` al `captureBuffer_` en la posición correspondiente al
//      total de frames procesados desde start() (`framesSinceStart_`).
//   2) Sobrescribir `output[]` con silencio y mezclar el chirp pre-generado en
//      la ventana de emisión [chirpStartOffsetSamples, +chirpDurationSamples].
//      Es overwrite, no mix: el AudioEngine ya silenció el pipeline DSP cuando
//      el tester arrancó (setAmbientMute(true)).
//   3) Cuando se emite el primer sample del chirp, marca emissionTimestampNs y
//      transiciona EMITTING → CAPTURING. Cuando se llena el buffer de captura,
//      marca completionTimestampNs, transiciona a ANALYZING, dispara la
//      cross-correlación (en este mismo callback porque el output ya está
//      silenciado y la operación no agrega latencia perceptible al loop) y
//      finaliza en DONE.
//
// Sin locks: state_ usa acquire/release; framesSinceStart_ es atómico relaxed/
// release porque solo lo escribe este callback (single-writer).
//
// Requirements: 5.2, 5.3, 5.12.
void LatencyLoopbackTester::onAudioCallback(const float* input, int numInputFrames,
                                            float*       output, int numOutputFrames) {
    // ─── Filtro temprano: solo procesamos en EMITTING o CAPTURING ───────────
    // IDLE / ARMED / ANALYZING / DONE → no-op.
    const int s = state_.load(std::memory_order_acquire);
    if (s != EMITTING && s != CAPTURING) {
        return;
    }

    // Snapshot del contador. Único escritor → relaxed alcanza para leer.
    const int64_t fStart = framesSinceStart_.load(std::memory_order_relaxed);

    // ─── 1) Captura: input[] → captureBuffer_[fStart .. fStart + numIn] ────
    // Si fStart ya pasó captureDurationSamples no hay slot que escribir; el
    // chequeo de fin de captura más abajo igualmente disparará la transición.
    const int captureDuration = params_.captureDurationSamples;
    if (input != nullptr && numInputFrames > 0 && fStart < captureDuration) {
        const int64_t remaining64 = static_cast<int64_t>(captureDuration) - fStart;
        const int     captureCount = static_cast<int>(
            std::min<int64_t>(static_cast<int64_t>(numInputFrames), remaining64));
        if (captureCount > 0) {
            std::memcpy(&captureBuffer_[static_cast<size_t>(fStart)],
                        input,
                        static_cast<size_t>(captureCount) * sizeof(float));
        }
    }

    // ─── 2) Emisión: silencio + chirp en la ventana de emisión ─────────────
    if (output != nullptr && numOutputFrames > 0) {
        // Overwrite con silencio (el pipeline DSP ya está muteado por
        // setAmbientMute, así que no estamos pisando audio útil).
        std::memset(output, 0, static_cast<size_t>(numOutputFrames) * sizeof(float));

        const int chirpDur      = params_.chirpDurationSamples;
        const int chirpEmitStart = params_.chirpStartOffsetSamples;
        const int chirpEmitEnd   = chirpEmitStart + chirpDur;

        // ¿Hay overlap entre la ventana de este callback y la del chirp?
        const int64_t cbEnd = fStart + static_cast<int64_t>(numOutputFrames);
        if (cbEnd > chirpEmitStart && fStart < chirpEmitEnd) {
            // Posición dentro de output[] donde empieza la copia del chirp.
            const int chirpStartInBuffer = static_cast<int>(
                std::max<int64_t>(0, static_cast<int64_t>(chirpEmitStart) - fStart));
            // Posición dentro de chirpBuffer_ desde donde leer.
            const int chirpStartInChirpBuf = static_cast<int>(
                std::max<int64_t>(0, fStart - static_cast<int64_t>(chirpEmitStart)));
            const int chirpRemaining = chirpDur - chirpStartInChirpBuf;
            const int copyCount = std::min(numOutputFrames - chirpStartInBuffer,
                                           chirpRemaining);
            if (copyCount > 0) {
                std::memcpy(&output[chirpStartInBuffer],
                            &chirpBuffer_[static_cast<size_t>(chirpStartInChirpBuf)],
                            static_cast<size_t>(copyCount) * sizeof(float));
            }

            // ¿Es la primera vez que emitimos un sample del chirp en este test?
            // Esto se cumple solo cuando fStart está antes (o exacto) de
            // chirpEmitStart y el callback cruza la frontera.
            if (fStart <= chirpEmitStart && cbEnd > chirpEmitStart) {
                struct timespec ts;
                clock_gettime(CLOCK_MONOTONIC, &ts);
                result_.emissionTimestampNs =
                    static_cast<int64_t>(ts.tv_sec) * 1000000000LL +
                    static_cast<int64_t>(ts.tv_nsec);

                // Transición EMITTING → CAPTURING. Si ya estábamos en
                // CAPTURING (no debería pasar; el chirp se emite una sola vez)
                // dejamos el estado igual.
                if (s == EMITTING) {
                    state_.store(CAPTURING, std::memory_order_release);
                }
            }
        }
    }

    // ─── 3) Avanzar contador y cerrar el test si llenamos la captura ───────
    const int64_t newFrames = fStart + static_cast<int64_t>(numOutputFrames);
    framesSinceStart_.store(newFrames, std::memory_order_release);

    if (newFrames >= static_cast<int64_t>(captureDuration)) {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        result_.completionTimestampNs =
            static_cast<int64_t>(ts.tv_sec) * 1000000000LL +
            static_cast<int64_t>(ts.tv_nsec);

        // Transición a ANALYZING antes de correr la cross-correlación; así
        // un getResult() concurrente ve el estado intermedio en lugar de
        // datos parcialmente escritos.
        state_.store(ANALYZING, std::memory_order_release);

        // Cross-correlación in-callback. El output ya está silenciado y la
        // emisión terminó hace varios callbacks, así que correrlo acá no
        // genera glitches audibles.
        runCrossCorrelation();

        state_.store(DONE, std::memory_order_release);
    }
}

// =============================================================================
//  cancel — aborta el test, descarta resultado y vuelve a IDLE
// =============================================================================
//
// Pensado para usarse desde el lado de control (Kotlin/Dart). NO debe llamarse
// desde el callback de audio (no hay locks pero limpiar `result_` con memset
// junto con un getResult() concurrente sería una carrera).
//
// La transición a IDLE detiene la máquina de estados de `onAudioCallback`
// (que ignora cualquier estado distinto de EMITTING/CAPTURING) y limpia el
// resultado para que un getResult() posterior al cancel no devuelva datos
// de un test anterior.
//
// Requirements: 5.13.
void LatencyLoopbackTester::cancel() {
    state_.store(IDLE, std::memory_order_release);

    // Reset del resultado para que un getResult() después de cancel devuelva
    // ceros + lagSamples=-1 (consistente con el contrato de "no test válido").
    std::memset(&result_, 0, sizeof(result_));
    result_.lagSamples = -1;
}

// =============================================================================
//  getResult — copia del resultado final tras el test
// =============================================================================
//
// Se espera que el consumidor verifique `isActive() == false` antes de llamar
// (idealmente cuando el estado interno ya pasó por DONE). El callback de audio
// es quien transiciona a DONE al terminar la cross-correlación; este método
// no muta estado: solo devuelve la última copia coherente de `result_`.
//
// Si el consumidor llama antes de tiempo (estado != DONE), recibe el contenido
// actual de result_ (típicamente ceros + lagSamples=-1 de prepare/cancel) sin
// que esto rompa nada — los flags success/lowConfidence van a indicar el
// estado real.
//
// Requirements: 5.5, 5.6, 5.7.
LoopbackResult LatencyLoopbackTester::getResult() const {
    return result_;
}

// =============================================================================
//  runCrossCorrelation — correlación normalizada chirp · captura
// =============================================================================
//
// Ejecutada desde `onAudioCallback` cuando la captura completa. Busca el lag
// (en samples) que maximiza la correlación normalizada entre `chirpBuffer_` y
// la ventana móvil de `captureBuffer_` arrancando en `chirpStartOffsetSamples`.
//
// Fórmula:
//
//     normalized(lag) = Σ_n chirp[n] · capture[off+lag+n]
//                       ─────────────────────────────────────
//                       √( Σ_n chirp[n]²  ·  Σ_n capture[off+lag+n]² )
//
// La normalización por la energía local del segmento capturado hace al
// algoritmo robusto frente a:
//   - variación de nivel (auricular más cerca/lejos del mic)
//   - ruido ambiente moderado
//   - DC offsets y ganancia desconocida del path de salida
//
// Triage de resultados:
//   - bestPeak >= minNormalizedPeak  →  success = true, lag y latencyMs válidos
//   - bestPeak <  minNormalizedPeak  →  lowConfidence = true, lagSamples=-1,
//                                       latencyMs = NaN (el caller debe usar
//                                       la estimación analítica como fallback)
//   - chirpEnergy ~ 0                →  caso patológico (no debería pasar con
//                                       el chirp generado), success=false con
//                                       errorMessage descriptivo.
//
// Costo: O(searchRange × chirpDur) ≈ 24000 × 960 ≈ 23M MACs. En un Cortex-A
// moderno corre en pocos ms; aceptable porque el output ya está silenciado y
// la captura terminó (no afecta latencia de audio en vivo).
//
// Requirements: 5.4, 5.5, 5.6, 5.7, 9.5.
void LatencyLoopbackTester::runCrossCorrelation() {
    const int chirpLen            = params_.chirpDurationSamples;
    const int searchRange         = params_.searchRangeSamples;
    const int captureLen          = params_.captureDurationSamples;
    const int chirpStartInCapture = params_.chirpStartOffsetSamples;

    // ─── Energía del chirp (constante a lo largo de los lags) ──────────────
    float chirpEnergy = 0.0f;
    for (int n = 0; n < chirpLen; ++n) {
        chirpEnergy += chirpBuffer_[n] * chirpBuffer_[n];
    }
    if (chirpEnergy < 1e-10f) {
        // Caso patológico: el chirp generado quedó plano. No debería ocurrir
        // con los defaults (sweep 200-4k Hz, amplitud 0.5), pero protegemos
        // contra una mala configuración futura.
        result_.success        = false;
        result_.lowConfidence  = true;
        result_.lagSamples     = -1;
        result_.latencyMs      = std::nan("");
        result_.normalizedPeak = 0.0f;
        std::strncpy(result_.errorMessage,
                     "chirp energy too low",
                     sizeof(result_.errorMessage) - 1);
        result_.errorMessage[sizeof(result_.errorMessage) - 1] = '\0';
        return;
    }

    // ─── Búsqueda del mejor lag en [0, searchRange) ────────────────────────
    float bestPeak = 0.0f;
    int   bestLag  = -1;
    for (int lag = 0; lag < searchRange; ++lag) {
        const int offset = chirpStartInCapture + lag;
        // Si el segmento se sale del buffer de captura, no hay material que
        // correlacionar. Cortamos acá.
        if (offset + chirpLen > captureLen) break;

        float xcorr         = 0.0f;
        float captureEnergy = 0.0f;
        for (int n = 0; n < chirpLen; ++n) {
            const float c = captureBuffer_[offset + n];
            xcorr         += chirpBuffer_[n] * c;
            captureEnergy += c * c;
        }
        // Segmento silencioso: skip (la división normalizaría por cero).
        if (captureEnergy < 1e-10f) continue;

        const float normalized = xcorr / std::sqrt(chirpEnergy * captureEnergy);
        const float absNorm    = std::fabs(normalized);
        if (absNorm > bestPeak) {
            bestPeak = absNorm;
            bestLag  = lag;
        }
    }

    result_.normalizedPeak = bestPeak;

    // ─── Triage por umbral de confianza ────────────────────────────────────
    if (bestPeak < params_.minNormalizedPeak) {
        // Pico demasiado bajo: probablemente no se detectó el chirp
        // (auricular silenciado, mic muy lejos, ruido excesivo). El caller
        // debería caer al estimador analítico.
        result_.success       = false;
        result_.lowConfidence = true;
        result_.lagSamples    = -1;
        result_.latencyMs     = std::nan("");
        std::strncpy(result_.errorMessage,
                     "peak below confidence threshold",
                     sizeof(result_.errorMessage) - 1);
        result_.errorMessage[sizeof(result_.errorMessage) - 1] = '\0';
    } else {
        // Detección con confianza: lag → latencia round-trip en ms.
        result_.success        = true;
        result_.lowConfidence  = false;
        result_.lagSamples     = bestLag;
        result_.latencyMs      = static_cast<double>(bestLag) * 1000.0 /
                                 static_cast<double>(params_.sampleRate);
        result_.errorMessage[0] = '\0';
    }
}

} // namespace latency_monitor

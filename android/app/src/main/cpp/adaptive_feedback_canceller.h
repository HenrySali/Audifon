/// @file adaptive_feedback_canceller.h
/// @brief Cancelador adaptativo de feedback acústico (AFC) con probe noise.
///
/// Problema que resuelve: el FBS (notch+guard) actual es REACTIVO — detecta el
/// howl cuando ya suena y lo atenúa con notches/guard. Un tono que "salta" de
/// frecuencia (como el de diag_20260615_182919.wav, 2.5-3 kHz) evade los notch
/// porque migra antes de que el hold expire. El AFC es PREVENTIVO: estima el
/// camino de feedback (mic→parlante→aire→mic) y RESTA la estimación de la señal
/// del mic ANTES de que entre al pipeline. Así el lazo nunca se cierra, y el
/// howl no nace.
///
/// Algoritmo: NLMS (Normalized Least Mean Squares) con probe noise decorrelante.
///   - FIR de `kFilterLength` taps modela el feedback path.
///   - La señal de referencia es la salida del parlante (buffer de salida del
///     bloque ANTERIOR, almacenada internamente).
///   - Se inyecta probe noise inaudible (~-50 dBFS) sumado a la salida del
///     parlante para decorrelacionar la referencia de la señal deseada (voz),
///     evitando entrainment/bias del filtro adaptativo.
///   - La estimación del feedback se resta sample-por-sample del mic.
///   - El error residual es la señal "limpia" que entra al resto del pipeline.
///
/// Approach "delay-based": el AFC guarda una copia del buffer de salida al final
/// de processBlock (post-MPO). En el SIGUIENTE processBlock, usa esa copia como
/// referencia x[n] para el filtro adaptivo. El retardo inherente de 1 bloque
/// (~1.3 ms a 48 kHz/64 o ~4 ms a 16 kHz/64) es menor que el retardo acústico
/// real mic↔parlante (~3-10 ms), así que la estimación sigue siendo válida.
///
/// Posición en el pipeline:
///   ENTRADA: opera sobre el buffer del mic ANTES del HPF (etapa -1).
///   SALIDA: inyecta probe noise AL buffer de salida, post-MPO (etapa 8+).
///
/// Diseño: header-only, sin deps externas, lock-free, solo resta (seguro).
///
/// Referencias:
/// - PMC7545262: NLMS + probe noise para AFC en audífonos.
/// - ScienceDirect 2006: PEM-AFC (Prediction Error Method).
/// - Springer 2023: probe + informative data para convergencia rápida.
/// - Kates 2008: "Digital Hearing Aids" cap. 8 (feedback cancellation).

#ifndef HEARING_AID_ADAPTIVE_FEEDBACK_CANCELLER_H
#define HEARING_AID_ADAPTIVE_FEEDBACK_CANCELLER_H

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>

/// Cancelador adaptativo de feedback con probe noise (AFC).
///
/// Uso típico (dentro de DspPipeline):
/// @code
///   AdaptiveFeedbackCanceller afc;
///   afc.init(48000);
///   // Al INICIO de processBlock:
///   afc.removeFeedback(micBuffer, blockSize);  // resta estimación del feedback
///   // ... pipeline normal (HPF → TNR → NR → EQ → WDRC → Vol → FBS → OC → MPO) ...
///   // Al FINAL de processBlock (post-MPO):
///   afc.injectProbeAndCapture(outputBuffer, blockSize); // agrega probe + guarda referencia
/// @endcode
class AdaptiveFeedbackCanceller {
public:
    // ─── Constantes de diseño ────────────────────────────────────────────────

    /// Longitud del filtro FIR adaptativo (taps).
    /// 48 taps a 48 kHz = 1 ms de retardo modelable. Cubre el delay acústico
    /// mic↔parlante en un auricular con cable (~0.5–2 ms). A 16 kHz cubre ~3 ms.
    static constexpr int kFilterLength = 48;

    /// Tamaño máximo de bloque soportado (para buffers internos estáticos).
    static constexpr int kMaxBlockSize = 512;

    /// Tamaño del ring buffer de referencia (historial del parlante).
    /// Debe ser >= kFilterLength + kMaxBlockSize para tener suficiente pasado.
    static constexpr int kRefBufSize = 1024;

    /// Step size NLMS (mu). Controla velocidad de convergencia vs misadjustment.
    /// 0.002 con leak=0.002 da convergencia neta lenta pero robusta contra
    /// entrainment (solo con feedback sostenido la adaptación gana sobre el leak).
    static constexpr float kDefaultMu = 0.002f;

    /// Regularización (delta) del NLMS para evitar división por cero.
    static constexpr float kDefaultDelta = 1e-6f;

    /// Factor de leak (lambda) del Leaky NLMS. Cada bloque los coeficientes se
    /// multiplican por (1 - leak). Con leak=0.002, los coeficientes decaen ~50%
    /// en 350 bloques (~1.4 s a 16kHz/64). Solo un feedback SOSTENIDO
    /// (correlación persistente) puede mantener los coeficientes altos contra
    /// el leak; la autocorrelación transitoria de voz no logra.
    static constexpr float kDefaultLeak = 0.002f;

    /// Amplitud del probe noise (lineal). -50 dBFS ≈ 0.00316.
    /// Inaudible en la salida (threshold de audición en silencio ~20 dB SPL,
    /// y con el offset de 93 dB esto es ~43 dB SPL — bajo el umbral auditivo
    /// normal a frecuencias medias).
    static constexpr float kDefaultProbeLevel = 0.003f;

    AdaptiveFeedbackCanceller() = default;
    ~AdaptiveFeedbackCanceller() = default;

    /// Inicializa el AFC para el sample rate dado. Resetea el filtro y buffers.
    /// @param sampleRate Hz (16000 o 48000)
    void init(int sampleRate) {
        sampleRate_ = (sampleRate > 0) ? sampleRate : 48000;

        // Reset filter coefficients (FIR taps)
        std::memset(w_, 0, sizeof(w_));

        // Reset reference ring buffer
        std::memset(refBuf_, 0, sizeof(refBuf_));
        refWriteIdx_ = 0;

        // Reset PRNG state (LCG seed)
        prngState_ = 12345u;

        // Parameters (defaults)
        mu_.store(kDefaultMu, std::memory_order_relaxed);
        delta_.store(kDefaultDelta, std::memory_order_relaxed);
        leak_.store(kDefaultLeak, std::memory_order_relaxed);
        probeLevel_.store(kDefaultProbeLevel, std::memory_order_relaxed);
        enabled_.store(true, std::memory_order_relaxed);

        // Diagnostic: running estimate of feedback path energy
        pathEnergy_.store(0.0f, std::memory_order_relaxed);
    }

    /// ETAPA 1 (inicio de processBlock): resta la estimación del feedback del
    /// buffer de mic. Opera sample-por-sample usando el historial del parlante
    /// (referencia) almacenado del bloque anterior.
    ///
    /// Después de esta llamada, `micBuffer` contiene la señal "limpia" (error
    /// del NLMS = voz + ruido ambiente, sin la componente de feedback).
    ///
    /// @param micBuffer Buffer de entrada del micrófono (modificado in-place)
    /// @param blockSize Número de muestras en el buffer
    void removeFeedback(float* micBuffer, int blockSize) {
        if (!enabled_.load(std::memory_order_relaxed)) return;
        if (micBuffer == nullptr || blockSize <= 0) return;
        if (blockSize > kMaxBlockSize) blockSize = kMaxBlockSize;

        const float mu = mu_.load(std::memory_order_relaxed);
        const float delta = delta_.load(std::memory_order_relaxed);
        const float leak = leak_.load(std::memory_order_relaxed);

        // Leaky NLMS: decay coeficientes cada bloque.
        // Con leak=0.002, un coeficiente espúreo (aprendido de autocorrelación
        // de voz) decae ~50% en 350 bloques (~1.4 s). Solo un feedback
        // SOSTENIDO (señal tonal estacionaria con correlación persistente)
        // puede mantener/crecer los coeficientes contra el leak.
        const float leakFactor = 1.0f - leak;
        for (int k = 0; k < kFilterLength; ++k) {
            w_[k] *= leakFactor;
        }

        // NLMS: adaptar + aplicar cada sample.
        for (int i = 0; i < blockSize; ++i) {
            float yHat = 0.0f;
            float normSq = 0.0f;

            for (int k = 0; k < kFilterLength; ++k) {
                const int offset = i - blockSize - k;
                const float xk = getRef(offset);
                yHat += w_[k] * xk;
                normSq += xk * xk;
            }

            // Error = mic - estimación del feedback
            const float error = micBuffer[i] - yHat;

            // NLMS update
            if (normSq > delta) {  // solo adaptar si hay energía en la ref
                const float norm = mu / (normSq + delta);
                for (int k = 0; k < kFilterLength; ++k) {
                    const int offset = i - blockSize - k;
                    w_[k] += norm * error * getRef(offset);
                }
            }

            // Aplicar: reemplazar mic por error (señal sin feedback)
            micBuffer[i] = error;
        }

        // Diagnóstico: energía del path estimado
        float energy = 0.0f;
        for (int k = 0; k < kFilterLength; ++k) {
            energy += w_[k] * w_[k];
        }
        pathEnergy_.store(energy, std::memory_order_relaxed);
    }

    /// ETAPA 2 (final de processBlock, post-MPO): inyecta probe noise inaudible
    /// al buffer de salida y almacena la salida (con probe) como referencia
    /// para el siguiente bloque.
    ///
    /// El probe noise decorrelaciona la referencia de la señal deseada (evita
    /// entrainment: sin probe, el NLMS confundiría voz auto-correlada con
    /// feedback y la cancelaría parcialmente).
    ///
    /// @param outputBuffer Buffer de salida del pipeline (modificado in-place:
    ///        se le suma el probe noise)
    /// @param blockSize Número de muestras
    void injectProbeAndCapture(float* outputBuffer, int blockSize) {
        if (!enabled_.load(std::memory_order_relaxed)) return;
        if (outputBuffer == nullptr || blockSize <= 0) return;
        if (blockSize > kMaxBlockSize) blockSize = kMaxBlockSize;

        const float probeAmp = probeLevel_.load(std::memory_order_relaxed);

        for (int i = 0; i < blockSize; ++i) {
            // Generar probe noise (LCG pseudo-random, distribuido [-1, +1])
            const float probe = generateProbe() * probeAmp;

            // Inyectar probe a la salida (inaudible a -50 dBFS)
            outputBuffer[i] += probe;

            // Almacenar en el ring buffer de referencia (señal del parlante
            // completa = salida DSP + probe). El NLMS la usará como `x[n]`
            // en el siguiente bloque.
            refBuf_[refWriteIdx_] = outputBuffer[i];
            refWriteIdx_ = (refWriteIdx_ + 1) & (kRefBufSize - 1);
        }
    }

    // ─── Setters (thread-safe, lock-free) ────────────────────────────────────

    /// Habilita/deshabilita el AFC. Default: ON.
    void setEnabled(bool enabled) {
        enabled_.store(enabled, std::memory_order_relaxed);
    }
    bool isEnabled() const {
        return enabled_.load(std::memory_order_relaxed);
    }

    /// Step size (mu) del NLMS. Rango: [0.001, 0.1]. Default: 0.01.
    void setStepSize(float mu) {
        mu = std::max(0.001f, std::min(0.1f, mu));
        mu_.store(mu, std::memory_order_relaxed);
    }

    /// Nivel del probe noise (lineal). Rango: [0.0, 0.01]. Default: 0.003.
    void setProbeLevel(float level) {
        level = std::max(0.0f, std::min(0.01f, level));
        probeLevel_.store(level, std::memory_order_relaxed);
    }

    /// Longitud efectiva del filtro (no cambia en runtime; informativo).
    int getFilterLength() const { return kFilterLength; }

    // ─── Diagnóstico (thread-safe, lectura desde UI) ─────────────────────────

    /// Energía del path de feedback estimado (sum of w²). Si es ~0, no hay
    /// feedback path modelado (señal limpia o AFC recién iniciado).
    float getPathEnergy() const {
        return pathEnergy_.load(std::memory_order_relaxed);
    }

private:
    /// Obtiene una muestra del ring buffer de referencia con offset negativo
    /// relativo a la posición de escritura actual.
    /// @param offset Offset negativo (0 = última muestra escrita, -1 = anterior, etc.)
    inline float getRef(int offset) const {
        // refWriteIdx_ apunta a la SIGUIENTE posición a escribir.
        // La última escrita es refWriteIdx_ - 1.
        // offset es negativo o cero.
        int idx = (refWriteIdx_ - 1 + offset) & (kRefBufSize - 1);
        return refBuf_[idx];
    }

    /// Generador de ruido pseudo-aleatorio (LCG rápido, calidad suficiente
    /// para probe noise decorrelante). Genera valores en [-1.0, +1.0].
    inline float generateProbe() {
        // LCG: x[n+1] = (a * x[n] + c) mod 2^32
        // Parámetros de Numerical Recipes (periodo 2^32).
        prngState_ = prngState_ * 1664525u + 1013904223u;
        // Mapear [0, 2^32) a [-1.0, +1.0]
        const float normalized = static_cast<float>(
            static_cast<int32_t>(prngState_)) / 2147483648.0f;
        return normalized;
    }

    // ─── Estado del filtro adaptivo (audio thread only) ──────────────────────

    /// Coeficientes del FIR adaptivo (feedback path estimate).
    float w_[kFilterLength] = {};

    /// Ring buffer de referencia (historial de la señal del parlante con probe).
    /// Tamaño potencia de 2 para mask en vez de modulo.
    float refBuf_[kRefBufSize] = {};

    /// Índice de escritura del ring buffer (apunta al SIGUIENTE slot libre).
    int refWriteIdx_ = 0;

    /// Estado del PRNG (LCG).
    uint32_t prngState_ = 12345u;

    /// Sample rate (informativo).
    int sampleRate_ = 48000;

    // ─── Parámetros atómicos (UI thread settable) ────────────────────────────

    std::atomic<float> mu_{kDefaultMu};
    std::atomic<float> delta_{kDefaultDelta};
    std::atomic<float> leak_{kDefaultLeak};
    std::atomic<float> probeLevel_{kDefaultProbeLevel};
    std::atomic<bool> enabled_{true};

    // ─── Diagnóstico ─────────────────────────────────────────────────────────

    std::atomic<float> pathEnergy_{0.0f};
};

#endif // HEARING_AID_ADAPTIVE_FEEDBACK_CANCELLER_H

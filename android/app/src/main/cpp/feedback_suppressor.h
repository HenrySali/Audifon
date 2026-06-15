/// @file feedback_suppressor.h
/// @brief Supresor de realimentación acústica (anti-howling / anti-Larsen).
///
/// Problema que resuelve: en un audífono basado en teléfono, el micrófono y el
/// parlante están cerca. A ganancia alta (bandas del EQ > +10 dB) la ganancia
/// del lazo acústico (mic → DSP → parlante → aire → mic) cruza el margen de
/// estabilidad (MSG) y el sistema entra en OSCILACIÓN: un pitido tonal sostenido
/// (efecto Larsen). El MPO acota la AMPLITUD del pitido pero NO rompe el lazo,
/// así que el pitido sigue (suena "grueso/recortado").
///
/// Estrategia (fase 1, bajo costo de CPU, solo atenúa):
///   1. DETECTOR de howling: por ventana de análisis mide tonalidad
///      (crest factor ≈ √2 para una sinusoide pura), nivel y estabilidad de
///      frecuencia. Un howling es tonal + fuerte + persistente + de frecuencia
///      estable. Voz y ruido tienen crest factor alto → no disparan.
///   2. NOTCH adaptativos: hasta `kMaxNotches` filtros peaking de ganancia
///      negativa (~-18 dB, Q alto) colocados en la(s) frecuencia(s) que
///      oscilan. Estiman la frecuencia por zero-crossings (preciso cuando la
///      señal es cuasi-sinusoidal, que es justo el caso del howl).
///   3. GUARD de ganancia (respaldo): si el howl persiste pese a los notch
///      (~300 ms), baja la ganancia de banda ancha unos dB hasta que el lazo
///      se estabiliza, y recupera al despejarse.
///
/// Se inserta en el pipeline DESPUÉS del Volume y ANTES del MPO (es lo último
/// que toca la señal que va a salir por el parlante, que es lo que realimenta).
///
/// Diseño: header-only (como TransientReducer), sample-by-sample, lock-free.
/// Solo atenúa (notch + guard ≤ 0 dB), nunca amplifica → seguro para las 3 apps.
///
/// Referencias: realimentación en audífonos — notch-filter feedback cancellation
/// (Maxwell & Zarek 1995), Maximum Stable Gain (MSG), howling detection por
/// tonalidad/persistencia (común en audífonos comerciales).

#ifndef HEARING_AID_FEEDBACK_SUPPRESSOR_H
#define HEARING_AID_FEEDBACK_SUPPRESSOR_H

#include <algorithm>
#include <atomic>
#include <cmath>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/// Supresor de realimentación acústica (anti-howling).
///
/// Uso típico:
/// @code
///   FeedbackSuppressor fbs;
///   fbs.init(16000);
///   fbs.setEnabled(true);
///   fbs.process(buffer, blockSize);  // in-place, post-Volume / pre-MPO
/// @endcode
class FeedbackSuppressor {
public:
    /// Máximo de notches adaptativos simultáneos. 2-3 cubre los modos de
    /// feedback más comunes sin teñir audibles el resto del espectro.
    static constexpr int kMaxNotches = 5;

    FeedbackSuppressor() = default;
    ~FeedbackSuppressor() = default;

    /// Inicializa con el sample rate del sistema.
    /// @param sampleRate Hz (típicamente 16000 o 48000)
    void init(int sampleRate) {
        sampleRate_ = (sampleRate > 0) ? sampleRate : 16000;

        // Ventana de análisis ≈ 16 ms a 16 kHz (256 muestras). A 48 kHz son
        // ~5.3 ms. Suficiente para estimar tonalidad y frecuencia del howl.
        analysisWindow_ = 256;

        const float windowMs = 1000.0f * static_cast<float>(analysisWindow_) /
                               static_cast<float>(sampleRate_);

        // Persistencia ≈ 100 ms antes de confirmar un howl (evita disparar con
        // transitorios tonales breves de la voz).
        persistWindows_ = std::max(2, static_cast<int>(100.0f / windowMs));

        // El notch se mantiene ≈ 1500 ms tras el último howl en esa frecuencia
        // (el feedback suele reaparecer en la misma banda; mantenerlo evita el
        // ciclo engage/release audible).
        notchHoldWindows_ = std::max(4, static_cast<int>(1500.0f / windowMs));

        // El guard espera ≈ 500 ms sin howl antes de empezar a recuperar la
        // ganancia (recuperación lenta para no reactivar el lazo / evitar pumping).
        guardRecoverDelayWindows_ = std::max(4, static_cast<int>(500.0f / windowMs));

        // Suavizado per-sample del guard (≈ 50 ms) para que los cambios de
        // ganancia de banda ancha sean libres de clicks.
        guardRecoverCoeff_ = 1.0f - std::exp(-1.0f / (0.050f * sampleRate_));

        // Rampa de mezcla seca/húmeda de cada notch (≈ 15 ms) para evitar clicks
        // al activar/desactivar.
        depthRampCoeff_ = 1.0f - std::exp(-1.0f / (0.015f * sampleRate_));

        // Reset de estado de análisis.
        winCount_ = 0;
        winSumSq_ = 0.0f;
        winPeak_ = 0.0f;
        winZeroCross_ = 0;
        prevSign_ = 0;
        tonalRunWindows_ = 0;
        guardClearWindows_ = 0;

        // Reset del guard.
        guardGain_ = 1.0f;
        guardTarget_ = 1.0f;

        // Reset de los notches.
        for (int n = 0; n < kMaxNotches; ++n) {
            notches_[n].reset();
        }
        activeNotchCount_.store(0, std::memory_order_relaxed);
        currentGuardGain_.store(1.0f, std::memory_order_relaxed);

        recomputeDepthLinear();
    }

    /// Procesa un bloque de audio in-place. Solo atenúa.
    /// @param buffer Audio float32 [-1.0, +1.0]
    /// @param blockSize Número de muestras
    void process(float* buffer, int blockSize) {
        if (!enabled_.load(std::memory_order_relaxed)) return;
        if (buffer == nullptr || blockSize <= 0) return;

        const float depth = depthLinear_.load(std::memory_order_relaxed);

        for (int i = 0; i < blockSize; ++i) {
            const float x = buffer[i];

            // ── Acumular estadística de la ventana de análisis (sobre la
            //    señal de ENTRADA al supresor: ahí se ve el howl antes de
            //    filtrarlo). ──
            const float ax = std::fabs(x);
            winSumSq_ += x * x;
            if (ax > winPeak_) winPeak_ = ax;
            const int sign = (x > 0.0f) ? 1 : ((x < 0.0f) ? -1 : 0);
            if (sign != 0) {
                if (prevSign_ != 0 && sign != prevSign_) winZeroCross_++;
                prevSign_ = sign;
            }
            if (++winCount_ >= analysisWindow_) {
                analyzeWindow();
                winCount_ = 0;
                winSumSq_ = 0.0f;
                winPeak_ = 0.0f;
                winZeroCross_ = 0;
            }

            // ── Aplicar los notch activos (cascada) ──
            float y = x;
            for (int n = 0; n < kMaxNotches; ++n) {
                Notch& nf = notches_[n];
                // Rampa de profundidad (mezcla seca/húmeda) hacia el target.
                nf.depth += depthRampCoeff_ * (nf.depthTarget - nf.depth);
                if (nf.depth > 1e-4f) {
                    const float filtered = nf.processSample(y);
                    // Mezcla: depth=1 → notch pleno; depth=0 → seca.
                    // El notch ya aplica -|depthDb|; combinamos con la rampa.
                    y = y + nf.depth * (filtered - y);
                } else {
                    // Inactivo: mantener el biquad "tibio" sin teñir la señal.
                    nf.processSample(y);
                }
            }
            (void)depth; // depth se usa al recomputar coeficientes del notch.

            // ── Guard de banda ancha (respaldo) ──
            guardGain_ += guardRecoverCoeff_ * (guardTarget_ - guardGain_);
            y *= guardGain_;

            buffer[i] = y;
        }

        currentGuardGain_.store(guardGain_, std::memory_order_relaxed);
    }

    /// Habilita/deshabilita el supresor (thread-safe). Default: ON.
    void setEnabled(bool enabled) {
        enabled_.store(enabled, std::memory_order_relaxed);
    }
    bool isEnabled() const {
        return enabled_.load(std::memory_order_relaxed);
    }

    /// Profundidad de cada notch en dB (negativo). Default: -18 dB.
    /// Rango: -6 (suave) a -30 (agresivo).
    void setDepthDb(float db) {
        if (db > 0.0f) db = 0.0f;
        if (db < -30.0f) db = -30.0f;
        depthDb_.store(db, std::memory_order_relaxed);
        recomputeDepthLinear();
    }
    float getDepthDb() const {
        return depthDb_.load(std::memory_order_relaxed);
    }

    // --- Diagnóstico (lectura desde hilo de UI) ---

    /// Cantidad de notches actualmente activos (0..kMaxNotches).
    int getActiveNotchCount() const {
        return activeNotchCount_.load(std::memory_order_relaxed);
    }
    /// Ganancia actual del guard de banda ancha (1.0 = sin recorte).
    float getGuardGain() const {
        return currentGuardGain_.load(std::memory_order_relaxed);
    }

private:
    /// Filtro notch (peaking EQ de ganancia negativa, RBJ cookbook).
    /// Direct Form II Transposed. depthDb fija la profundidad del valle.
    struct Notch {
        // Coeficientes (a0 normalizado).
        float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f, a1 = 0.0f, a2 = 0.0f;
        // Estado del biquad.
        float z1 = 0.0f, z2 = 0.0f;
        // Frecuencia central actual (Hz). 0 = libre.
        float freq = 0.0f;
        // Mezcla seca/húmeda actual y objetivo (rampa anti-click).
        float depth = 0.0f;
        float depthTarget = 0.0f;
        // Ventanas restantes antes de liberar el notch.
        int holdWindows = 0;

        void reset() {
            b0 = 1.0f; b1 = b2 = a1 = a2 = 0.0f;
            z1 = z2 = 0.0f;
            freq = 0.0f;
            depth = depthTarget = 0.0f;
            holdWindows = 0;
        }

        inline float processSample(float x) {
            const float y = b0 * x + z1;
            z1 = b1 * x - a1 * y + z2;
            z2 = b2 * x - a2 * y;
            return y;
        }

        /// Recalcula coeficientes para un peaking-EQ de ganancia negativa.
        /// @param f0 Frecuencia central (Hz)
        /// @param fs Sample rate (Hz)
        /// @param ampLinear A = 10^(depthDb/40) (≤ 1 para un valle)
        /// @param q Factor de calidad (ancho del valle)
        void setCoeffs(float f0, float fs, float ampLinear, float q) {
            const float w0 = 2.0f * static_cast<float>(M_PI) * f0 / fs;
            const float cosw0 = std::cos(w0);
            const float sinw0 = std::sin(w0);
            const float alpha = sinw0 / (2.0f * q);
            const float A = ampLinear;
            const float a0 = 1.0f + alpha / A;
            b0 = (1.0f + alpha * A) / a0;
            b1 = (-2.0f * cosw0) / a0;
            b2 = (1.0f - alpha * A) / a0;
            a1 = (-2.0f * cosw0) / a0;
            a2 = (1.0f - alpha / A) / a0;
        }
    };

    /// Analiza la ventana recién completada y actualiza el estado del detector,
    /// los notch y el guard. Se llama cada `analysisWindow_` muestras.
    void analyzeWindow() {
        const float n = static_cast<float>(analysisWindow_);
        const float rms = std::sqrt(winSumSq_ / n);
        const float peak = winPeak_;

        // Crest factor: peak / rms. Sinusoide pura ≈ 1.414; voz/ruido ≫.
        const float crest = (rms > 1e-6f) ? (peak / rms) : 99.0f;

        // Frecuencia dominante estimada por zero-crossings (válida cuando la
        // señal es cuasi-sinusoidal, que es el caso durante el howl).
        const float freq = static_cast<float>(winZeroCross_) *
                           static_cast<float>(sampleRate_) / (2.0f * n);

        // ¿Esta ventana es "tonal y fuerte" (candidata a howl)?
        const bool tonal = (crest < kCrestThresh) &&
                           (rms > kMinRmsForHowl) &&
                           (freq > kMinHowlFreq) && (freq < kMaxHowlFreq);

        // Persistencia: contamos ventanas tonales+fuertes consecutivas. NO la
        // reiniciamos si la frecuencia salta: un howl real "salta" de modo
        // dentro de la banda con ganancia alta, y queremos que el guard siga
        // enganchado aunque el pitido se mude de frecuencia.
        if (tonal) {
            tonalRunWindows_++;
        } else {
            tonalRunWindows_ = 0;
        }

        // ¿Howl confirmado? → notch en la frecuencia actual + duck progresivo.
        const bool howlConfirmed = (tonalRunWindows_ >= persistWindows_);
        if (howlConfirmed) {
            engageNotch(freq);
            guardClearWindows_ = 0;
            // Duck progresivo del guard: baja un paso por ventana hasta el piso.
            // Garantiza romper el lazo aunque el margen sea grande o el howl
            // salte entre frecuencias (los notch angostos no bastan solos).
            guardTarget_ = std::max(kGuardFloorLinear, guardTarget_ * kGuardStepDown);
        } else {
            // Sin howl: tras un retardo, recuperar la ganancia gradualmente.
            guardClearWindows_++;
            if (guardClearWindows_ >= guardRecoverDelayWindows_ &&
                guardTarget_ < 1.0f) {
                guardTarget_ = std::min(1.0f, guardTarget_ + kGuardRecoverStep);
            }
        }

        // Envejecer los notch: decrementar hold; liberar el que llegó a 0.
        int active = 0;
        for (int i = 0; i < kMaxNotches; ++i) {
            Notch& nf = notches_[i];
            if (nf.depthTarget > 0.0f) {
                if (nf.holdWindows > 0) {
                    nf.holdWindows--;
                } else {
                    nf.depthTarget = 0.0f; // iniciar release (rampa lo baja)
                }
                active++;
            } else if (nf.depth > 1e-4f) {
                active++; // todavía rampando hacia 0
            }
        }
        activeNotchCount_.store(active, std::memory_order_relaxed);
    }

    /// Coloca o refresca un notch en la frecuencia `freq`.
    void engageNotch(float freq) {
        const float A = depthAmpLinear_; // 10^(depthDb/40)

        // 1) ¿Hay un notch ya cerca de esta frecuencia? → refrescar su hold.
        for (int i = 0; i < kMaxNotches; ++i) {
            Notch& nf = notches_[i];
            if (nf.depthTarget > 0.0f && nf.freq > 0.0f &&
                std::fabs(freq - nf.freq) <= kFreqTolerance * nf.freq) {
                nf.holdWindows = notchHoldWindows_;
                return;
            }
        }

        // 2) Buscar un slot libre (depthTarget==0 y depth≈0).
        for (int i = 0; i < kMaxNotches; ++i) {
            Notch& nf = notches_[i];
            if (nf.depthTarget <= 0.0f && nf.depth < 1e-4f) {
                nf.z1 = nf.z2 = 0.0f; // reset de estado (coeffs nuevos)
                nf.freq = freq;
                nf.setCoeffs(freq, static_cast<float>(sampleRate_), A, kNotchQ);
                nf.depthTarget = 1.0f;
                nf.holdWindows = notchHoldWindows_;
                return;
            }
        }

        // 3) Sin slots: robar el de menor hold restante (el más "viejo").
        int victim = 0;
        int minHold = notches_[0].holdWindows;
        for (int i = 1; i < kMaxNotches; ++i) {
            if (notches_[i].holdWindows < minHold) {
                minHold = notches_[i].holdWindows;
                victim = i;
            }
        }
        Notch& nf = notches_[victim];
        nf.z1 = nf.z2 = 0.0f;
        nf.freq = freq;
        nf.setCoeffs(freq, static_cast<float>(sampleRate_), A, kNotchQ);
        nf.depthTarget = 1.0f;
        nf.holdWindows = notchHoldWindows_;
    }

    void recomputeDepthLinear() {
        const float db = depthDb_.load(std::memory_order_relaxed);
        // A = 10^(dB/40) para peaking EQ (ganancia de pico/valle = A^2 = 10^(dB/20)).
        depthAmpLinear_ = std::pow(10.0f, db / 40.0f);
        // depthLinear_ se mantiene por compat de lectura; el efecto real lo
        // fija depthAmpLinear_ en los coeficientes del notch.
        depthLinear_.store(std::pow(10.0f, db / 20.0f), std::memory_order_relaxed);
    }

    // --- Parámetros de detección (constantes de diseño) ---
    static constexpr float kCrestThresh = 1.9f;     ///< crest < esto ⇒ tonal (sine ≈ 1.414)
    static constexpr float kMinRmsForHowl = 0.02f;  ///< ≈ -34 dBFS: el howl es fuerte
    static constexpr float kMinHowlFreq = 800.0f;   ///< Hz: feedback suele ser agudo
    static constexpr float kMaxHowlFreq = 7000.0f;  ///< Hz
    static constexpr float kFreqTolerance = 0.06f;  ///< ±6 % para "misma" frecuencia
    static constexpr float kNotchQ = 12.0f;         ///< Q moderado: cubre varios modos del howl
    static constexpr float kGuardStepDown = 0.85f;  ///< factor de duck del guard por ventana
    static constexpr float kGuardRecoverStep = 0.003f; ///< recuperación LENTA (paso fijo/ventana)
    static constexpr float kGuardFloorLinear = 0.0631f; ///< piso del guard ≈ -24 dB

    // --- Configuración del sistema ---
    int sampleRate_ = 16000;
    int analysisWindow_ = 256;
    int persistWindows_ = 6;
    int notchHoldWindows_ = 90;
    int guardRecoverDelayWindows_ = 30;
    float guardRecoverCoeff_ = 0.0f;
    float depthRampCoeff_ = 0.0f;
    float depthAmpLinear_ = 0.354813f; // 10^(-18/40)

    // --- Estado del detector (audio thread) ---
    int winCount_ = 0;
    float winSumSq_ = 0.0f;
    float winPeak_ = 0.0f;
    int winZeroCross_ = 0;
    int prevSign_ = 0;
    int tonalRunWindows_ = 0;
    int guardClearWindows_ = 0;

    // --- Guard de banda ancha (audio thread) ---
    float guardGain_ = 1.0f;
    float guardTarget_ = 1.0f;

    // --- Notches (audio thread) ---
    Notch notches_[kMaxNotches];

    // --- Parámetros atómicos (UI thread settable) ---
    std::atomic<bool> enabled_{true};
    std::atomic<float> depthDb_{-18.0f};
    std::atomic<float> depthLinear_{0.125893f}; // 10^(-18/20)

    // --- Diagnóstico (UI thread readable) ---
    std::atomic<int> activeNotchCount_{0};
    std::atomic<float> currentGuardGain_{1.0f};
};

#endif // HEARING_AID_FEEDBACK_SUPPRESSOR_H

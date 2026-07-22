/// @file dnn_denoiser.cpp
/// @brief Implementación del wrapper GTCRN DNN denoiser (OnnxRuntime).
///
/// Diseño dataflow estilo LabVIEW (ver `dnn_denoiser.h` para la doc del SubVI).
///
/// Pipeline interno:
///
///   ┌───────────────┐        ┌───────────────┐        ┌─────────────┐
///   │ audio thread  │  push  │  inputRing    │  pop   │   worker    │
///   │  process()    │──────▶ │ (SPSC float)  │──────▶ │   thread    │
///   └───────────────┘        └───────────────┘        └─────┬───────┘
///        │                                                   │
///        │  (parallel: also pushes to dryDelayRing_)          ▼
///        ▼                                              STFT(320,Hann)
///   ┌───────────────┐                                        │
///   │ dryDelayRing_ │◀───────── time-aligned delay           ▼
///   │ (SPSC float)  │                                  ONNX session.Run()
///   └───────┬───────┘                                        │
///           │                                                ▼
///           │                                          iSTFT (OLA)
///           │                                                │
///           │             ┌───────────────┐                 │
///           └────────────▶│  outputRing   │◀────────────────┘
///                         │ (SPSC float)  │
///                         └──────┬────────┘
///                                │
///                                ▼
///                       audio thread pop + crossfade + intensity mix
///
/// Lock-free: audio thread NUNCA bloquea. Worker bloquea con CV cuando
/// no hay datos suficientes.

#include "dnn_denoiser.h"

#include "onnxruntime/onnxruntime_cxx_api.h"

// WPE Beamformer (header-only) for dual-channel spatial filtering.
// Operates on frequency-domain complex spectra. Used in processDualFrame()
// to combine 2ch STFT spectra into 1ch enhanced spectrum before ONNX inference.
#include "../wpe_beamformer.h"

#include <android/asset_manager.h>
#include <android/log.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

#define DNN_LOG_TAG "DnnDenoiser"
#define DNN_LOGI(...) __android_log_print(ANDROID_LOG_INFO,  DNN_LOG_TAG, __VA_ARGS__)
#define DNN_LOGW(...) __android_log_print(ANDROID_LOG_WARN,  DNN_LOG_TAG, __VA_ARGS__)
#define DNN_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, DNN_LOG_TAG, __VA_ARGS__)

namespace dnn_denoiser {

namespace {

constexpr float kPi = 3.14159265358979323846f;

// ─────────────────────────────────────────────────────────────────────────────
// SPSC ring buffer (single-producer, single-consumer, lock-free)
// ─────────────────────────────────────────────────────────────────────────────

/// Ring buffer SPSC para floats. Tamaño debe ser potencia de 2.
/// Productor (push) y consumidor (pop) están en hilos distintos.
/// No bloqueante en ambas direcciones (devuelve cuántos samples copió).
class SpscRing {
public:
    void init(int capacity) {
        capacity_ = capacity;
        mask_ = capacity - 1;
        buf_.assign(capacity, 0.0f);
        head_.store(0, std::memory_order_relaxed);
        tail_.store(0, std::memory_order_relaxed);
    }

    /// Espacio libre actual (visto por el productor).
    int freeSpace() const {
        const int head = head_.load(std::memory_order_relaxed);
        const int tail = tail_.load(std::memory_order_acquire);
        return capacity_ - (head - tail);
    }

    /// Samples disponibles (visto por el consumidor).
    int available() const {
        const int head = head_.load(std::memory_order_acquire);
        const int tail = tail_.load(std::memory_order_relaxed);
        return head - tail;
    }

    /// Productor: empuja hasta `n` samples. Devuelve cuántos efectivamente entraron.
    int push(const float* src, int n) {
        const int head = head_.load(std::memory_order_relaxed);
        const int tail = tail_.load(std::memory_order_acquire);
        const int free = capacity_ - (head - tail);
        const int toPush = std::min(n, free);
        for (int i = 0; i < toPush; ++i) {
            buf_[(head + i) & mask_] = src[i];
        }
        head_.store(head + toPush, std::memory_order_release);
        return toPush;
    }

    /// Consumidor: tira hasta `n` samples. Devuelve cuántos efectivamente leyó.
    int pop(float* dst, int n) {
        const int tail = tail_.load(std::memory_order_relaxed);
        const int head = head_.load(std::memory_order_acquire);
        const int avail = head - tail;
        const int toPop = std::min(n, avail);
        for (int i = 0; i < toPop; ++i) {
            dst[i] = buf_[(tail + i) & mask_];
        }
        tail_.store(tail + toPop, std::memory_order_release);
        return toPop;
    }

    /// Vacía completamente el buffer (desde el consumidor).
    /// SAFE solo cuando se sabe que el productor no está empujando.
    void clear() {
        tail_.store(head_.load(std::memory_order_acquire),
                    std::memory_order_release);
    }

private:
    std::vector<float>  buf_;
    int                 capacity_ = 0;
    int                 mask_     = 0;
    std::atomic<int>    head_{0};
    std::atomic<int>    tail_{0};
};

// ─────────────────────────────────────────────────────────────────────────────
// Real-signal DFT twiddle factors are precomputed in Impl (see twiddleRe/Im).
// The naive cos/sin-per-sample approach was removed because it accumulated
// floating-point precision errors with large angles, producing metallic
// artifacts ("matraca") that increased with intensity.
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// FFT radix-2 (in-place complex) - kept for WPE beamformer or other uses
// ─────────────────────────────────────────────────────────────────────────────

/// FFT in-place compleja, decimacion-en-tiempo, radix-2.
/// re/im: arrays de longitud N (potencia de 2).
/// Si invert=true -> IFFT (escala por 1/N al final).
/// NOTE: Not used for the DNN STFT path (which uses dftForward/dftInverse
/// with precomputed twiddle factors for N=320). Kept for potential use by
/// other modules that need power-of-2 FFT.
inline void fftRadix2(float* re, float* im, int N, bool invert) {
    // Bit-reversal permutation.
    int j = 0;
    for (int i = 1; i < N; ++i) {
        int bit = N >> 1;
        for (; j & bit; bit >>= 1) {
            j ^= bit;
        }
        j ^= bit;
        if (i < j) {
            std::swap(re[i], re[j]);
            std::swap(im[i], im[j]);
        }
    }

    // Cooley-Tukey butterflies.
    for (int len = 2; len <= N; len <<= 1) {
        const float ang = (invert ? 2.0f : -2.0f) * kPi / static_cast<float>(len);
        const float wReStep = std::cos(ang);
        const float wImStep = std::sin(ang);
        for (int i = 0; i < N; i += len) {
            float wRe = 1.0f;
            float wIm = 0.0f;
            const int half = len / 2;
            for (int k = 0; k < half; ++k) {
                const float xRe = re[i + k];
                const float xIm = im[i + k];
                const float yRe = re[i + k + half] * wRe - im[i + k + half] * wIm;
                const float yIm = re[i + k + half] * wIm + im[i + k + half] * wRe;
                re[i + k]        = xRe + yRe;
                im[i + k]        = xIm + yIm;
                re[i + k + half] = xRe - yRe;
                im[i + k + half] = xIm - yIm;
                const float nwRe = wRe * wReStep - wIm * wImStep;
                const float nwIm = wRe * wImStep + wIm * wReStep;
                wRe = nwRe;
                wIm = nwIm;
            }
        }
    }

    if (invert) {
        const float inv = 1.0f / static_cast<float>(N);
        for (int i = 0; i < N; ++i) {
            re[i] *= inv;
            im[i] *= inv;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers para describir/inspeccionar tensores ONNX.
// ─────────────────────────────────────────────────────────────────────────────

/// Calcula el número de elementos de un shape (todas las dims producto).
int64_t shapeNumel(const std::vector<int64_t>& shape) {
    int64_t n = 1;
    for (int64_t d : shape) {
        if (d <= 0) return 0;  // dim dinámica → no podemos pre-allocar
        n *= d;
    }
    return n;
}

// ─────────────────────────────────────────────────────────────────────────────
// SubVI LabVIEW — Resampler 48↔16 (polyphase / lineal)
// ─────────────────────────────────────────────────────────────────────────────
//
// CONTROLES (configuración):
//   ├─ inputRate (int Hz)         — sample rate de la señal de entrada
//   ├─ outputRate (int Hz)        — sample rate deseado a la salida
//   └─ mode (auto-detect)         — Identity | Poly48to16 | Poly16to48 | Linear
//
// ENTRADAS (signal wires):
//   └─ in[]  (float, n samples a inputRate)
//
// PROCESAMIENTO:
//   - Identity (in==out): memcpy passthrough.
//   - Poly48to16 (M=3, 72 taps): downsample con FIR Kaiser β=8.5, fc=7.5 kHz.
//   - Poly16to48 (L=3, 72 taps prototipo, 24 por fase): upsample.
//   - Linear (cualquier otro ratio): interpolación lineal stateful con
//     fracción acumulada (suficiente para denoising, no para audio crítico).
//
// SALIDAS:
//   ├─ out[] (float, k samples a outputRate)
//   └─ k     (cantidad real escrita; varía por sample para conservar estado)
//
// INDICADORES (debug):
//   ├─ groupDelaySamples (float)  — latencia introducida en samples a outputRate
//   └─ groupDelayMs (float)       — latencia en ms
//
// ESTADO:
//   - delay line interna (72 floats para polyphase / 1 float para lineal)
//   - phase counter para polyphase
//   - fracción acumulada para lineal
//
// THREAD-SAFETY: sólo se accede desde el audio thread. setInputSampleRate
// (que llama a init/reset) se invoca desde el hilo de control ANTES de que
// arranque el audio callback. No hay locking interno.
//
// LATENCIA:
//   - MEJORA #3 (ruido-profundo.md): polyphase 72 taps Kaiser β=8.5 (antes 96 β=8).
//   - Polyphase 72 taps: group delay = (72-1)/2 = 35.5 samples.
//     A 48 kHz → ~0.74 ms. Round-trip (down + up) ≈ 1.48 ms (antes 1.98 ms).
//   - Lineal: ~0 muestras (fase acumulada).
class Resampler {
public:
    enum class Mode {
        kIdentity,        // ratio 1:1, memcpy puro
        kPolyDown48to16,  // FIR polyphase con M=3
        kPolyUp16to48,    // FIR polyphase con L=3
        kLinearGeneric    // lineal stateful (otras rates)
    };

    /// Configura el resampler. Idempotente: si la configuración no cambió
    /// respecto al último init, no resetea el estado.
    void configure(Mode mode, const float* proto, int protoN, float linearRatio) {
        const bool same = (mode == mode_) &&
                          (mode != Mode::kLinearGeneric || linearRatio == linearRatio_);
        if (same && initialized_) return;

        mode_ = mode;

        switch (mode) {
            case Mode::kIdentity:
                delay_.clear();
                phase_ = 0;
                writeIdx_ = 0;
                groupDelaySamples_ = 0.0f;
                break;

            case Mode::kPolyDown48to16:
                proto_.assign(proto, proto + protoN);
                protoN_ = protoN;
                delay_.assign(protoN, 0.0f);
                phase_ = 0;
                writeIdx_ = 0;
                // Group delay del prototipo simétrico: (N-1)/2 samples a 48 kHz.
                // Salida a 16 kHz: equivalente a (N-1)/2 / 3 samples a 16 kHz,
                // pero medido en tiempo es (N-1)/2 / 48000 segundos.
                groupDelaySamples_ = static_cast<float>(protoN - 1) / 2.0f;
                break;

            case Mode::kPolyUp16to48: {
                // Splittear el prototipo en L=3 polyphase components,
                // cada una de N/L = 32 taps. Multiplicar por L para
                // compensar la inserción de ceros.
                constexpr int kL = 3;
                phaseTaps_ = protoN / kL;  // 32
                phases_.assign(kL, std::vector<float>(phaseTaps_, 0.0f));
                for (int n = 0; n < phaseTaps_; ++n) {
                    for (int k = 0; k < kL; ++k) {
                        const int idx = n * kL + k;
                        if (idx < protoN) {
                            phases_[k][n] = proto[idx] * static_cast<float>(kL);
                        }
                    }
                }
                delay_.assign(phaseTaps_, 0.0f);
                writeIdx_ = 0;
                groupDelaySamples_ = static_cast<float>(protoN - 1) / 2.0f;
                break;
            }

            case Mode::kLinearGeneric:
                linearRatio_ = linearRatio;
                linearAccum_ = 0.0f;
                linearLast_  = 0.0f;
                groupDelaySamples_ = 0.0f;
                break;
        }
        initialized_ = true;
    }

    /// Limpia el estado interno (delay-lines, fase, fracción) sin reconfigurar.
    void reset() {
        std::fill(delay_.begin(), delay_.end(), 0.0f);
        phase_ = 0;
        writeIdx_ = 0;
        linearAccum_ = 0.0f;
        linearLast_  = 0.0f;
    }

    /// Procesa `n` samples de entrada. Escribe hasta `outMax` samples de
    /// salida. Devuelve cuántos samples efectivamente escribió.
    int process(const float* in, int n, float* out, int outMax) {
        if (n <= 0 || outMax <= 0) return 0;
        switch (mode_) {
            case Mode::kIdentity:        return processIdentity(in, n, out, outMax);
            case Mode::kPolyDown48to16:  return processPolyDown(in, n, out, outMax);
            case Mode::kPolyUp16to48:    return processPolyUp(in, n, out, outMax);
            case Mode::kLinearGeneric:   return processLinear(in, n, out, outMax);
        }
        return 0;
    }

    /// Latencia introducida (group delay) en samples a la rate de salida.
    float groupDelaySamples() const { return groupDelaySamples_; }

    /// Latencia introducida en milisegundos, dado el output rate.
    float groupDelayMs(int outputRateHz) const {
        if (outputRateHz <= 0) return 0.0f;
        return groupDelaySamples_ * 1000.0f / static_cast<float>(outputRateHz);
    }

private:
    int processIdentity(const float* in, int n, float* out, int outMax) {
        const int k = std::min(n, outMax);
        std::memcpy(out, in, k * sizeof(float));
        return k;
    }

    int processPolyDown(const float* in, int n, float* out, int outMax) {
        // M=3 decimación. Para cada input: escribe en delay line; cada M-ésimo
        // input genera un output como producto interno de proto * delay.
        constexpr int kM = 3;
        const int N = protoN_;
        int written = 0;
        for (int i = 0; i < n; ++i) {
            delay_[writeIdx_] = in[i];
            writeIdx_ = (writeIdx_ + 1) % N;
            ++phase_;
            if (phase_ == kM) {
                phase_ = 0;
                if (written < outMax) {
                    // y = sum_{k=0..N-1} proto[k] * delay[ writeIdx_ - 1 - k ]
                    float acc = 0.0f;
                    int idx = writeIdx_ - 1;
                    if (idx < 0) idx += N;
                    for (int k = 0; k < N; ++k) {
                        acc += proto_[k] * delay_[idx];
                        idx = (idx == 0) ? (N - 1) : (idx - 1);
                    }
                    out[written++] = acc;
                }
            }
        }
        return written;
    }

    int processPolyUp(const float* in, int n, float* out, int outMax) {
        // L=3 interpolación. Cada input genera L outputs vía polyphase.
        // El phase counter (phase_) se preserva entre llamadas para que un
        // outMax pequeño no descarte fases pendientes.
        constexpr int kL = 3;
        int written = 0;
        int consumed = 0;

        // Si quedan fases pendientes del input anterior, drenarlas primero.
        while (phase_ > 0 && phase_ < kL && written < outMax) {
            float acc = 0.0f;
            int idx = writeIdx_ - 1;
            if (idx < 0) idx += phaseTaps_;
            const auto& ph = phases_[phase_];
            for (int t = 0; t < phaseTaps_; ++t) {
                acc += ph[t] * delay_[idx];
                idx = (idx == 0) ? (phaseTaps_ - 1) : (idx - 1);
            }
            out[written++] = acc;
            ++phase_;
        }
        if (phase_ >= kL) phase_ = 0;

        while (consumed < n && written < outMax) {
            delay_[writeIdx_] = in[consumed++];
            writeIdx_ = (writeIdx_ + 1) % phaseTaps_;
            phase_ = 0;
            while (phase_ < kL && written < outMax) {
                float acc = 0.0f;
                int idx = writeIdx_ - 1;
                if (idx < 0) idx += phaseTaps_;
                const auto& ph = phases_[phase_];
                for (int t = 0; t < phaseTaps_; ++t) {
                    acc += ph[t] * delay_[idx];
                    idx = (idx == 0) ? (phaseTaps_ - 1) : (idx - 1);
                }
                out[written++] = acc;
                ++phase_;
            }
            if (phase_ >= kL) phase_ = 0;
        }
        return written;
    }

    int processLinear(const float* in, int n, float* out, int outMax) {
        // Interpolación lineal con fracción acumulada.
        // ratio = inputRate / outputRate (ej. 44100/16000 = 2.756).
        // Para cada output, posición de input = outIdx * ratio.
        // Mantenemos linearAccum_ como índice fraccional (en samples de input)
        // relativo al sample de input "next" que aún no consumimos.
        int written = 0;
        int consumed = 0;  // samples del input ya pasados.
        // linearAccum_ ∈ [0, 1) — fracción dentro del intervalo [last, in[0]].
        while (written < outMax) {
            // Necesitamos avanzar input mientras linearAccum_ >= 1.0
            while (linearAccum_ >= 1.0f) {
                if (consumed >= n) {
                    // Sin más entrada: terminamos este batch.
                    return written;
                }
                linearLast_ = in[consumed++];
                linearAccum_ -= 1.0f;
            }
            // Output: linealmente entre linearLast_ y in[consumed] (next).
            const float next = (consumed < n) ? in[consumed]
                                              : linearLast_;  // hold tail
            const float frac = linearAccum_;
            out[written++] = linearLast_ * (1.0f - frac) + next * frac;
            linearAccum_ += linearRatio_;
        }
        return written;
    }

    Mode mode_ = Mode::kIdentity;
    bool initialized_ = false;

    // Polyphase state.
    std::vector<float>              proto_;       // prototipo (down)
    int                             protoN_ = 0;
    std::vector<std::vector<float>> phases_;      // L sub-filtros (up)
    int                             phaseTaps_ = 0;
    std::vector<float>              delay_;
    int                             writeIdx_ = 0;
    int                             phase_    = 0;

    // Linear state.
    float linearRatio_ = 1.0f;   // inputRate / outputRate
    float linearAccum_ = 0.0f;
    float linearLast_  = 0.0f;

    // Indicators.
    float groupDelaySamples_ = 0.0f;
};

/// Diseño del prototipo LPF para resampler polyphase 48↔16.
///   - 72 taps (24 por fase para L/M=3) — MEJORA #3 (ruido-profundo.md): bajado de 96 → 72.
///   - Cutoff fc = 7.5 kHz (midpoint del transition band 7-8 kHz)
///   - Ventana Kaiser β=8.5 — MEJORA #3: subido de β=8 a β=8.5 para mantener ~80 dB
///     stopband con menos taps. Group delay baja de 47.5 → 35.5 samples
///     (0.99 ms → 0.74 ms a 48 kHz). Round-trip down+up: 1.98 ms → 1.48 ms.
///   - Normalizado para DC gain = 1.0 (downsample). El interpolador
///     compensa la inserción de ceros multiplicando los polyphase por L.
///
/// Constantes de la mejora — declaradas explícitas para que la matemática del polyphase
/// (24 taps por fase = 72/3) quede documentada y validable.
inline constexpr int   kProtoTaps  = 72;     // 72/3 = 24 taps por fase, sin remainder
inline constexpr float kKaiserBeta = 8.5f;   // ~80 dB stopband con 72 taps
inline float besselI0Approx(float x) {
    // Abramowitz & Stegun 9.8.1 / 9.8.2 polynomial approximation.
    const float ax = std::fabs(x);
    if (ax < 3.75f) {
        const float y = (x / 3.75f) * (x / 3.75f);
        return 1.0f + y * (3.5156229f + y * (3.0899424f + y * (1.2067492f
            + y * (0.2659732f + y * (0.0360768f + y * 0.0045813f)))));
    }
    const float y = 3.75f / ax;
    return (std::exp(ax) / std::sqrt(ax)) *
        (0.39894228f + y * (0.01328592f + y * (0.00225319f
        + y * (-0.00157565f + y * (0.00916281f + y * (-0.02057706f
        + y * (0.02635537f + y * (-0.01647633f + y * 0.00392377f))))))));
}

inline void designResamplerProtoLpf(float* h, int N) {
    // fc normalizado respecto a 48 kHz: 7500/48000 = 0.15625
    // (cutoff en el midpoint de la banda de transición 7-8 kHz).
    const float fc = 7500.0f / 48000.0f;
    // MEJORA #3 (ruido-profundo.md): β=8.5 (antes 8.0) para mantener 80 dB stopband
    // con N=72 taps en vez de 96. Ver constexpr kKaiserBeta arriba.
    const float beta = kKaiserBeta;
    const float center = (N - 1) / 2.0f;
    const float i0Beta = besselI0Approx(beta);
    float sum = 0.0f;
    for (int n = 0; n < N; ++n) {
        // Ideal LPF (sinc):  h_ideal[n] = 2*fc * sinc(2*fc*(n - center))
        const float arg = 2.0f * fc * (static_cast<float>(n) - center);
        float ideal;
        if (std::fabs(arg) < 1e-9f) {
            ideal = 2.0f * fc;
        } else {
            const float px = kPi * arg;
            ideal = 2.0f * fc * std::sin(px) / px;
        }
        // Kaiser window.
        const float ratio = (2.0f * static_cast<float>(n) / (N - 1)) - 1.0f;
        const float winArg = beta * std::sqrt(std::max(0.0f, 1.0f - ratio * ratio));
        const float win = besselI0Approx(winArg) / i0Beta;
        h[n] = ideal * win;
        sum += h[n];
    }
    // Normalizar a unity DC gain.
    if (sum > 1e-12f) {
        for (int n = 0; n < N; ++n) h[n] /= sum;
    }
}

}  // namespace

// ─────────────────────────────────────────────────────────────────────────────
// PIMPL: Impl
// ─────────────────────────────────────────────────────────────────────────────

struct DnnDenoiser::Impl {
    // ─── ONNX Runtime ──────────────────────────────────────────────────
    Ort::Env                          env{ORT_LOGGING_LEVEL_WARNING, DNN_LOG_TAG};
    Ort::SessionOptions               sessionOpts;
    std::unique_ptr<Ort::Session>     session;
    Ort::MemoryInfo                   memInfo{Ort::MemoryInfo::CreateCpu(
                                          OrtArenaAllocator, OrtMemTypeDefault)};
    std::vector<std::string>          inputNames;
    std::vector<std::string>          outputNames;
    std::vector<const char*>          inputNameCStr;
    std::vector<const char*>          outputNameCStr;
    std::vector<std::vector<int64_t>> inputShapes;
    std::vector<std::vector<int64_t>> outputShapes;

    /// Modelo cargado y listo para inferencia.
    bool modelReady = false;

    // ─── Dual-channel ONNX + WPE Beamformer ──────────────────────────
    /// Canales de entrada del modelo activo (1 = mono ONNX, 2 = dual ONNX+WPE).
    /// Lo lee el worker para elegir la ruta de inferencia.
    std::atomic<int> channels{1};

    /// WPE beamformer instance for dual-channel spatial filtering.
    /// Operates on frequency-domain complex spectra, producing single-channel
    /// enhanced output that feeds into the ONNX GTCRN core.
    WpeBeamformer wpeBeamformer;

    /// STFT input buffer for channel 1 (dual-channel mode).
    /// Channel 0 reuses the existing stftInBuf.
    std::vector<float> stftInBufCh1;      // [kDnnFftSize]

    /// Workspace FFT arrays for channel 1 (dual-channel STFT).
    std::vector<float> fftReCh1;           // [kDnnFftSize]
    std::vector<float> fftImCh1;           // [kDnnFftSize]

    // ─── STFT state (worker thread only) ───────────────────────────────
    /// Ventana Hann de análisis y síntesis (root-Hann simétrica → COLA con hop=N/2).
    std::vector<float> hannWin;            // [kDnnFftSize]

    /// Buffer circular del STFT input: mantenemos los últimos kDnnFftSize samples,
    /// y desplazamos kDnnHopSize por frame.
    std::vector<float> stftInBuf;          // [kDnnFftSize]

    /// Buffer de overlap-add para reconstrucción del iSTFT.
    std::vector<float> olaBuf;             // [kDnnFftSize]

    /// Workspace para FFT (re/im).
    std::vector<float> fftRe;              // [kDnnFftSize]
    std::vector<float> fftIm;              // [kDnnFftSize]

    /// Workspace for windowed time-domain signal before DFT.
    std::vector<float> dftWorkBuf;         // [kDnnFftSize]

    /// Precomputed twiddle factors for the real DFT (forward and inverse).
    /// twiddleRe[k*N+n] = cos(-2*pi*k*n/N), twiddleIm[k*N+n] = sin(-2*pi*k*n/N)
    /// for k=0..nBins-1, n=0..N-1. Eliminates repeated cos/sin calls with large
    /// angles that caused floating-point precision drift ("matraca" artifact).
    std::vector<float> twiddleRe;          // [nBins * kDnnFftSize] = 161*320 = 51520
    std::vector<float> twiddleIm;          // [nBins * kDnnFftSize] = 161*320 = 51520

    /// Buffer staging del frame de salida ya finalizado (kDnnHopSize samples).
    std::vector<float> outputFrame;

    /// Tensor staging para el input "mix" del modelo.
    std::vector<float> mixTensorData;

    /// Caches recurrentes (uno por input cache). Se actualizan tras cada Run().
    std::vector<std::vector<float>>   caches;
    /// Índices (en inputNames/outputNames) que corresponden a las caches.
    /// La convención GTCRN es: input[0] = "mix", input[1..] = caches en orden;
    /// output[0] = "enh", output[1..] = nuevas caches en MISMO orden.
    int                               mixInputIdx  = -1;
    int                               enhOutputIdx = -1;
    std::vector<int>                  cacheInputIdx;   // posiciones en inputNames
    std::vector<int>                  cacheOutputIdx;  // posiciones en outputNames

    // ─── Ring buffers (audio ↔ worker) ─────────────────────────────────
    SpscRing inputRing;     ///< audio_thread → worker     (ch0 @ 16 kHz)
    SpscRing inputRingCh1;  ///< audio_thread → worker     (ch1 @ 16 kHz, solo dual)
    SpscRing outputRing;    ///< worker → audio_thread     (samples @ 16 kHz, enhanced)
    SpscRing dryDelayRing;  ///< audio_thread → audio_thread (dry alineada @ inputSr)

    // ─── Resampler 48↔16 (encapsulado, ver Resampler arriba) ───────────
    /// Sample rate de entrada/salida observado del audio engine.
    /// 0 = no configurado todavía → asumimos 16 kHz (bypass).
    int       inputSr = kDnnSampleRate;
    /// LPF prototipo precomputado. MEJORA #3 (ruido-profundo.md): 72 taps Kaiser β=8.5,
    /// fc=7.5 kHz (antes 96 taps β=8). Compartido entre downsampler y upsampler.
    std::vector<float> protoLpf;
    /// Down: inputSr → 16 kHz (audio thread input ch0 → inputRing).
    Resampler down;
    /// Down ch1: inputSr → 16 kHz (audio thread input ch1 → inputRingCh1).
    /// Idéntico a `down` pero con estado propio (delay-line independiente).
    /// Spec: gtcrn-dual-channel (tarea 2.3).
    Resampler downCh1;
    /// Up:   16 kHz → inputSr (outputRing → wet buffer en rate nativa).
    Resampler up;
    /// Buffer staging para los samples de ch0 a 16 kHz tras downsample.
    std::vector<float> downStaging;
    /// Buffer staging para los samples de ch1 a 16 kHz tras downsample (dual).
    std::vector<float> downStagingCh1;
    /// Buffer staging para los samples enhanced @ 16 kHz tirados del outputRing.
    std::vector<float> wet16k;
    /// Buffer staging para wet upsampleado a inputSr (mismo blockSize que input).
    std::vector<float> wetNativeRate;

    // ─── Worker thread ─────────────────────────────────────────────────
    std::thread             worker;
    std::atomic<bool>       workerRun{false};
    std::atomic<bool>       resetRequested{false};
    std::mutex              workerMtx;
    std::condition_variable workerCv;

    /// Pointer to the outer DnnDenoiser::voiceActive_ atomic.
    /// Set after construction via setVoiceActivePtr(). The worker loop reads
    /// this to pass the actual VAD state to the WPE beamformer.
    std::atomic<bool>* voiceActivePtr_ = nullptr;

    /// Contadores expuestos (también espejados en atomics públicos del wrapper).
    std::atomic<uint64_t>   processedFramesLocal{0};
    std::atomic<uint64_t>   droppedFramesLocal{0};
    std::atomic<uint32_t>   lastInferenceUsLocal{0};

    // ─── Noise gate con hysteresis (FIX tktktk Causa 2) ──────────────────
    /// Ganancia actual del noise gate [0..1]. Rampea suavemente entre abierto
    /// (1.0) y cerrado (0.0) para evitar clicks por conmutación rápida.
    float gateGain_ = 1.0f;
    /// Contador de frames consecutivos por debajo del umbral de cierre.
    /// El gate solo cierra después de kHystFrames consecutivos (~60 ms).
    int   gateHoldCounter_ = 0;

    Impl() {
        sessionOpts.SetIntraOpNumThreads(1);
        sessionOpts.SetInterOpNumThreads(1);
        sessionOpts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);

        hannWin.assign(kDnnFftSize, 0.0f);
        stftInBuf.assign(kDnnFftSize, 0.0f);
        olaBuf.assign(kDnnFftSize, 0.0f);
        fftRe.assign(kDnnFftSize, 0.0f);
        fftIm.assign(kDnnFftSize, 0.0f);
        dftWorkBuf.assign(kDnnFftSize, 0.0f);
        outputFrame.assign(kDnnHopSize, 0.0f);

        // Precompute twiddle factors for the DFT (forward/inverse).
        // twiddleRe[k*N+n] = cos(-2*pi*k*n/N)
        // twiddleIm[k*N+n] = sin(-2*pi*k*n/N)
        // for k=0..nBins-1 (161), n=0..N-1 (320).
        {
            constexpr int N = kDnnFftSize;
            constexpr int nBins = N / 2 + 1;
            twiddleRe.resize(nBins * N);
            twiddleIm.resize(nBins * N);
            for (int k = 0; k < nBins; ++k) {
                for (int n = 0; n < N; ++n) {
                    const double angle = -2.0 * static_cast<double>(kPi)
                                         * static_cast<double>(k)
                                         * static_cast<double>(n)
                                         / static_cast<double>(N);
                    twiddleRe[k * N + n] = static_cast<float>(std::cos(angle));
                    twiddleIm[k * N + n] = static_cast<float>(std::sin(angle));
                }
            }
        }

        // Vorbis window (DPDFNet8 training convention).
        // DPDFNet8 fue entrenado con ventana Vorbis (sherpa-onnx MakeVorbisWindow).
        // Fórmula: w[n] = sin(π/2 · sin²(π·n/N))
        // Cumple COLA con hop = N/2 (50% overlap): sum(w²) = 1.
        for (int i = 0; i < kDnnFftSize; ++i) {
            const float sinArg = kPi * static_cast<float>(i) / static_cast<float>(kDnnFftSize);
            const float sinSq = std::sin(sinArg) * std::sin(sinArg);
            hannWin[i] = std::sin(kPi * 0.5f * sinSq);
        }

        inputRing.init(kDnnRingCapacity);
        inputRingCh1.init(kDnnRingCapacity);
        outputRing.init(kDnnRingCapacity);
        dryDelayRing.init(kDnnRingCapacity);

        // Pre-fill dryDelayRing with zeros to compensate for the latency
        // of the wet path. Valor exacto para 16 kHz (sin resampler):
        // 1 hop STFT buffering = kDnnHopSize = 160 samples = 10 ms.
        // Se recalcula en applyInputSampleRate() para la rate real de Oboe.
        {
            constexpr int kInitialPreFill = kDnnHopSize; // 160 @ 16k = 10 ms
            std::vector<float> zeros(kInitialPreFill, 0.0f);
            dryDelayRing.push(zeros.data(), kInitialPreFill);
        }

        // ── Resampler: prototipo Kaiser y modo identidad por default ──
        // El verdadero modo se activa cuando AudioEngine llama
        // setInputSampleRate(48000). Hasta entonces asumimos 16 kHz
        // (passthrough bit-exact).
        // MEJORA #3 (ruido-profundo.md): 72 taps (24 por fase) Kaiser β=8.5
        // — group delay 35.5 samples (0.74 ms @ 48 kHz). Antes: 96 taps β=8.
        protoLpf.assign(kProtoTaps, 0.0f);
        designResamplerProtoLpf(protoLpf.data(), kProtoTaps);
        down.configure(Resampler::Mode::kIdentity, nullptr, 0, 1.0f);
        downCh1.configure(Resampler::Mode::kIdentity, nullptr, 0, 1.0f);
        up.configure(Resampler::Mode::kIdentity, nullptr, 0, 1.0f);
        // Staging buffers: dimensionar generoso para blockSize típico de Oboe.
        // Oboe suele dar burst de 96-192 frames @ 48 kHz; con M=3 → ~64 a 16 kHz.
        // Reservamos 1024 para absorber bursts más grandes sin reasignar.
        downStaging.assign(1024, 0.0f);
        downStagingCh1.assign(1024, 0.0f);
        wet16k.assign(1024, 0.0f);
        wetNativeRate.assign(2048, 0.0f);

        // Dual-channel: STFT buffers for ch1 and WPE beamformer reset.
        stftInBufCh1.assign(kDnnFftSize, 0.0f);
        fftReCh1.assign(kDnnFftSize, 0.0f);
        fftImCh1.assign(kDnnFftSize, 0.0f);
        wpeBeamformer.reset();
    }

    ~Impl() {
        stopWorker();
    }

    /// Lee el modelo desde assets a un buffer en RAM (síncrono).
    /// Retorna vector vacío en caso de fallo.
    std::vector<uint8_t> readAsset(AAssetManager* mgr, const char* assetPath) {
        std::vector<uint8_t> data;
        if (mgr == nullptr || assetPath == nullptr) {
            DNN_LOGE("readAsset: AAssetManager or path is null");
            return data;
        }
        AAsset* asset = AAssetManager_open(mgr, assetPath, AASSET_MODE_BUFFER);
        if (asset == nullptr) {
            DNN_LOGE("readAsset: cannot open asset %s", assetPath);
            return data;
        }
        const off_t sz = AAsset_getLength(asset);
        if (sz <= 0) {
            DNN_LOGE("readAsset: asset %s has invalid size %ld", assetPath, (long)sz);
            AAsset_close(asset);
            return data;
        }
        data.resize(static_cast<size_t>(sz));
        const int read = AAsset_read(asset, data.data(), data.size());
        AAsset_close(asset);
        if (read != static_cast<int>(data.size())) {
            DNN_LOGE("readAsset: read %d bytes, expected %zu", read, data.size());
            data.clear();
        }
        return data;
    }

    /// Loads the dual-channel ONNX model (gtcrn_dual_core.onnx) from assets.
    /// Uses the same OnnxRuntime infrastructure as the mono path (initialize()).
    /// The dual model has the same interface as the mono model:
    ///   inputs[0] = "mix" [1,1,161,2], inputs[1..3] = caches
    ///   outputs[0] = "enh" [1,1,161,2], outputs[1..3] = updated caches
    ///
    /// Returns true if the model loaded and introspection passed.
    /// Spec: gtcrn-dual-channel (Option D).
    bool loadDualOnnxModel(AAssetManager* mgr, const char* assetPath) {
        std::vector<uint8_t> bytes = readAsset(mgr, assetPath);
        if (bytes.empty()) {
            DNN_LOGE("loadDualOnnxModel: failed to read ONNX model from assets");
            return false;
        }
        DNN_LOGI("loadDualOnnxModel: model loaded (%zu bytes)", bytes.size());

        try {
            session = std::make_unique<Ort::Session>(
                env, bytes.data(), bytes.size(), sessionOpts);
        } catch (const Ort::Exception& e) {
            DNN_LOGE("loadDualOnnxModel: Ort::Session failed: %s", e.what());
            return false;
        }

        if (!introspectModel()) {
            DNN_LOGE("loadDualOnnxModel: model introspection failed");
            session.reset();
            return false;
        }

        DNN_LOGI("loadDualOnnxModel: OK, dual ONNX model ready (WPE+GTCRN core)");
        return true;
    }

    /// Processes one dual-channel frame: STFT(2ch) -> WPE -> ONNX -> iSTFT/OLA.
    ///
    /// Takes kDnnHopSize samples from each channel (ch0, ch1) at 16 kHz.
    /// Performs STFT on both, runs WPE beamformer to get single-channel enhanced
    /// spectrum, then feeds it through the ONNX GTCRN core (same as processOneFrame
    /// for the ONNX run + iSTFT/OLA). Pushes kDnnHopSize samples to outputRing.
    ///
    /// @param hopCh0  kDnnHopSize new samples from microphone 0 (16 kHz)
    /// @param hopCh1  kDnnHopSize new samples from microphone 1 (16 kHz)
    /// @param vadActive  Current VAD state (for WPE noise estimation)
    /// @return true if frame processed OK; false -> bypass (model failure)
    bool processDualFrame(const float* hopCh0, const float* hopCh1, bool vadActive) {
        constexpr int nBins = kDnnFftSize / 2 + 1;  // 161

        // ── 1. STFT for channel 0 ───────────────────────────────────────
        // Shift stftInBuf left by kDnnHopSize and append new samples.
        std::memmove(stftInBuf.data(),
                     stftInBuf.data() + kDnnHopSize,
                     (kDnnFftSize - kDnnHopSize) * sizeof(float));
        std::memcpy(stftInBuf.data() + (kDnnFftSize - kDnnHopSize),
                    hopCh0, kDnnHopSize * sizeof(float));

        // Apply analysis window (sqrt-Hann) and forward DFT for ch0.
        for (int i = 0; i < kDnnFftSize; ++i) {
            dftWorkBuf[i] = stftInBuf[i] * hannWin[i];
        }
        dftForward(dftWorkBuf.data(), fftRe.data(), fftIm.data());

        // Store ch0 spectrum in complex format for WPE.
        WpeBeamformer::Complex X0[WpeBeamformer::kNumBins];
        for (int f = 0; f < nBins; ++f) {
            X0[f] = WpeBeamformer::Complex(fftRe[f], fftIm[f]);
        }

        // ── 2. STFT for channel 1 ───────────────────────────────────────
        std::memmove(stftInBufCh1.data(),
                     stftInBufCh1.data() + kDnnHopSize,
                     (kDnnFftSize - kDnnHopSize) * sizeof(float));
        std::memcpy(stftInBufCh1.data() + (kDnnFftSize - kDnnHopSize),
                    hopCh1, kDnnHopSize * sizeof(float));

        for (int i = 0; i < kDnnFftSize; ++i) {
            dftWorkBuf[i] = stftInBufCh1[i] * hannWin[i];
        }
        dftForward(dftWorkBuf.data(), fftReCh1.data(), fftImCh1.data());

        WpeBeamformer::Complex X1[WpeBeamformer::kNumBins];
        for (int f = 0; f < nBins; ++f) {
            X1[f] = WpeBeamformer::Complex(fftReCh1[f], fftImCh1[f]);
        }

        // ── 3. WPE beamformer: 2ch spectra -> 1ch enhanced spectrum ─────
        WpeBeamformer::Complex Y[WpeBeamformer::kNumBins];
        wpeBeamformer.process(X0, X1, Y, vadActive);

        // ── 4. Pack enhanced spectrum into ONNX input [1,1,nBins,2] ──────
        const auto& mixShape = inputShapes[mixInputIdx];
        if (mixShape.size() != 4 || mixShape[0] != 1 || mixShape[1] != 1 ||
            mixShape[2] != nBins || mixShape[3] != 2) {
            DNN_LOGE("processDualFrame: unsupported mix shape (expected [1,1,%d,2])", nBins);
            return false;
        }
        std::fill(mixTensorData.begin(), mixTensorData.end(), 0.0f);
        for (int f = 0; f < nBins; ++f) {
            mixTensorData[f * 2 + 0] = Y[f].real();
            mixTensorData[f * 2 + 1] = Y[f].imag();
        }

        // ── 5. Build ONNX tensors and Run ────────────────────────────────
        std::vector<Ort::Value> inputs;
        inputs.reserve(inputNames.size());
        for (size_t i = 0; i < inputNames.size(); ++i) {
            inputs.push_back(Ort::Value(nullptr));
        }

        inputs[mixInputIdx] = Ort::Value::CreateTensor<float>(
            memInfo,
            mixTensorData.data(),
            mixTensorData.size(),
            inputShapes[mixInputIdx].data(),
            inputShapes[mixInputIdx].size());

        for (size_t k = 0; k < cacheInputIdx.size(); ++k) {
            const int idx = cacheInputIdx[k];
            inputs[idx] = Ort::Value::CreateTensor<float>(
                memInfo,
                caches[k].data(),
                caches[k].size(),
                inputShapes[idx].data(),
                inputShapes[idx].size());
        }

        std::vector<Ort::Value> outputs;
        const auto t0 = std::chrono::steady_clock::now();
        try {
            outputs = session->Run(
                Ort::RunOptions{nullptr},
                inputNameCStr.data(), inputs.data(), inputs.size(),
                outputNameCStr.data(), outputNameCStr.size());
        } catch (const Ort::Exception& e) {
            DNN_LOGE("processDualFrame: OnnxRuntime Run failed: %s", e.what());
            return false;
        }
        const auto t1 = std::chrono::steady_clock::now();
        const auto us = std::chrono::duration_cast<std::chrono::microseconds>(
                            t1 - t0).count();
        lastInferenceUsLocal.store(static_cast<uint32_t>(us),
                                    std::memory_order_relaxed);

        if (outputs.size() != outputNames.size()) {
            DNN_LOGE("processDualFrame: Run returned %zu outputs (expected %zu)",
                     outputs.size(), outputNames.size());
            return false;
        }

        // ── 6. Copy updated caches ──────────────────────────────────────
        for (size_t k = 0; k < cacheOutputIdx.size(); ++k) {
            const int idx = cacheOutputIdx[k];
            const float* p = outputs[idx].GetTensorData<float>();
            const size_t n = caches[k].size();
            std::memcpy(caches[k].data(), p, n * sizeof(float));
        }

        // ── 7. Unpack enhanced tensor -> nBins complex spectrum ──────────
        const float* enhData = outputs[enhOutputIdx].GetTensorData<float>();
        for (int f = 0; f < nBins; ++f) {
            fftRe[f] = enhData[f * 2 + 0];
            fftIm[f] = enhData[f * 2 + 1];
        }

        // ── 8. Inverse DFT -> kDnnFftSize real samples ───────────────────
        // dftInverse handles Hermitian symmetry internally.
        // Output goes to dftWorkBuf to avoid aliasing with fftRe/fftIm inputs.
        dftInverse(fftRe.data(), fftIm.data(), dftWorkBuf.data());

        // ── 9. Synthesis window (Vorbis) + OLA ─────────────────────────
        for (int i = 0; i < kDnnFftSize; ++i) {
            dftWorkBuf[i] *= hannWin[i];
            olaBuf[i] += dftWorkBuf[i];
        }

        // ── 10. Extract kDnnHopSize samples from OLA buffer ──────────────
        std::memcpy(outputFrame.data(), olaBuf.data(),
                    kDnnHopSize * sizeof(float));
        std::memmove(olaBuf.data(),
                     olaBuf.data() + kDnnHopSize,
                     (kDnnFftSize - kDnnHopSize) * sizeof(float));
        std::fill(olaBuf.begin() + (kDnnFftSize - kDnnHopSize),
                  olaBuf.end(), 0.0f);

        // ── 11. Push to outputRing ───────────────────────────────────────
        if (outputRing.freeSpace() < kDnnHopSize) {
            droppedFramesLocal.fetch_add(1, std::memory_order_relaxed);
            return true;
        }
        outputRing.push(outputFrame.data(), kDnnHopSize);

        return true;
    }

    /// Inspecciona la sesión ONNX para descubrir nombres y shapes de I/O.
    /// Retorna true si el modelo cumple el contrato esperado (input "mix" 4D,
    /// el resto son cache tensors fijos; outputs en orden equivalente).
    bool introspectModel() {
        if (!session) return false;

        Ort::AllocatorWithDefaultOptions allocator;

        const size_t numIn  = session->GetInputCount();
        const size_t numOut = session->GetOutputCount();

        inputNames.clear();
        outputNames.clear();
        inputShapes.clear();
        outputShapes.clear();
        cacheInputIdx.clear();
        cacheOutputIdx.clear();
        mixInputIdx  = -1;
        enhOutputIdx = -1;

        // ── Inputs ────────────────────────────────────────────────────
        for (size_t i = 0; i < numIn; ++i) {
            auto name    = session->GetInputNameAllocated(i, allocator);
            std::string s(name.get());
            inputNames.push_back(s);

            auto info   = session->GetInputTypeInfo(i);
            auto tinfo  = info.GetTensorTypeAndShapeInfo();
            std::vector<int64_t> shape = tinfo.GetShape();
            // Reemplazar dims dinámicas (-1) por 1 (caso del time axis del mix).
            for (auto& d : shape) {
                if (d < 0) d = 1;
            }
            inputShapes.push_back(shape);

            DNN_LOGI("Input[%zu]: name=%s, shape=[%s]", i, s.c_str(), [&](){
                std::string r;
                for (auto d : shape) { r += std::to_string(d) + ","; }
                return r;
            }().c_str());
        }

        // ── Outputs ───────────────────────────────────────────────────
        for (size_t i = 0; i < numOut; ++i) {
            auto name    = session->GetOutputNameAllocated(i, allocator);
            std::string s(name.get());
            outputNames.push_back(s);

            auto info   = session->GetOutputTypeInfo(i);
            auto tinfo  = info.GetTensorTypeAndShapeInfo();
            std::vector<int64_t> shape = tinfo.GetShape();
            for (auto& d : shape) {
                if (d < 0) d = 1;
            }
            outputShapes.push_back(shape);

            DNN_LOGI("Output[%zu]: name=%s, shape=[%s]", i, s.c_str(), [&](){
                std::string r;
                for (auto d : shape) { r += std::to_string(d) + ","; }
                return r;
            }().c_str());
        }

        // ── Asignación POSICIONAL FIJA de mix/enh/caches ──────────────
        //
        // Convención GTCRN oficial (sherpa-onnx, csukuangfj/sherpa-onnx-hf):
        //   inputs[0]  = "mix"           (audio en frecuencia, [B, F, T, 2])
        //   inputs[1]  = "conv_cache"    (cache recurrente conv layers)
        //   inputs[2]  = "tra_cache"     (cache recurrente transformer)
        //   inputs[3]  = "inter_cache"   (cache recurrente inter-frame)
        //   outputs[0] = "enh"           (audio enhanced en frecuencia)
        //   outputs[1] = "conv_cache"    (cache actualizado)
        //   outputs[2] = "tra_cache"     (cache actualizado)
        //   outputs[3] = "inter_cache"   (cache actualizado)
        //
        // ELIMINADA la heurística por nombre (substring "mix"/"enh"): los
        // exporters ONNX a veces renombran los IO ("input_0", "output_0",
        // o nombres traducidos) y la búsqueda por substring fallaba
        // silenciosamente, dejando el modelo corriendo con caches sin
        // actualizar y produciendo audio "metálico" tras unos segundos.
        // El orden POSICIONAL es el contrato real del modelo.
        mixInputIdx  = 0;
        enhOutputIdx = 0;

        if (inputNames.size() != 4) {
            DNN_LOGW("Expected 4 inputs (GTCRN convention: mix + 3 caches), "
                     "got %zu — sherpa-onnx fallback path",
                     inputNames.size());
        }
        if (outputNames.size() != 4) {
            DNN_LOGW("Expected 4 outputs (GTCRN convention: enh + 3 caches), "
                     "got %zu — sherpa-onnx fallback path",
                     outputNames.size());
        }

        // Caches: TODOS los inputs/outputs distintos de la posición 0.
        for (size_t i = 1; i < inputNames.size(); ++i) {
            cacheInputIdx.push_back(static_cast<int>(i));
        }
        for (size_t i = 1; i < outputNames.size(); ++i) {
            cacheOutputIdx.push_back(static_cast<int>(i));
        }

        if (cacheInputIdx.size() != cacheOutputIdx.size()) {
            DNN_LOGE("Cache count mismatch: %zu inputs vs %zu outputs",
                     cacheInputIdx.size(), cacheOutputIdx.size());
            return false;
        }

        // ── Validar shape del input "mix" ─────────────────────────────
        if (mixInputIdx < 0 ||
            inputShapes[mixInputIdx].size() < 3) {
            DNN_LOGE("mix input has unexpected shape (need ≥3 dims)");
            return false;
        }

        // ── Pre-allocar caches con ceros ──────────────────────────────
        caches.clear();
        for (int idx : cacheInputIdx) {
            const int64_t numel = shapeNumel(inputShapes[idx]);
            if (numel <= 0) {
                DNN_LOGE("Cache input has dynamic shape, cannot pre-allocate");
                return false;
            }
            caches.emplace_back(static_cast<size_t>(numel), 0.0f);
        }

        // ── DPDFNet: inicializar state desde metadata ONNX ───────────
        // DPDFNet embeds erb_norm_init and spec_norm_init in ONNX custom
        // metadata. Without proper initialization the first ~500ms produce
        // loud artifacts because the running normalization starts from zero.
        // For GTCRN (no metadata) this block is a harmless no-op.
        {
            Ort::ModelMetadata modelMeta = session->GetModelMetadata();
            Ort::AllocatorWithDefaultOptions metaAlloc;
            // Try to read DPDFNet-specific metadata key
            Ort::AllocatedStringPtr erbCheck =
                modelMeta.LookupCustomMetadataMapAllocated("erb_norm_init", metaAlloc);
            if (erbCheck && erbCheck.get() != nullptr && erbCheck.get()[0] != '\0' && !caches.empty()) {
                DNN_LOGI("DPDFNet metadata detected — initializing state vector");
                auto& stateVec = caches[0]; // single flat state vector
                Ort::AllocatedStringPtr specStr =
                    modelMeta.LookupCustomMetadataMapAllocated("spec_norm_init", metaAlloc);
                Ort::AllocatedStringPtr erbSzStr =
                    modelMeta.LookupCustomMetadataMapAllocated("erb_norm_state_size", metaAlloc);
                Ort::AllocatedStringPtr specSzStr =
                    modelMeta.LookupCustomMetadataMapAllocated("spec_norm_state_size", metaAlloc);
                if (specStr && erbSzStr && specSzStr) {
                    const int erbSz = std::atoi(erbSzStr.get());
                    const int specSz = std::atoi(specSzStr.get());
                    // Parse erb_norm_init CSV into stateVec[0..erbSz-1]
                    {
                        std::string csv(erbCheck.get());
                        int pos = 0;
                        size_t start = 0, end;
                        while ((end = csv.find(',', start)) != std::string::npos
                               && pos < erbSz
                               && pos < static_cast<int>(stateVec.size())) {
                            stateVec[pos++] = std::stof(csv.substr(start, end - start));
                            start = end + 1;
                        }
                        if (pos < erbSz && start < csv.size()
                            && pos < static_cast<int>(stateVec.size())) {
                            stateVec[pos] = std::stof(csv.substr(start));
                        }
                    }
                    // Parse spec_norm_init CSV into stateVec[erbSz..erbSz+specSz-1]
                    {
                        std::string csv(specStr.get());
                        int pos = erbSz;
                        size_t start = 0, end;
                        while ((end = csv.find(',', start)) != std::string::npos
                               && pos < erbSz + specSz
                               && pos < static_cast<int>(stateVec.size())) {
                            stateVec[pos++] = std::stof(csv.substr(start, end - start));
                            start = end + 1;
                        }
                        if (pos < erbSz + specSz && start < csv.size()
                            && pos < static_cast<int>(stateVec.size())) {
                            stateVec[pos] = std::stof(csv.substr(start));
                        }
                    }
                    DNN_LOGI("DPDFNet state initialized: erb=%d, spec=%d, total=%zu",
                             erbSz, specSz, stateVec.size());
                } else {
                    DNN_LOGW("DPDFNet metadata keys found but values missing");
                }
            }
        }

        // Pre-allocar buffer del mix tensor.
        const int64_t mixNumel = shapeNumel(inputShapes[mixInputIdx]);
        if (mixNumel <= 0) {
            DNN_LOGE("mix input has invalid total size");
            return false;
        }
        mixTensorData.assign(static_cast<size_t>(mixNumel), 0.0f);

        // Punteros C-string para Run().
        inputNameCStr.clear();
        outputNameCStr.clear();
        for (auto& s : inputNames)  inputNameCStr.push_back(s.c_str());
        for (auto& s : outputNames) outputNameCStr.push_back(s.c_str());

        DNN_LOGI("Model introspection OK: mix=%d, enh=%d, %zu caches",
                 mixInputIdx, enhOutputIdx, caches.size());
        return true;
    }

    /// Resetea caches y buffers STFT (a llamar cuando reset_requested).
    void resetWorkerState() {
        for (auto& c : caches) {
            std::fill(c.begin(), c.end(), 0.0f);
        }
        std::fill(stftInBuf.begin(),  stftInBuf.end(),  0.0f);
        std::fill(olaBuf.begin(),     olaBuf.end(),     0.0f);
        std::fill(fftRe.begin(),      fftRe.end(),      0.0f);
        std::fill(fftIm.begin(),      fftIm.end(),      0.0f);
        std::fill(dftWorkBuf.begin(), dftWorkBuf.end(), 0.0f);
        std::fill(outputFrame.begin(),outputFrame.end(),0.0f);
        // Dual-channel state.
        std::fill(stftInBufCh1.begin(), stftInBufCh1.end(), 0.0f);
        std::fill(fftReCh1.begin(), fftReCh1.end(), 0.0f);
        std::fill(fftImCh1.begin(), fftImCh1.end(), 0.0f);
        wpeBeamformer.reset();
        // Noise gate state.
        gateGain_ = 1.0f;
        gateHoldCounter_ = 0;
    }

    /// Forward real DFT using precomputed twiddle factors.
    /// Computes nBins = N/2+1 complex bins from N real samples.
    /// Uses the precomputed twiddleRe/twiddleIm tables to avoid repeated
    /// cos/sin calls that caused floating-point precision drift.
    void dftForward(const float* x, float* outRe, float* outIm) {
        constexpr int N = kDnnFftSize;
        constexpr int nBins = N / 2 + 1;
        for (int k = 0; k < nBins; ++k) {
            float sumRe = 0, sumIm = 0;
            const int base = k * N;
            for (int n = 0; n < N; ++n) {
                sumRe += x[n] * twiddleRe[base + n];
                sumIm += x[n] * twiddleIm[base + n];
            }
            outRe[k] = sumRe;
            outIm[k] = sumIm;
        }
    }

    /// Inverse real DFT using precomputed twiddle factors (conjugate).
    /// Reconstructs N real samples from nBins = N/2+1 complex bins.
    /// Reuses twiddleRe and negates twiddleIm for the conjugate (inverse) transform.
    void dftInverse(const float* inRe, const float* inIm, float* out) {
        constexpr int N = kDnnFftSize;
        constexpr int nBins = N / 2 + 1;
        const float invN = 1.0f / static_cast<float>(N);
        for (int n = 0; n < N; ++n) {
            float sum = inRe[0]; // DC
            for (int k = 1; k < nBins - 1; ++k) {
                const int idx = k * N + n;
                // Hermitian: X[k]*exp(j*w) + X[N-k]*exp(-j*w) = 2*Re(X[k]*exp(j*w))
                // exp(j*2pi*k*n/N) = twiddleRe[idx] - j*twiddleIm[idx] (conjugate)
                float cosKN = twiddleRe[idx];   // cos(-2pi*k*n/N) = cos(2pi*k*n/N)
                float sinKN = -twiddleIm[idx];  // -sin(-2pi*k*n/N) = sin(2pi*k*n/N)
                sum += 2.0f * (inRe[k] * cosKN - inIm[k] * sinKN);
            }
            // Nyquist (k = nBins-1 = N/2)
            const int idxNyq = (nBins - 1) * N + n;
            float cosNyq = twiddleRe[idxNyq];
            float sinNyq = -twiddleIm[idxNyq];
            sum += inRe[nBins-1] * cosNyq - inIm[nBins-1] * sinNyq;
            out[n] = sum * invN;
        }
    }

    /// Ejecuta una inferencia GTCRN sobre un frame de kDnnHopSize samples
    /// nuevos provenientes de inputRing. Empuja kDnnHopSize samples al outputRing.
    /// Devuelve true si el frame se procesó OK (false → falla, el wrapper
    /// debería pasar a bypass).
    bool processOneFrame(const float* hopIn) {
        // ── 1. Desplazar stftInBuf a la izquierda por kDnnHopSize y append ──
        std::memmove(stftInBuf.data(),
                     stftInBuf.data() + kDnnHopSize,
                     (kDnnFftSize - kDnnHopSize) * sizeof(float));
        std::memcpy(stftInBuf.data() + (kDnnFftSize - kDnnHopSize),
                    hopIn, kDnnHopSize * sizeof(float));

        // ── 2. Aplicar ventana de analisis (sqrt-Hann) ───────────────────
        for (int i = 0; i < kDnnFftSize; ++i) {
            dftWorkBuf[i] = stftInBuf[i] * hannWin[i];
        }

        // ── 3. Forward DFT -> nBins complex bins ─────────────────────────
        constexpr int nBins = kDnnFftSize / 2 + 1;  // 161
        dftForward(dftWorkBuf.data(), fftRe.data(), fftIm.data());

        // ── 4. Empacar en mixTensorData con shape del modelo ─────────────
        // El modelo tiene shape [1, 1, nBins, 2] donde nBins=161.
        // Validamos dinamicamente contra el shape introspectado.
        const auto& mixShape = inputShapes[mixInputIdx];

        // Buscar la dim que coincide con nBins en el shape del modelo.
        int freqDim = -1;
        for (size_t i = 0; i < mixShape.size(); ++i) {
            if (mixShape[i] == nBins) {
                freqDim = static_cast<int>(i);
                break;
            }
        }
        if (freqDim < 0) {
            DNN_LOGE("Cannot find freq dim (expected size=%d) in mix shape", nBins);
            return false;
        }

        // Para simplicidad asumimos shape [1, 1, nBins, 2].
        std::fill(mixTensorData.begin(), mixTensorData.end(), 0.0f);
        if (mixShape.size() == 4 && mixShape[0] == 1 && mixShape[1] == 1 &&
            mixShape[2] == nBins && mixShape[3] == 2) {
            // [1, 1, nBins, 2] -> idx = freq * 2 + complex
            for (int f = 0; f < nBins; ++f) {
                mixTensorData[f * 2 + 0] = fftRe[f];
                mixTensorData[f * 2 + 1] = fftIm[f];
            }
        } else {
            DNN_LOGE("Unsupported mix shape (expected [1,1,%d,2])", nBins);
            return false;
        }

        // ── 5. Construir tensores ONNX ───────────────────────────────────
        std::vector<Ort::Value> inputs;
        inputs.reserve(inputNames.size());

        for (size_t i = 0; i < inputNames.size(); ++i) {
            inputs.push_back(Ort::Value(nullptr));
        }

        inputs[mixInputIdx] = Ort::Value::CreateTensor<float>(
            memInfo,
            mixTensorData.data(),
            mixTensorData.size(),
            inputShapes[mixInputIdx].data(),
            inputShapes[mixInputIdx].size());

        for (size_t k = 0; k < cacheInputIdx.size(); ++k) {
            const int idx = cacheInputIdx[k];
            inputs[idx] = Ort::Value::CreateTensor<float>(
                memInfo,
                caches[k].data(),
                caches[k].size(),
                inputShapes[idx].data(),
                inputShapes[idx].size());
        }

        // ── 6. Run() ─────────────────────────────────────────────────────
        std::vector<Ort::Value> outputs;
        const auto t0 = std::chrono::steady_clock::now();
        try {
            outputs = session->Run(
                Ort::RunOptions{nullptr},
                inputNameCStr.data(),  inputs.data(),  inputs.size(),
                outputNameCStr.data(), outputNameCStr.size());
        } catch (const Ort::Exception& e) {
            DNN_LOGE("OnnxRuntime Run failed: %s", e.what());
            return false;
        }
        const auto t1 = std::chrono::steady_clock::now();
        const auto us = std::chrono::duration_cast<std::chrono::microseconds>(
                            t1 - t0).count();
        lastInferenceUsLocal.store(static_cast<uint32_t>(us),
                                    std::memory_order_relaxed);

        if (outputs.size() != outputNames.size()) {
            DNN_LOGE("Run returned %zu outputs (expected %zu)",
                     outputs.size(), outputNames.size());
            return false;
        }

        // ── 7. Copiar caches actualizadas ────────────────────────────────
        for (size_t k = 0; k < cacheOutputIdx.size(); ++k) {
            const int idx = cacheOutputIdx[k];
            const float* p = outputs[idx].GetTensorData<float>();
            const size_t n = caches[k].size();
            std::memcpy(caches[k].data(), p, n * sizeof(float));
        }

        // ── 8. Desempacar enh tensor -> fftRe/fftIm (nBins) ─────────────
        const float* enhData = outputs[enhOutputIdx].GetTensorData<float>();
        for (int f = 0; f < nBins; ++f) {
            fftRe[f] = enhData[f * 2 + 0];
            fftIm[f] = enhData[f * 2 + 1];
        }

        // ── 9. Inverse DFT -> kDnnFftSize real samples ───────────────────
        // dftInverse handles Hermitian symmetry internally.
        // Output goes to dftWorkBuf to avoid aliasing with fftRe/fftIm inputs.
        dftInverse(fftRe.data(), fftIm.data(), dftWorkBuf.data());

        // ── 10. Aplicar ventana de sintesis (Vorbis) y OLA ─────────────
        //
        // DPDFNet: El modelo devuelve espectro enhanced. Para reconstrucción
        // perfecta con ventana Vorbis y hop=N/2 (50% overlap):
        //   w²[n] + w²[n+hop] = 1  (propiedad COLA de Vorbis)
        // Se aplica ventana de síntesis (misma Vorbis) sin escala adicional.
        for (int i = 0; i < kDnnFftSize; ++i) {
            dftWorkBuf[i] *= hannWin[i];
            olaBuf[i] += dftWorkBuf[i];
        }

        // ── 11. Extraer kDnnHopSize samples del inicio del olaBuf ────────
        std::memcpy(outputFrame.data(), olaBuf.data(),
                    kDnnHopSize * sizeof(float));

        // Shift olaBuf: descartar primeros kDnnHopSize, append zeros al final.
        std::memmove(olaBuf.data(),
                     olaBuf.data() + kDnnHopSize,
                     (kDnnFftSize - kDnnHopSize) * sizeof(float));
        std::fill(olaBuf.begin() + (kDnnFftSize - kDnnHopSize),
                  olaBuf.end(), 0.0f);

        // ── 11b. Noise gate DESACTIVADO (era la causa de la matraca) ─────
        //
        // El gate previo modulaba la amplitud del frame en base al RMS con
        // rampas de 0.33 por frame de 10 ms. En señales de nivel borderline
        // (ventilador, aire acondicionado, tráfico lejano) esa modulación
        // caía dentro del knee (0.001–0.01), exactamente en el rango del
        // piso de ruido residual del GTCRN post-inferencia, produciendo
        // oscilaciones periódicas de ganancia audibles como MATRACA a
        // ~30 Hz (la velocidad de la rampa dividida por el hop).
        //
        // El GTCRN ya aprende ganancias por banda con suavizado interno;
        // añadir un gate adicional en cascada es redundante y solo agrega
        // artefactos. Si en el futuro se quiere un gate real, va al final
        // del pipeline DSP (post-EQ / pre-MPO), no aquí dentro del wrapper
        // del modelo.
        //
        // Los miembros gateGain_ (=1.0) y gateHoldCounter_ (=0) quedan en
        // sus valores iniciales; no se tocan, no se aplican.

        // ── 12. Push outputFrame al outputRing ───────────────────────────
        if (outputRing.freeSpace() < kDnnHopSize) {
            droppedFramesLocal.fetch_add(1, std::memory_order_relaxed);
            return true;
        }
        outputRing.push(outputFrame.data(), kDnnHopSize);

        return true;
    }

    /// Loop principal del worker.
    ///
    /// Both mono and dual paths now operate frame-by-frame at kDnnHopSize:
    ///   - mono (1): drena kDnnHopSize de inputRing -> STFT+ONNX (processOneFrame).
    ///   - dual (2): drena kDnnHopSize de inputRing y inputRingCh1 ->
    ///               STFT(2ch)+WPE+ONNX+iSTFT (processDualFrame).
    /// The inference ALWAYS runs here, never in the audio thread.
    void workerLoop() {
        DNN_LOGI("Worker thread started");
        std::vector<float> hopBuf(kDnnHopSize, 0.0f);
        std::vector<float> hopCh0(kDnnHopSize, 0.0f);
        std::vector<float> hopCh1(kDnnHopSize, 0.0f);

        while (workerRun.load(std::memory_order_acquire)) {
            // Reset si fue solicitado.
            if (resetRequested.exchange(false, std::memory_order_acq_rel)) {
                resetWorkerState();
                inputRing.clear();
                inputRingCh1.clear();
                outputRing.clear();
                // dryDelayRing lo limpia el audio thread (nosotros no podemos).
            }

            const bool dual = (channels.load(std::memory_order_acquire) == 2);
            // Both paths now use kDnnHopSize (frame-by-frame, 10ms latency).
            const int  need = kDnnHopSize;

            // Esperar hasta tener `need` samples disponibles (ambos canales si dual).
            {
                std::unique_lock<std::mutex> lk(workerMtx);
                workerCv.wait_for(lk, std::chrono::milliseconds(5),
                                  [this, dual, need] {
                    if (!workerRun.load(std::memory_order_acquire)) return true;
                    if (resetRequested.load(std::memory_order_acquire)) return true;
                    if (dual) {
                        return inputRing.available() >= need &&
                               inputRingCh1.available() >= need;
                    }
                    return inputRing.available() >= need;
                });
            }
            if (!workerRun.load(std::memory_order_acquire)) break;
            if (!modelReady) continue;

            if (dual) {
                // ── Ruta dual: WPE + ONNX (frame-by-frame) ────────────
                if (inputRing.available() < kDnnHopSize ||
                    inputRingCh1.available() < kDnnHopSize) {
                    continue;
                }
                const int p0 = inputRing.pop(hopCh0.data(), kDnnHopSize);
                const int p1 = inputRingCh1.pop(hopCh1.data(), kDnnHopSize);
                if (p0 < kDnnHopSize || p1 < kDnnHopSize) continue;

                // VAD state: read from the outer DnnDenoiser's voiceActive_
                // atomic, which is set by notifyVoiceActive() from the audio
                // thread. When vadActive is false (noise-only), the WPE
                // beamformer updates its noise covariance for spatial filtering.
                const bool vadActive = (voiceActivePtr_ != nullptr)
                    ? voiceActivePtr_->load(std::memory_order_acquire)
                    : true;  // Conservative fallback if pointer not set

                const bool ok = processDualFrame(hopCh0.data(), hopCh1.data(), vadActive);
                if (!ok) {
                    DNN_LOGW("processDualFrame failed -> flagging inactive");
                    modelReady = false;
                    continue;
                }
                processedFramesLocal.fetch_add(1, std::memory_order_relaxed);
            } else {
                // ── Ruta mono legacy: STFT + ONNX ──────────────────────
                if (inputRing.available() < kDnnHopSize) continue;
                const int popped = inputRing.pop(hopBuf.data(), kDnnHopSize);
                if (popped < kDnnHopSize) continue;  // race extraño, reintentar.

                const bool ok = processOneFrame(hopBuf.data());
                if (!ok) {
                    DNN_LOGW("processOneFrame failed → flagging inactive");
                    modelReady = false;  // bypass permanente hasta reset.
                    continue;
                }
                processedFramesLocal.fetch_add(1, std::memory_order_relaxed);
            }
        }
        DNN_LOGI("Worker thread exited");
    }

    void startWorker() {
        if (worker.joinable()) return;
        workerRun.store(true, std::memory_order_release);
        worker = std::thread([this]{ workerLoop(); });
    }

    void stopWorker() {
        workerRun.store(false, std::memory_order_release);
        workerCv.notify_all();
        if (worker.joinable()) worker.join();
    }

    /// Configura el resampler para una rate de entrada dada.
    /// Se llama desde el hilo de control (NO el audio thread).
    /// Idempotente: si la rate no cambió respecto a la anterior, es no-op.
    void applyInputSampleRate(int sr) {
        if (sr <= 0) sr = kDnnSampleRate;
        if (sr == inputSr && down.groupDelaySamples() >= 0.0f) {
            // Misma rate ya configurada: no-op.
            return;
        }
        inputSr = sr;
        if (sr == kDnnSampleRate) {
            // 16 kHz: bypass del resampler.
            down.configure(Resampler::Mode::kIdentity, nullptr, 0, 1.0f);
            downCh1.configure(Resampler::Mode::kIdentity, nullptr, 0, 1.0f);
            up.configure(Resampler::Mode::kIdentity, nullptr, 0, 1.0f);
            DNN_LOGI("Resampler: 16 kHz native — bypass (latency = 0 ms)");
        } else if (sr == 48000) {
            // 48 kHz: polyphase 3:1 con prototipo Kaiser de kProtoTaps taps.
            // MEJORA #3 (ruido-profundo.md): 72 taps β=8.5 (antes 96 β=8) — mismo
            // stopband, ~0.5 ms menos de round-trip delay.
            down.configure(Resampler::Mode::kPolyDown48to16,
                           protoLpf.data(),
                           static_cast<int>(protoLpf.size()), 0.0f);
            // ch1 usa un resampler idéntico con estado propio (tarea 2.3).
            downCh1.configure(Resampler::Mode::kPolyDown48to16,
                              protoLpf.data(),
                              static_cast<int>(protoLpf.size()), 0.0f);
            up.configure(Resampler::Mode::kPolyUp16to48,
                         protoLpf.data(),
                         static_cast<int>(protoLpf.size()), 0.0f);
            const float dlyDownMs = down.groupDelayMs(kDnnSampleRate);
            const float dlyUpMs   = up.groupDelayMs(48000);
            DNN_LOGI("Resampler: 48000 → polyphase 3:1, %d taps Kaiser β=%.1f, "
                     "fc=7.5 kHz. Down delay=%.2f ms, Up delay=%.2f ms, "
                     "round-trip ≈ %.2f ms",
                     kProtoTaps, static_cast<double>(kKaiserBeta),
                     dlyDownMs, dlyUpMs, dlyDownMs + dlyUpMs);
        } else {
            // Rate genérico: linear con ratio inputSr/16000 (down) y 16000/inputSr (up).
            const float downRatio = static_cast<float>(sr) / static_cast<float>(kDnnSampleRate);
            const float upRatio   = static_cast<float>(kDnnSampleRate) / static_cast<float>(sr);
            down.configure(Resampler::Mode::kLinearGeneric, nullptr, 0, downRatio);
            downCh1.configure(Resampler::Mode::kLinearGeneric, nullptr, 0, downRatio);
            up.configure(Resampler::Mode::kLinearGeneric, nullptr, 0, upRatio);
            DNN_LOGW("Resampler: %d Hz → linear interpolation (downRatio=%.4f, "
                     "upRatio=%.4f). Quality OK for denoiser, suboptimal for "
                     "non-integer ratios.", sr, downRatio, upRatio);
        }
        // Limpiar rings: las dimensiones lógicas cambian al cambiar la rate.
        inputRing.clear();
        inputRingCh1.clear();
        outputRing.clear();
        dryDelayRing.clear();

        // ── Re-aplicar pre-fill del dryDelayRing según la rate actual ────
        // FIX matraca: el pre-fill compensa la latencia ALGORÍTMICA exacta
        // del wet path (down + STFT buffering + up). Sin esto, dry se
        // adelanta al wet y la mezcla produce comb filtering audible
        // ("matraca") que empeora a mayor intensity.
        //
        // Latencia exacta del wet path en samples @ inputSr:
        //   1. Downsampler group delay: (kProtoTaps-1)/2 samples @ inputSr
        //   2. STFT buffering: 1 hop = kDnnHopSize samples @ 16 kHz
        //      → convertido a inputSr: kDnnHopSize * (inputSr / 16000)
        //   3. Upsampler group delay: (kProtoTaps-1)/2 samples @ inputSr
        //
        // El OLA NO introduce hop extra porque stftInBuf arranca con zeros.
        // El jitter del worker thread NO se compensa aquí — se absorbe por
        // el ring buffer (4096 capacidad) y por el crossfade suave de underrun.
        {
            int preFill = 0;
            if (inputSr == kDnnSampleRate) {
                // 16 kHz: sin resampler. Latencia = 1 hop STFT buffering.
                preFill = kDnnHopSize; // 160 samples = 10 ms
            } else if (inputSr == 48000) {
                // 48 kHz polyphase: resamplers + 1 hop STFT.
                // Down: (72-1)/2 = 35.5 samples @ 48 kHz
                // Hop:  160 * 3 = 480 samples @ 48 kHz
                // Up:   (72-1)/2 = 35.5 samples @ 48 kHz
                // Total exacto: 551 samples @ 48 kHz (11.48 ms)
                const float downDelay = static_cast<float>(kProtoTaps - 1) / 2.0f;
                const float hopAtNative = static_cast<float>(kDnnHopSize) * 3.0f;
                const float upDelay = downDelay;
                preFill = static_cast<int>(
                    std::round(downDelay + hopAtNative + upDelay));
            } else {
                // Rate genérica: resampler lineal (delay≈0) + hop escalado.
                const float ratio = static_cast<float>(inputSr) /
                                    static_cast<float>(kDnnSampleRate);
                preFill = static_cast<int>(
                    std::round(static_cast<float>(kDnnHopSize) * ratio));
            }
            if (preFill > 0 && preFill < kDnnRingCapacity / 2) {
                std::vector<float> zeros(preFill, 0.0f);
                dryDelayRing.push(zeros.data(), preFill);
                DNN_LOGI("dryDelayRing pre-fill: %d samples @ %d Hz (%.2f ms)",
                         preFill, inputSr,
                         1000.0f * static_cast<float>(preFill) /
                         static_cast<float>(inputSr));
            }
        }

        // Reset estado interno worker para evitar mezclar buffers de la rate vieja.
        // Solo disparar reset si el worker ya estaba produciendo output con una
        // rate previa (processedFramesLocal > 0). En la primera configuracion
        // (startup), los rings estan vacios y no hay estado previo que limpiar;
        // disparar reset aqui provocaria que el worker descarte el primer bloque
        // y nunca arranque (Frames: 0 permanente).
        if (processedFramesLocal.load(std::memory_order_relaxed) > 0) {
            resetRequested.store(true, std::memory_order_release);
            workerCv.notify_one();
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// DnnDenoiser methods
// ─────────────────────────────────────────────────────────────────────────────

DnnDenoiser::DnnDenoiser() : impl_(std::make_unique<Impl>()) {
    // Give the Impl a pointer to our voiceActive_ atomic so the worker loop
    // can read the actual VAD state for the WPE beamformer.
    impl_->voiceActivePtr_ = &voiceActive_;
}

DnnDenoiser::~DnnDenoiser() = default;

int DnnDenoiser::inputChannels() const {
    if (!impl_) return 1;
    return impl_->channels.load(std::memory_order_acquire);
}

void DnnDenoiser::setInputSampleRate(int sampleRateHz) {
    if (!impl_) return;
    impl_->applyInputSampleRate(sampleRateHz);

    // Spec dnn-voice-level-recovery (Paso 1, Tarea 2):
    // Recalcular pasos por sample de la rampa asimétrica del cap.
    // El loop de mezcla corre a `inputSampleRate` (no a 16 kHz), así que
    // el step depende de la rate efectiva. Attack más corto que release
    // para reducir rápido el wet cuando aparece voz, y restaurar lento
    // al volver a no-voz (estilo WDRC asimétrico).
    if (sampleRateHz > 0) {
        const float samplesPerMs   = static_cast<float>(sampleRateHz) / 1000.0f;
        const float attackSamples  = kVoiceCapAttackMs  * samplesPerMs;
        const float releaseSamples = kVoiceCapReleaseMs * samplesPerMs;
        stepAttackPerSample_  = (attackSamples  > 0.0f) ? (1.0f / attackSamples)  : 1.0f;
        stepReleasePerSample_ = (releaseSamples > 0.0f) ? (1.0f / releaseSamples) : 1.0f;
    }
}

bool DnnDenoiser::initialize(AAssetManager* assetMgr, const char* assetPath) {
    if (impl_->modelReady) {
        DNN_LOGW("initialize: already initialized, no-op");
        return true;
    }

    DNN_LOGI("initialize: loading %s", assetPath ? assetPath : "(null)");

    std::vector<uint8_t> modelBytes = impl_->readAsset(assetMgr, assetPath);
    if (modelBytes.empty()) {
        DNN_LOGE("initialize: failed to read model from assets");
        active_.store(false, std::memory_order_release);
        return false;
    }

    DNN_LOGI("initialize: model loaded (%zu bytes)", modelBytes.size());

    try {
        impl_->session = std::make_unique<Ort::Session>(
            impl_->env, modelBytes.data(), modelBytes.size(),
            impl_->sessionOpts);
    } catch (const Ort::Exception& e) {
        DNN_LOGE("initialize: Ort::Session failed: %s", e.what());
        active_.store(false, std::memory_order_release);
        return false;
    }

    if (!impl_->introspectModel()) {
        DNN_LOGE("initialize: model introspection failed");
        impl_->session.reset();
        active_.store(false, std::memory_order_release);
        return false;
    }

    impl_->channels.store(1, std::memory_order_release);
    impl_->modelReady = true;
    active_.store(true, std::memory_order_release);
    impl_->startWorker();
    DNN_LOGI("initialize: OK, worker thread running (mono)");
    return true;
}

bool DnnDenoiser::initializeDual(AAssetManager* assetMgr, const char* assetPath) {
    if (impl_->modelReady) {
        DNN_LOGW("initializeDual: already initialized, no-op");
        return impl_->channels.load(std::memory_order_acquire) == 2;
    }

    DNN_LOGI("initializeDual: loading %s (ONNX dual-channel, WPE+GTCRN core)",
             assetPath ? assetPath : "(null)");

    // Load the ONNX model using the same OnnxRuntime infrastructure as mono.
    // The dual model has the same interface: [1,1,161,2] + caches.
    if (!impl_->loadDualOnnxModel(assetMgr, assetPath)) {
        DNN_LOGE("initializeDual: model load/validation failed -> bypass");
        impl_->channels.store(1, std::memory_order_release);
        active_.store(false, std::memory_order_release);
        return false;
    }

    impl_->channels.store(2, std::memory_order_release);
    impl_->modelReady = true;
    active_.store(true, std::memory_order_release);
    impl_->startWorker();
    DNN_LOGI("initializeDual: OK, worker thread running (dual-channel WPE+ONNX)");
    return true;
}

void DnnDenoiser::process(float* buffer, int blockSize) {
    if (buffer == nullptr || blockSize <= 0) return;

    const bool en  = enabled_.load(std::memory_order_acquire);
    const bool act = active_.load(std::memory_order_acquire);

    // Fast path 1: bypass total — sin modelo o sin enable + crossfade en 0.
    // Salimos sin tocar el buffer (bit-exact).
    if (!en && crossfadeGain_ <= 0.0f) {
        return;
    }

    // Si no estamos activos (modelo no cargado o falla), saltar la cola DSP
    // pero respetar el crossfade out (si venía siendo wet y ahora apagamos).
    if (!act) {
        // Si crossfadeGain_ > 0 (estábamos en wet) hacemos crossfade out con
        // dry buffer (que es el mismo que el input). Como no hay wet, el
        // resultado es simplemente el dry; sólo evolucionamos el gain.
        crossfadeTarget_ = 0.0f;
        if (crossfadeGain_ > 0.0f) {
            for (int i = 0; i < blockSize; ++i) {
                crossfadeGain_ = std::max(0.0f, crossfadeGain_ - kCrossfadeStep);
            }
        }
        return;
    }

    // Actualizar target del crossfade.
    crossfadeTarget_ = en ? 1.0f : 0.0f;

    // ── Etapa 1: dryDelayRing va SIEMPRE en samples a la rate nativa ────
    // Esto garantiza que dry y wet quedan alineados 1:1 a la salida (ya
    // upsampleada) sin interpolar el dry (que perdería calidad).
    const int pushedDry = impl_->dryDelayRing.push(buffer, blockSize);
    (void)pushedDry;  // si el ring se llena, el reset lo limpia.

    // ── Etapa 2: DOWNSAMPLE input → 16 kHz → inputRing ──────────────────
    // En modo identity (inputSr==16000) el resampler hace memcpy.
    // Garantizar que el staging buffer tiene capacidad suficiente.
    if (static_cast<int>(impl_->downStaging.size()) < blockSize) {
        impl_->downStaging.assign(blockSize, 0.0f);  // realloc raro fuera de hot path.
    }
    const int down16k = impl_->down.process(buffer, blockSize,
                                            impl_->downStaging.data(),
                                            static_cast<int>(impl_->downStaging.size()));
    if (down16k > 0) {
        const int pushedIn = impl_->inputRing.push(impl_->downStaging.data(), down16k);
        if (pushedIn < down16k) {
            droppedFrames_.fetch_add(1, std::memory_order_relaxed);
        }
        // Notificar al worker (solo si recién llegamos al umbral).
        if (impl_->inputRing.available() >= kDnnHopSize) {
            impl_->workerCv.notify_one();
        }
    }

    // ── Etapa 3: tirar wet @ 16 kHz del outputRing y UPSAMPLE a inputSr ──
    // El upsampler es stateful; alimentamos un sample 16k a la vez hasta
    // acumular `blockSize` muestras a la rate nativa. Si nos quedamos sin
    // wet 16k antes de completar, marcamos underrun y pasamos al fallback.
    if (static_cast<int>(impl_->wetNativeRate.size()) < blockSize) {
        impl_->wetNativeRate.assign(blockSize, 0.0f);
    }
    int wetWritten = 0;
    bool underrun = false;
    while (wetWritten < blockSize) {
        // ¿Cuántos samples 16k necesitamos para obtener al menos 1 sample nativo?
        // En el peor caso (polyphase up con phase==L-1) basta con 1.
        float in16k;
        const int got = impl_->outputRing.pop(&in16k, 1);
        if (got < 1) {
            underrun = true;
            break;
        }
        // Procesar ese 1 sample 16k → produce 1..L outputs nativos.
        const int produced = impl_->up.process(
            &in16k, 1,
            impl_->wetNativeRate.data() + wetWritten,
            blockSize - wetWritten);
        wetWritten += produced;
        if (produced == 0) {
            // Lineal en ratio < 1: a veces un input no genera output todavía.
            // Continuar pidiendo más samples 16k.
            continue;
        }
    }

    // ── Etapa 4: pop dry @ rate nativa para mezclar 1:1 con wetNativeRate ──
    // Mantener alineamiento estricto: si hay underrun consumimos igualmente
    // del dryDelayRing para que la siguiente vuelta arranque sincronizada.
    std::vector<float> dry(blockSize, 0.0f);
    const int gotDry = impl_->dryDelayRing.pop(dry.data(), blockSize);

    if (underrun) {
        // ── FIX tktktk (Causa 1): crossfade suave hacia dry en underrun ──
        // En vez de saltar abruptamente a dry, hacemos un crossfade rápido
        // (5 ms) desde la mezcla actual hacia dry puro. Si hay wet parcial
        // disponible (wetWritten > 0), lo usamos para los primeros samples
        // y transicionamos a dry para el resto, evitando el click abrupto.
        //
        // Además, forzamos crossfadeTarget_ a 0 temporalmente para que si
        // el underrun persiste varios bloques, el gain baje gradualmente
        // (no se quede en 1.0 intentando mezclar wet que no existe).
        const float savedTarget = crossfadeTarget_;
        // Step rápido de underrun: 5 ms (~80 samples @ 16 kHz, ~240 @ 48 kHz).
        // Más rápido que el crossfade normal (50 ms) pero sin ser instantáneo.
        const float kUnderrunStep = 1.0f / (0.005f * static_cast<float>(
            impl_->inputSr > 0 ? impl_->inputSr : 16000));

        const float userIntensity = intensity_.load(std::memory_order_acquire);
        const bool  vadActive     = voiceActive_.load(std::memory_order_acquire);
        const float voiceCap      = voiceCap_.load(std::memory_order_acquire);
        const float target        = vadActive ? std::min(userIntensity, voiceCap)
                                              : userIntensity;

        for (int i = 0; i < blockSize; ++i) {
            // Bajar crossfadeGain_ rápidamente hacia 0 durante underrun.
            if (crossfadeGain_ > 0.0f) {
                crossfadeGain_ = std::max(0.0f, crossfadeGain_ - kUnderrunStep);
            }

            // Rampa de effectiveIntensity_ sigue avanzando.
            if (effectiveIntensity_ > target) {
                effectiveIntensity_ = std::max(target,
                    effectiveIntensity_ - (stepAttackPerSample_ > 0.0f
                        ? stepAttackPerSample_ : 1.0f));
            } else if (effectiveIntensity_ < target) {
                effectiveIntensity_ = std::min(target,
                    effectiveIntensity_ + (stepReleasePerSample_ > 0.0f
                        ? stepReleasePerSample_ : 1.0f));
            }

            const float dnnAmount = crossfadeGain_ * effectiveIntensity_;
            const float drySample = (gotDry > i) ? dry[i] : buffer[i];

            float mixed;
            if (i < wetWritten) {
                // Usar wet parcial disponible para suavizar la transición.
                mixed = drySample * (1.0f - dnnAmount)
                      + impl_->wetNativeRate[i] * dnnAmount;
            } else {
                // Sin wet: salida es dry puro (dnnAmount ya baja a 0).
                mixed = drySample;
            }
            buffer[i] = std::max(-1.0f, std::min(1.0f, mixed));
        }

        // Restaurar target para que el siguiente bloque (si ya no hay
        // underrun) vuelva a subir el crossfade normalmente.
        crossfadeTarget_ = savedTarget;

        if (wetWritten > 0) {
            droppedFrames_.fetch_add(1, std::memory_order_relaxed);
        }

        effectiveIntensityAtomic_.store(effectiveIntensity_,
                                        std::memory_order_release);
        return;
    }

    // ── Etapa 5: mezcla normal dry ↔ wet con intensity, crossfade y VAD cap ────
    //
    // Spec dnn-voice-level-recovery (Paso 1):
    //   - userIntensity      : valor del slider del usuario (R1.4, transparente).
    //   - voiceActive        : feedback del VAD del bloque anterior, vía
    //                          notifyVoiceActive (R1.1, R1.2).
    //   - target             : userIntensity capeado a voiceCap_ si hay voz.
    //   - effectiveIntensity_: rampa asimétrica per-sample hacia target.
    //
    // La modulación NO viola el invariante "DNN solo atenúa": bajar
    // effectiveIntensity_ aumenta el peso del dry; nunca amplifica (R1.7).
    const float userIntensity = intensity_.load(std::memory_order_acquire);
    const bool  vadActive     = voiceActive_.load(std::memory_order_acquire);
    const float voiceCap      = voiceCap_.load(std::memory_order_acquire);
    const float target        = vadActive ? std::min(userIntensity, voiceCap)
                                          : userIntensity;
    // Pasos defensivos: si setInputSampleRate aún no corrió, los pasos son 0
    // y la rampa degenera en step instantáneo (effectiveIntensity_ salta a target).
    const float stepAttack  = stepAttackPerSample_;
    const float stepRelease = stepReleasePerSample_;

    for (int i = 0; i < blockSize; ++i) {
        // Avanzar crossfade un sample.
        if (crossfadeGain_ < crossfadeTarget_) {
            crossfadeGain_ = std::min(crossfadeTarget_,
                                      crossfadeGain_ + kCrossfadeStep);
        } else if (crossfadeGain_ > crossfadeTarget_) {
            crossfadeGain_ = std::max(crossfadeTarget_,
                                      crossfadeGain_ - kCrossfadeStep);
        }

        // Rampa asimétrica del effectiveIntensity_ hacia target (R1.3, R1.5).
        // Bajar = attack rápido; subir = release lento.
        if (effectiveIntensity_ > target) {
            if (stepAttack <= 0.0f) {
                effectiveIntensity_ = target;
            } else {
                effectiveIntensity_ -= stepAttack;
                if (effectiveIntensity_ < target) effectiveIntensity_ = target;
            }
        } else if (effectiveIntensity_ < target) {
            if (stepRelease <= 0.0f) {
                effectiveIntensity_ = target;
            } else {
                effectiveIntensity_ += stepRelease;
                if (effectiveIntensity_ > target) effectiveIntensity_ = target;
            }
        }

        // Mezcla: amount of DNN = crossfadeGain_ * effectiveIntensity_.
        const float dnnAmount = crossfadeGain_ * effectiveIntensity_;
        const float drySample = (gotDry > i) ? dry[i] : buffer[i];
        const float mixed     = drySample * (1.0f - dnnAmount)
                              + impl_->wetNativeRate[i] * dnnAmount;

        // Clamp ±1.0 por seguridad.
        buffer[i] = std::max(-1.0f, std::min(1.0f, mixed));
    }

    // Espejar el effective al atomic para getEffectiveIntensity() (R2.1).
    effectiveIntensityAtomic_.store(effectiveIntensity_,
                                    std::memory_order_release);

    // Espejar contadores al wrapper público.
    processedFrames_.store(impl_->processedFramesLocal.load(std::memory_order_relaxed),
                            std::memory_order_relaxed);
    droppedFrames_.store(impl_->droppedFramesLocal.load(std::memory_order_relaxed) +
                            droppedFrames_.load(std::memory_order_relaxed),
                            std::memory_order_relaxed);
    lastInferenceUs_.store(impl_->lastInferenceUsLocal.load(std::memory_order_relaxed),
                            std::memory_order_relaxed);
}

void DnnDenoiser::processStereo(const float* ch0, const float* ch1,
                                float* output, int blockSize) {
    if (ch0 == nullptr || ch1 == nullptr || output == nullptr || blockSize <= 0) {
        return;
    }

    // Bypass = ch0 passthrough (respeta el aliasing output==ch0 sin memcpy UB).
    auto passthroughCh0 = [&]() {
        if (output != ch0) {
            std::memcpy(output, ch0, static_cast<size_t>(blockSize) * sizeof(float));
        }
    };

    const bool en   = enabled_.load(std::memory_order_acquire);
    const bool act  = active_.load(std::memory_order_acquire);
    const bool dual = (impl_->channels.load(std::memory_order_acquire) == 2);

    // Fast path bypass: sin enable (y crossfade ya en 0), o modelo no dual.
    // El modo mono no puede procesar estéreo → ch0 passthrough (R4.5).
    if (!dual || (!en && crossfadeGain_ <= 0.0f)) {
        passthroughCh0();
        return;
    }

    // Modelo dual pero no activo (falla de carga/inferencia): bypass con
    // crossfade out si veníamos en wet, luego ch0 passthrough (R4.3, R4.4).
    if (!act) {
        crossfadeTarget_ = 0.0f;
        if (crossfadeGain_ > 0.0f) {
            for (int i = 0; i < blockSize; ++i) {
                crossfadeGain_ = std::max(0.0f, crossfadeGain_ - kCrossfadeStep);
            }
        }
        passthroughCh0();
        return;
    }

    crossfadeTarget_ = en ? 1.0f : 0.0f;

    // ── Etapa 1: dry = ch0 → dryDelayRing (samples a rate nativa) ───────
    // ch0 es la señal "dry" de la mezcla dry/wet y del crossfade (tarea 2.6).
    impl_->dryDelayRing.push(ch0, blockSize);

    // ── Etapa 2: DOWNSAMPLE ch0→inputRing y ch1→inputRingCh1 (a 16 kHz) ─
    if (static_cast<int>(impl_->downStaging.size()) < blockSize) {
        impl_->downStaging.assign(blockSize, 0.0f);
    }
    if (static_cast<int>(impl_->downStagingCh1.size()) < blockSize) {
        impl_->downStagingCh1.assign(blockSize, 0.0f);
    }
    const int d0 = impl_->down.process(ch0, blockSize,
                                       impl_->downStaging.data(),
                                       static_cast<int>(impl_->downStaging.size()));
    const int d1 = impl_->downCh1.process(ch1, blockSize,
                                          impl_->downStagingCh1.data(),
                                          static_cast<int>(impl_->downStagingCh1.size()));
    if (d0 > 0) {
        const int pushed0 = impl_->inputRing.push(impl_->downStaging.data(), d0);
        if (pushed0 < d0) droppedFrames_.fetch_add(1, std::memory_order_relaxed);
    }
    if (d1 > 0) {
        const int pushed1 = impl_->inputRingCh1.push(impl_->downStagingCh1.data(), d1);
        if (pushed1 < d1) droppedFrames_.fetch_add(1, std::memory_order_relaxed);
    }
    // Notificar al worker solo cuando ambos canales tienen un frame completo.
    // Both mono and dual paths now use kDnnHopSize for frame-by-frame processing.
    if (impl_->inputRing.available() >= kDnnHopSize &&
        impl_->inputRingCh1.available() >= kDnnHopSize) {
        impl_->workerCv.notify_one();
    }

    // ── Etapa 3: tirar wet @16 kHz del outputRing y UPSAMPLE a inputSr ──
    if (static_cast<int>(impl_->wetNativeRate.size()) < blockSize) {
        impl_->wetNativeRate.assign(blockSize, 0.0f);
    }
    int wetWritten = 0;
    bool underrun  = false;
    while (wetWritten < blockSize) {
        float in16k;
        const int got = impl_->outputRing.pop(&in16k, 1);
        if (got < 1) {
            underrun = true;
            break;
        }
        const int produced = impl_->up.process(
            &in16k, 1,
            impl_->wetNativeRate.data() + wetWritten,
            blockSize - wetWritten);
        wetWritten += produced;
        if (produced == 0) {
            continue;
        }
    }

    // ── Etapa 4: pop dry (=ch0 realineado) @ rate nativa ────────────────
    std::vector<float> dry(blockSize, 0.0f);
    const int gotDry = impl_->dryDelayRing.pop(dry.data(), blockSize);

    if (underrun) {
        // El worker no alcanzó la tasa: salida = ch0 (Bypass_Seguro), avanzar
        // el crossfade y descartar wet parcial.
        for (int i = 0; i < blockSize; ++i) {
            if (crossfadeGain_ < crossfadeTarget_) {
                crossfadeGain_ = std::min(crossfadeTarget_,
                                          crossfadeGain_ + kCrossfadeStep);
            } else if (crossfadeGain_ > crossfadeTarget_) {
                crossfadeGain_ = std::max(crossfadeTarget_,
                                          crossfadeGain_ - kCrossfadeStep);
            }
        }
        if (wetWritten > 0) {
            droppedFrames_.fetch_add(1, std::memory_order_relaxed);
        }
        passthroughCh0();
        return;
    }

    // ── Etapa 5: mezcla dry(ch0) ↔ wet con intensity, crossfade y VAD cap ─
    // Misma máquina que process() (spec dnn-voice-level-recovery), con ch0
    // como señal dry (tarea 2.6). NO amplifica: bajar el amount pesa más ch0.
    const float userIntensity = intensity_.load(std::memory_order_acquire);
    const bool  vadActive     = voiceActive_.load(std::memory_order_acquire);
    const float voiceCap      = voiceCap_.load(std::memory_order_acquire);
    const float target        = vadActive ? std::min(userIntensity, voiceCap)
                                          : userIntensity;
    const float stepAttack  = stepAttackPerSample_;
    const float stepRelease = stepReleasePerSample_;

    for (int i = 0; i < blockSize; ++i) {
        // Avanzar crossfade un sample.
        if (crossfadeGain_ < crossfadeTarget_) {
            crossfadeGain_ = std::min(crossfadeTarget_,
                                      crossfadeGain_ + kCrossfadeStep);
        } else if (crossfadeGain_ > crossfadeTarget_) {
            crossfadeGain_ = std::max(crossfadeTarget_,
                                      crossfadeGain_ - kCrossfadeStep);
        }

        // Rampa asimétrica del effectiveIntensity_ hacia target.
        if (effectiveIntensity_ > target) {
            if (stepAttack <= 0.0f) {
                effectiveIntensity_ = target;
            } else {
                effectiveIntensity_ -= stepAttack;
                if (effectiveIntensity_ < target) effectiveIntensity_ = target;
            }
        } else if (effectiveIntensity_ < target) {
            if (stepRelease <= 0.0f) {
                effectiveIntensity_ = target;
            } else {
                effectiveIntensity_ += stepRelease;
                if (effectiveIntensity_ > target) effectiveIntensity_ = target;
            }
        }

        const float dnnAmount = crossfadeGain_ * effectiveIntensity_;
        const float drySample = (gotDry > i) ? dry[i] : ch0[i];
        const float mixed     = drySample * (1.0f - dnnAmount)
                              + impl_->wetNativeRate[i] * dnnAmount;

        // Clamp ±1.0 por seguridad.
        output[i] = std::max(-1.0f, std::min(1.0f, mixed));
    }

    // Espejar el effective al atomic para getEffectiveIntensity().
    effectiveIntensityAtomic_.store(effectiveIntensity_,
                                    std::memory_order_release);

    // Espejar contadores al wrapper público.
    processedFrames_.store(impl_->processedFramesLocal.load(std::memory_order_relaxed),
                            std::memory_order_relaxed);
    droppedFrames_.store(impl_->droppedFramesLocal.load(std::memory_order_relaxed) +
                            droppedFrames_.load(std::memory_order_relaxed),
                            std::memory_order_relaxed);
    lastInferenceUs_.store(impl_->lastInferenceUsLocal.load(std::memory_order_relaxed),
                            std::memory_order_relaxed);
}

void DnnDenoiser::setEnabled(bool enabled) {
    enabled_.store(enabled, std::memory_order_release);
    DNN_LOGI("setEnabled: %d (active=%d)", enabled ? 1 : 0,
             active_.load(std::memory_order_acquire) ? 1 : 0);
}

void DnnDenoiser::setIntensity(float intensity) {
    if (intensity < 0.0f) intensity = 0.0f;
    if (intensity > 1.0f) intensity = 1.0f;
    intensity_.store(intensity, std::memory_order_release);
}

void DnnDenoiser::notifyVoiceActive(bool active) {
    // Escritura lock-free; el audio thread la consume en `process()` para
    // calcular el target del cap. La rampa propiamente dicha se cablea en
    // la Tarea 2 del spec dnn-voice-level-recovery.
    voiceActive_.store(active, std::memory_order_release);
}

void DnnDenoiser::setVoiceCap(float cap) {
    if (cap < 0.0f) cap = 0.0f;
    if (cap > 1.0f) cap = 1.0f;
    voiceCap_.store(cap, std::memory_order_release);
}

void DnnDenoiser::reset() {
    if (impl_) {
        impl_->resetRequested.store(true, std::memory_order_release);
        impl_->workerCv.notify_one();
        // El audio thread también necesita limpiar el dryDelayRing y los
        // delay-lines del resampler para evitar mezclar samples viejos
        // (de antes del reset) con los nuevos en el siguiente bloque.
        impl_->dryDelayRing.clear();
        impl_->down.reset();
        impl_->downCh1.reset();
        impl_->up.reset();
    }
    crossfadeGain_   = 0.0f;
    crossfadeTarget_ = enabled_.load(std::memory_order_acquire) ? 1.0f : 0.0f;
}

}  // namespace dnn_denoiser

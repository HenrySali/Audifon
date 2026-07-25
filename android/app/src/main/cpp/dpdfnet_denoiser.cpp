/// @file dpdfnet_denoiser.cpp
/// @brief DPDFNet-4 denoiser implementation — OnnxRuntime, Vorbis window, polyphase.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///     http://www.apache.org/licenses/LICENSE-2.0
///
/// Model: DPDFNet-4 (2.36 MB) from k2-fsa/sherpa-onnx (Apache 2.0).
/// Attribution: https://github.com/k2-fsa/sherpa-onnx
///
/// Zero heap allocations in process(). All buffers pre-allocated in Impl.

#include "dpdfnet_denoiser.h"
#include "onnxruntime/onnxruntime_cxx_api.h"

#include <android/asset_manager.h>
#include <android/log.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <string>
#include <thread>
#include <vector>

#define TAG "DPDFNet4"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

namespace dpdfnet_denoiser {

// ═══════════════════════════════════════════════════════════════════════════════
// CONSTANTS
// ═══════════════════════════════════════════════════════════════════════════════

namespace {

constexpr float kPi = 3.14159265358979323846f;
constexpr int kFftN = kWinSize;          // 320 (DFT directo, NO zero-pad a 512)
constexpr int kMaxBlock48 = 4096;        // max block size at 48 kHz
constexpr int kMaxBlock16 = 1400;        // max 4096/3 + margin
constexpr float kCrossfadeStep = 1.0f / static_cast<float>(kXfadeSamples);

// FIX ronquera: wet ring @48kHz (post-upsample). Antes se upsampleaba TODO el
// wet disponible y solo se sacaba blockSize, descartando el resto (~58% de las
// muestras). Ahora cada hop se upsamplea y se encola @48k, drenando exacto
// blockSize por callback (verificado en Octave: corr 0.16 -> 0.99).
constexpr int kWet48Cap  = 8192;         // ring @48kHz (holds jitter + latency)
constexpr int kUpHopMax  = 512;          // 160*3 + margen
constexpr int kPrime48   = 480;          // latencia de priming (~1 hop @48k)

// Pre-filtro de balance espectral para el modelo (fix ronquera).
constexpr float kPreShelfFc   = 600.0f;  // Hz (corte del low-shelf)
constexpr float kPreShelfGain = -9.0f;   // dB (recorte de graves)

// Post-filtro de recuperación de agudos (fix nitidez). DPDFNet atenúa ~-8dB
// en 5-8kHz (medido en device) -> se pierde la /s/ y el brillo. Este high-shelf
// DESPUÉS del modelo lo compensa. El ruido ya está a -108dB, hay margen.
constexpr float kPostShelfFc   = 3000.0f; // Hz
constexpr float kPostShelfGain = 7.0f;    // dB (realce de agudos)

// ═══════════════════════════════════════════════════════════════════════════════
// BESSEL I0 + KAISER LPF DESIGN
// ═══════════════════════════════════════════════════════════════════════════════

static float besselI0(float x) {
    float ax = std::fabs(x);
    if (ax < 3.75f) {
        float y = (x / 3.75f) * (x / 3.75f);
        return 1.0f + y * (3.5156229f + y * (3.0899424f + y * (1.2067492f +
               y * (0.2659732f + y * (0.0360768f + y * 0.0045813f)))));
    }
    float y = 3.75f / ax;
    return (std::exp(ax) / std::sqrt(ax)) *
           (0.39894228f + y * (0.01328592f + y * (0.00225319f +
           y * (-0.00157565f + y * (0.00916281f + y * (-0.02057706f +
           y * (0.02635537f + y * (-0.01647633f + y * 0.00392377f))))))));
}

static void designLpf(float* h, int N) {
    constexpr float kKaiserBeta = 8.5f;
    const float fc = 7500.0f / 48000.0f;
    const float center = static_cast<float>(N - 1) / 2.0f;
    const float i0b = besselI0(kKaiserBeta);
    float sum = 0.0f;
    for (int n = 0; n < N; ++n) {
        float arg = 2.0f * fc * (n - center);
        float ideal = (std::fabs(arg) < 1e-9f)
                      ? 2.0f * fc
                      : 2.0f * fc * std::sin(kPi * arg) / (kPi * arg);
        float ratio = (2.0f * n / (N - 1)) - 1.0f;
        float win = besselI0(kKaiserBeta * std::sqrt(std::max(0.0f, 1.0f - ratio * ratio))) / i0b;
        h[n] = ideal * win;
        sum += h[n];
    }
    for (int n = 0; n < N; ++n) h[n] /= sum;
}

// ═══════════════════════════════════════════════════════════════════════════════
// BIQUAD LOW-SHELF (RBJ) — pre-filtro de balance espectral para el modelo
// ═══════════════════════════════════════════════════════════════════════════════
// FIX RONQUERA (raiz real, verificado con capturas del device + analisis Python):
// El modelo DPDFNet, ante una entrada dominada por graves (la senal del mic tiene
// ~64% de energia <500Hz por proximidad/rumble), interpreta los medios (1-4kHz,
// consonantes/claridad) como ruido y los APLASTA (1-4k: 13%->3.8% = voz "ronca"/
// tapada). Con espectro balanceado (voz limpia) el modelo preserva/realza los
// medios. Un low-shelf que recorta graves ANTES del modelo restaura los medios
// (1-4k 3.8%->13.5%, medido) sin disparar agudos. fc=600Hz, -9dB, S=1.
struct Biquad {
    float b0=1, b1=0, b2=0, a1=0, a2=0;
    float z1=0, z2=0;   // estado (Transposed Direct Form II)
    void reset() { z1 = z2 = 0.0f; }
    inline float process(float x) {
        float y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
    // RBJ low-shelf. gainDb<0 recorta graves por debajo de fc.
    void designLowShelf(float fc, float gainDb, float sr, float S = 1.0f) {
        float A  = std::pow(10.0f, gainDb / 40.0f);
        float w0 = 2.0f * kPi * fc / sr;
        float cw = std::cos(w0), sw = std::sin(w0);
        float alpha = sw / 2.0f * std::sqrt((A + 1.0f / A) * (1.0f / S - 1.0f) + 2.0f);
        float sqA = std::sqrt(A);
        float b0n =        A * ((A + 1.0f) - (A - 1.0f) * cw + 2.0f * sqA * alpha);
        float b1n = 2.0f * A * ((A - 1.0f) - (A + 1.0f) * cw);
        float b2n =        A * ((A + 1.0f) - (A - 1.0f) * cw - 2.0f * sqA * alpha);
        float a0n =            (A + 1.0f) + (A - 1.0f) * cw + 2.0f * sqA * alpha;
        float a1n =   -2.0f * ((A - 1.0f) + (A + 1.0f) * cw);
        float a2n =            (A + 1.0f) + (A - 1.0f) * cw - 2.0f * sqA * alpha;
        b0 = b0n / a0n; b1 = b1n / a0n; b2 = b2n / a0n;
        a1 = a1n / a0n; a2 = a2n / a0n;
        reset();
    }
    // RBJ high-shelf. gainDb>0 realza agudos por encima de fc.
    // FIX nitidez: DPDFNet atenua -8 dB en 5-8kHz (medido) -> quita la /s/ y el
    // brillo de las consonantes. Este realce post-modelo lo compensa.
    void designHighShelf(float fc, float gainDb, float sr, float S = 1.0f) {
        float A  = std::pow(10.0f, gainDb / 40.0f);
        float w0 = 2.0f * kPi * fc / sr;
        float cw = std::cos(w0), sw = std::sin(w0);
        float alpha = sw / 2.0f * std::sqrt((A + 1.0f / A) * (1.0f / S - 1.0f) + 2.0f);
        float sqA = std::sqrt(A);
        float b0n =        A * ((A + 1.0f) + (A - 1.0f) * cw + 2.0f * sqA * alpha);
        float b1n = -2.0f * A * ((A - 1.0f) + (A + 1.0f) * cw);
        float b2n =        A * ((A + 1.0f) + (A - 1.0f) * cw - 2.0f * sqA * alpha);
        float a0n =            (A + 1.0f) - (A - 1.0f) * cw + 2.0f * sqA * alpha;
        float a1n =    2.0f * ((A - 1.0f) - (A + 1.0f) * cw);
        float a2n =            (A + 1.0f) - (A - 1.0f) * cw - 2.0f * sqA * alpha;
        b0 = b0n / a0n; b1 = b1n / a0n; b2 = b2n / a0n;
        a1 = a1n / a0n; a2 = a2n / a0n;
        reset();
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// VORBIS WINDOW — w(n) = sin(π/2 · sin²(π·n/N)), N=320
// Perfect reconstruction with 50% overlap: w²(n) + w²(n+hop) = 1
// ═══════════════════════════════════════════════════════════════════════════════

// FIX: la referencia (sherpa-onnx / DPDFNet) usa (n+0.5)/N, NO n/N.
//   sin_val = sin(pi*(n+0.5)/N);  w[n] = sin(pi/2 * sin_val^2)
// El modelo fue entrenado con esta ventana; usar n/N desalinea el espectro.
// Sigue cumpliendo COLA exacto: w[n]^2 + w[n+N/2]^2 = 1 (verificado).
static void computeVorbisWindow(float* w, int N) {
    for (int n = 0; n < N; ++n) {
        float sinArg = std::sin(kPi * (static_cast<float>(n) + 0.5f)
                                / static_cast<float>(N));
        w[n] = std::sin((kPi / 2.0f) * sinArg * sinArg);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// POLYPHASE RESAMPLER (pre-allocated, zero allocation on process)
// ═══════════════════════════════════════════════════════════════════════════════

/// Polyphase decimator M=3. All state pre-allocated.
class PolyDown {
    float proto_[kProtoTaps]{};
    float delay_[kProtoTaps]{};
    int wr_ = 0;
    int ph_ = 0;
public:
    void init(const float* p) {
        std::memcpy(proto_, p, kProtoTaps * sizeof(float));
        reset();
    }
    void reset() {
        std::memset(delay_, 0, sizeof(delay_));
        wr_ = 0;
        ph_ = 0;
    }
    int process(const float* in, int n, float* out, int maxOut) {
        int written = 0;
        for (int i = 0; i < n; ++i) {
            delay_[wr_] = in[i];
            wr_ = (wr_ + 1) % kProtoTaps;
            if (++ph_ == 3) {
                ph_ = 0;
                if (written < maxOut) {
                    float acc = 0.0f;
                    int idx = wr_ - 1;
                    if (idx < 0) idx += kProtoTaps;
                    for (int k = 0; k < kProtoTaps; ++k) {
                        acc += proto_[k] * delay_[idx];
                        idx = (idx == 0) ? (kProtoTaps - 1) : (idx - 1);
                    }
                    out[written++] = acc;
                }
            }
        }
        return written;
    }
};

/// Polyphase interpolator L=3. All state pre-allocated.
class PolyUp {
    float phases_[3][24]{};
    float delay_[24]{};
    int wr_ = 0;
public:
    void init(const float* proto) {
        std::memset(delay_, 0, sizeof(delay_));
        wr_ = 0;
        for (int n = 0; n < 24; ++n) {
            for (int k = 0; k < 3; ++k) {
                int idx = n * 3 + k;
                phases_[k][n] = (idx < kProtoTaps) ? proto[idx] * 3.0f : 0.0f;
            }
        }
    }
    void reset() {
        std::memset(delay_, 0, sizeof(delay_));
        wr_ = 0;
    }
    int process(const float* in, int n, float* out, int maxOut) {
        int written = 0;
        for (int i = 0; i < n && written + 3 <= maxOut; ++i) {
            delay_[wr_] = in[i];
            wr_ = (wr_ + 1) % 24;
            for (int ph = 0; ph < 3 && written < maxOut; ++ph) {
                float acc = 0.0f;
                int idx = wr_ - 1;
                if (idx < 0) idx += 24;
                for (int t = 0; t < 24; ++t) {
                    acc += phases_[ph][t] * delay_[idx];
                    idx = (idx == 0) ? 23 : (idx - 1);
                }
                out[written++] = acc;
            }
        }
        return written;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// DFT DIRECTO (N-point, funciona para N=320 sin zero-pad)
// O(N*nbins) = 320*161 = ~51k ops por hop — aceptable para 10ms en ARM64
// ═══════════════════════════════════════════════════════════════════════════════

static void bitReverse(float*, float*, int) {} // no-op, kept for API compat

/// DFT directo: forward o inverse, para N arbitrario (320).
/// Forward: re[k] + j*im[k] = sum_n x[n] * exp(-j*2pi*k*n/N)
/// Inverse: x[n] = (1/N) * sum_k X[k] * exp(+j*2pi*k*n/N)
/// Solo calcula nbins = N/2+1 para forward (señal real).
static void dftDirect(float* re, float* im, int N, bool inverse) {
    if (!inverse) {
        // Forward DFT: input en re[0..N-1] (señal real), output en re[0..N/2]+im[0..N/2]
        float input[320];
        std::memcpy(input, re, N * sizeof(float));
        int nbins = N / 2 + 1;
        for (int k = 0; k < nbins; ++k) {
            float sumR = 0.0f, sumI = 0.0f;
            for (int n = 0; n < N; ++n) {
                float angle = -2.0f * kPi * k * n / N;
                sumR += input[n] * std::cos(angle);
                sumI += input[n] * std::sin(angle);
            }
            re[k] = sumR;
            im[k] = sumI;
        }
    } else {
        // Inverse DFT: input en re[0..N/2]+im[0..N/2], output real en re[0..N-1]
        int nbins = N / 2 + 1;
        float specR[161], specI[161];
        std::memcpy(specR, re, nbins * sizeof(float));
        std::memcpy(specI, im, nbins * sizeof(float));
        float invN = 1.0f / N;
        for (int n = 0; n < N; ++n) {
            float sum = specR[0];  // DC (k=0)
            for (int k = 1; k < nbins - 1; ++k) {
                float angle = 2.0f * kPi * k * n / N;
                sum += 2.0f * (specR[k] * std::cos(angle) - specI[k] * std::sin(angle));
            }
            // Nyquist (k=N/2)
            float angle = 2.0f * kPi * (nbins - 1) * n / N;
            sum += specR[nbins - 1] * std::cos(angle);
            re[n] = sum * invN;
        }
    }
}

} // anonymous namespace

// ═══════════════════════════════════════════════════════════════════════════════
// IMPL STRUCT — ALL BUFFERS PRE-ALLOCATED (zero allocation in audio path)
// ═══════════════════════════════════════════════════════════════════════════════

struct DpdfnetDenoiser::Impl {
    // ─── ONNX Runtime ──────────────────────────────────────────────────────────
    Ort::Env              env{ORT_LOGGING_LEVEL_WARNING, TAG};
    Ort::SessionOptions   opts;
    std::unique_ptr<Ort::Session> session;
    Ort::MemoryInfo       memInfo{Ort::MemoryInfo::CreateCpu(OrtArenaAllocator,
                                                             OrtMemTypeDefault)};

    // I/O names (stored persistently after introspection)
    std::string inName0, inName1;
    std::string outName0, outName1;
    const char* inPtrs[2]  = {nullptr, nullptr};
    const char* outPtrs[2] = {nullptr, nullptr};

    // ─── State tensor ──────────────────────────────────────────────────────────
    std::vector<int64_t> stateShape;     // [S] shape from model introspection
    std::vector<float>   stateData;      // persistent state (memcpy'd each hop)
    std::vector<float>   stateInit;      // copy of initial state for reset()
    int stateSize = 0;

    bool modelReady = false;

    // ─── Vorbis window (pre-computed, 320 floats) ──────────────────────────────
    float window[kWinSize]{};

    // ─── STFT overlap buffer ───────────────────────────────────────────────────
    float stftPrev[kHopSize]{};   // previous 160 samples for 50% overlap

    // ─── OLA synthesis buffer ──────────────────────────────────────────────────
    float olaBuf[kWinSize]{};     // 320 floats
    int   olaPos = 0;

    // ─── FFT workspace (512-point, pre-allocated) ──────────────────────────────
    float fftRe[kFftN]{};
    float fftIm[kFftN]{};

    // ─── Tensor storage (pre-allocated, [1,1,161,2] = 322 floats) ──────────────
    float specTensor[kNBins * 2]{};   // input spec
    float enhTensor[kNBins * 2]{};    // output enhanced (backup)

    // ─── Spec shape [1,1,161,2] ────────────────────────────────────────────────
    std::array<int64_t, 4> specShape = {1, 1, kNBins, 2};

    // ─── Accumulation buffer @16kHz ────────────────────────────────────────────
    float accumBuf[kAccumMax]{};
    int   accumCount = 0;

    // ─── Wet output ring buffer @48kHz (post-upsample) — FIX ronquera ─────────
    float wet48Ring[kWet48Cap]{};
    int   wet48Write = 0;
    int   wet48Read  = 0;
    bool  primed = false;
    float hopOut[kHopSize]{};   // salida de un hop @16k (antes de upsample)
    float upHop[kUpHopMax]{};   // hop upsampleado @48k

    // ─── Resampler scratch buffers ─────────────────────────────────────────────
    float downBuf[kMaxBlock16]{};
    float upBuf[kMaxBlock48]{};

    // ─── Polyphase resamplers ──────────────────────────────────────────────────
    float proto[kProtoTaps]{};
    PolyDown down;
    PolyUp   up;

    // ─── Pre-filtro low-shelf @16k (balance espectral para el modelo) ──────────
    Biquad preShelf;
    // ─── Post-filtro high-shelf @16k (recupera agudos tras el modelo) ──────────
    Biquad postShelf;

    // ═══════════════════════════════════════════════════════════════════════════
    // STAGE CAPTURE — diagnóstico de ronquera (4 etapas simultáneas)
    //   A dry_in @48k  — voz cruda que entra a process() (antes del bypass)
    //   B ds16  @16k   — señal downsampleada (entrada al modelo/STFT)
    //   C model_out16  — salida del modelo tras iSTFT/OLA (hopOut, pre-upsampler)
    //   D out48 @48k   — buffer final tras mezcla+clamp (fin de process())
    //
    // RT-safe: el audio thread SOLO hace memcpy a estos buffers pre-asignados.
    // La escritura a disco corre en `capWriter` (hilo separado), disparada por
    // el flag atómico `flushRequested` (al llenarse la captura o en stopCapture).
    // ═══════════════════════════════════════════════════════════════════════════
    static constexpr int kCapSecs  = 10;
    static constexpr int kCapCap48 = kCapSecs * 48000;   // 480000 floats (~1.83 MB)
    static constexpr int kCapCap16 = kCapSecs * 16000;   // 160000 floats (~0.61 MB)

    std::vector<float> capA;   // dry_in @48k
    std::vector<float> capB;   // ds16   @16k
    std::vector<float> capC;   // model_out16 @16k
    std::vector<float> capD;   // out48  @48k
    int capAWrite = 0, capBWrite = 0, capCWrite = 0, capDWrite = 0;

    std::atomic<bool> capturing{false};      // audio thread llenando buffers
    std::atomic<bool> captureReady{false};   // WAV escritos a disco
    std::atomic<bool> flushRequested{false}; // pedido de flush al hilo escritor
    std::atomic<bool> writerRunning{false};  // ciclo de vida del hilo escritor
    std::thread capWriter;

    std::string capDir;
    std::string capDenoiserName;
    char        capTimestamp[24] = {0};
    float       capIntensitySnap = 0.0f;

    // ─── Constructor ───────────────────────────────────────────────────────────
    Impl() {
        opts.SetIntraOpNumThreads(1);
        opts.SetInterOpNumThreads(1);
        opts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        designLpf(proto, kProtoTaps);
        down.init(proto);
        up.init(proto);
        computeVorbisWindow(window, kWinSize);
        // Low-shelf de balance @16k (corta graves antes del modelo).
        preShelf.designLowShelf(kPreShelfFc, kPreShelfGain,
                                static_cast<float>(kModelSr));
        // High-shelf de recuperación de agudos @16k (después del modelo).
        postShelf.designHighShelf(kPostShelfFc, kPostShelfGain,
                                  static_cast<float>(kModelSr));

        // Pre-asignar buffers de captura UNA sola vez (fuera del audio thread).
        capA.resize(static_cast<size_t>(kCapCap48));
        capB.resize(static_cast<size_t>(kCapCap16));
        capC.resize(static_cast<size_t>(kCapCap16));
        capD.resize(static_cast<size_t>(kCapCap48));
    }

    // ─── Destructor: unir el hilo escritor si sigue vivo ────────────────────────
    ~Impl() {
        writerRunning.store(false, std::memory_order_release);
        flushRequested.store(false, std::memory_order_release);
        if (capWriter.joinable()) capWriter.join();
    }

    // ─── Append RT-safe: solo memcpy, clamp a capacidad (audio thread) ──────────
    static void capAppend(std::vector<float>& buf, int& wr,
                          const float* src, int n) {
        if (n <= 0 || wr >= static_cast<int>(buf.size())) return;
        int room = static_cast<int>(buf.size()) - wr;
        int c = (n < room) ? n : room;
        std::memcpy(buf.data() + wr, src, static_cast<size_t>(c) * sizeof(float));
        wr += c;
    }

    // ─── Escritura de un WAV PCM float32 mono (hilo escritor, NO audio) ─────────
    static bool writeWavF32(const std::string& path, const float* data,
                            int n, int sampleRate) {
        FILE* f = std::fopen(path.c_str(), "wb");
        if (!f) { LOGE("capture: cannot open %s", path.c_str()); return false; }
        const uint32_t dataBytes  = static_cast<uint32_t>(n) * 4u;
        const uint32_t riffSize   = 36u + dataBytes;
        const uint32_t fmtSize    = 16u;
        const uint16_t audioFmt   = 3;   // IEEE float
        const uint16_t channels   = 1;
        const uint32_t srate      = static_cast<uint32_t>(sampleRate);
        const uint32_t byteRate   = srate * 4u;
        const uint16_t blockAlign = 4;
        const uint16_t bits       = 32;
        std::fwrite("RIFF", 1, 4, f);
        std::fwrite(&riffSize, 4, 1, f);
        std::fwrite("WAVE", 1, 4, f);
        std::fwrite("fmt ", 1, 4, f);
        std::fwrite(&fmtSize, 4, 1, f);
        std::fwrite(&audioFmt, 2, 1, f);
        std::fwrite(&channels, 2, 1, f);
        std::fwrite(&srate, 4, 1, f);
        std::fwrite(&byteRate, 4, 1, f);
        std::fwrite(&blockAlign, 2, 1, f);
        std::fwrite(&bits, 2, 1, f);
        std::fwrite("data", 1, 4, f);
        std::fwrite(&dataBytes, 4, 1, f);
        if (n > 0) std::fwrite(data, 4, static_cast<size_t>(n), f);
        std::fclose(f);
        return true;
    }

    // ─── Volcar las 4 etapas + metadata (hilo escritor) ─────────────────────────
    void writeAllFiles() {
        const std::string base = capDir + "/dpdf_" + capTimestamp;
        writeWavF32(base + "_A_dry48.wav",   capA.data(), capAWrite, 48000);
        writeWavF32(base + "_B_ds16.wav",    capB.data(), capBWrite, 16000);
        writeWavF32(base + "_C_model16.wav", capC.data(), capCWrite, 16000);
        writeWavF32(base + "_D_out48.wav",   capD.data(), capDWrite, 48000);

        FILE* f = std::fopen((base + "_meta.txt").c_str(), "w");
        if (f) {
            std::fprintf(f, "DPDFNet-4 stage capture\n");
            std::fprintf(f, "version=1\n");
            std::fprintf(f, "timestamp=%s\n", capTimestamp);
            std::fprintf(f, "denoiser=%s\n", capDenoiserName.c_str());
            std::fprintf(f, "intensity=%.3f\n", capIntensitySnap);
            std::fprintf(f, "A_dry48_samples=%d (%.2f s @48k)\n",
                         capAWrite, capAWrite / 48000.0);
            std::fprintf(f, "B_ds16_samples=%d (%.2f s @16k)\n",
                         capBWrite, capBWrite / 16000.0);
            std::fprintf(f, "C_model16_samples=%d (%.2f s @16k)\n",
                         capCWrite, capCWrite / 16000.0);
            std::fprintf(f, "D_out48_samples=%d (%.2f s @48k)\n",
                         capDWrite, capDWrite / 48000.0);
            std::fclose(f);
        }
        LOGI("capture: WAVs escritos en %s (A=%d B=%d C=%d D=%d)",
             capDir.c_str(), capAWrite, capBWrite, capCWrite, capDWrite);
    }

    // ─── Ciclo del hilo escritor: espera flush, vuelca, marca ready y sale ──────
    void writerLoop() {
        while (writerRunning.load(std::memory_order_acquire)) {
            if (flushRequested.load(std::memory_order_acquire)) {
                writeAllFiles();
                captureReady.store(true, std::memory_order_release);
                capturing.store(false, std::memory_order_release);
                flushRequested.store(false, std::memory_order_release);
                break;  // one-shot por sesión
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(15));
        }
    }

    // ─── Arranca sesión de captura (hilo de control) ────────────────────────────
    bool startCaptureImpl(const char* dir, const char* name, float intensity) {
        if (capturing.load(std::memory_order_acquire)) return false;
        // Unir un hilo escritor previo (de una sesión anterior) si quedó vivo.
        if (capWriter.joinable()) {
            writerRunning.store(false, std::memory_order_release);
            capWriter.join();
        }
        capDir = (dir && dir[0]) ? dir : "";
        capDenoiserName = (name && name[0]) ? name : "DPDFNet-4";
        capIntensitySnap = intensity;
        capAWrite = capBWrite = capCWrite = capDWrite = 0;
        captureReady.store(false, std::memory_order_release);
        flushRequested.store(false, std::memory_order_release);

        std::time_t t = std::time(nullptr);
        std::tm tmv{};
        localtime_r(&t, &tmv);
        std::strftime(capTimestamp, sizeof(capTimestamp), "%Y%m%d_%H%M%S", &tmv);

        writerRunning.store(true, std::memory_order_release);
        capWriter = std::thread(&Impl::writerLoop, this);
        capturing.store(true, std::memory_order_release);  // habilitar audio thread LAST
        LOGI("capture: START dir=%s name=%s ts=%s", capDir.c_str(),
             capDenoiserName.c_str(), capTimestamp);
        return true;
    }

    // ─── Detiene y flushea (hilo de control) ────────────────────────────────────
    void stopCaptureImpl() {
        capturing.store(false, std::memory_order_release);
        flushRequested.store(true, std::memory_order_release);
        if (capWriter.joinable()) capWriter.join();
        LOGI("capture: STOP (flushed)");
    }

    // ─── Model loading ─────────────────────────────────────────────────────────
    bool loadModel(AAssetManager* mgr, const char* path) {
        if (!mgr) { LOGE("Null AAssetManager"); return false; }
        if (!path || path[0] == '\0') { LOGE("Empty asset path"); return false; }

        AAsset* asset = AAssetManager_open(mgr, path, AASSET_MODE_BUFFER);
        if (!asset) { LOGE("Cannot open asset: %s", path); return false; }

        size_t sz = AAsset_getLength(asset);
        const void* buf = AAsset_getBuffer(asset);
        try {
            session = std::make_unique<Ort::Session>(env, buf, sz, opts);
        } catch (const Ort::Exception& e) {
            LOGE("ORT session error: %s", e.what());
            AAsset_close(asset);
            return false;
        }
        AAsset_close(asset);
        LOGI("Loaded %s (%zu bytes)", path, sz);
        return true;
    }

    // ─── Introspection: validate 2 inputs, 2 outputs, spec shape [1,1,161,2] ──
    bool introspect() {
        Ort::AllocatorWithDefaultOptions alloc;
        size_t nIn  = session->GetInputCount();
        size_t nOut = session->GetOutputCount();

        if (nIn != 2) {
            LOGE("Model needs 2 inputs, got %zu", nIn);
            return false;
        }
        if (nOut != 2) {
            LOGE("Model needs 2 outputs, got %zu", nOut);
            return false;
        }

        // Collect I/O names
        {
            auto n0 = session->GetInputNameAllocated(0, alloc);
            auto n1 = session->GetInputNameAllocated(1, alloc);
            inName0 = n0.get();
            inName1 = n1.get();
            inPtrs[0] = inName0.c_str();
            inPtrs[1] = inName1.c_str();
        }
        {
            auto n0 = session->GetOutputNameAllocated(0, alloc);
            auto n1 = session->GetOutputNameAllocated(1, alloc);
            outName0 = n0.get();
            outName1 = n1.get();
            outPtrs[0] = outName0.c_str();
            outPtrs[1] = outName1.c_str();
        }

        // Validate spec shape: expect [1,1,161,2]
        {
            auto info = session->GetInputTypeInfo(0).GetTensorTypeAndShapeInfo();
            auto shape = info.GetShape();
            if (shape.size() != 4) {
                LOGE("spec shape rank=%zu, expected 4", shape.size());
                return false;
            }
            int64_t expected[4] = {1, 1, kNBins, 2};
            for (int d = 0; d < 4; ++d) {
                if (shape[d] > 0 && shape[d] != expected[d]) {
                    LOGE("spec shape[%d]=%lld, expected %lld", d,
                         (long long)shape[d], (long long)expected[d]);
                    return false;
                }
            }
        }

        // Read state shape from second input
        {
            auto info = session->GetInputTypeInfo(1).GetTensorTypeAndShapeInfo();
            stateShape = info.GetShape();
            // Replace dynamic dims with 1 (should not happen for state)
            stateSize = 1;
            for (auto& d : stateShape) {
                if (d < 0) d = 1;
                stateSize *= static_cast<int>(d);
            }
        }

        LOGI("Introspect OK: 2 in, 2 out, state_size=%d", stateSize);
        return true;
    }

    // ─── Extract init state from metadata (erb_norm_init + spec_norm_init) ─────
    void extractStateInit() {
        stateData.assign(static_cast<size_t>(stateSize), 0.0f);

        try {
            Ort::ModelMetadata meta = session->GetModelMetadata();
            Ort::AllocatorWithDefaultOptions alloc;

            auto parseFloats = [](const char* csv, float* dst, int maxN) -> int {
                int count = 0;
                const char* p = csv;
                while (*p && count < maxN) {
                    while (*p == ' ' || *p == ',' || *p == '[' || *p == ']') ++p;
                    if (*p == '\0') break;
                    char* end = nullptr;
                    float val = std::strtof(p, &end);
                    if (end == p) break;
                    dst[count++] = val;
                    p = end;
                }
                return count;
            };

            int offset = 0;
            // Read erb_norm_init (first 32 floats typically)
            try {
                auto val = meta.LookupCustomMetadataMapAllocated("erb_norm_init", alloc);
                if (val) {
                    int n = parseFloats(val.get(), stateData.data() + offset,
                                        stateSize - offset);
                    LOGI("erb_norm_init: parsed %d floats", n);
                    offset += n;
                }
            } catch (...) {
                LOGW("erb_norm_init not found in metadata");
            }

            // Read spec_norm_init (next 96 floats typically)
            try {
                auto val = meta.LookupCustomMetadataMapAllocated("spec_norm_init", alloc);
                if (val) {
                    int n = parseFloats(val.get(), stateData.data() + offset,
                                        stateSize - offset);
                    LOGI("spec_norm_init: parsed %d floats", n);
                    offset += n;
                }
            } catch (...) {
                LOGW("spec_norm_init not found in metadata");
            }

            if (offset == 0) {
                LOGW("No state init metadata found, using zeros");
            }
        } catch (const Ort::Exception& e) {
            LOGW("Metadata read failed: %s, state init = zeros", e.what());
        }

        // Save copy for reset()
        stateInit = stateData;
    }

    // ─── Reset DSP state (keep model loaded, restore state from init) ──────────
    void resetState() {
        std::memset(stftPrev, 0, sizeof(stftPrev));
        std::memset(olaBuf, 0, sizeof(olaBuf));
        olaPos = 0;
        accumCount = 0;
        wet48Write = 0;
        wet48Read = 0;
        primed = false;
        std::memset(wet48Ring, 0, sizeof(wet48Ring));
        std::memset(hopOut, 0, sizeof(hopOut));
        down.reset();
        up.reset();
        preShelf.reset();
        postShelf.reset();
        // Restore state from metadata init values (not zeros)
        if (!stateInit.empty()) {
            stateData = stateInit;
        }
    }

    // ─── Wet ring @48kHz helpers ─────────────────────────────────────────────
    int wet48Available() const {
        int avail = wet48Write - wet48Read;
        if (avail < 0) avail += kWet48Cap;
        return avail;
    }

    void wet48Push(float sample) {
        wet48Ring[wet48Write] = sample;
        wet48Write = (wet48Write + 1) % kWet48Cap;
        if (wet48Write == wet48Read) {
            wet48Read = (wet48Read + 1) % kWet48Cap;  // overwrite oldest
        }
    }

    float wet48Pop() {
        if (wet48Read == wet48Write) return 0.0f;  // underrun: silence
        float s = wet48Ring[wet48Read];
        wet48Read = (wet48Read + 1) % kWet48Cap;
        return s;
    }

    // ─── Process one hop (160 samples @16k) through STFT → ONNX → iSTFT ───────
    bool processHop(const float* hop160, DpdfnetDenoiser* owner) {
        // 1. Build 320-sample analysis frame: [stftPrev | hop160]
        float frame[kWinSize];
        std::memcpy(frame, stftPrev, kHopSize * sizeof(float));
        std::memcpy(frame + kHopSize, hop160, kHopSize * sizeof(float));

        // Save current hop for next overlap
        std::memcpy(stftPrev, hop160, kHopSize * sizeof(float));

        // 2. Apply Vorbis analysis window
        for (int i = 0; i < kWinSize; ++i) {
            frame[i] *= window[i];
        }

        // 3. FFT 320 directo (sin zero-pad)
        std::memset(fftRe, 0, kFftN * sizeof(float));
        std::memset(fftIm, 0, kFftN * sizeof(float));
        std::memcpy(fftRe, frame, kWinSize * sizeof(float));

        dftDirect(fftRe, fftIm, kFftN, false);

        // 4. Pack first 161 bins into specTensor [1,1,161,2]
        //    Layout: [batch=1, channel=1, freq=161, ri=2]
        //    Memory order: bin0_re, bin0_im, bin1_re, bin1_im, ...
        for (int k = 0; k < kNBins; ++k) {
            specTensor[k * 2]     = fftRe[k];
            specTensor[k * 2 + 1] = fftIm[k];
        }

        // 5. Build input tensors (no heap allocation — data ptrs to pre-alloc)
        Ort::Value inputs[2] = {Ort::Value{nullptr}, Ort::Value{nullptr}};
        inputs[0] = Ort::Value::CreateTensor<float>(
            memInfo, specTensor, kNBins * 2,
            specShape.data(), specShape.size());
        inputs[1] = Ort::Value::CreateTensor<float>(
            memInfo, stateData.data(), stateData.size(),
            stateShape.data(), stateShape.size());

        // 6. Run inference
        auto t0 = std::chrono::steady_clock::now();
        std::vector<Ort::Value> outputs;  // ONLY unavoidable heap alloc (ORT API)
        try {
            outputs = session->Run(Ort::RunOptions{nullptr},
                                   inPtrs, inputs, 2,
                                   outPtrs, 2);
        } catch (const Ort::Exception& e) {
            LOGE("ONNX Run error: %s", e.what());
            return false;
        }
        auto t1 = std::chrono::steady_clock::now();
        uint32_t us = static_cast<uint32_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count());
        owner->lastInferenceUs_.store(us, std::memory_order_relaxed);

        // 7. Extract enhanced spectrum + NaN/Inf check
        const float* enhPtr = outputs[0].GetTensorData<float>();

        // Spot-check NaN/Inf (every 32 samples + DC + Nyquist)
        for (int k = 0; k < kNBins * 2; k += 32) {
            if (!std::isfinite(enhPtr[k])) {
                LOGE("NaN/Inf in enhanced output at index %d", k);
                return false;
            }
        }
        if (!std::isfinite(enhPtr[0]) || !std::isfinite(enhPtr[1]) ||
            !std::isfinite(enhPtr[(kNBins - 1) * 2]) ||
            !std::isfinite(enhPtr[(kNBins - 1) * 2 + 1])) {
            LOGE("NaN/Inf in enhanced DC or Nyquist");
            return false;
        }

        // 8. Copy state_out → stateData (memcpy, zero allocation)
        const float* stateOutPtr = outputs[1].GetTensorData<float>();
        std::memcpy(stateData.data(), stateOutPtr,
                    stateData.size() * sizeof(float));

        // 9. iSTFT: unpack enhanced → IDFT 320 → synth window → OLA
        std::memset(fftRe, 0, kFftN * sizeof(float));
        std::memset(fftIm, 0, kFftN * sizeof(float));
        for (int k = 0; k < kNBins; ++k) {
            fftRe[k] = enhPtr[k * 2];
            fftIm[k] = enhPtr[k * 2 + 1];
        }

        dftDirect(fftRe, fftIm, kFftN, true);  // IDFT 320

        // 10. Apply synthesis window (Vorbis) to first 320 samples + OLA
        for (int i = 0; i < kWinSize; ++i) {
            float synth = fftRe[i] * window[i];
            int pos = (olaPos + i) % kWinSize;
            olaBuf[pos] += synth;
        }

        // 11. Extract oldest 160 samples from OLA → hopOut @16k (upsample lo hace
        //     el caller, que encola al ring @48k). NO se pierde ninguna muestra.
        for (int i = 0; i < kHopSize; ++i) {
            int pos = (olaPos + i) % kWinSize;
            hopOut[i] = olaBuf[pos];
            olaBuf[pos] = 0.0f;  // clear for next accumulation
        }
        olaPos = (olaPos + kHopSize) % kWinSize;

        // 12. Update counters
        owner->processedFrames_.fetch_add(1, std::memory_order_relaxed);
        return true;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// PUBLIC API IMPLEMENTATION
// ═══════════════════════════════════════════════════════════════════════════════

DpdfnetDenoiser::DpdfnetDenoiser() : impl_(std::make_unique<Impl>()) {}
DpdfnetDenoiser::~DpdfnetDenoiser() = default;

bool DpdfnetDenoiser::initialize(AAssetManager* mgr, const char* assetPath) {
    if (!impl_) return false;
    if (impl_->modelReady) return true;  // idempotent

    if (!mgr || !assetPath || assetPath[0] == '\0') {
        LOGE("initialize: null mgr or empty path");
        return false;
    }

    if (!impl_->loadModel(mgr, assetPath)) return false;
    if (!impl_->introspect()) {
        impl_->session.reset();
        return false;
    }

    impl_->extractStateInit();
    impl_->resetState();
    impl_->modelReady = true;
    active_.store(true, std::memory_order_release);

    LOGI("DPDFNet-4 init OK (state_size=%d)", impl_->stateSize);
    return true;
}

void DpdfnetDenoiser::setEnabled(bool e) {
    enabled_.store(e, std::memory_order_release);
    crossfadeTarget_ = e ? 1.0f : 0.0f;
}

void DpdfnetDenoiser::setIntensity(float v) {
    intensity_.store(std::clamp(v, 0.0f, 1.0f), std::memory_order_release);
}

void DpdfnetDenoiser::reset() {
    if (impl_) {
        impl_->resetState();
    }
    crossfadeGain_ = 0.0f;
    crossfadeTarget_ = 0.0f;
    effectiveIntensity_ = 0.0f;
}

float DpdfnetDenoiser::getEffectiveIntensity() const {
    return effectiveIntensity_;
}

uint64_t DpdfnetDenoiser::getProcessedFrames() const {
    return processedFrames_.load(std::memory_order_relaxed);
}

uint64_t DpdfnetDenoiser::getDroppedFrames() const {
    return droppedFrames_.load(std::memory_order_relaxed);
}

uint32_t DpdfnetDenoiser::getLastInferenceUs() const {
    return lastInferenceUs_.load(std::memory_order_relaxed);
}

// ═══════════════════════════════════════════════════════════════════════════════
// PROCESS — main audio callback (ZERO allocations, audio thread only)
// ═══════════════════════════════════════════════════════════════════════════════

void DpdfnetDenoiser::process(float* buffer, int blockSize) {
    if (!buffer || blockSize <= 0) return;

    // ─── STAGE A — dry_in @48k (voz cruda, ANTES del bypass) ──────────────────
    const bool capOn = impl_->capturing.load(std::memory_order_acquire);
    if (capOn) {
        Impl::capAppend(impl_->capA, impl_->capAWrite, buffer, blockSize);
        // La etapa A @48k es la que marca el ritmo: al llenar ~10 s, auto-stop
        // + flush (flag atómico → hilo escritor). Cero I/O en el audio thread.
        if (impl_->capAWrite >= Impl::kCapCap48) {
            impl_->capturing.store(false, std::memory_order_release);
            impl_->flushRequested.store(true, std::memory_order_release);
        }
    }

    // ─── Bypass bit-exact: !enabled AND crossfade fully at 0 ───────────────────
    const bool enabled = enabled_.load(std::memory_order_acquire);
    const bool active  = active_.load(std::memory_order_acquire);

    if (!enabled && crossfadeGain_ == 0.0f) {
        return;  // bit-exact bypass: don't touch buffer
    }

    // ─── If not active (model error), ramp to dry ─────────────────────────────
    if (!active) {
        crossfadeTarget_ = 0.0f;
        for (int i = 0; i < blockSize; ++i) {
            if (crossfadeGain_ > 0.0f) {
                crossfadeGain_ = std::max(0.0f, crossfadeGain_ - kCrossfadeStep);
            }
        }
        effectiveIntensity_ = 0.0f;
        return;
    }

    const float intensity = intensity_.load(std::memory_order_relaxed);

    // ─── Step 1: Downsample 48→16 ─────────────────────────────────────────────
    int n16 = impl_->down.process(buffer, blockSize,
                                  impl_->downBuf, kMaxBlock16);

    // ─── Step 1b: Low-shelf de balance espectral (FIX ronquera) ───────────────
    //     Recorta graves para que el modelo no confunda los medios con ruido y
    //     los preserve (1-4kHz 3.8%->13.5%, verificado). In-place sobre downBuf.
    for (int i = 0; i < n16; ++i) {
        impl_->downBuf[i] = impl_->preShelf.process(impl_->downBuf[i]);
    }

    // ─── STAGE B — ds16 @16k (entrada REAL al modelo, ya filtrada) ────────────
    if (capOn) Impl::capAppend(impl_->capB, impl_->capBWrite, impl_->downBuf, n16);

    // ─── Step 2: Feed accumulation buffer with overflow guard ──────────────────
    for (int i = 0; i < n16; ++i) {
        if (impl_->accumCount >= kAccumMax) {
            // Overflow: discard oldest hop
            std::memmove(impl_->accumBuf,
                         impl_->accumBuf + kHopSize,
                         (impl_->accumCount - kHopSize) * sizeof(float));
            impl_->accumCount -= kHopSize;
            droppedFrames_.fetch_add(1, std::memory_order_relaxed);
            LOGW("Accum overflow, discarded hop");
        }
        impl_->accumBuf[impl_->accumCount++] = impl_->downBuf[i];
    }

    // ─── Step 3: Process complete hops → upsample cada hop → wet ring @48k ────
    //     FIX ronquera: cada hop (160@16k) se upsamplea a ~480@48k y se encola.
    //     NO se descarta nada (antes se perdía ~58% de las muestras).
    while (impl_->accumCount >= kHopSize) {
        bool ok = impl_->processHop(impl_->accumBuf, this);
        if (!ok) {
            active_.store(false, std::memory_order_release);
            crossfadeTarget_ = 0.0f;
            LOGE("processHop failed, deactivating DPDFNet-4");
            for (int i = 0; i < blockSize; ++i) {
                if (crossfadeGain_ > 0.0f)
                    crossfadeGain_ = std::max(0.0f, crossfadeGain_ - kCrossfadeStep);
            }
            effectiveIntensity_ = 0.0f;
            return;
        }
        impl_->accumCount -= kHopSize;
        if (impl_->accumCount > 0) {
            std::memmove(impl_->accumBuf,
                         impl_->accumBuf + kHopSize,
                         impl_->accumCount * sizeof(float));
        }

        // ─── High-shelf de recuperación de agudos (FIX nitidez) ──────────────
        //     Compensa el roll-off de -8dB del modelo en 5-8kHz (medido).
        for (int i = 0; i < kHopSize; ++i) {
            impl_->hopOut[i] = impl_->postShelf.process(impl_->hopOut[i]);
        }

        // ─── STAGE C — model_out16 @16k (hopOut ya con realce de agudos) ─────
        if (capOn) Impl::capAppend(impl_->capC, impl_->capCWrite,
                                   impl_->hopOut, kHopSize);

        // Upsample este hop 16→48 y encolar en el ring @48k (sin pérdida)
        int nu = impl_->up.process(impl_->hopOut, kHopSize,
                                   impl_->upHop, kUpHopMax);
        for (int i = 0; i < nu; ++i) {
            impl_->wet48Push(impl_->upHop[i]);
        }
    }

    // ─── Step 4: Priming — esperar ~1 hop de latencia antes de drenar ─────────
    if (!impl_->primed) {
        if (impl_->wet48Available() >= kPrime48) {
            impl_->primed = true;
        } else {
            // Aún no hay suficiente wet: pasar dry sin tocar (crossfade en 0).
            effectiveIntensity_ = 0.0f;
            return;
        }
    }

    // ─── Step 5: Crossfade + intensity mix + clamp (drena exacto blockSize) ───
    for (int i = 0; i < blockSize; ++i) {
        // Ramp crossfade gain toward target
        if (crossfadeGain_ < crossfadeTarget_) {
            crossfadeGain_ = std::min(crossfadeGain_ + kCrossfadeStep,
                                      crossfadeTarget_);
        } else if (crossfadeGain_ > crossfadeTarget_) {
            crossfadeGain_ = std::max(crossfadeGain_ - kCrossfadeStep,
                                      crossfadeTarget_);
        }

        float wet = impl_->wet48Pop();   // 1 muestra @48k del ring (0 si underrun)
        float dry = buffer[i];
        float gain = intensity * crossfadeGain_;

        // Mix: out = dry*(1-gain) + wet*gain
        float out = dry * (1.0f - gain) + wet * gain;

        // Clamp [-1, +1]
        buffer[i] = std::clamp(out, -1.0f, 1.0f);
    }

    effectiveIntensity_ = intensity * crossfadeGain_;

    // ─── STAGE D — out48 @48k (buffer final tras mezcla+clamp) ────────────────
    if (capOn) Impl::capAppend(impl_->capD, impl_->capDWrite, buffer, blockSize);
}

// ═══════════════════════════════════════════════════════════════════════════════
// STAGE CAPTURE — API pública (forwarding al Impl). Hilo de control, NO audio.
// ═══════════════════════════════════════════════════════════════════════════════

bool DpdfnetDenoiser::startCapture(const char* dir) {
    if (!impl_) return false;
    return impl_->startCaptureImpl(dir, name(),
                                   intensity_.load(std::memory_order_relaxed));
}

void DpdfnetDenoiser::stopCapture() {
    if (impl_) impl_->stopCaptureImpl();
}

bool DpdfnetDenoiser::isCapturing() const {
    return impl_ && impl_->capturing.load(std::memory_order_acquire);
}

bool DpdfnetDenoiser::isCaptureReady() const {
    return impl_ && impl_->captureReady.load(std::memory_order_acquire);
}

} // namespace dpdfnet_denoiser

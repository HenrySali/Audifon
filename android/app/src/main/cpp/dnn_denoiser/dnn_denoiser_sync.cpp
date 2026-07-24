/// @file dnn_denoiser_sync.cpp
/// @brief Implementación SÍNCRONA del GTCRN DNN denoiser (OnnxRuntime).
///
/// DIFERENCIA con dnn_denoiser.cpp:
///   - NO usa worker thread, mutex, condition_variable ni ring buffers SPSC.
///   - La inferencia ONNX se ejecuta DIRECTAMENTE en el audio callback (process()).
///   - Elimina el problema de "traqueteo/matraca" por frames dropeados cuando
///     la inferencia tarda más que el deadline del ring buffer.
///   - Trade-off: si la inferencia excede el deadline del audio callback,
///     se produce un glitch de bloqueo (xrun) en vez de un frame dropeado.
///     En arm64 moderno (Snapdragon 6xx+), GTCRN tarda ~1.5ms/frame << 10ms hop.
///
/// Pipeline síncrono (sin ring buffers):
///
///   process(buffer, blockSize) @ inputSampleRate
///      │
///      ├─ 1. Guardar dry (para mezcla posterior)
///      ├─ 2. Downsample polyphase 48→16 kHz (acumular en accumBuf_)
///      ├─ 3. Por cada hop completo (kDnnHopSize=160 @16k):
///      │      ├─ STFT analysis (DFT 320, ventana Vorbis)
///      │      ├─ Pack tensor "mix" [1,1,161,2]
///      │      ├─ ONNX Run (mix + caches → enh + new_caches)
///      │      ├─ Unpack enhanced spectrum
///      │      ├─ iSTFT synthesis (OLA)
///      │      └─ Noise gate con hysteresis
///      ├─ 4. Upsample 16→48 kHz (polyphase)
///      └─ 5. Mezcla dry/wet con intensity, crossfade y VAD cap
///
/// Misma interfaz pública que dnn_denoiser.h (DnnDenoiser class).

#include "dnn_denoiser.h"

#include "onnxruntime/onnxruntime_cxx_api.h"
#include "../wpe_beamformer.h"

#include <android/asset_manager.h>
#include <android/log.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <vector>

#define DNN_LOG_TAG "DnnDenoiserSync"
#define DNN_LOGI(...) __android_log_print(ANDROID_LOG_INFO,  DNN_LOG_TAG, __VA_ARGS__)
#define DNN_LOGW(...) __android_log_print(ANDROID_LOG_WARN,  DNN_LOG_TAG, __VA_ARGS__)
#define DNN_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, DNN_LOG_TAG, __VA_ARGS__)

namespace dnn_denoiser {

namespace {

constexpr float kPi = 3.14159265358979323846f;

// ─────────────────────────────────────────────────────────────────────────────
// Helpers ONNX
// ─────────────────────────────────────────────────────────────────────────────

int64_t shapeNumel(const std::vector<int64_t>& shape) {
    int64_t n = 1;
    for (int64_t d : shape) {
        if (d <= 0) return 0;
        n *= d;
    }
    return n;
}

// ─────────────────────────────────────────────────────────────────────────────
// Resampler polyphase 48↔16 kHz (72 taps Kaiser β=8.5)
// ─────────────────────────────────────────────────────────────────────────────

class Resampler {
public:
    enum class Mode {
        kIdentity,
        kPolyDown48to16,
        kPolyUp16to48,
        kLinearGeneric
    };

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
                groupDelaySamples_ = static_cast<float>(protoN - 1) / 2.0f;
                break;
            case Mode::kPolyUp16to48: {
                constexpr int kL = 3;
                phaseTaps_ = protoN / kL;
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

    void reset() {
        std::fill(delay_.begin(), delay_.end(), 0.0f);
        phase_ = 0;
        writeIdx_ = 0;
        linearAccum_ = 0.0f;
        linearLast_  = 0.0f;
    }

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

    float groupDelaySamples() const { return groupDelaySamples_; }
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
        constexpr int kL = 3;
        int written = 0;
        int consumed = 0;

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
        int written = 0;
        int consumed = 0;
        while (written < outMax) {
            while (linearAccum_ >= 1.0f) {
                if (consumed >= n) return written;
                linearLast_ = in[consumed++];
                linearAccum_ -= 1.0f;
            }
            const float next = (consumed < n) ? in[consumed] : linearLast_;
            out[written++] = linearLast_ * (1.0f - linearAccum_) + next * linearAccum_;
            linearAccum_ += linearRatio_;
        }
        return written;
    }

    Mode mode_ = Mode::kIdentity;
    bool initialized_ = false;
    std::vector<float>              proto_;
    int                             protoN_ = 0;
    std::vector<std::vector<float>> phases_;
    int                             phaseTaps_ = 0;
    std::vector<float>              delay_;
    int                             writeIdx_ = 0;
    int                             phase_    = 0;
    float linearRatio_ = 1.0f;
    float linearAccum_ = 0.0f;
    float linearLast_  = 0.0f;
    float groupDelaySamples_ = 0.0f;
};

// ─────────────────────────────────────────────────────────────────────────────
// Kaiser LPF prototype design (72 taps, β=8.5, fc=7.5 kHz @ 48 kHz)
// ─────────────────────────────────────────────────────────────────────────────

inline constexpr int   kProtoTaps  = 72;
inline constexpr float kKaiserBeta = 8.5f;

inline float besselI0Approx(float x) {
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
    const float fc = 7500.0f / 48000.0f;
    const float beta = kKaiserBeta;
    const float center = (N - 1) / 2.0f;
    const float i0Beta = besselI0Approx(beta);
    float sum = 0.0f;
    for (int n = 0; n < N; ++n) {
        const float arg = 2.0f * fc * (static_cast<float>(n) - center);
        float ideal;
        if (std::fabs(arg) < 1e-9f) {
            ideal = 2.0f * fc;
        } else {
            const float px = kPi * arg;
            ideal = 2.0f * fc * std::sin(px) / px;
        }
        const float ratio = (2.0f * static_cast<float>(n) / (N - 1)) - 1.0f;
        const float winArg = beta * std::sqrt(std::max(0.0f, 1.0f - ratio * ratio));
        const float win = besselI0Approx(winArg) / i0Beta;
        h[n] = ideal * win;
        sum += h[n];
    }
    if (sum > 1e-12f) {
        for (int n = 0; n < N; ++n) h[n] /= sum;
    }
}

}  // namespace

// ─────────────────────────────────────────────────────────────────────────────
// PIMPL: Impl (SÍNCRONO — sin worker thread ni ring buffers)
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
    bool modelReady = false;

    // ─── Dual-channel WPE Beamformer ──────────────────────────────────
    std::atomic<int> channels{1};
    WpeBeamformer wpeBeamformer;
    std::vector<float> stftInBufCh1;       // [kDnnFftSize]
    std::vector<float> fftReCh1;           // [kDnnFftSize]
    std::vector<float> fftImCh1;           // [kDnnFftSize]

    // ─── STFT state (procesado síncrono en audio thread) ───────────────
    std::vector<float> hannWin;            // [kDnnFftSize] ventana Vorbis
    std::vector<float> stftInBuf;          // [kDnnFftSize]
    std::vector<float> olaBuf;             // [kDnnFftSize]
    std::vector<float> fftRe;              // [kDnnFftSize]
    std::vector<float> fftIm;              // [kDnnFftSize]
    std::vector<float> dftWorkBuf;         // [kDnnFftSize]
    std::vector<float> twiddleRe;          // [nBins * kDnnFftSize]
    std::vector<float> twiddleIm;          // [nBins * kDnnFftSize]
    std::vector<float> outputFrame;        // [kDnnHopSize]
    std::vector<float> mixTensorData;

    // ─── ONNX Caches recurrentes ──────────────────────────────────────
    std::vector<std::vector<float>>   caches;
    int                               mixInputIdx  = -1;
    int                               enhOutputIdx = -1;
    std::vector<int>                  cacheInputIdx;
    std::vector<int>                  cacheOutputIdx;

    // ─── Buffer de acumulación síncrono (reemplaza ring buffers) ───────
    /// Samples @16 kHz acumulados hasta tener un hop completo.
    std::vector<float> accumBuf;           // crece hasta kDnnHopSize
    int accumCount = 0;

    /// Buffer de acumulación para ch1 (dual-channel).
    std::vector<float> accumBufCh1;
    int accumCountCh1 = 0;

    /// Buffer de salida @16 kHz producido por inferencia (puede acumular
    /// múltiples hops si el blockSize de entrada es grande).
    std::vector<float> wetBuf16k;
    int wetBuf16kCount = 0;
    int wetBuf16kRead  = 0;  // posición de lectura para upsample

    // ─── Resampler 48↔16 ──────────────────────────────────────────────
    int inputSr = kDnnSampleRate;
    std::vector<float> protoLpf;
    Resampler down;
    Resampler downCh1;
    Resampler up;
    std::vector<float> downStaging;
    std::vector<float> downStagingCh1;
    std::vector<float> wetNativeRate;

    // ─── Dry delay buffer (para alinear dry con wet) ──────────────────
    /// En el modo síncrono, la latencia del wet es determinística:
    /// el resampler + STFT buffering introduce delay fijo. Almacenamos
    /// dry en un delay line circular para alinearla con wet.
    std::vector<float> dryDelay;
    int dryDelaySize  = 0;   // total samples de delay
    int dryDelayWrite = 0;
    int dryDelayRead  = 0;
    int dryDelayCount = 0;   // samples actualmente en el buffer

    // ─── Noise gate con hysteresis ────────────────────────────────────
    float gateGain_ = 1.0f;
    float gateGainApplied_ = 1.0f;
    int   gateHoldCounter_ = 0;

    // ─── Contadores ───────────────────────────────────────────────────
    std::atomic<uint64_t> processedFramesLocal{0};
    std::atomic<uint32_t> lastInferenceUsLocal{0};

    /// Pointer to the outer DnnDenoiser::voiceActive_ atomic.
    std::atomic<bool>* voiceActivePtr_ = nullptr;

    // ─── Constructor ──────────────────────────────────────────────────
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

        // Precompute twiddle factors.
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

        // Ventana Vorbis (COLA con hop=N/2).
        for (int i = 0; i < kDnnFftSize; ++i) {
            const float sinArg = kPi * static_cast<float>(i) / static_cast<float>(kDnnFftSize);
            const float sinSq = std::sin(sinArg) * std::sin(sinArg);
            hannWin[i] = std::sin(kPi * 0.5f * sinSq);
        }

        // Acumuladores y buffers de trabajo.
        accumBuf.assign(kDnnHopSize, 0.0f);
        accumCount = 0;
        accumBufCh1.assign(kDnnHopSize, 0.0f);
        accumCountCh1 = 0;
        // wetBuf16k se reserva generosamente (puede acumular varios hops).
        wetBuf16k.assign(kDnnHopSize * 8, 0.0f);
        wetBuf16kCount = 0;
        wetBuf16kRead  = 0;

        // Resampler: identidad por default hasta setInputSampleRate().
        protoLpf.assign(kProtoTaps, 0.0f);
        designResamplerProtoLpf(protoLpf.data(), kProtoTaps);
        down.configure(Resampler::Mode::kIdentity, nullptr, 0, 1.0f);
        downCh1.configure(Resampler::Mode::kIdentity, nullptr, 0, 1.0f);
        up.configure(Resampler::Mode::kIdentity, nullptr, 0, 1.0f);

        downStaging.assign(1024, 0.0f);
        downStagingCh1.assign(1024, 0.0f);
        wetNativeRate.assign(2048, 0.0f);

        // Dry delay: se dimensiona en applyInputSampleRate().
        dryDelay.assign(4096, 0.0f);
        dryDelaySize  = 0;
        dryDelayWrite = 0;
        dryDelayRead  = 0;
        dryDelayCount = 0;

        // Dual-channel buffers.
        stftInBufCh1.assign(kDnnFftSize, 0.0f);
        fftReCh1.assign(kDnnFftSize, 0.0f);
        fftImCh1.assign(kDnnFftSize, 0.0f);
        wpeBeamformer.reset();
    }

    ~Impl() = default;

    // ─── Asset loading ────────────────────────────────────────────────
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

    // ─── Model introspection ──────────────────────────────────────────
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

        for (size_t i = 0; i < numIn; ++i) {
            auto name = session->GetInputNameAllocated(i, allocator);
            std::string s(name.get());
            inputNames.push_back(s);
            auto info  = session->GetInputTypeInfo(i);
            auto tinfo = info.GetTensorTypeAndShapeInfo();
            std::vector<int64_t> shape = tinfo.GetShape();
            for (auto& d : shape) { if (d < 0) d = 1; }
            inputShapes.push_back(shape);
            DNN_LOGI("Input[%zu]: name=%s, shape=[%s]", i, s.c_str(), [&](){
                std::string r;
                for (auto d : shape) { r += std::to_string(d) + ","; }
                return r;
            }().c_str());
        }

        for (size_t i = 0; i < numOut; ++i) {
            auto name = session->GetOutputNameAllocated(i, allocator);
            std::string s(name.get());
            outputNames.push_back(s);
            auto info  = session->GetOutputTypeInfo(i);
            auto tinfo = info.GetTensorTypeAndShapeInfo();
            std::vector<int64_t> shape = tinfo.GetShape();
            for (auto& d : shape) { if (d < 0) d = 1; }
            outputShapes.push_back(shape);
            DNN_LOGI("Output[%zu]: name=%s, shape=[%s]", i, s.c_str(), [&](){
                std::string r;
                for (auto d : shape) { r += std::to_string(d) + ","; }
                return r;
            }().c_str());
        }

        // Asignación posicional fija (convención GTCRN).
        mixInputIdx  = 0;
        enhOutputIdx = 0;

        for (size_t i = 1; i < inputNames.size(); ++i)
            cacheInputIdx.push_back(static_cast<int>(i));
        for (size_t i = 1; i < outputNames.size(); ++i)
            cacheOutputIdx.push_back(static_cast<int>(i));

        if (cacheInputIdx.size() != cacheOutputIdx.size()) {
            DNN_LOGE("Cache count mismatch: %zu inputs vs %zu outputs",
                     cacheInputIdx.size(), cacheOutputIdx.size());
            return false;
        }

        if (mixInputIdx < 0 || inputShapes[mixInputIdx].size() < 3) {
            DNN_LOGE("mix input has unexpected shape (need ≥3 dims)");
            return false;
        }

        // Pre-allocate caches with zeros.
        caches.clear();
        for (int idx : cacheInputIdx) {
            const int64_t numel = shapeNumel(inputShapes[idx]);
            if (numel <= 0) {
                DNN_LOGE("Cache input has dynamic shape, cannot pre-allocate");
                return false;
            }
            caches.emplace_back(static_cast<size_t>(numel), 0.0f);
        }

        // Pre-allocate mix tensor buffer.
        const int64_t mixNumel = shapeNumel(inputShapes[mixInputIdx]);
        if (mixNumel <= 0) {
            DNN_LOGE("mix input has invalid total size");
            return false;
        }
        mixTensorData.assign(static_cast<size_t>(mixNumel), 0.0f);

        // Build C-string pointers for Run().
        inputNameCStr.clear();
        outputNameCStr.clear();
        for (auto& s : inputNames)  inputNameCStr.push_back(s.c_str());
        for (auto& s : outputNames) outputNameCStr.push_back(s.c_str());

        DNN_LOGI("Model introspection OK: mix=%d, enh=%d, %zu caches",
                 mixInputIdx, enhOutputIdx, caches.size());
        return true;
    }

    // ─── DFT forward/inverse con twiddle precomputados ────────────────
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

    void dftInverse(const float* inRe, const float* inIm, float* out) {
        constexpr int N = kDnnFftSize;
        constexpr int nBins = N / 2 + 1;
        const float invN = 1.0f / static_cast<float>(N);
        for (int n = 0; n < N; ++n) {
            float sum = inRe[0];  // DC
            for (int k = 1; k < nBins - 1; ++k) {
                const int idx = k * N + n;
                float cosKN = twiddleRe[idx];
                float sinKN = -twiddleIm[idx];
                sum += 2.0f * (inRe[k] * cosKN - inIm[k] * sinKN);
            }
            // Nyquist
            const int idxNyq = (nBins - 1) * N + n;
            float cosNyq = twiddleRe[idxNyq];
            float sinNyq = -twiddleIm[idxNyq];
            sum += inRe[nBins-1] * cosNyq - inIm[nBins-1] * sinNyq;
            out[n] = sum * invN;
        }
    }

    // ─── Reset state ──────────────────────────────────────────────────
    void resetState() {
        for (auto& c : caches) std::fill(c.begin(), c.end(), 0.0f);
        std::fill(stftInBuf.begin(), stftInBuf.end(), 0.0f);
        std::fill(olaBuf.begin(), olaBuf.end(), 0.0f);
        std::fill(fftRe.begin(), fftRe.end(), 0.0f);
        std::fill(fftIm.begin(), fftIm.end(), 0.0f);
        std::fill(dftWorkBuf.begin(), dftWorkBuf.end(), 0.0f);
        std::fill(outputFrame.begin(), outputFrame.end(), 0.0f);
        std::fill(stftInBufCh1.begin(), stftInBufCh1.end(), 0.0f);
        std::fill(fftReCh1.begin(), fftReCh1.end(), 0.0f);
        std::fill(fftImCh1.begin(), fftImCh1.end(), 0.0f);
        wpeBeamformer.reset();
        accumCount = 0;
        accumCountCh1 = 0;
        wetBuf16kCount = 0;
        wetBuf16kRead  = 0;
        gateGain_ = 1.0f;
        gateGainApplied_ = 1.0f;
        gateHoldCounter_ = 0;
        // Reset dry delay.
        std::fill(dryDelay.begin(), dryDelay.end(), 0.0f);
        dryDelayWrite = 0;
        dryDelayRead  = 0;
        dryDelayCount = 0;
    }

    // ─── Procesar un hop STFT + ONNX (mono) ──────────────────────────
    /// Ejecuta una inferencia GTCRN sobre kDnnHopSize samples @16 kHz.
    /// Escribe kDnnHopSize samples enhanced al wetBuf16k.
    /// Retorna true si OK.
    bool processOneHop(const float* hopIn) {
        constexpr int nBins = kDnnFftSize / 2 + 1;  // 161

        // 1. Desplazar stftInBuf y append nuevo hop.
        std::memmove(stftInBuf.data(),
                     stftInBuf.data() + kDnnHopSize,
                     (kDnnFftSize - kDnnHopSize) * sizeof(float));
        std::memcpy(stftInBuf.data() + (kDnnFftSize - kDnnHopSize),
                    hopIn, kDnnHopSize * sizeof(float));

        // 2. Ventana de análisis (Vorbis).
        for (int i = 0; i < kDnnFftSize; ++i) {
            dftWorkBuf[i] = stftInBuf[i] * hannWin[i];
        }

        // 3. Forward DFT.
        dftForward(dftWorkBuf.data(), fftRe.data(), fftIm.data());

        // 4. Pack mix tensor [1,1,nBins,2].
        const auto& mixShape = inputShapes[mixInputIdx];
        if (mixShape.size() != 4 || mixShape[2] != nBins || mixShape[3] != 2) {
            DNN_LOGE("Unsupported mix shape");
            return false;
        }
        std::fill(mixTensorData.begin(), mixTensorData.end(), 0.0f);
        for (int f = 0; f < nBins; ++f) {
            mixTensorData[f * 2 + 0] = fftRe[f];
            mixTensorData[f * 2 + 1] = fftIm[f];
        }

        // 5. Build ONNX tensors.
        std::vector<Ort::Value> inputs;
        inputs.reserve(inputNames.size());
        for (size_t i = 0; i < inputNames.size(); ++i)
            inputs.push_back(Ort::Value(nullptr));

        inputs[mixInputIdx] = Ort::Value::CreateTensor<float>(
            memInfo, mixTensorData.data(), mixTensorData.size(),
            inputShapes[mixInputIdx].data(), inputShapes[mixInputIdx].size());

        for (size_t k = 0; k < cacheInputIdx.size(); ++k) {
            const int idx = cacheInputIdx[k];
            inputs[idx] = Ort::Value::CreateTensor<float>(
                memInfo, caches[k].data(), caches[k].size(),
                inputShapes[idx].data(), inputShapes[idx].size());
        }

        // 6. ONNX Run.
        std::vector<Ort::Value> outputs;
        const auto t0 = std::chrono::steady_clock::now();
        try {
            outputs = session->Run(
                Ort::RunOptions{nullptr},
                inputNameCStr.data(), inputs.data(), inputs.size(),
                outputNameCStr.data(), outputNameCStr.size());
        } catch (const Ort::Exception& e) {
            DNN_LOGE("OnnxRuntime Run failed: %s", e.what());
            return false;
        }
        const auto t1 = std::chrono::steady_clock::now();
        lastInferenceUsLocal.store(
            static_cast<uint32_t>(std::chrono::duration_cast<
                std::chrono::microseconds>(t1 - t0).count()),
            std::memory_order_relaxed);

        if (outputs.size() != outputNames.size()) {
            DNN_LOGE("Run returned %zu outputs (expected %zu)",
                     outputs.size(), outputNames.size());
            return false;
        }

        // 7. Copy updated caches.
        for (size_t k = 0; k < cacheOutputIdx.size(); ++k) {
            const int idx = cacheOutputIdx[k];
            const float* p = outputs[idx].GetTensorData<float>();
            std::memcpy(caches[k].data(), p, caches[k].size() * sizeof(float));
        }

        // 8. Unpack enhanced spectrum.
        const float* enhData = outputs[enhOutputIdx].GetTensorData<float>();
        for (int f = 0; f < nBins; ++f) {
            fftRe[f] = enhData[f * 2 + 0];
            fftIm[f] = enhData[f * 2 + 1];
        }

        // 9. Inverse DFT.
        dftInverse(fftRe.data(), fftIm.data(), dftWorkBuf.data());

        // 10. Synthesis window (Vorbis) + OLA.
        for (int i = 0; i < kDnnFftSize; ++i) {
            dftWorkBuf[i] *= hannWin[i];
            olaBuf[i] += dftWorkBuf[i];
        }

        // 11. Extract hop from OLA.
        std::memcpy(outputFrame.data(), olaBuf.data(),
                    kDnnHopSize * sizeof(float));
        std::memmove(olaBuf.data(), olaBuf.data() + kDnnHopSize,
                     (kDnnFftSize - kDnnHopSize) * sizeof(float));
        std::fill(olaBuf.begin() + (kDnnFftSize - kDnnHopSize), olaBuf.end(), 0.0f);

        // 11b. Noise gate con hysteresis.
        {
            float energy = 0.0f;
            for (int i = 0; i < kDnnHopSize; ++i)
                energy += outputFrame[i] * outputFrame[i];
            const float rms = std::sqrt(energy / static_cast<float>(kDnnHopSize));

            constexpr float kGateClose  = 0.001f;
            constexpr float kGateOpen   = 0.01f;
            constexpr int   kHystFrames = 6;
            constexpr float kGateFloor  = 0.05f;

            if (rms >= kGateOpen) {
                gateHoldCounter_ = 0;
                gateGain_ = std::min(1.0f, gateGain_ + 0.33f);
            } else if (rms < kGateClose) {
                gateHoldCounter_++;
                if (gateHoldCounter_ >= kHystFrames)
                    gateGain_ = std::max(kGateFloor, gateGain_ - 0.25f);
            } else {
                gateHoldCounter_ = 0;
                const float kneeTarget =
                    std::max(kGateFloor,
                             (rms - kGateClose) / (kGateOpen - kGateClose));
                const float step = 0.2f;
                if (gateGain_ < kneeTarget)
                    gateGain_ = std::min(kneeTarget, gateGain_ + step);
                else
                    gateGain_ = std::max(kneeTarget, gateGain_ - step);
            }

            // Per-sample ramp to avoid clicks at hop boundaries.
            const float gStart = gateGainApplied_;
            const float gEnd   = gateGain_;
            if (gStart < 0.999f || gEnd < 0.999f) {
                const float invN = 1.0f / static_cast<float>(kDnnHopSize);
                for (int i = 0; i < kDnnHopSize; ++i) {
                    const float t = static_cast<float>(i + 1) * invN;
                    outputFrame[i] *= gStart + (gEnd - gStart) * t;
                }
            }
            gateGainApplied_ = gEnd;
        }

        // 12. Append to wetBuf16k.
        if (wetBuf16kCount + kDnnHopSize > static_cast<int>(wetBuf16k.size())) {
            wetBuf16k.resize(wetBuf16kCount + kDnnHopSize * 4);
        }
        std::memcpy(wetBuf16k.data() + wetBuf16kCount,
                    outputFrame.data(), kDnnHopSize * sizeof(float));
        wetBuf16kCount += kDnnHopSize;

        processedFramesLocal.fetch_add(1, std::memory_order_relaxed);
        return true;
    }

    // ─── Procesar un hop dual (WPE + ONNX) ───────────────────────────
    bool processDualHop(const float* hopCh0, const float* hopCh1In, bool vadActive) {
        constexpr int nBins = kDnnFftSize / 2 + 1;

        // STFT channel 0.
        std::memmove(stftInBuf.data(), stftInBuf.data() + kDnnHopSize,
                     (kDnnFftSize - kDnnHopSize) * sizeof(float));
        std::memcpy(stftInBuf.data() + (kDnnFftSize - kDnnHopSize),
                    hopCh0, kDnnHopSize * sizeof(float));
        for (int i = 0; i < kDnnFftSize; ++i)
            dftWorkBuf[i] = stftInBuf[i] * hannWin[i];
        dftForward(dftWorkBuf.data(), fftRe.data(), fftIm.data());

        WpeBeamformer::Complex X0[WpeBeamformer::kNumBins];
        for (int f = 0; f < nBins; ++f)
            X0[f] = WpeBeamformer::Complex(fftRe[f], fftIm[f]);

        // STFT channel 1.
        std::memmove(stftInBufCh1.data(), stftInBufCh1.data() + kDnnHopSize,
                     (kDnnFftSize - kDnnHopSize) * sizeof(float));
        std::memcpy(stftInBufCh1.data() + (kDnnFftSize - kDnnHopSize),
                    hopCh1In, kDnnHopSize * sizeof(float));
        for (int i = 0; i < kDnnFftSize; ++i)
            dftWorkBuf[i] = stftInBufCh1[i] * hannWin[i];
        dftForward(dftWorkBuf.data(), fftReCh1.data(), fftImCh1.data());

        WpeBeamformer::Complex X1[WpeBeamformer::kNumBins];
        for (int f = 0; f < nBins; ++f)
            X1[f] = WpeBeamformer::Complex(fftReCh1[f], fftImCh1[f]);

        // WPE beamformer.
        WpeBeamformer::Complex Y[WpeBeamformer::kNumBins];
        wpeBeamformer.process(X0, X1, Y, vadActive);

        // Pack enhanced spectrum into ONNX input.
        const auto& mixShape = inputShapes[mixInputIdx];
        if (mixShape.size() != 4 || mixShape[2] != nBins || mixShape[3] != 2) {
            DNN_LOGE("processDualHop: unsupported mix shape");
            return false;
        }
        std::fill(mixTensorData.begin(), mixTensorData.end(), 0.0f);
        for (int f = 0; f < nBins; ++f) {
            mixTensorData[f * 2 + 0] = Y[f].real();
            mixTensorData[f * 2 + 1] = Y[f].imag();
        }

        // ONNX Run (same as mono path from here).
        std::vector<Ort::Value> inputs;
        inputs.reserve(inputNames.size());
        for (size_t i = 0; i < inputNames.size(); ++i)
            inputs.push_back(Ort::Value(nullptr));

        inputs[mixInputIdx] = Ort::Value::CreateTensor<float>(
            memInfo, mixTensorData.data(), mixTensorData.size(),
            inputShapes[mixInputIdx].data(), inputShapes[mixInputIdx].size());

        for (size_t k = 0; k < cacheInputIdx.size(); ++k) {
            const int idx = cacheInputIdx[k];
            inputs[idx] = Ort::Value::CreateTensor<float>(
                memInfo, caches[k].data(), caches[k].size(),
                inputShapes[idx].data(), inputShapes[idx].size());
        }

        std::vector<Ort::Value> outputs;
        const auto t0 = std::chrono::steady_clock::now();
        try {
            outputs = session->Run(
                Ort::RunOptions{nullptr},
                inputNameCStr.data(), inputs.data(), inputs.size(),
                outputNameCStr.data(), outputNameCStr.size());
        } catch (const Ort::Exception& e) {
            DNN_LOGE("processDualHop: OnnxRuntime Run failed: %s", e.what());
            return false;
        }
        const auto t1 = std::chrono::steady_clock::now();
        lastInferenceUsLocal.store(
            static_cast<uint32_t>(std::chrono::duration_cast<
                std::chrono::microseconds>(t1 - t0).count()),
            std::memory_order_relaxed);

        if (outputs.size() != outputNames.size()) return false;

        // Copy updated caches.
        for (size_t k = 0; k < cacheOutputIdx.size(); ++k) {
            const int idx = cacheOutputIdx[k];
            const float* p = outputs[idx].GetTensorData<float>();
            std::memcpy(caches[k].data(), p, caches[k].size() * sizeof(float));
        }

        // Unpack enhanced spectrum.
        constexpr int nB = kDnnFftSize / 2 + 1;
        const float* enhData = outputs[enhOutputIdx].GetTensorData<float>();
        for (int f = 0; f < nB; ++f) {
            fftRe[f] = enhData[f * 2 + 0];
            fftIm[f] = enhData[f * 2 + 1];
        }

        // iSTFT + OLA.
        dftInverse(fftRe.data(), fftIm.data(), dftWorkBuf.data());
        for (int i = 0; i < kDnnFftSize; ++i) {
            dftWorkBuf[i] *= hannWin[i];
            olaBuf[i] += dftWorkBuf[i];
        }
        std::memcpy(outputFrame.data(), olaBuf.data(),
                    kDnnHopSize * sizeof(float));
        std::memmove(olaBuf.data(), olaBuf.data() + kDnnHopSize,
                     (kDnnFftSize - kDnnHopSize) * sizeof(float));
        std::fill(olaBuf.begin() + (kDnnFftSize - kDnnHopSize), olaBuf.end(), 0.0f);

        // Append to wetBuf16k.
        if (wetBuf16kCount + kDnnHopSize > static_cast<int>(wetBuf16k.size()))
            wetBuf16k.resize(wetBuf16kCount + kDnnHopSize * 4);
        std::memcpy(wetBuf16k.data() + wetBuf16kCount,
                    outputFrame.data(), kDnnHopSize * sizeof(float));
        wetBuf16kCount += kDnnHopSize;

        processedFramesLocal.fetch_add(1, std::memory_order_relaxed);
        return true;
    }

    // ─── Configurar sample rate y dry delay ───────────────────────────
    void applyInputSampleRate(int sr) {
        if (sr <= 0) sr = kDnnSampleRate;
        if (sr == inputSr && down.groupDelaySamples() >= 0.0f) return;
        inputSr = sr;

        if (sr == kDnnSampleRate) {
            down.configure(Resampler::Mode::kIdentity, nullptr, 0, 1.0f);
            downCh1.configure(Resampler::Mode::kIdentity, nullptr, 0, 1.0f);
            up.configure(Resampler::Mode::kIdentity, nullptr, 0, 1.0f);
            DNN_LOGI("Resampler: 16 kHz native — bypass");
        } else if (sr == 48000) {
            down.configure(Resampler::Mode::kPolyDown48to16,
                           protoLpf.data(), static_cast<int>(protoLpf.size()), 0.0f);
            downCh1.configure(Resampler::Mode::kPolyDown48to16,
                              protoLpf.data(), static_cast<int>(protoLpf.size()), 0.0f);
            up.configure(Resampler::Mode::kPolyUp16to48,
                         protoLpf.data(), static_cast<int>(protoLpf.size()), 0.0f);
            DNN_LOGI("Resampler: 48000 -> polyphase 3:1, %d taps Kaiser", kProtoTaps);
        } else {
            const float downRatio = static_cast<float>(sr) / static_cast<float>(kDnnSampleRate);
            const float upRatio   = static_cast<float>(kDnnSampleRate) / static_cast<float>(sr);
            down.configure(Resampler::Mode::kLinearGeneric, nullptr, 0, downRatio);
            downCh1.configure(Resampler::Mode::kLinearGeneric, nullptr, 0, downRatio);
            up.configure(Resampler::Mode::kLinearGeneric, nullptr, 0, upRatio);
            DNN_LOGW("Resampler: %d Hz -> linear interpolation", sr);
        }

        // Calcular dry delay size para alinear dry con wet.
        // Latencia del wet: downsampler + 1 hop STFT + upsampler.
        int delayNeeded = 0;
        if (inputSr == kDnnSampleRate) {
            delayNeeded = kDnnHopSize;
        } else if (inputSr == 48000) {
            const float downDelay = static_cast<float>(kProtoTaps - 1) / 2.0f;
            const float hopAtNative = static_cast<float>(kDnnHopSize) * 3.0f;
            const float upDelay = downDelay;
            delayNeeded = static_cast<int>(std::round(downDelay + hopAtNative + upDelay));
        } else {
            const float ratio = static_cast<float>(inputSr) /
                                static_cast<float>(kDnnSampleRate);
            delayNeeded = static_cast<int>(
                std::round(static_cast<float>(kDnnHopSize) * ratio));
        }

        dryDelaySize = delayNeeded;
        if (static_cast<int>(dryDelay.size()) < delayNeeded + 2048) {
            dryDelay.resize(delayNeeded + 2048, 0.0f);
        }
        // Reset dry delay and pre-fill with zeros.
        std::fill(dryDelay.begin(), dryDelay.end(), 0.0f);
        dryDelayWrite = delayNeeded;  // write pointer starts ahead
        dryDelayRead  = 0;
        dryDelayCount = delayNeeded;  // pre-filled with zeros (silence)

        DNN_LOGI("Dry delay: %d samples @ %d Hz (%.2f ms)",
                 delayNeeded, inputSr,
                 1000.0f * static_cast<float>(delayNeeded) / static_cast<float>(inputSr));

        // Reset resampler and accumulator state.
        if (processedFramesLocal.load(std::memory_order_relaxed) > 0) {
            resetState();
            down.reset();
            downCh1.reset();
            up.reset();
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// DnnDenoiser public methods (synchronous implementation)
// ─────────────────────────────────────────────────────────────────────────────

DnnDenoiser::DnnDenoiser() : impl_(std::make_unique<Impl>()) {
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

    DNN_LOGI("initialize(sync): loading %s", assetPath ? assetPath : "(null)");

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
    // NO worker thread — procesamiento síncrono.
    DNN_LOGI("initialize(sync): OK, model ready (synchronous processing, no worker thread)");
    return true;
}

bool DnnDenoiser::initializeDual(AAssetManager* assetMgr, const char* assetPath) {
    if (impl_->modelReady) {
        DNN_LOGW("initializeDual: already initialized, no-op");
        return impl_->channels.load(std::memory_order_acquire) == 2;
    }

    DNN_LOGI("initializeDual(sync): loading %s", assetPath ? assetPath : "(null)");

    std::vector<uint8_t> bytes = impl_->readAsset(assetMgr, assetPath);
    if (bytes.empty()) {
        DNN_LOGE("initializeDual: failed to read ONNX model");
        impl_->channels.store(1, std::memory_order_release);
        active_.store(false, std::memory_order_release);
        return false;
    }

    try {
        impl_->session = std::make_unique<Ort::Session>(
            impl_->env, bytes.data(), bytes.size(), impl_->sessionOpts);
    } catch (const Ort::Exception& e) {
        DNN_LOGE("initializeDual: Ort::Session failed: %s", e.what());
        active_.store(false, std::memory_order_release);
        return false;
    }

    if (!impl_->introspectModel()) {
        DNN_LOGE("initializeDual: model introspection failed");
        impl_->session.reset();
        active_.store(false, std::memory_order_release);
        return false;
    }

    impl_->channels.store(2, std::memory_order_release);
    impl_->modelReady = true;
    active_.store(true, std::memory_order_release);
    DNN_LOGI("initializeDual(sync): OK, dual-channel model ready (WPE+ONNX, no worker)");
    return true;
}

void DnnDenoiser::process(float* buffer, int blockSize) {
    if (buffer == nullptr || blockSize <= 0) return;

    const bool en  = enabled_.load(std::memory_order_acquire);
    const bool act = active_.load(std::memory_order_acquire);

    // Fast path: bypass total.
    if (!en && crossfadeGain_ <= 0.0f) return;

    if (!act) {
        crossfadeTarget_ = 0.0f;
        if (crossfadeGain_ > 0.0f) {
            for (int i = 0; i < blockSize; ++i)
                crossfadeGain_ = std::max(0.0f, crossfadeGain_ - kCrossfadeStep);
        }
        return;
    }

    crossfadeTarget_ = en ? 1.0f : 0.0f;

    // ── 1. Push dry to delay buffer ─────────────────────────────────────
    const int dlyCapacity = static_cast<int>(impl_->dryDelay.size());
    for (int i = 0; i < blockSize; ++i) {
        impl_->dryDelay[impl_->dryDelayWrite % dlyCapacity] = buffer[i];
        impl_->dryDelayWrite = (impl_->dryDelayWrite + 1) % dlyCapacity;
        impl_->dryDelayCount++;
    }

    // ── 2. Downsample input → 16 kHz → accumulate ──────────────────────
    if (static_cast<int>(impl_->downStaging.size()) < blockSize)
        impl_->downStaging.assign(blockSize, 0.0f);

    const int down16k = impl_->down.process(
        buffer, blockSize,
        impl_->downStaging.data(),
        static_cast<int>(impl_->downStaging.size()));

    // Reset wet buffer for this call.
    impl_->wetBuf16kCount = 0;
    impl_->wetBuf16kRead  = 0;

    // Accumulate and process complete hops.
    for (int i = 0; i < down16k; ++i) {
        impl_->accumBuf[impl_->accumCount++] = impl_->downStaging[i];
        if (impl_->accumCount >= kDnnHopSize) {
            const bool ok = impl_->processOneHop(impl_->accumBuf.data());
            impl_->accumCount = 0;
            if (!ok) {
                DNN_LOGW("processOneHop failed -> bypass");
                impl_->modelReady = false;
                active_.store(false, std::memory_order_release);
                return;
            }
        }
    }

    // ── 3. Upsample wet @16 kHz → native rate ──────────────────────────
    if (static_cast<int>(impl_->wetNativeRate.size()) < blockSize)
        impl_->wetNativeRate.assign(blockSize + 256, 0.0f);

    int wetWritten = 0;
    while (wetWritten < blockSize && impl_->wetBuf16kRead < impl_->wetBuf16kCount) {
        float in16k = impl_->wetBuf16k[impl_->wetBuf16kRead++];
        const int produced = impl_->up.process(
            &in16k, 1,
            impl_->wetNativeRate.data() + wetWritten,
            blockSize - wetWritten);
        wetWritten += produced;
    }

    // ── 4. Pop dry from delay buffer ────────────────────────────────────
    const int dlyCapacity2 = static_cast<int>(impl_->dryDelay.size());
    std::vector<float> dry(blockSize, 0.0f);
    int gotDry = 0;
    for (int i = 0; i < blockSize && impl_->dryDelayCount > 0; ++i) {
        dry[i] = impl_->dryDelay[impl_->dryDelayRead % dlyCapacity2];
        impl_->dryDelayRead = (impl_->dryDelayRead + 1) % dlyCapacity2;
        impl_->dryDelayCount--;
        gotDry++;
    }

    // ── 5. Mix dry/wet with intensity, crossfade, VAD cap ───────────────
    const float userIntensity = intensity_.load(std::memory_order_acquire);
    const bool  vadActive     = voiceActive_.load(std::memory_order_acquire);
    const float voiceCap      = voiceCap_.load(std::memory_order_acquire);
    const float target        = vadActive ? std::min(userIntensity, voiceCap)
                                          : userIntensity;
    const float stepAttack  = stepAttackPerSample_;
    const float stepRelease = stepReleasePerSample_;

    for (int i = 0; i < blockSize; ++i) {
        if (crossfadeGain_ < crossfadeTarget_)
            crossfadeGain_ = std::min(crossfadeTarget_, crossfadeGain_ + kCrossfadeStep);
        else if (crossfadeGain_ > crossfadeTarget_)
            crossfadeGain_ = std::max(crossfadeTarget_, crossfadeGain_ - kCrossfadeStep);

        if (effectiveIntensity_ > target) {
            if (stepAttack <= 0.0f) effectiveIntensity_ = target;
            else { effectiveIntensity_ -= stepAttack;
                   if (effectiveIntensity_ < target) effectiveIntensity_ = target; }
        } else if (effectiveIntensity_ < target) {
            if (stepRelease <= 0.0f) effectiveIntensity_ = target;
            else { effectiveIntensity_ += stepRelease;
                   if (effectiveIntensity_ > target) effectiveIntensity_ = target; }
        }

        const float dnnAmount = crossfadeGain_ * effectiveIntensity_;
        const float drySample = (i < gotDry) ? dry[i] : buffer[i];
        const float wetSample = (i < wetWritten) ? impl_->wetNativeRate[i] : drySample;
        const float mixed = drySample * (1.0f - dnnAmount) + wetSample * dnnAmount;
        buffer[i] = std::max(-1.0f, std::min(1.0f, mixed));
    }

    effectiveIntensityAtomic_.store(effectiveIntensity_, std::memory_order_release);
    processedFrames_.store(impl_->processedFramesLocal.load(std::memory_order_relaxed),
                            std::memory_order_relaxed);
    lastInferenceUs_.store(impl_->lastInferenceUsLocal.load(std::memory_order_relaxed),
                            std::memory_order_relaxed);
}

void DnnDenoiser::processStereo(const float* ch0, const float* ch1,
                                float* output, int blockSize) {
    if (ch0 == nullptr || ch1 == nullptr || output == nullptr || blockSize <= 0)
        return;

    auto passthroughCh0 = [&]() {
        if (output != ch0)
            std::memcpy(output, ch0, static_cast<size_t>(blockSize) * sizeof(float));
    };

    const bool en   = enabled_.load(std::memory_order_acquire);
    const bool act  = active_.load(std::memory_order_acquire);
    const bool dual = (impl_->channels.load(std::memory_order_acquire) == 2);

    if (!dual || (!en && crossfadeGain_ <= 0.0f)) {
        passthroughCh0();
        return;
    }

    if (!act) {
        crossfadeTarget_ = 0.0f;
        if (crossfadeGain_ > 0.0f) {
            for (int i = 0; i < blockSize; ++i)
                crossfadeGain_ = std::max(0.0f, crossfadeGain_ - kCrossfadeStep);
        }
        passthroughCh0();
        return;
    }

    crossfadeTarget_ = en ? 1.0f : 0.0f;

    // 1. Push ch0 to dry delay.
    const int dlyCapacity = static_cast<int>(impl_->dryDelay.size());
    for (int i = 0; i < blockSize; ++i) {
        impl_->dryDelay[impl_->dryDelayWrite % dlyCapacity] = ch0[i];
        impl_->dryDelayWrite = (impl_->dryDelayWrite + 1) % dlyCapacity;
        impl_->dryDelayCount++;
    }

    // 2. Downsample both channels.
    if (static_cast<int>(impl_->downStaging.size()) < blockSize)
        impl_->downStaging.assign(blockSize, 0.0f);
    if (static_cast<int>(impl_->downStagingCh1.size()) < blockSize)
        impl_->downStagingCh1.assign(blockSize, 0.0f);

    const int d0 = impl_->down.process(ch0, blockSize,
        impl_->downStaging.data(), static_cast<int>(impl_->downStaging.size()));
    const int d1 = impl_->downCh1.process(ch1, blockSize,
        impl_->downStagingCh1.data(), static_cast<int>(impl_->downStagingCh1.size()));

    // Reset wet buffer.
    impl_->wetBuf16kCount = 0;
    impl_->wetBuf16kRead  = 0;

    // Accumulate both channels and process dual hops.
    const int minSamples = std::min(d0, d1);
    for (int i = 0; i < minSamples; ++i) {
        impl_->accumBuf[impl_->accumCount] = impl_->downStaging[i];
        impl_->accumBufCh1[impl_->accumCountCh1] = impl_->downStagingCh1[i];
        impl_->accumCount++;
        impl_->accumCountCh1++;

        if (impl_->accumCount >= kDnnHopSize && impl_->accumCountCh1 >= kDnnHopSize) {
            const bool vadActive = (impl_->voiceActivePtr_ != nullptr)
                ? impl_->voiceActivePtr_->load(std::memory_order_acquire) : true;

            const bool ok = impl_->processDualHop(
                impl_->accumBuf.data(), impl_->accumBufCh1.data(), vadActive);
            impl_->accumCount = 0;
            impl_->accumCountCh1 = 0;
            if (!ok) {
                DNN_LOGW("processDualHop failed -> bypass");
                impl_->modelReady = false;
                active_.store(false, std::memory_order_release);
                passthroughCh0();
                return;
            }
        }
    }

    // 3. Upsample wet.
    if (static_cast<int>(impl_->wetNativeRate.size()) < blockSize)
        impl_->wetNativeRate.assign(blockSize + 256, 0.0f);

    int wetWritten = 0;
    while (wetWritten < blockSize && impl_->wetBuf16kRead < impl_->wetBuf16kCount) {
        float in16k = impl_->wetBuf16k[impl_->wetBuf16kRead++];
        const int produced = impl_->up.process(
            &in16k, 1,
            impl_->wetNativeRate.data() + wetWritten,
            blockSize - wetWritten);
        wetWritten += produced;
    }

    // 4. Pop dry.
    const int dlyCapacity2 = static_cast<int>(impl_->dryDelay.size());
    std::vector<float> dry(blockSize, 0.0f);
    int gotDry = 0;
    for (int i = 0; i < blockSize && impl_->dryDelayCount > 0; ++i) {
        dry[i] = impl_->dryDelay[impl_->dryDelayRead % dlyCapacity2];
        impl_->dryDelayRead = (impl_->dryDelayRead + 1) % dlyCapacity2;
        impl_->dryDelayCount--;
        gotDry++;
    }

    // 5. Mix dry/wet.
    const float userIntensity = intensity_.load(std::memory_order_acquire);
    const bool  vadActive     = voiceActive_.load(std::memory_order_acquire);
    const float voiceCap      = voiceCap_.load(std::memory_order_acquire);
    const float target        = vadActive ? std::min(userIntensity, voiceCap)
                                          : userIntensity;
    const float stepAttack  = stepAttackPerSample_;
    const float stepRelease = stepReleasePerSample_;

    for (int i = 0; i < blockSize; ++i) {
        if (crossfadeGain_ < crossfadeTarget_)
            crossfadeGain_ = std::min(crossfadeTarget_, crossfadeGain_ + kCrossfadeStep);
        else if (crossfadeGain_ > crossfadeTarget_)
            crossfadeGain_ = std::max(crossfadeTarget_, crossfadeGain_ - kCrossfadeStep);

        if (effectiveIntensity_ > target) {
            if (stepAttack <= 0.0f) effectiveIntensity_ = target;
            else { effectiveIntensity_ -= stepAttack;
                   if (effectiveIntensity_ < target) effectiveIntensity_ = target; }
        } else if (effectiveIntensity_ < target) {
            if (stepRelease <= 0.0f) effectiveIntensity_ = target;
            else { effectiveIntensity_ += stepRelease;
                   if (effectiveIntensity_ > target) effectiveIntensity_ = target; }
        }

        const float dnnAmount = crossfadeGain_ * effectiveIntensity_;
        const float drySample = (i < gotDry) ? dry[i] : ch0[i];
        const float wetSample = (i < wetWritten) ? impl_->wetNativeRate[i] : drySample;
        const float mixed = drySample * (1.0f - dnnAmount) + wetSample * dnnAmount;
        output[i] = std::max(-1.0f, std::min(1.0f, mixed));
    }

    effectiveIntensityAtomic_.store(effectiveIntensity_, std::memory_order_release);
    processedFrames_.store(impl_->processedFramesLocal.load(std::memory_order_relaxed),
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
    voiceActive_.store(active, std::memory_order_release);
}

void DnnDenoiser::setVoiceCap(float cap) {
    if (cap < 0.0f) cap = 0.0f;
    if (cap > 1.0f) cap = 1.0f;
    voiceCap_.store(cap, std::memory_order_release);
}

void DnnDenoiser::reset() {
    if (impl_) {
        impl_->resetState();
        impl_->down.reset();
        impl_->downCh1.reset();
        impl_->up.reset();
    }
    crossfadeGain_   = 0.0f;
    crossfadeTarget_ = enabled_.load(std::memory_order_acquire) ? 1.0f : 0.0f;
}

}  // namespace dnn_denoiser

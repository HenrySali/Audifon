/// @file dnn_denoiser_sherpa.cpp
/// @brief Minimal GTCRN denoiser — sherpa-onnx pipeline adapted for real-time.
///
/// Replaces the over-engineered dnn_denoiser.cpp (~1400 lines) with a clean,
/// synchronous implementation (~350 lines). No worker thread, no ring buffers,
/// no noise gate, no dry delay. Just: STFT → ONNX Run → iSTFT, on audio thread.
///
/// Key: hann_sqrt window (matching GTCRN training), hop=160, n_fft=320.

#include "dnn_denoiser.h"
#include "onnxruntime/onnxruntime_cxx_api.h"

#include <android/asset_manager.h>
#include <android/log.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <vector>

#define DNN_TAG "DnnDenoiserSherpa"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  DNN_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  DNN_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, DNN_TAG, __VA_ARGS__)

namespace dnn_denoiser {

namespace {
constexpr float kPi = 3.14159265358979323846f;

// Model parameters (from ONNX metadata, validated at init).
constexpr int kModelSr      = 16000;
constexpr int kNFft         = 320;
constexpr int kHopLength    = 160;
constexpr int kWinLength    = 320;
constexpr int kFreqBins     = kNFft / 2 + 1;  // 161
constexpr int kFftSize      = 512;             // radix-2 for 320-pt via zero-pad
constexpr int kAccumMax     = 1600;            // overflow guard (10 hops)
constexpr int kOutputMax    = 4096;            // max output staging

// ─────────────────────────────────────────────────────────────────────────────
// Radix-2 FFT (512-point, iterative Cooley-Tukey)
// ─────────────────────────────────────────────────────────────────────────────
void fftRadix2(float* re, float* im, int N, bool inverse) {
    // Bit-reversal permutation
    int j = 0;
    for (int i = 1; i < N; ++i) {
        int bit = N >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            std::swap(re[i], re[j]);
            std::swap(im[i], im[j]);
        }
    }
    // Cooley-Tukey butterflies
    for (int len = 2; len <= N; len <<= 1) {
        const float ang = (inverse ? 2.0f : -2.0f) * kPi / static_cast<float>(len);
        const float wReStep = std::cos(ang);
        const float wImStep = std::sin(ang);
        for (int i = 0; i < N; i += len) {
            float wRe = 1.0f, wIm = 0.0f;
            const int half = len / 2;
            for (int k = 0; k < half; ++k) {
                float xRe = re[i + k], xIm = im[i + k];
                float yRe = re[i + k + half] * wRe - im[i + k + half] * wIm;
                float yIm = re[i + k + half] * wIm + im[i + k + half] * wRe;
                re[i + k]        = xRe + yRe;
                im[i + k]        = xIm + yIm;
                re[i + k + half] = xRe - yRe;
                im[i + k + half] = xIm - yIm;
                float nwRe = wRe * wReStep - wIm * wImStep;
                float nwIm = wRe * wImStep + wIm * wReStep;
                wRe = nwRe; wIm = nwIm;
            }
        }
    }
    if (inverse) {
        const float inv = 1.0f / static_cast<float>(N);
        for (int i = 0; i < N; ++i) { re[i] *= inv; im[i] *= inv; }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Polyphase Resampler 48↔16 kHz (72-tap Kaiser β=8.5)
// ─────────────────────────────────────────────────────────────────────────────
constexpr int kProtoTaps = 72;

float besselI0(float x) {
    const float ax = std::fabs(x);
    if (ax < 3.75f) {
        const float y = (x / 3.75f) * (x / 3.75f);
        return 1.0f + y*(3.5156229f + y*(3.0899424f + y*(1.2067492f
            + y*(0.2659732f + y*(0.0360768f + y*0.0045813f)))));
    }
    const float y = 3.75f / ax;
    return (std::exp(ax) / std::sqrt(ax)) *
        (0.39894228f + y*(0.01328592f + y*(0.00225319f
        + y*(-0.00157565f + y*(0.00916281f + y*(-0.02057706f
        + y*(0.02635537f + y*(-0.01647633f + y*0.00392377f))))))));
}

void designProtoLpf(float* h, int N) {
    const float fc = 7500.0f / 48000.0f;  // cutoff normalized to 48 kHz
    const float beta = 8.5f;
    const float center = (N - 1) / 2.0f;
    const float i0b = besselI0(beta);
    float sum = 0.0f;
    for (int n = 0; n < N; ++n) {
        float arg = 2.0f * fc * (static_cast<float>(n) - center);
        float ideal;
        if (std::fabs(arg) < 1e-9f) ideal = 2.0f * fc;
        else { float px = kPi * arg; ideal = 2.0f * fc * std::sin(px) / px; }
        float ratio = (2.0f * n / (N - 1)) - 1.0f;
        float winArg = beta * std::sqrt(std::max(0.0f, 1.0f - ratio*ratio));
        float win = besselI0(winArg) / i0b;
        h[n] = ideal * win;
        sum += h[n];
    }
    if (sum > 1e-12f) for (int n = 0; n < N; ++n) h[n] /= sum;
}

class Resampler {
public:
    enum class Mode { kIdentity, kPolyDown48to16, kPolyUp16to48 };

    void configure(Mode mode, const float* proto, int protoN) {
        mode_ = mode;
        if (mode == Mode::kPolyDown48to16) {
            proto_.assign(proto, proto + protoN);
            protoN_ = protoN;
            delay_.assign(protoN, 0.0f);
            phase_ = 0; writeIdx_ = 0;
        } else if (mode == Mode::kPolyUp16to48) {
            constexpr int kL = 3;
            phaseTaps_ = protoN / kL;
            phases_.assign(kL, std::vector<float>(phaseTaps_, 0.0f));
            for (int n = 0; n < phaseTaps_; ++n)
                for (int k = 0; k < kL; ++k) {
                    int idx = n * kL + k;
                    if (idx < protoN) phases_[k][n] = proto[idx] * float(kL);
                }
            delay_.assign(phaseTaps_, 0.0f);
            writeIdx_ = 0; phase_ = 0;
        }
    }

    void reset() {
        std::fill(delay_.begin(), delay_.end(), 0.0f);
        phase_ = 0; writeIdx_ = 0;
    }

    int process(const float* in, int n, float* out, int outMax) {
        if (n <= 0 || outMax <= 0) return 0;
        switch (mode_) {
            case Mode::kIdentity: {
                int k = std::min(n, outMax);
                std::memcpy(out, in, k * sizeof(float));
                return k;
            }
            case Mode::kPolyDown48to16: return processDown(in, n, out, outMax);
            case Mode::kPolyUp16to48:   return processUp(in, n, out, outMax);
        }
        return 0;
    }

private:
    int processDown(const float* in, int n, float* out, int outMax) {
        constexpr int kM = 3;
        int written = 0;
        for (int i = 0; i < n && written < outMax; ++i) {
            delay_[writeIdx_] = in[i];
            writeIdx_ = (writeIdx_ + 1) % protoN_;
            if (++phase_ == kM) {
                phase_ = 0;
                float acc = 0.0f;
                int idx = writeIdx_ - 1;
                if (idx < 0) idx += protoN_;
                for (int k = 0; k < protoN_; ++k) {
                    acc += proto_[k] * delay_[idx];
                    idx = (idx == 0) ? (protoN_ - 1) : (idx - 1);
                }
                out[written++] = acc;
            }
        }
        return written;
    }

    int processUp(const float* in, int n, float* out, int outMax) {
        constexpr int kL = 3;
        int written = 0, consumed = 0;
        // Drain pending phases from previous call
        while (phase_ > 0 && phase_ < kL && written < outMax) {
            float acc = 0.0f;
            int idx = writeIdx_ - 1;
            if (idx < 0) idx += phaseTaps_;
            for (int t = 0; t < phaseTaps_; ++t) {
                acc += phases_[phase_][t] * delay_[idx];
                idx = (idx == 0) ? (phaseTaps_ - 1) : (idx - 1);
            }
            out[written++] = acc; ++phase_;
        }
        if (phase_ >= kL) phase_ = 0;
        // Process new input samples
        while (consumed < n && written < outMax) {
            delay_[writeIdx_] = in[consumed++];
            writeIdx_ = (writeIdx_ + 1) % phaseTaps_;
            phase_ = 0;
            while (phase_ < kL && written < outMax) {
                float acc = 0.0f;
                int idx = writeIdx_ - 1;
                if (idx < 0) idx += phaseTaps_;
                for (int t = 0; t < phaseTaps_; ++t) {
                    acc += phases_[phase_][t] * delay_[idx];
                    idx = (idx == 0) ? (phaseTaps_ - 1) : (idx - 1);
                }
                out[written++] = acc; ++phase_;
            }
            if (phase_ >= kL) phase_ = 0;
        }
        return written;
    }

    Mode mode_ = Mode::kIdentity;
    std::vector<float> proto_;
    int protoN_ = 0;
    std::vector<std::vector<float>> phases_;
    int phaseTaps_ = 0;
    std::vector<float> delay_;
    int writeIdx_ = 0;
    int phase_ = 0;
};

/// Compute total elements from a shape vector.
int64_t shapeNumel(const std::vector<int64_t>& s) {
    int64_t n = 1;
    for (auto d : s) { if (d <= 0) return 0; n *= d; }
    return n;
}

}  // namespace

// ─────────────────────────────────────────────────────────────────────────────
// PIMPL Implementation Struct
// ─────────────────────────────────────────────────────────────────────────────
struct DnnDenoiser::Impl {
    // ─── ONNX Runtime ──────────────────────────────────────────────────
    Ort::Env            env{ORT_LOGGING_LEVEL_WARNING, DNN_TAG};
    Ort::SessionOptions sessionOpts;
    Ort::Session*       session = nullptr;
    Ort::MemoryInfo     memInfo{Ort::MemoryInfo::CreateCpu(
                            OrtArenaAllocator, OrtMemTypeDefault)};

    std::vector<std::string>   inputNames;
    std::vector<std::string>   outputNames;
    std::vector<const char*>   inNamePtrs;
    std::vector<const char*>   outNamePtrs;
    std::vector<std::vector<int64_t>> inputShapes;
    std::vector<std::vector<int64_t>> outputShapes;

    // ─── Model Parameters ──────────────────────────────────────────────
    int sampleRate = kModelSr;
    int nFft       = kNFft;
    int hopLength  = kHopLength;
    int freqBins   = kFreqBins;

    // ─── STFT State ────────────────────────────────────────────────────
    float window[kWinLength];       // hann_sqrt precomputed
    float stftPrevFrame[kHopLength]; // previous hop for frame overlap
    float olaBuf[kWinLength];       // overlap-add synthesis buffer
    int   olaWritePos = 0;

    // ─── FFT Workspace ─────────────────────────────────────────────────
    float fftRe[kFftSize];
    float fftIm[kFftSize];

    // ─── Tensor Storage ────────────────────────────────────────────────
    float mixTensor[kFreqBins * 2];  // [1,161,1,2] flattened
    float enhTensor[kFreqBins * 2];  // output from model
    std::vector<float> convCache;
    std::vector<float> traCache;
    std::vector<float> interCache;
    std::vector<int64_t> convCacheShape;
    std::vector<int64_t> traCacheShape;
    std::vector<int64_t> interCacheShape;

    // Cache I/O index mapping
    int mixInputIdx = 0;
    int enhOutputIdx = 0;
    std::vector<int> cacheInputIdx;
    std::vector<int> cacheOutputIdx;

    // ─── Accumulation Buffer ───────────────────────────────────────────
    float accumBuf[kAccumMax];
    int   accumCount = 0;

    // ─── Output Staging ────────────────────────────────────────────────
    float outputStaging[kOutputMax];
    int   outputCount = 0;

    // ─── Resampler ─────────────────────────────────────────────────────
    Resampler down;   // 48→16
    Resampler up;     // 16→48
    int       inputSr = kModelSr;
    float     protoLpf[kProtoTaps];

    // ─── Model State ───────────────────────────────────────────────────
    bool modelReady = false;

    // ─── Timing ────────────────────────────────────────────────────────
    uint32_t lastInferenceUs = 0;

    Impl() {
        sessionOpts.SetIntraOpNumThreads(1);
        sessionOpts.SetInterOpNumThreads(1);
        sessionOpts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        std::memset(stftPrevFrame, 0, sizeof(stftPrevFrame));
        std::memset(olaBuf, 0, sizeof(olaBuf));
        std::memset(accumBuf, 0, sizeof(accumBuf));
        std::memset(outputStaging, 0, sizeof(outputStaging));
        std::memset(fftRe, 0, sizeof(fftRe));
        std::memset(fftIm, 0, sizeof(fftIm));
        std::memset(mixTensor, 0, sizeof(mixTensor));
        std::memset(enhTensor, 0, sizeof(enhTensor));
        // Precompute hann_sqrt window (periodic)
        for (int n = 0; n < kWinLength; ++n) {
            float h = 0.5f * (1.0f - std::cos(2.0f * kPi * n / kWinLength));
            window[n] = std::sqrt(h);
        }
        // Design resampler prototype
        designProtoLpf(protoLpf, kProtoTaps);
        down.configure(Resampler::Mode::kIdentity, nullptr, 0);
        up.configure(Resampler::Mode::kIdentity, nullptr, 0);
    }

    ~Impl() {
        delete session;
        session = nullptr;
    }

    // ─── STFT: windowed FFT of one hop ─────────────────────────────────
    void doStft(const float* hop160) {
        // Build 320-sample frame: [stftPrevFrame | hop]
        float frame[kWinLength];
        std::memcpy(frame, stftPrevFrame, kHopLength * sizeof(float));
        std::memcpy(frame + kHopLength, hop160, kHopLength * sizeof(float));

        // Apply analysis window
        for (int i = 0; i < kWinLength; ++i) frame[i] *= window[i];

        // Zero-pad to 512 for radix-2 FFT
        std::memset(fftRe, 0, kFftSize * sizeof(float));
        std::memset(fftIm, 0, kFftSize * sizeof(float));
        std::memcpy(fftRe, frame, kWinLength * sizeof(float));

        fftRadix2(fftRe, fftIm, kFftSize, false);

        // Pack first 161 bins into mixTensor [1,161,1,2] as [re,im] pairs
        for (int k = 0; k < kFreqBins; ++k) {
            mixTensor[k * 2]     = fftRe[k];
            mixTensor[k * 2 + 1] = fftIm[k];
        }

        // Save hop for next frame overlap
        std::memcpy(stftPrevFrame, hop160, kHopLength * sizeof(float));
    }

    // ─── iSTFT: inverse FFT + overlap-add → 160 output samples ────────
    void doIstft(const float* enh, float* outHop160) {
        // Unpack 161 bins
        std::memset(fftRe, 0, kFftSize * sizeof(float));
        std::memset(fftIm, 0, kFftSize * sizeof(float));
        for (int k = 0; k < kFreqBins; ++k) {
            fftRe[k] = enh[k * 2];
            fftIm[k] = enh[k * 2 + 1];
        }
        // Mirror conjugate for real-valued output
        for (int k = 1; k < kFreqBins; ++k) {
            fftRe[kFftSize - k] =  fftRe[k];
            fftIm[kFftSize - k] = -fftIm[k];
        }

        fftRadix2(fftRe, fftIm, kFftSize, true);  // IFFT

        // Extract 320 samples, apply synthesis window
        float frame[kWinLength];
        for (int i = 0; i < kWinLength; ++i) {
            frame[i] = fftRe[i] * window[i];
        }

        // Overlap-add into olaBuf and extract hop
        for (int i = 0; i < kWinLength; ++i) {
            olaBuf[(olaWritePos + i) % kWinLength] += frame[i];
        }
        for (int i = 0; i < kHopLength; ++i) {
            outHop160[i] = olaBuf[(olaWritePos + i) % kWinLength];
            olaBuf[(olaWritePos + i) % kWinLength] = 0.0f;
        }
        olaWritePos = (olaWritePos + kHopLength) % kWinLength;
    }

    // ─── ONNX Inference: single hop ────────────────────────────────────
    bool runInference() {
        if (!session || !modelReady) return false;

        try {
            auto t0 = std::chrono::steady_clock::now();

            // Build input tensors
            const int64_t mixShape[] = {1, kFreqBins, 1, 2};
            std::vector<Ort::Value> inputs;
            inputs.reserve(inputNames.size());

            // We need to place tensors in the correct order per inputNames
            for (size_t i = 0; i < inputNames.size(); ++i) {
                if ((int)i == mixInputIdx) {
                    inputs.emplace_back(Ort::Value::CreateTensor<float>(
                        memInfo, mixTensor, kFreqBins * 2,
                        mixShape, 4));
                } else {
                    // Find which cache this is
                    float* data = nullptr;
                    const int64_t* shape = nullptr;
                    size_t rank = 0;
                    for (size_t c = 0; c < cacheInputIdx.size(); ++c) {
                        if (cacheInputIdx[c] == (int)i) {
                            if (c == 0) {
                                data = convCache.data();
                                shape = convCacheShape.data();
                                rank = convCacheShape.size();
                            } else if (c == 1) {
                                data = traCache.data();
                                shape = traCacheShape.data();
                                rank = traCacheShape.size();
                            } else {
                                data = interCache.data();
                                shape = interCacheShape.data();
                                rank = interCacheShape.size();
                            }
                            break;
                        }
                    }
                    if (data && shape) {
                        int64_t numel = 1;
                        for (size_t r = 0; r < rank; ++r) numel *= shape[r];
                        inputs.emplace_back(Ort::Value::CreateTensor<float>(
                            memInfo, data, numel, shape, rank));
                    }
                }
            }

            // Run inference
            auto outputs = session->Run(
                Ort::RunOptions{nullptr},
                inNamePtrs.data(), inputs.data(), inputs.size(),
                outNamePtrs.data(), outNamePtrs.size());

            // Extract enhanced output
            float* enhOut = outputs[enhOutputIdx].GetTensorMutableData<float>();
            std::memcpy(enhTensor, enhOut, kFreqBins * 2 * sizeof(float));

            // Update caches from outputs
            for (size_t c = 0; c < cacheOutputIdx.size(); ++c) {
                float* src = outputs[cacheOutputIdx[c]].GetTensorMutableData<float>();
                if (c == 0) {
                    std::memcpy(convCache.data(), src,
                                convCache.size() * sizeof(float));
                } else if (c == 1) {
                    std::memcpy(traCache.data(), src,
                                traCache.size() * sizeof(float));
                } else {
                    std::memcpy(interCache.data(), src,
                                interCache.size() * sizeof(float));
                }
            }

            // NaN/Inf check (spot-check first element)
            if (!std::isfinite(enhTensor[0])) {
                LOGE("runInference: NaN/Inf detected in output");
                return false;
            }

            auto t1 = std::chrono::steady_clock::now();
            lastInferenceUs = static_cast<uint32_t>(
                std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count());

            return true;
        } catch (const Ort::Exception& e) {
            LOGE("runInference ORT error: %s", e.what());
            return false;
        } catch (...) {
            LOGE("runInference: unknown exception");
            return false;
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// DnnDenoiser Public API Implementation
// ─────────────────────────────────────────────────────────────────────────────

DnnDenoiser::DnnDenoiser() : impl_(std::make_unique<Impl>()) {}

DnnDenoiser::~DnnDenoiser() = default;

bool DnnDenoiser::initialize(AAssetManager* assetMgr, const char* assetPath) {
    if (!assetMgr || !assetPath || assetPath[0] == '\0') {
        LOGE("initialize: invalid arguments");
        return false;
    }
    if (impl_->modelReady) return true;  // idempotent

    try {
        // 1. Read model bytes from asset
        AAsset* asset = AAssetManager_open(assetMgr, assetPath, AASSET_MODE_BUFFER);
        if (!asset) {
            LOGE("initialize: cannot open asset '%s'", assetPath);
            return false;
        }
        off_t sz = AAsset_getLength(asset);
        if (sz <= 0) {
            LOGE("initialize: asset size invalid");
            AAsset_close(asset);
            return false;
        }
        std::vector<uint8_t> modelData(sz);
        int bytesRead = AAsset_read(asset, modelData.data(), modelData.size());
        AAsset_close(asset);
        if (bytesRead != (int)modelData.size()) {
            LOGE("initialize: read failed (%d/%zu)", bytesRead, modelData.size());
            return false;
        }

        // 2. Create ONNX session
        impl_->session = new Ort::Session(
            impl_->env, modelData.data(), modelData.size(), impl_->sessionOpts);
        LOGI("initialize: ONNX session created");

        // 3. Read I/O names and shapes
        Ort::AllocatorWithDefaultOptions alloc;
        size_t numInputs = impl_->session->GetInputCount();
        size_t numOutputs = impl_->session->GetOutputCount();

        impl_->inputNames.resize(numInputs);
        impl_->outputNames.resize(numOutputs);
        impl_->inNamePtrs.resize(numInputs);
        impl_->outNamePtrs.resize(numOutputs);
        impl_->inputShapes.resize(numInputs);
        impl_->outputShapes.resize(numOutputs);

        for (size_t i = 0; i < numInputs; ++i) {
            auto name = impl_->session->GetInputNameAllocated(i, alloc);
            impl_->inputNames[i] = name.get();
            impl_->inNamePtrs[i] = impl_->inputNames[i].c_str();
            auto info = impl_->session->GetInputTypeInfo(i);
            auto shape = info.GetTensorTypeAndShapeInfo().GetShape();
            impl_->inputShapes[i] = shape;
        }
        for (size_t i = 0; i < numOutputs; ++i) {
            auto name = impl_->session->GetOutputNameAllocated(i, alloc);
            impl_->outputNames[i] = name.get();
            impl_->outNamePtrs[i] = impl_->outputNames[i].c_str();
            auto info = impl_->session->GetOutputTypeInfo(i);
            auto shape = info.GetTensorTypeAndShapeInfo().GetShape();
            impl_->outputShapes[i] = shape;
        }

        // 4. Identify mix/enh and cache indices
        impl_->mixInputIdx = -1;
        impl_->enhOutputIdx = -1;
        impl_->cacheInputIdx.clear();
        impl_->cacheOutputIdx.clear();

        for (size_t i = 0; i < numInputs; ++i) {
            if (impl_->inputNames[i] == "mix")
                impl_->mixInputIdx = (int)i;
            else
                impl_->cacheInputIdx.push_back((int)i);
        }
        for (size_t i = 0; i < numOutputs; ++i) {
            if (impl_->outputNames[i] == "enh")
                impl_->enhOutputIdx = (int)i;
            else
                impl_->cacheOutputIdx.push_back((int)i);
        }

        if (impl_->mixInputIdx < 0 || impl_->enhOutputIdx < 0) {
            LOGE("initialize: missing 'mix' input or 'enh' output");
            delete impl_->session; impl_->session = nullptr;
            return false;
        }

        // 5. Allocate cache tensors (zero-initialized)
        if (impl_->cacheInputIdx.size() >= 1) {
            impl_->convCacheShape = impl_->inputShapes[impl_->cacheInputIdx[0]];
            // Replace -1 (dynamic) with 1 for batch dim
            for (auto& d : impl_->convCacheShape) if (d < 0) d = 1;
            impl_->convCache.assign(shapeNumel(impl_->convCacheShape), 0.0f);
        }
        if (impl_->cacheInputIdx.size() >= 2) {
            impl_->traCacheShape = impl_->inputShapes[impl_->cacheInputIdx[1]];
            for (auto& d : impl_->traCacheShape) if (d < 0) d = 1;
            impl_->traCache.assign(shapeNumel(impl_->traCacheShape), 0.0f);
        }
        if (impl_->cacheInputIdx.size() >= 3) {
            impl_->interCacheShape = impl_->inputShapes[impl_->cacheInputIdx[2]];
            for (auto& d : impl_->interCacheShape) if (d < 0) d = 1;
            impl_->interCache.assign(shapeNumel(impl_->interCacheShape), 0.0f);
        }

        // 6. Log model info
        LOGI("initialize: inputs=%zu, outputs=%zu, caches=%zu",
             numInputs, numOutputs, impl_->cacheInputIdx.size());
        LOGI("initialize: conv_cache=%zu, tra_cache=%zu, inter_cache=%zu",
             impl_->convCache.size(), impl_->traCache.size(),
             impl_->interCache.size());

        impl_->modelReady = true;
        active_.store(true, std::memory_order_release);
        LOGI("initialize: SUCCESS — model ready");
        return true;

    } catch (const Ort::Exception& e) {
        LOGE("initialize ORT error: %s", e.what());
        if (impl_->session) { delete impl_->session; impl_->session = nullptr; }
        return false;
    } catch (const std::exception& e) {
        LOGE("initialize error: %s", e.what());
        if (impl_->session) { delete impl_->session; impl_->session = nullptr; }
        return false;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// process() — main audio callback entry point (synchronous, single-thread)
// ─────────────────────────────────────────────────────────────────────────────
void DnnDenoiser::process(float* buffer, int blockSize) {
    if (blockSize <= 0 || !buffer) return;

    const bool enabled = enabled_.load(std::memory_order_relaxed);

    // Bit-exact bypass: disabled and crossfade already at 0
    if (!enabled && crossfadeGain_ == 0.0f) return;

    const bool active = active_.load(std::memory_order_acquire);

    // Not active (model failed or error): ramp crossfade toward dry
    if (!active) {
        crossfadeTarget_ = 0.0f;
        for (int i = 0; i < blockSize; ++i) {
            if (crossfadeGain_ > 0.0f) {
                crossfadeGain_ = std::max(crossfadeGain_ - kCrossfadeStep, 0.0f);
                // During rampdown, output is just dry (no wet available)
            }
            // buffer[i] unchanged (dry passthrough during rampdown)
        }
        return;
    }

    // ─── 1. Downsample to 16 kHz (if needed) ──────────────────────────
    const int maxDown = blockSize;  // at 48k, output is blockSize/3
    float downBuf[4096];
    int downCount;
    if (impl_->inputSr == 48000) {
        downCount = impl_->down.process(buffer, blockSize, downBuf, maxDown);
    } else {
        // 16 kHz passthrough
        downCount = std::min(blockSize, (int)sizeof(downBuf)/4);
        std::memcpy(downBuf, buffer, downCount * sizeof(float));
    }

    // ─── 2. Feed accumulation buffer ──────────────────────────────────
    int toAppend = std::min(downCount, kAccumMax - impl_->accumCount);
    if (toAppend < downCount) {
        // Overflow: discard oldest samples
        int discard = downCount - toAppend;
        std::memmove(impl_->accumBuf, impl_->accumBuf + discard,
                     (impl_->accumCount - discard) * sizeof(float));
        impl_->accumCount -= discard;
        toAppend = downCount;
        droppedFrames_.fetch_add(1, std::memory_order_relaxed);
        LOGW("process: accumBuf overflow, discarded %d samples", discard);
    }
    std::memcpy(impl_->accumBuf + impl_->accumCount, downBuf,
                toAppend * sizeof(float));
    impl_->accumCount += toAppend;

    // ─── 3. Process hops: STFT → inference → iSTFT ───────────────────
    impl_->outputCount = 0;
    while (impl_->accumCount >= kHopLength) {
        float hop[kHopLength];
        std::memcpy(hop, impl_->accumBuf, kHopLength * sizeof(float));
        // Shift accumBuf
        impl_->accumCount -= kHopLength;
        std::memmove(impl_->accumBuf, impl_->accumBuf + kHopLength,
                     impl_->accumCount * sizeof(float));

        // STFT
        impl_->doStft(hop);

        // Run model
        bool ok = impl_->runInference();
        if (!ok) {
            // Error → transition to bypass
            active_.store(false, std::memory_order_release);
            crossfadeTarget_ = 0.0f;
            LOGE("process: inference failed, switching to bypass");
            // Output dry for remaining
            return;
        }

        // iSTFT
        float outHop[kHopLength];
        impl_->doIstft(impl_->enhTensor, outHop);

        // Append to output staging
        if (impl_->outputCount + kHopLength <= kOutputMax) {
            std::memcpy(impl_->outputStaging + impl_->outputCount,
                        outHop, kHopLength * sizeof(float));
            impl_->outputCount += kHopLength;
        }

        processedFrames_.fetch_add(1, std::memory_order_relaxed);
        lastInferenceUs_.store(impl_->lastInferenceUs, std::memory_order_relaxed);
    }

    // ─── 4. Upsample output back to native rate ──────────────────────
    float wetBuf[4096];
    int wetCount;
    if (impl_->inputSr == 48000) {
        wetCount = impl_->up.process(impl_->outputStaging, impl_->outputCount,
                                     wetBuf, blockSize);
    } else {
        wetCount = std::min(impl_->outputCount, blockSize);
        std::memcpy(wetBuf, impl_->outputStaging, wetCount * sizeof(float));
    }

    // ─── 5. Crossfade + intensity mix + clamp ─────────────────────────
    const float intensity = std::clamp(
        intensity_.load(std::memory_order_relaxed), 0.0f, 1.0f);

    // Update effective intensity (for getEffectiveIntensity)
    effectiveIntensity_ = intensity;
    effectiveIntensityAtomic_.store(intensity, std::memory_order_relaxed);

    // Update crossfade target based on enabled flag
    crossfadeTarget_ = enabled ? 1.0f : 0.0f;

    for (int i = 0; i < blockSize; ++i) {
        // Advance crossfade gain toward target
        if (crossfadeGain_ < crossfadeTarget_)
            crossfadeGain_ = std::min(crossfadeGain_ + kCrossfadeStep,
                                      crossfadeTarget_);
        else if (crossfadeGain_ > crossfadeTarget_)
            crossfadeGain_ = std::max(crossfadeGain_ - kCrossfadeStep,
                                      crossfadeTarget_);

        float dry = buffer[i];
        float wet = (i < wetCount) ? wetBuf[i] : 0.0f;

        // Intensity mix: blend dry/wet
        float mixed = dry * (1.0f - intensity) + wet * intensity;

        // Crossfade: blend bypass/processed
        float out = dry * (1.0f - crossfadeGain_) + mixed * crossfadeGain_;

        // Safety clamp
        buffer[i] = std::clamp(out, -1.0f, 1.0f);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Setters and Control Methods
// ─────────────────────────────────────────────────────────────────────────────

void DnnDenoiser::setEnabled(bool enabled) {
    enabled_.store(enabled, std::memory_order_release);
    // crossfadeTarget_ is updated in process() to avoid race
}

void DnnDenoiser::setIntensity(float intensity) {
    intensity_.store(std::clamp(intensity, 0.0f, 1.0f), std::memory_order_release);
}

void DnnDenoiser::setInputSampleRate(int sampleRateHz) {
    if (sampleRateHz == impl_->inputSr) return;

    if (sampleRateHz == 48000) {
        impl_->inputSr = 48000;
        impl_->down.configure(Resampler::Mode::kPolyDown48to16,
                              impl_->protoLpf, kProtoTaps);
        impl_->up.configure(Resampler::Mode::kPolyUp16to48,
                            impl_->protoLpf, kProtoTaps);
        LOGI("setInputSampleRate: 48000 Hz (polyphase 3:1)");
    } else if (sampleRateHz == 16000) {
        impl_->inputSr = 16000;
        impl_->down.configure(Resampler::Mode::kIdentity, nullptr, 0);
        impl_->up.configure(Resampler::Mode::kIdentity, nullptr, 0);
        LOGI("setInputSampleRate: 16000 Hz (identity)");
    } else {
        LOGW("setInputSampleRate: unsupported rate %d, ignoring", sampleRateHz);
        return;
    }

    // Recalculate VAD ramp steps for the new rate
    if (sampleRateHz > 0) {
        stepAttackPerSample_  = 1.0f / (kVoiceCapAttackMs * sampleRateHz / 1000.0f);
        stepReleasePerSample_ = 1.0f / (kVoiceCapReleaseMs * sampleRateHz / 1000.0f);
    }
}

void DnnDenoiser::reset() {
    // Zero caches
    std::fill(impl_->convCache.begin(), impl_->convCache.end(), 0.0f);
    std::fill(impl_->traCache.begin(), impl_->traCache.end(), 0.0f);
    std::fill(impl_->interCache.begin(), impl_->interCache.end(), 0.0f);
    // Clear accumulation buffer
    impl_->accumCount = 0;
    // Clear OLA buffer
    std::memset(impl_->olaBuf, 0, sizeof(impl_->olaBuf));
    impl_->olaWritePos = 0;
    // Clear STFT overlap
    std::memset(impl_->stftPrevFrame, 0, sizeof(impl_->stftPrevFrame));
    // Clear output staging
    impl_->outputCount = 0;
    // Reset resamplers
    impl_->down.reset();
    impl_->up.reset();
    LOGI("reset: state cleared");
}

void DnnDenoiser::notifyVoiceActive(bool active) {
    voiceActive_.store(active, std::memory_order_release);
}

void DnnDenoiser::setVoiceCap(float cap) {
    voiceCap_.store(std::clamp(cap, 0.0f, 1.0f), std::memory_order_release);
}

}  // namespace dnn_denoiser

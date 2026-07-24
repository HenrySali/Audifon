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
#include <cstring>
#include <string>
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
constexpr int kFftN = kFftSize;          // 512
constexpr int kMaxBlock48 = 4096;        // max block size at 48 kHz
constexpr int kMaxBlock16 = 1400;        // max 4096/3 + margin
constexpr float kCrossfadeStep = 1.0f / static_cast<float>(kXfadeSamples);

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
// VORBIS WINDOW — w(n) = sin(π/2 · sin²(π·n/N)), N=320
// Perfect reconstruction with 50% overlap: w²(n) + w²(n+hop) = 1
// ═══════════════════════════════════════════════════════════════════════════════

static void computeVorbisWindow(float* w, int N) {
    for (int n = 0; n < N; ++n) {
        float sinArg = std::sin(kPi * static_cast<float>(n) / static_cast<float>(N));
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
// RADIX-2 FFT (512-point Cooley-Tukey, in-place)
// ═══════════════════════════════════════════════════════════════════════════════

static void bitReverse(float* re, float* im, int N) {
    for (int i = 1, j = 0; i < N; ++i) {
        int bit = N >> 1;
        while (j & bit) { j ^= bit; bit >>= 1; }
        j ^= bit;
        if (i < j) {
            std::swap(re[i], re[j]);
            std::swap(im[i], im[j]);
        }
    }
}

static void fftRadix2(float* re, float* im, int N, bool inverse) {
    bitReverse(re, im, N);
    const float sign = inverse ? 1.0f : -1.0f;
    for (int len = 2; len <= N; len <<= 1) {
        float ang = sign * 2.0f * kPi / static_cast<float>(len);
        float wRe = std::cos(ang);
        float wIm = std::sin(ang);
        for (int i = 0; i < N; i += len) {
            float curRe = 1.0f, curIm = 0.0f;
            for (int j = 0; j < len / 2; ++j) {
                int u = i + j;
                int v = i + j + len / 2;
                float tRe = curRe * re[v] - curIm * im[v];
                float tIm = curRe * im[v] + curIm * re[v];
                re[v] = re[u] - tRe;
                im[v] = im[u] - tIm;
                re[u] += tRe;
                im[u] += tIm;
                float newCurRe = curRe * wRe - curIm * wIm;
                curIm = curRe * wIm + curIm * wRe;
                curRe = newCurRe;
            }
        }
    }
    if (inverse) {
        float invN = 1.0f / static_cast<float>(N);
        for (int i = 0; i < N; ++i) { re[i] *= invN; im[i] *= invN; }
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

    // ─── Wet output ring buffer @16kHz ─────────────────────────────────────────
    float wetRing[kWetBufCap]{};
    int   wetWrite = 0;
    int   wetRead  = 0;

    // ─── Resampler scratch buffers ─────────────────────────────────────────────
    float downBuf[kMaxBlock16]{};
    float upBuf[kMaxBlock48]{};

    // ─── Polyphase resamplers ──────────────────────────────────────────────────
    float proto[kProtoTaps]{};
    PolyDown down;
    PolyUp   up;

    // ─── Constructor ───────────────────────────────────────────────────────────
    Impl() {
        opts.SetIntraOpNumThreads(1);
        opts.SetInterOpNumThreads(1);
        opts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        designLpf(proto, kProtoTaps);
        down.init(proto);
        up.init(proto);
        computeVorbisWindow(window, kWinSize);
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
        wetWrite = 0;
        wetRead = 0;
        std::memset(wetRing, 0, sizeof(wetRing));
        down.reset();
        up.reset();
        // Restore state from metadata init values (not zeros)
        if (!stateInit.empty()) {
            stateData = stateInit;
        }
    }

    // ─── Wet ring helpers ────────────────────────────────────────────────────
    int wetAvailable() const {
        int avail = wetWrite - wetRead;
        if (avail < 0) avail += kWetBufCap;
        return avail;
    }

    void wetPush(float sample) {
        wetRing[wetWrite] = sample;
        wetWrite = (wetWrite + 1) % kWetBufCap;
        if (wetWrite == wetRead) {
            wetRead = (wetRead + 1) % kWetBufCap;  // overwrite oldest
        }
    }

    float wetPop() {
        if (wetRead == wetWrite) return 0.0f;  // underrun: silence
        float s = wetRing[wetRead];
        wetRead = (wetRead + 1) % kWetBufCap;
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

        // 3. Zero-pad to 512 and FFT
        std::memset(fftRe, 0, kFftN * sizeof(float));
        std::memset(fftIm, 0, kFftN * sizeof(float));
        std::memcpy(fftRe, frame, kWinSize * sizeof(float));

        fftRadix2(fftRe, fftIm, kFftN, false);

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

        // 9. iSTFT: unpack enhanced → Hermitian → IFFT → synth window → OLA
        std::memset(fftRe, 0, kFftN * sizeof(float));
        std::memset(fftIm, 0, kFftN * sizeof(float));
        for (int k = 0; k < kNBins; ++k) {
            fftRe[k] = enhPtr[k * 2];
            fftIm[k] = enhPtr[k * 2 + 1];
        }
        // Hermitian symmetry for real-valued output
        for (int k = 1; k < kNBins - 1; ++k) {
            fftRe[kFftN - k] =  fftRe[k];
            fftIm[kFftN - k] = -fftIm[k];
        }

        fftRadix2(fftRe, fftIm, kFftN, true);  // IFFT

        // 10. Apply synthesis window (Vorbis) to first 320 samples + OLA
        for (int i = 0; i < kWinSize; ++i) {
            float synth = fftRe[i] * window[i];
            int pos = (olaPos + i) % kWinSize;
            olaBuf[pos] += synth;
        }

        // 11. Extract oldest 160 samples from OLA → push to wet ring
        for (int i = 0; i < kHopSize; ++i) {
            int pos = (olaPos + i) % kWinSize;
            wetPush(olaBuf[pos]);
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

    // ─── Step 3: Process complete hops ─────────────────────────────────────────
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
    }

    // ─── Step 4: Pull wet from ring and upsample 16→48 ────────────────────────
    int wetAvail = impl_->wetAvailable();
    int nUp = 0;

    if (wetAvail > 0) {
        // Pull wet samples into a temp @16kHz
        float temp16[kMaxBlock16];
        int toPull = std::min(wetAvail, kMaxBlock16);
        for (int i = 0; i < toPull; ++i) {
            temp16[i] = impl_->wetPop();
        }
        // Upsample 16→48
        nUp = impl_->up.process(temp16, toPull, impl_->upBuf, kMaxBlock48);
    }

    // ─── Step 5: Crossfade + intensity mix + clamp ─────────────────────────────
    int wetIdx = 0;
    for (int i = 0; i < blockSize; ++i) {
        // Ramp crossfade gain toward target
        if (crossfadeGain_ < crossfadeTarget_) {
            crossfadeGain_ = std::min(crossfadeGain_ + kCrossfadeStep,
                                      crossfadeTarget_);
        } else if (crossfadeGain_ > crossfadeTarget_) {
            crossfadeGain_ = std::max(crossfadeGain_ - kCrossfadeStep,
                                      crossfadeTarget_);
        }

        float wet = (wetIdx < nUp) ? impl_->upBuf[wetIdx++] : 0.0f;
        float dry = buffer[i];
        float gain = intensity * crossfadeGain_;

        // Mix: out = dry*(1-gain) + wet*gain
        float out = dry * (1.0f - gain) + wet * gain;

        // Clamp [-1, +1]
        buffer[i] = std::clamp(out, -1.0f, 1.0f);
    }

    effectiveIntensity_ = intensity * crossfadeGain_;
}

} // namespace dpdfnet_denoiser

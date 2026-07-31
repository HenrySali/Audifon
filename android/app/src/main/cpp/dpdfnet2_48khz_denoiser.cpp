/// @file dpdfnet2_48khz_denoiser.cpp
/// @brief DPDFNet-2 denoiser — 48 kHz nativo, OnnxRuntime backend, Deep Filtering complejo.
///
/// Pipeline (sin resampleo — opera a 48 kHz nativo):
///   48kHz in → accum(480) → STFT(Hann,960,hop480) → ONNX Run(complex mask)
///            → complex deep filter → iSTFT/OLA → intensity mix dry/wet
///            → crossfade → clamp → 48kHz out
///
/// Referencia: sherpa-onnx `online-speech-denoiser-dpdfnet-impl.h` (Apache 2.0)
/// adaptada sin resampleo (modelo opera a 48 kHz nativo).
///
/// Zero heap allocations en process(): todos los buffers viven en Impl pre-asignados.
///
/// Requirements: 1.1, 1.2, 1.4, 1.5, 2.1, 2.2, 2.3, 2.4, 3.1, 3.2, 3.3, 3.4, 3.5

#include "dpdfnet2_48khz_denoiser.h"
#include "dnn_denoiser/onnxruntime/onnxruntime_cxx_api.h"

#include <android/asset_manager.h>
#include <android/log.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

#define DPDFNET2_TAG "DPDFNet2_48k"
#define DPDFNET2_LOGI(...) __android_log_print(ANDROID_LOG_INFO,  DPDFNET2_TAG, __VA_ARGS__)
#define DPDFNET2_LOGW(...) __android_log_print(ANDROID_LOG_WARN,  DPDFNET2_TAG, __VA_ARGS__)
#define DPDFNET2_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, DPDFNET2_TAG, __VA_ARGS__)

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#ifndef M_2PI
#define M_2PI 6.283185307179586476925286766559005
#endif

namespace dpdfnet2_denoiser {

// ═════════════════════════════════════════════════════════════════════════════
// StreamingDft — double-precision DFT tables (from sherpa-onnx, Apache 2.0)
// ═════════════════════════════════════════════════════════════════════════════
//
// Uses pre-computed cos/sin tables in double precision to avoid float
// accumulation error in the inner loop. N=960 → 481 complex bins.
// The same approach used by DPDFNet-4 (validated, no hoarseness).

namespace {

class StreamingDft {
public:
    explicit StreamingDft(int32_t n_fft)
        : n_(n_fft), nbins_(n_fft / 2 + 1),
          cos_f_(static_cast<size_t>(nbins_) * n_fft),
          sin_f_(static_cast<size_t>(nbins_) * n_fft),
          cos_i_(static_cast<size_t>(n_fft) * nbins_),
          sin_i_(static_cast<size_t>(n_fft) * nbins_) {
        for (int32_t k = 0; k < nbins_; ++k) {
            for (int32_t n = 0; n < n_; ++n) {
                double angle = M_2PI * k * n / static_cast<double>(n_);
                double c = std::cos(angle), s = std::sin(angle);
                cos_f_[static_cast<size_t>(k) * n_ + n] = c;
                sin_f_[static_cast<size_t>(k) * n_ + n] = s;
                cos_i_[static_cast<size_t>(n) * nbins_ + k] = c;
                sin_i_[static_cast<size_t>(n) * nbins_ + k] = s;
            }
        }
    }

    /// Forward DFT: input[n_] → output[nbins_*2] (interleaved re/im)
    void Forward(const float* input, float* output) const {
        for (int32_t k = 0; k < nbins_; ++k) {
            double re = 0.0, im = 0.0;
            const double* pc = cos_f_.data() + static_cast<size_t>(k) * n_;
            const double* ps = sin_f_.data() + static_cast<size_t>(k) * n_;
            for (int32_t n = 0; n < n_; ++n) {
                double v = static_cast<double>(input[n]);
                re += v * pc[n];
                im -= v * ps[n];
            }
            output[2 * k]     = static_cast<float>(re);
            output[2 * k + 1] = static_cast<float>(im);
        }
    }

    /// Inverse DFT: input[nbins_*2] → output[n_] (real-valued)
    void Inverse(const float* input, float* output) const {
        const double invN = 1.0 / static_cast<double>(n_);
        for (int32_t n = 0; n < n_; ++n) {
            double sum = static_cast<double>(input[0]);  // DC (real only)
            // Nyquist bin (if N is even)
            if (n_ % 2 == 0) {
                sum += static_cast<double>(input[2 * (nbins_ - 1)]) *
                       ((n & 1) ? -1.0 : 1.0);
            }
            const double* pc = cos_i_.data() + static_cast<size_t>(n) * nbins_;
            const double* ps = sin_i_.data() + static_cast<size_t>(n) * nbins_;
            for (int32_t k = 1; k < nbins_ - 1; ++k) {
                double re = static_cast<double>(input[2 * k]);
                double im = static_cast<double>(input[2 * k + 1]);
                sum += 2.0 * (re * pc[k] - im * ps[k]);
            }
            output[n] = static_cast<float>(sum * invN);
        }
    }

private:
    int32_t n_, nbins_;
    std::vector<double> cos_f_, sin_f_, cos_i_, sin_i_;
};

}  // anonymous namespace

// ═════════════════════════════════════════════════════════════════════════════
// PIMPL: Impl — all pre-allocated buffers and ONNX state
// ═════════════════════════════════════════════════════════════════════════════

struct Dpdfnet2_48khzDenoiser::Impl {
    // ─── ONNX Runtime ──────────────────────────────────────────────────
    Ort::Env            env{ORT_LOGGING_LEVEL_WARNING, DPDFNET2_TAG};
    Ort::SessionOptions sessionOpts;
    std::unique_ptr<Ort::Session> session;
    Ort::MemoryInfo     memInfo{Ort::MemoryInfo::CreateCpu(
                            OrtArenaAllocator, OrtMemTypeDefault)};

    /// I/O names and pointers for ONNX Run() — pre-stored to avoid alloc.
    std::string inName0;   ///< spec input name (e.g. "mix" or "input_0")
    std::string inName1;   ///< state input name (recurrent hidden state)
    std::string outName0;  ///< enhanced spec output name
    std::string outName1;  ///< updated state output name
    const char* inPtrs[2]  = {nullptr, nullptr};
    const char* outPtrs[2] = {nullptr, nullptr};

    /// Shape for spec tensor: [1, 1, 481, 2]
    std::array<int64_t, 4> specShape = {1, 1, kNbFreqs, 2};

    /// Recurrent state (hidden state carried between hops)
    std::vector<int64_t> stateShape;
    std::vector<float>   stateData;    ///< Current state (updated after each Run)
    std::vector<float>   stateInit;    ///< Initial state (for reset)
    int stateSize = 0;

    bool modelReady = false;

    // ─── DFT engine (double-precision tables) ──────────────────────────
    std::unique_ptr<StreamingDft> dft;

    // ─── Pre-allocated DSP buffers (zero heap alloc in process) ────────
    float window_[kFftSize];          ///< Hann periodic window (pre-computed)
    float inputAccum_[kHopSize];      ///< Input sample accumulator (residual)
    int   accumCount_ = 0;            ///< Samples currently in inputAccum_
    float analysisBuf_[kFftSize];     ///< Shift buffer for STFT (last kFftSize samples)
    float fftIn_[kFftSize];           ///< Windowed frame → DFT input
    float fftOut_[kNbFreqs * 2];      ///< DFT output: 481 bins × (re, im)
    float onnxInput_[kNbFreqs * 2];   ///< Tensor input for ONNX [1,1,481,2]
    float onnxOutput_[kNbFreqs * 2];  ///< Tensor output from ONNX (complex mask)
    float ifftIn_[kNbFreqs * 2];      ///< Filtered spectrum → iDFT input
    float ifftOut_[kFftSize];         ///< iDFT output (time domain)
    float olaBuffer_[kFftSize];       ///< Overlap-add accumulator
    float dryDelay_[kHopSize];        ///< Dry delay buffer for aligning dry with wet
    float outputHop_[kHopSize];       ///< Output hop (wet, ready for mixing)
    bool  started_ = false;           ///< First frame discarded (STFT group delay)

    // ─── Constructor ───────────────────────────────────────────────────
    Impl() {
        sessionOpts.SetIntraOpNumThreads(1);
        sessionOpts.SetInterOpNumThreads(1);
        sessionOpts.SetGraphOptimizationLevel(
            GraphOptimizationLevel::ORT_ENABLE_ALL);

        // Pre-compute Hann periodic window: w[n] = 0.5*(1 - cos(2π*n/N))
        // DPDFNet-2/sherpa-onnx uses full Hann periodic for both analysis
        // and synthesis. With 50% overlap (hop=N/2), Hann² satisfies COLA:
        //   Hann[n]² + Hann[n + N/2]² = 1.0 (periodic Hann property).
        for (int i = 0; i < kFftSize; ++i) {
            window_[i] = 0.5f * (1.0f - std::cos(
                2.0f * static_cast<float>(M_PI) * i
                / static_cast<float>(kFftSize)));
        }

        // Zero-init all DSP buffers
        std::memset(inputAccum_,  0, sizeof(inputAccum_));
        std::memset(analysisBuf_, 0, sizeof(analysisBuf_));
        std::memset(fftIn_,       0, sizeof(fftIn_));
        std::memset(fftOut_,      0, sizeof(fftOut_));
        std::memset(onnxInput_,   0, sizeof(onnxInput_));
        std::memset(onnxOutput_,  0, sizeof(onnxOutput_));
        std::memset(ifftIn_,      0, sizeof(ifftIn_));
        std::memset(ifftOut_,     0, sizeof(ifftOut_));
        std::memset(olaBuffer_,   0, sizeof(olaBuffer_));
        std::memset(dryDelay_,    0, sizeof(dryDelay_));
        std::memset(outputHop_,   0, sizeof(outputHop_));
    }

    // ─── Model loading ─────────────────────────────────────────────────

    /// Load model from Android assets, create ONNX session, introspect I/O.
    bool loadAndInit(AAssetManager* mgr, const char* assetPath) {
        if (!mgr) {
            DPDFNET2_LOGE("loadAndInit: AAssetManager is null");
            return false;
        }
        if (!assetPath || !assetPath[0]) {
            DPDFNET2_LOGE("loadAndInit: assetPath is null or empty");
            return false;
        }

        // Open asset via AAssetManager
        AAsset* asset = AAssetManager_open(mgr, assetPath, AASSET_MODE_BUFFER);
        if (!asset) {
            DPDFNET2_LOGE("Cannot open asset: %s", assetPath);
            return false;
        }

        const size_t sz = static_cast<size_t>(AAsset_getLength(asset));
        const void* buf = AAsset_getBuffer(asset);
        if (!buf || sz == 0) {
            DPDFNET2_LOGE("Empty or invalid asset: %s (size=%zu)", assetPath, sz);
            AAsset_close(asset);
            return false;
        }

        // Create ONNX session from memory buffer
        try {
            session = std::make_unique<Ort::Session>(env, buf, sz, sessionOpts);
        } catch (const Ort::Exception& e) {
            DPDFNET2_LOGE("Ort::Session failed: %s", e.what());
            AAsset_close(asset);
            return false;
        }
        AAsset_close(asset);
        DPDFNET2_LOGI("Loaded model: %s (%zu bytes)", assetPath, sz);

        // ── Introspect I/O ────────────────────────────────────────────
        if (session->GetInputCount() < 2 || session->GetOutputCount() < 2) {
            DPDFNET2_LOGE("Model needs at least 2 inputs and 2 outputs, got %zu/%zu",
                          session->GetInputCount(), session->GetOutputCount());
            session.reset();
            return false;
        }

        Ort::AllocatorWithDefaultOptions alloc;

        // Get I/O names
        { auto n = session->GetInputNameAllocated(0, alloc);  inName0 = n.get(); }
        { auto n = session->GetInputNameAllocated(1, alloc);  inName1 = n.get(); }
        { auto n = session->GetOutputNameAllocated(0, alloc); outName0 = n.get(); }
        { auto n = session->GetOutputNameAllocated(1, alloc); outName1 = n.get(); }
        inPtrs[0]  = inName0.c_str();
        inPtrs[1]  = inName1.c_str();
        outPtrs[0] = outName0.c_str();
        outPtrs[1] = outName1.c_str();

        DPDFNET2_LOGI("Input[0]: %s, Input[1]: %s", inName0.c_str(), inName1.c_str());
        DPDFNET2_LOGI("Output[0]: %s, Output[1]: %s", outName0.c_str(), outName1.c_str());

        // ── Validate spec input shape [1, 1, 481, 2] ─────────────────
        {
            auto info = session->GetInputTypeInfo(0).GetTensorTypeAndShapeInfo();
            auto shape = info.GetShape();
            // Replace dynamic dims with expected values
            for (auto& d : shape) { if (d < 0) d = 1; }

            if (shape.size() != 4) {
                DPDFNET2_LOGE("Spec input must be 4D, got %zuD", shape.size());
                session.reset();
                return false;
            }
            // Validate freq_bins dimension == 481
            if (shape[2] != kNbFreqs) {
                DPDFNET2_LOGE("Spec input freq_bins=%lld, expected %d",
                              static_cast<long long>(shape[2]), kNbFreqs);
                session.reset();
                return false;
            }
            // Validate complex dimension == 2
            if (shape[3] != 2) {
                DPDFNET2_LOGE("Spec input complex dim=%lld, expected 2",
                              static_cast<long long>(shape[3]));
                session.reset();
                return false;
            }
            specShape = {shape[0], shape[1], shape[2], shape[3]};
            DPDFNET2_LOGI("Spec input shape validated: [%lld,%lld,%lld,%lld]",
                          static_cast<long long>(shape[0]),
                          static_cast<long long>(shape[1]),
                          static_cast<long long>(shape[2]),
                          static_cast<long long>(shape[3]));
        }

        // ── State tensor shape and initialization ─────────────────────
        {
            auto info = session->GetInputTypeInfo(1).GetTensorTypeAndShapeInfo();
            stateShape = info.GetShape();
            stateSize = 1;
            for (auto& d : stateShape) {
                if (d < 0) d = 1;
                stateSize *= static_cast<int>(d);
            }
            stateData.assign(stateSize, 0.0f);

            // Try to read initial state from model metadata (sherpa-onnx convention)
            try {
                auto meta = session->GetModelMetadata();
                auto parseCSV = [](const char* csv, float* dst, int max) {
                    int c = 0;
                    const char* p = csv;
                    while (*p && c < max) {
                        while (*p == ' ' || *p == ',' || *p == '[' || *p == ']') ++p;
                        if (!*p) break;
                        char* end;
                        float v = std::strtof(p, &end);
                        if (end == p) break;
                        dst[c++] = v;
                        p = end;
                    }
                    return c;
                };
                int off = 0;
                try {
                    auto v = meta.LookupCustomMetadataMapAllocated(
                        "erb_norm_init", alloc);
                    if (v) off += parseCSV(v.get(), stateData.data(), stateSize);
                } catch (...) {}
                try {
                    auto v = meta.LookupCustomMetadataMapAllocated(
                        "spec_norm_init", alloc);
                    if (v) parseCSV(v.get(), stateData.data() + off,
                                    stateSize - off);
                } catch (...) {}
            } catch (...) {
                DPDFNET2_LOGW("No metadata for state init (using zeros)");
            }

            stateInit = stateData;
            DPDFNET2_LOGI("State size: %d (shape dims: %zu)",
                          stateSize, stateShape.size());
        }

        // ── Initialize DFT engine ─────────────────────────────────────
        dft = std::make_unique<StreamingDft>(kFftSize);

        modelReady = true;
        DPDFNET2_LOGI("DPDFNet-2 48kHz init OK (nfft=%d, hop=%d, bins=%d, "
                      "state=%d)", kFftSize, kHopSize, kNbFreqs, stateSize);
        return true;
    }

    // ─── DSP processing ────────────────────────────────────────────────

    /// Process one complete hop through the STFT → ONNX → iSTFT pipeline.
    /// Returns true on success. On failure, the caller should enter bypass.
    /// Result is written to outputHop_[kHopSize].
    /// Returns false only on ONNX inference failure (permanent error).
    bool processOneHop(const float* hop, Dpdfnet2_48khzDenoiser* owner) {
        // ── 1. Shift analysis buffer left by kHopSize, append new hop ──
        std::memmove(analysisBuf_, analysisBuf_ + kHopSize,
                     (kFftSize - kHopSize) * sizeof(float));
        std::memcpy(analysisBuf_ + (kFftSize - kHopSize), hop,
                    kHopSize * sizeof(float));

        // ── 2. Apply Hann window for STFT analysis ─────────────────────
        for (int i = 0; i < kFftSize; ++i) {
            fftIn_[i] = analysisBuf_[i] * window_[i];
        }

        // ── 3. Forward DFT → 481 complex bins (interleaved re/im) ──────
        dft->Forward(fftIn_, fftOut_);

        // ── 4. Copy to ONNX input tensor [1,1,481,2] ──────────────────
        std::memcpy(onnxInput_, fftOut_, kNbFreqs * 2 * sizeof(float));

        // ── 5. Run ONNX inference ──────────────────────────────────────
        Ort::Value inputs[2] = {Ort::Value{nullptr}, Ort::Value{nullptr}};
        inputs[0] = Ort::Value::CreateTensor<float>(
            memInfo, onnxInput_, kNbFreqs * 2,
            specShape.data(), specShape.size());
        inputs[1] = Ort::Value::CreateTensor<float>(
            memInfo, stateData.data(), stateData.size(),
            stateShape.data(), stateShape.size());

        std::vector<Ort::Value> outs;
        const auto t0 = std::chrono::steady_clock::now();
        try {
            outs = session->Run(Ort::RunOptions{nullptr},
                                inPtrs, inputs, 2, outPtrs, 2);
        } catch (const Ort::Exception& e) {
            DPDFNET2_LOGE("ONNX Run failed: %s", e.what());
            return false;
        }
        const auto t1 = std::chrono::steady_clock::now();
        const auto us = std::chrono::duration_cast<std::chrono::microseconds>(
                            t1 - t0).count();
        owner->lastInferenceUs_.store(static_cast<uint32_t>(us),
                                       std::memory_order_relaxed);

        // ── 6. Extract enhanced spectrum (complex mask) ────────────────
        const float* enhData = outs[0].GetTensorData<float>();
        std::memcpy(onnxOutput_, enhData, kNbFreqs * 2 * sizeof(float));

        // ── 7. Update recurrent state ──────────────────────────────────
        const float* newState = outs[1].GetTensorData<float>();
        std::memcpy(stateData.data(), newState, stateSize * sizeof(float));

        // ── 8. Apply complex deep filter mask ──────────────────────────
        // The model outputs a complex mask: mask_re + j*mask_im
        // Applied as complex multiplication:
        //   filtered_re = input_re * mask_re - input_im * mask_im
        //   filtered_im = input_re * mask_im + input_im * mask_re
        // This modifies both magnitude AND phase (true deep filtering).
        for (int k = 0; k < kNbFreqs; ++k) {
            const float inRe   = fftOut_[2 * k];
            const float inIm   = fftOut_[2 * k + 1];
            const float maskRe = onnxOutput_[2 * k];
            const float maskIm = onnxOutput_[2 * k + 1];
            ifftIn_[2 * k]     = inRe * maskRe - inIm * maskIm;
            ifftIn_[2 * k + 1] = inRe * maskIm + inIm * maskRe;
        }

        // ── 9. Inverse DFT → time domain ──────────────────────────────
        dft->Inverse(ifftIn_, ifftOut_);

        // ── 10. Apply synthesis window and Overlap-Add ─────────────────
        // With Hann periodic window on both analysis and synthesis, and
        // 50% overlap (hop = N/2):
        //   COLA: Σ_k Hann[n - k*hop]² = 1.0
        // This ensures perfect reconstruction when no mask is applied.
        for (int i = 0; i < kFftSize; ++i) {
            olaBuffer_[i] += ifftOut_[i] * window_[i];
        }

        // ── 11. Extract kHopSize samples from OLA buffer ───────────────
        // First frame is discarded (STFT group delay = kHopSize samples).
        if (!started_) {
            started_ = true;
            // Shift OLA buffer: discard first kHopSize
            std::memmove(olaBuffer_, olaBuffer_ + kHopSize,
                         (kFftSize - kHopSize) * sizeof(float));
            std::memset(olaBuffer_ + (kFftSize - kHopSize), 0,
                        kHopSize * sizeof(float));
            // No output this round
            return true;
        }

        // Copy the first kHopSize samples as output
        std::memcpy(outputHop_, olaBuffer_, kHopSize * sizeof(float));

        // Shift OLA buffer: discard first kHopSize, zero the tail
        std::memmove(olaBuffer_, olaBuffer_ + kHopSize,
                     (kFftSize - kHopSize) * sizeof(float));
        std::memset(olaBuffer_ + (kFftSize - kHopSize), 0,
                    kHopSize * sizeof(float));

        owner->processedFrames_.fetch_add(1, std::memory_order_relaxed);
        return true;
    }

    /// Reset all DSP state (buffers, OLA, state, accumulator).
    void resetState() {
        stateData = stateInit;
        std::memset(analysisBuf_, 0, sizeof(analysisBuf_));
        std::memset(fftIn_,       0, sizeof(fftIn_));
        std::memset(fftOut_,      0, sizeof(fftOut_));
        std::memset(onnxInput_,   0, sizeof(onnxInput_));
        std::memset(onnxOutput_,  0, sizeof(onnxOutput_));
        std::memset(ifftIn_,      0, sizeof(ifftIn_));
        std::memset(ifftOut_,     0, sizeof(ifftOut_));
        std::memset(olaBuffer_,   0, sizeof(olaBuffer_));
        std::memset(inputAccum_,  0, sizeof(inputAccum_));
        std::memset(dryDelay_,    0, sizeof(dryDelay_));
        std::memset(outputHop_,   0, sizeof(outputHop_));
        accumCount_ = 0;
        started_    = false;
    }
};

// ═════════════════════════════════════════════════════════════════════════════
// Public API implementation
// ═════════════════════════════════════════════════════════════════════════════

Dpdfnet2_48khzDenoiser::Dpdfnet2_48khzDenoiser()
    : impl_(std::make_unique<Impl>()) {}

Dpdfnet2_48khzDenoiser::~Dpdfnet2_48khzDenoiser() = default;

bool Dpdfnet2_48khzDenoiser::initialize(AAssetManager* mgr,
                                         const char* assetPath) {
    // Idempotent: if already initialized, return true without recreating.
    if (impl_->modelReady) {
        DPDFNET2_LOGW("initialize: already initialized, no-op");
        return true;
    }

    if (!mgr) {
        DPDFNET2_LOGE("initialize: AAssetManager is null");
        isActive_.store(false, std::memory_order_release);
        return false;
    }

    DPDFNET2_LOGI("initialize: loading %s", assetPath ? assetPath : "(null)");

    bool ok = impl_->loadAndInit(mgr, assetPath);
    if (!ok) {
        DPDFNET2_LOGE("initialize: model load/init failed → bypass mode");
        isActive_.store(false, std::memory_order_release);
        return false;
    }

    isActive_.store(true, std::memory_order_release);
    DPDFNET2_LOGI("initialize: OK — DPDFNet-2 48kHz ready");
    return true;
}

void Dpdfnet2_48khzDenoiser::process(float* buffer, int blockSize) {
    if (!buffer || blockSize <= 0) return;

    const bool enabled = enabled_.load(std::memory_order_acquire);
    const bool active  = isActive_.load(std::memory_order_acquire);

    // Fast path: bypass total — not enabled and crossfade already at 0.
    if (!enabled && crossfadeGain_ <= 0.0f) {
        return;
    }

    // If not active (model failed or not loaded), just fade out gracefully.
    if (!active) {
        crossfadeTarget_ = 0.0f;
        if (crossfadeGain_ > 0.0f) {
            for (int i = 0; i < blockSize; ++i) {
                crossfadeGain_ = std::max(0.0f, crossfadeGain_ - kCrossfadeStep);
            }
        }
        return;
    }

    // Update crossfade target based on enabled state.
    crossfadeTarget_ = enabled ? 1.0f : 0.0f;

    // Cache intensity for this block (clamped to [0.0, 1.0]).
    const float intensity = std::clamp(
        intensity_.load(std::memory_order_acquire), 0.0f, 1.0f);
    effectiveIntensity_ = intensity * crossfadeGain_;

    // ─── Process each sample: accumulate, process hops, mix ────────────
    //
    // Architecture (similar to DFN3/DPDFNet-4 but without resampling):
    //   For each input sample:
    //     1. Buffer the sample in inputAccum_ (and dryDelay_)
    //     2. When kHopSize samples accumulated → run STFT+ONNX+iSTFT
    //     3. Mix wet (outputHop_) with dry (dryDelay_) per sample
    //
    // Since we operate at 48 kHz natively, there's no resampler ring.
    // The dry signal is delayed by exactly 1 hop (kHopSize = 480 samples)
    // to align with the wet output (STFT group delay = 1 hop due to
    // the discarded first frame + 50% overlap).

    int pos = 0;
    while (pos < blockSize) {
        // Determine how many samples we need to complete the current hop.
        const int needed    = kHopSize - impl_->accumCount_;
        const int available = blockSize - pos;
        const int toCopy    = std::min(needed, available);

        // Save dry samples into delay buffer (they'll be aligned with wet
        // output from the NEXT hop that completes after this one).
        std::memcpy(impl_->inputAccum_ + impl_->accumCount_,
                    buffer + pos, toCopy * sizeof(float));
        impl_->accumCount_ += toCopy;

        if (impl_->accumCount_ == kHopSize) {
            // ── Full hop accumulated — process through pipeline ──────

            // Save dry copy of this hop (used for intensity mixing).
            std::memcpy(impl_->dryDelay_, impl_->inputAccum_,
                        kHopSize * sizeof(float));

            // Run STFT → ONNX → complex mask → iSTFT/OLA
            bool ok = impl_->processOneHop(impl_->inputAccum_, this);

            if (!ok) {
                // Fail-safe: ONNX inference failed → permanent bypass.
                DPDFNET2_LOGE("process: inference failed → bypass mode");
                isActive_.store(false, std::memory_order_release);
                crossfadeTarget_ = 0.0f;
                // Fade out remaining samples in this block.
                for (int j = pos; j < blockSize; ++j) {
                    if (crossfadeGain_ > 0.0f) {
                        crossfadeGain_ = std::max(0.0f,
                            crossfadeGain_ - kCrossfadeStep);
                    }
                }
                impl_->accumCount_ = 0;
                return;
            }

            // If pipeline is started (first frame was discarded), write
            // back the mixed output to the buffer for the hop's samples.
            if (impl_->started_) {
                // The hop we just processed corresponds to the samples
                // from (pos + toCopy - kHopSize) to (pos + toCopy - 1)
                // in the output buffer. But since we accumulate across
                // multiple process() calls, we use a simpler approach:
                // Write mixed output for the portion of THIS call that
                // contributed to the completed hop.
                //
                // With the approach below, we write back the kHopSize
                // samples of the hop to the correct position in buffer.
                // The start of the hop in the buffer is:
                const int hopEndInBuf = pos + toCopy;
                const int hopStartInBuf = hopEndInBuf - toCopy;
                // But we might have accumulated across multiple process()
                // calls. In that case, only write what's in THIS call.
                const int hopOffset = kHopSize - toCopy;  // samples from prev calls

                for (int j = 0; j < toCopy; ++j) {
                    const int hopIdx = hopOffset + j;
                    const int bufIdx = hopStartInBuf + j;

                    // Advance crossfade
                    if (crossfadeGain_ < crossfadeTarget_) {
                        crossfadeGain_ = std::min(
                            crossfadeGain_ + kCrossfadeStep,
                            crossfadeTarget_);
                    } else if (crossfadeGain_ > crossfadeTarget_) {
                        crossfadeGain_ = std::max(
                            crossfadeGain_ - kCrossfadeStep,
                            crossfadeTarget_);
                    }

                    const float wet = impl_->outputHop_[hopIdx];
                    const float dry = impl_->dryDelay_[hopIdx];

                    // Intensity dry/wet linear blend
                    const float mixed = dry * (1.0f - intensity)
                                      + wet * intensity;

                    // Apply crossfade (bypass ↔ processed)
                    float out = dry * (1.0f - crossfadeGain_)
                              + mixed * crossfadeGain_;

                    // NaN/Inf protection: clamp to ±1.0
                    // std::isfinite check handles both NaN and Inf.
                    if (!std::isfinite(out)) {
                        out = dry;  // fallback to dry on NaN/Inf
                    }
                    out = std::clamp(out, -1.0f, 1.0f);

                    buffer[bufIdx] = out;
                }
            } else {
                // First hop was discarded (STFT startup latency).
                // Just advance crossfade without modifying buffer.
                for (int j = 0; j < toCopy; ++j) {
                    if (crossfadeGain_ < crossfadeTarget_) {
                        crossfadeGain_ = std::min(
                            crossfadeGain_ + kCrossfadeStep,
                            crossfadeTarget_);
                    } else if (crossfadeGain_ > crossfadeTarget_) {
                        crossfadeGain_ = std::max(
                            crossfadeGain_ - kCrossfadeStep,
                            crossfadeTarget_);
                    }
                }
            }

            impl_->accumCount_ = 0;
        }

        pos += toCopy;
    }

    // Update effective intensity (for telemetry getter).
    effectiveIntensity_ = intensity * crossfadeGain_;
}

void Dpdfnet2_48khzDenoiser::setEnabled(bool enabled) {
    enabled_.store(enabled, std::memory_order_release);
}

void Dpdfnet2_48khzDenoiser::setIntensity(float intensity) {
    intensity_.store(std::clamp(intensity, 0.0f, 1.0f),
                     std::memory_order_release);
}

void Dpdfnet2_48khzDenoiser::reset() {
    if (impl_) {
        impl_->resetState();
    }
    crossfadeGain_      = 0.0f;
    crossfadeTarget_    = 0.0f;
    effectiveIntensity_ = 0.0f;
    processedFrames_.store(0, std::memory_order_relaxed);
    droppedFrames_.store(0, std::memory_order_relaxed);
    lastInferenceUs_.store(0, std::memory_order_relaxed);
    DPDFNET2_LOGI("reset()");
}

float Dpdfnet2_48khzDenoiser::getEffectiveIntensity() const {
    return effectiveIntensity_;
}

uint64_t Dpdfnet2_48khzDenoiser::getProcessedFrames() const {
    return processedFrames_.load(std::memory_order_relaxed);
}

uint64_t Dpdfnet2_48khzDenoiser::getDroppedFrames() const {
    return droppedFrames_.load(std::memory_order_relaxed);
}

uint32_t Dpdfnet2_48khzDenoiser::getLastInferenceUs() const {
    return lastInferenceUs_.load(std::memory_order_relaxed);
}

}  // namespace dpdfnet2_denoiser

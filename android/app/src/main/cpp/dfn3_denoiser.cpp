/// @file dfn3_denoiser.cpp
/// @brief DeepFilterNet3 OnnxRuntime-based denoiser implementation.
///
/// Replaces the old Rust/tract dlopen approach that crashed with off-by-one.
/// Runs enc.onnx + erb_dec.onnx directly via OnnxRuntime C++ API.
///
/// DSP pipeline per hop:
///   1. STFT (FFT 960, Hann, hop 480) → 481 complex bins
///   2. ERB features (481→32 bands, log power)
///   3. Spectral features (96 bins × 2 re/im)
///   4. Encoder → embeddings + skip connections
///   5. ERB decoder → 32 gains
///   6. Apply ERB mask (interpolated to 481 bins)
///   7. iSTFT (OLA) → 480 samples out

#include "dfn3_denoiser.h"
#include "dnn_denoiser/onnxruntime/onnxruntime_cxx_api.h"

#include <android/asset_manager.h>
#include <android/log.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

#define DFN3_TAG "Dfn3Onnx"
#define DFN3_LOGI(...) __android_log_print(ANDROID_LOG_INFO,  DFN3_TAG, __VA_ARGS__)
#define DFN3_LOGW(...) __android_log_print(ANDROID_LOG_WARN,  DFN3_TAG, __VA_ARGS__)
#define DFN3_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, DFN3_TAG, __VA_ARGS__)

namespace dfn3_denoiser {

static constexpr float kPi = 3.14159265358979323846f;
static constexpr float kLogFloor = 1e-10f;
/// Smoothing factor for ERB feature temporal smoothing (matches DFN3 default).
static constexpr float kErbAlpha = 0.98f;

// ═════════════════════════════════════════════════════════════════════════════
// ERB Filterbank — maps 481 FFT bins to 32 ERB bands (DeepFilterNet3 default)
// ═════════════════════════════════════════════════════════════════════════════
//
// The ERB scale used by DFN3 divides 0–24 kHz into 32 bands with widths
// following the Equivalent Rectangular Bandwidth formula. Each band covers
// a range of FFT bin indices. The table below is pre-computed for
// sr=48000, fft=960, nb_erb=32 matching the upstream DFN3 configuration.
//
// Band boundaries (inclusive start bin, exclusive end bin):
static constexpr int kErbBands[kNbErb + 1] = {
    0,   2,   4,   6,   8,  10,  13,  16,  20,  24,
   29,  35,  42,  50,  60,  71,  85, 101, 120, 142,
  169, 200, 237, 281, 333, 395, 468, 481, 481, 481,
  481, 481, 481
};
// NOTE: bands 27–31 are "dead" (start==end==481) because at sr=48k/fft=960
// with 32 ERB bands the high-frequency bands exceed Nyquist. DFN3 handles
// this by padding those bands to 0. This matches the upstream behavior.

// ═════════════════════════════════════════════════════════════════════════════
// Mixed-radix FFT (factors 2,3,5) — supports N=960 = 2^6 × 3 × 5
// ═════════════════════════════════════════════════════════════════════════════
//
// Minimal self-contained implementation optimized for the single case N=960.
// Uses Cooley-Tukey decimation-in-time with mixed radix decomposition.
// Not general purpose — only N values factorizable into 2,3,5 are supported.

namespace {

struct Cpx { float r, i; };

/// In-place mixed-radix FFT. N must factor into 2,3,5.
/// If inverse=true, performs IFFT (no 1/N scaling — caller must divide).
class MixedRadixFft {
public:
    void init(int n, bool inverse) {
        n_ = n;
        inverse_ = inverse;
        // Compute twiddle factors
        twiddles_.resize(n);
        const float sign = inverse ? 1.0f : -1.0f;
        for (int i = 0; i < n; ++i) {
            float angle = sign * 2.0f * kPi * i / static_cast<float>(n);
            twiddles_[i] = {std::cos(angle), std::sin(angle)};
        }
        // Factor N
        factors_.clear();
        int rem = n;
        for (int f : {2, 3, 5}) {
            while (rem % f == 0) {
                factors_.push_back(f);
                rem /= f;
            }
        }
        // Allocate scratch
        scratch_.resize(n);
    }

    /// Compute FFT in-place on data[0..n-1].
    void compute(Cpx* data) {
        // Stockham auto-sort approach: alternates between data and scratch
        Cpx* src = data;
        Cpx* dst = scratch_.data();
        int stride = 1;
        for (int fi = static_cast<int>(factors_.size()) - 1; fi >= 0; --fi) {
            int radix = factors_[fi];
            int m = n_ / (stride * radix);
            butterflyGeneric(src, dst, stride, m, radix);
            stride *= radix;
            std::swap(src, dst);
        }
        // If result ended up in scratch, copy back
        if (src != data) {
            std::memcpy(data, src, n_ * sizeof(Cpx));
        }
    }

private:
    int n_ = 0;
    bool inverse_ = false;
    std::vector<Cpx> twiddles_;
    std::vector<int> factors_;
    std::vector<Cpx> scratch_;

    static Cpx mul(Cpx a, Cpx b) {
        return {a.r * b.r - a.i * b.i, a.r * b.i + a.i * b.r};
    }

    void butterflyGeneric(const Cpx* src, Cpx* dst,
                          int stride, int m, int radix) {
        // Generic DIT butterfly for any small radix
        for (int k = 0; k < m; ++k) {
            for (int r = 0; r < radix; ++r) {
                Cpx acc = {0.0f, 0.0f};
                for (int s = 0; s < radix; ++s) {
                    int srcIdx = k + s * m;
                    int twIdx = (r * s * stride) % n_;
                    Cpx tw = twiddles_[twIdx];
                    Cpx val = src[srcIdx];
                    acc.r += val.r * tw.r - val.i * tw.i;
                    acc.i += val.r * tw.i + val.i * tw.r;
                }
                dst[k * radix + r] = acc;
            }
        }
    }
};

/// Real-valued FFT using complex FFT of half size.
/// For N=960 real inputs, produces 481 complex outputs (N/2+1 bins).
/// Uses the standard "pack real into complex" trick.
class RealFft {
public:
    void init(int n) {
        n_ = n;
        halfN_ = n / 2;
        fft_.init(halfN_, false);
        ifft_.init(halfN_, true);
        // Twiddles for unpack step
        unpackTw_.resize(halfN_);
        for (int k = 0; k < halfN_; ++k) {
            float angle = -kPi * k / static_cast<float>(halfN_);
            unpackTw_[k] = {std::cos(angle), std::sin(angle)};
        }
        tmp_.resize(halfN_);
    }

    /// Forward real FFT: input[0..N-1] → output[0..N/2] (N/2+1 complex bins)
    void forward(const float* input, Cpx* output) {
        // Pack N reals as N/2 complex: z[k] = input[2k] + j*input[2k+1]
        for (int k = 0; k < halfN_; ++k) {
            tmp_[k] = {input[2 * k], input[2 * k + 1]};
        }
        fft_.compute(tmp_.data());
        // Unpack to N/2+1 bins using the split formula
        // X[k] = 0.5*(Z[k] + conj(Z[N/2-k])) - 0.5j*W^k*(Z[k] - conj(Z[N/2-k]))
        output[0] = {tmp_[0].r + tmp_[0].i, 0.0f};
        output[halfN_] = {tmp_[0].r - tmp_[0].i, 0.0f};
        for (int k = 1; k < halfN_; ++k) {
            Cpx zk = tmp_[k];
            Cpx znk = {tmp_[halfN_ - k].r, -tmp_[halfN_ - k].i}; // conj(Z[N/2-k])
            Cpx even = {0.5f * (zk.r + znk.r), 0.5f * (zk.i + znk.i)};
            Cpx odd  = {0.5f * (zk.r - znk.r), 0.5f * (zk.i - znk.i)};
            // Multiply odd by -j * W^k = -j * (cos - j*sin) = -sin - j*cos
            // Actually: twiddle for unpack is e^{-j*pi*k/halfN}
            Cpx tw = unpackTw_[k];
            Cpx oddTw = {odd.r * tw.r - odd.i * tw.i,
                         odd.r * tw.i + odd.i * tw.r};
            // Correct formula: X[k] = even + j*oddTw... let me use standard form
            // X[k] = 0.5*(Z[k] + Z*[N/2-k]) + 0.5*W_N^k * (Z[k] - Z*[N/2-k]) * (-j)
            // Simplified: X[k] = even - j * oddTw
            output[k] = {even.r + oddTw.i, even.i - oddTw.r};
        }
    }

    /// Inverse real FFT: input[0..N/2] (N/2+1 bins) → output[0..N-1] reals.
    /// Does NOT divide by N — caller must scale.
    void inverse(const Cpx* input, float* output) {
        // Re-pack N/2+1 bins into N/2 complex for inverse FFT
        // Reverse of the forward unpack step
        tmp_[0] = {0.5f * (input[0].r + input[halfN_].r),
                   0.5f * (input[0].r - input[halfN_].r)};
        for (int k = 1; k < halfN_; ++k) {
            Cpx xk = input[k];
            Cpx xnk = {input[halfN_ - k].r, -input[halfN_ - k].i}; // conj(X[N/2-k])
            Cpx even = {0.5f * (xk.r + xnk.r), 0.5f * (xk.i + xnk.i)};
            Cpx odd  = {0.5f * (xk.r - xnk.r), 0.5f * (xk.i - xnk.i)};
            // Inverse twiddle: conjugate
            Cpx tw = {unpackTw_[k].r, -unpackTw_[k].i};
            Cpx oddTw = {odd.r * tw.r - odd.i * tw.i,
                         odd.r * tw.i + odd.i * tw.r};
            // Z[k] = even + j*oddTw → pack as (re, im) for IFFT
            tmp_[k] = {even.r - oddTw.i, even.i + oddTw.r};
        }
        ifft_.compute(tmp_.data());
        // Scale by 1/halfN (IFFT didn't scale) and interleave
        const float scale = 1.0f / static_cast<float>(halfN_);
        for (int k = 0; k < halfN_; ++k) {
            output[2 * k]     = tmp_[k].r * scale;
            output[2 * k + 1] = tmp_[k].i * scale;
        }
    }

private:
    int n_ = 0;
    int halfN_ = 0;
    MixedRadixFft fft_;
    MixedRadixFft ifft_;
    std::vector<Cpx> unpackTw_;
    std::vector<Cpx> tmp_;
};

}  // anonymous namespace

// ═════════════════════════════════════════════════════════════════════════════
// PIMPL — Implementation struct
// ═════════════════════════════════════════════════════════════════════════════

struct Dfn3Denoiser::Impl {
    // ─── OnnxRuntime state ───────────────────────────────────────────────
    Ort::Env env{ORT_LOGGING_LEVEL_WARNING, DFN3_TAG};
    Ort::SessionOptions sessionOpts;
    std::unique_ptr<Ort::Session> encSession;
    std::unique_ptr<Ort::Session> erbDecSession;
    Ort::MemoryInfo memInfo{Ort::MemoryInfo::CreateCpu(
        OrtArenaAllocator, OrtMemTypeDefault)};

    // ─── STFT state ─────────────────────────────────────────────────────
    RealFft fft;
    float hannWin[kFftSize];       ///< Hann analysis window (sqrt for COLA)
    float stftInBuf[kFftSize];     ///< Sliding input buffer (last kFftSize samples)
    float olaBuf[kFftSize];        ///< Overlap-add output buffer
    Cpx   specBuf[kNbFreqs];       ///< Current frame spectrum (481 bins)

    // ─── Feature buffers ────────────────────────────────────────────────
    float erbFeats[kNbErb];        ///< ERB log-power features (temporally smoothed)
    float specFeatsRe[kNbDf];      ///< Spectral features (real part of first 96 bins)
    float specFeatsIm[kNbDf];      ///< Spectral features (imag part of first 96 bins)

    // ─── Encoder output caching ─────────────────────────────────────────
    // The encoder produces: emb, e0, e1, e2, e3, c0, lsnr
    // We need emb + e0..e3 for the ERB decoder.
    // Sizes depend on model architecture — we'll query at init time.
    std::vector<float> encOutputs;  ///< Flat concatenation of encoder outputs

    bool ready = false;

    Impl() {
        sessionOpts.SetIntraOpNumThreads(1);
        sessionOpts.SetInterOpNumThreads(1);
        sessionOpts.SetGraphOptimizationLevel(
            GraphOptimizationLevel::ORT_ENABLE_ALL);

        // Initialize Hann window (periodic, sqrt for perfect reconstruction)
        for (int i = 0; i < kFftSize; ++i) {
            float w = 0.5f * (1.0f - std::cos(2.0f * kPi * i / kFftSize));
            hannWin[i] = std::sqrt(w);
        }

        // Zero-init buffers
        std::memset(stftInBuf, 0, sizeof(stftInBuf));
        std::memset(olaBuf, 0, sizeof(olaBuf));
        std::memset(erbFeats, 0, sizeof(erbFeats));
        std::memset(specFeatsRe, 0, sizeof(specFeatsRe));
        std::memset(specFeatsIm, 0, sizeof(specFeatsIm));

        // Initialize FFT
        fft.init(kFftSize);
    }

    /// Load model from Android assets into OnnxRuntime session.
    std::unique_ptr<Ort::Session> loadModel(AAssetManager* mgr,
                                             const std::string& path) {
        AAsset* asset = AAssetManager_open(mgr, path.c_str(), AASSET_MODE_BUFFER);
        if (!asset) {
            DFN3_LOGE("Cannot open asset: %s", path.c_str());
            return nullptr;
        }
        const size_t sz = static_cast<size_t>(AAsset_getLength(asset));
        const void* buf = AAsset_getBuffer(asset);
        if (!buf || sz == 0) {
            AAsset_close(asset);
            DFN3_LOGE("Empty asset: %s", path.c_str());
            return nullptr;
        }
        try {
            auto session = std::make_unique<Ort::Session>(
                env, buf, sz, sessionOpts);
            AAsset_close(asset);
            DFN3_LOGI("Loaded model: %s (%zu bytes)", path.c_str(), sz);
            return session;
        } catch (const Ort::Exception& e) {
            AAsset_close(asset);
            DFN3_LOGE("ORT error loading %s: %s", path.c_str(), e.what());
            return nullptr;
        }
    }

    /// STFT analysis: shift in kHopSize new samples, window, FFT → specBuf.
    void analysis(const float* hop) {
        // Shift stftInBuf left by kHopSize, append new hop
        std::memmove(stftInBuf, stftInBuf + kHopSize,
                     (kFftSize - kHopSize) * sizeof(float));
        std::memcpy(stftInBuf + (kFftSize - kHopSize), hop,
                    kHopSize * sizeof(float));

        // Apply window and compute FFT
        float windowed[kFftSize];
        for (int i = 0; i < kFftSize; ++i) {
            windowed[i] = stftInBuf[i] * hannWin[i];
        }
        fft.forward(windowed, specBuf);
    }

    /// iSTFT synthesis: apply mask to specBuf, IFFT, window, overlap-add.
    /// Writes kHopSize samples to output.
    void synthesis(float* output) {
        // Inverse FFT → time domain
        float timeBuf[kFftSize];
        fft.inverse(specBuf, timeBuf);

        // Apply synthesis window (sqrt-Hann) and overlap-add
        for (int i = 0; i < kFftSize; ++i) {
            timeBuf[i] *= hannWin[i];
        }

        // Add to OLA buffer
        for (int i = 0; i < kFftSize; ++i) {
            olaBuf[i] += timeBuf[i];
        }

        // Output the first kHopSize samples (they are complete)
        std::memcpy(output, olaBuf, kHopSize * sizeof(float));

        // Shift OLA buffer left by kHopSize
        std::memmove(olaBuf, olaBuf + kHopSize,
                     (kFftSize - kHopSize) * sizeof(float));
        // Zero the new region
        std::memset(olaBuf + (kFftSize - kHopSize), 0,
                    kHopSize * sizeof(float));
    }

    /// Extract ERB features from specBuf → erbFeats[32].
    /// Log-compressed mean power per ERB band, with temporal smoothing.
    void extractErbFeatures() {
        for (int b = 0; b < kNbErb; ++b) {
            int start = kErbBands[b];
            int end   = kErbBands[b + 1];
            if (start >= end) {
                // Dead band (high freq beyond Nyquist)
                erbFeats[b] = kErbAlpha * erbFeats[b]; // decay to 0
                continue;
            }
            float power = 0.0f;
            for (int k = start; k < end; ++k) {
                float re = specBuf[k].r;
                float im = specBuf[k].i;
                power += re * re + im * im;
            }
            power /= static_cast<float>(end - start);
            // Log compression (matching DFN3 upstream)
            float logPow = std::log10(std::max(power, kLogFloor));
            // Temporal smoothing
            erbFeats[b] = kErbAlpha * erbFeats[b] + (1.0f - kErbAlpha) * logPow;
        }
    }

    /// Extract spectral features (first 96 bins, re+im normalized).
    void extractSpecFeatures() {
        for (int k = 0; k < kNbDf; ++k) {
            specFeatsRe[k] = specBuf[k].r;
            specFeatsIm[k] = specBuf[k].i;
        }
    }

    /// Apply ERB gains to specBuf. Gains are per-band [0..1]; interpolated
    /// across bins within each band.
    void applyErbMask(const float* gains) {
        for (int b = 0; b < kNbErb; ++b) {
            int start = kErbBands[b];
            int end   = kErbBands[b + 1];
            float g = std::max(0.0f, std::min(1.0f, gains[b]));
            for (int k = start; k < end; ++k) {
                specBuf[k].r *= g;
                specBuf[k].i *= g;
            }
        }
    }

    /// Run encoder + ERB decoder and return gains.
    /// Returns true on success (gains written to outGains[kNbErb]).
    bool runInference(float* outGains) {
        if (!encSession || !erbDecSession) return false;

        try {
            // ── Prepare encoder inputs ──────────────────────────────────
            // feat_erb: [1, 1, 1, 32]
            std::vector<int64_t> erbShape = {1, 1, 1, kNbErb};
            auto erbTensor = Ort::Value::CreateTensor<float>(
                memInfo, erbFeats, kNbErb, erbShape.data(), erbShape.size());

            // feat_spec: [1, 2, 1, 96] — interleaved re/im
            float specInput[2 * kNbDf];
            std::memcpy(specInput, specFeatsRe, kNbDf * sizeof(float));
            std::memcpy(specInput + kNbDf, specFeatsIm, kNbDf * sizeof(float));
            std::vector<int64_t> specShape = {1, 2, 1, kNbDf};
            auto specTensor = Ort::Value::CreateTensor<float>(
                memInfo, specInput, 2 * kNbDf,
                specShape.data(), specShape.size());

            // ── Run encoder ─────────────────────────────────────────────
            const char* encInputNames[] = {"feat_erb", "feat_spec"};
            Ort::Value encInputs[] = {std::move(erbTensor), std::move(specTensor)};

            // Query output names from session
            Ort::AllocatorWithDefaultOptions alloc;
            size_t numEncOutputs = encSession->GetOutputCount();
            std::vector<std::string> encOutNames;
            std::vector<const char*> encOutNamePtrs;
            for (size_t i = 0; i < numEncOutputs; ++i) {
                auto name = encSession->GetOutputNameAllocated(i, alloc);
                encOutNames.push_back(name.get());
            }
            for (auto& s : encOutNames) encOutNamePtrs.push_back(s.c_str());

            auto encResults = encSession->Run(
                Ort::RunOptions{nullptr},
                encInputNames, encInputs, 2,
                encOutNamePtrs.data(), numEncOutputs);

            // ── Run ERB decoder ─────────────────────────────────────────
            // ERB decoder inputs: emb, e3, e2, e1, e0 (from encoder outputs)
            // We pass all encoder outputs to the ERB decoder.
            size_t numErbInputs = erbDecSession->GetInputCount();
            size_t numErbOutputs = erbDecSession->GetOutputCount();

            // Get ERB decoder input/output names
            std::vector<std::string> erbInNames, erbOutNames;
            std::vector<const char*> erbInNamePtrs, erbOutNamePtrs;
            for (size_t i = 0; i < numErbInputs; ++i) {
                auto name = erbDecSession->GetInputNameAllocated(i, alloc);
                erbInNames.push_back(name.get());
            }
            for (auto& s : erbInNames) erbInNamePtrs.push_back(s.c_str());
            for (size_t i = 0; i < numErbOutputs; ++i) {
                auto name = erbDecSession->GetOutputNameAllocated(i, alloc);
                erbOutNames.push_back(name.get());
            }
            for (auto& s : erbOutNames) erbOutNamePtrs.push_back(s.c_str());

            // Map encoder outputs to ERB decoder inputs by name matching
            // The encoder outputs are: e0, e1, e2, e3, emb, c0, lsnr
            // The ERB decoder expects: emb, e3, e2, e1, e0
            std::vector<Ort::Value> erbInputs;
            for (size_t i = 0; i < numErbInputs; ++i) {
                bool found = false;
                for (size_t j = 0; j < numEncOutputs; ++j) {
                    if (erbInNames[i] == encOutNames[j]) {
                        erbInputs.push_back(std::move(encResults[j]));
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    // Create zero tensor as fallback
                    DFN3_LOGW("ERB dec input '%s' not found in enc outputs",
                              erbInNames[i].c_str());
                    return false;
                }
            }

            auto erbResults = erbDecSession->Run(
                Ort::RunOptions{nullptr},
                erbInNamePtrs.data(), erbInputs.data(), numErbInputs,
                erbOutNamePtrs.data(), numErbOutputs);

            // ── Extract mask output (m: [1, 1, 1, 32]) ─────────────────
            if (erbResults.empty()) return false;
            const float* maskData = erbResults[0].GetTensorData<float>();
            auto maskShape = erbResults[0].GetTensorTypeAndShapeInfo().GetShape();
            int maskSize = 1;
            for (auto d : maskShape) maskSize *= static_cast<int>(d);

            // Copy mask to output (sigmoid is already applied in the model)
            int toCopy = std::min(maskSize, kNbErb);
            for (int i = 0; i < toCopy; ++i) {
                outGains[i] = maskData[i];
            }
            // Pad remaining bands with 1.0 (passthrough)
            for (int i = toCopy; i < kNbErb; ++i) {
                outGains[i] = 1.0f;
            }

            return true;
        } catch (const Ort::Exception& e) {
            DFN3_LOGW("Inference error: %s", e.what());
            return false;
        }
    }
};

// ═════════════════════════════════════════════════════════════════════════════
// Public API implementation
// ═════════════════════════════════════════════════════════════════════════════

Dfn3Denoiser::Dfn3Denoiser() : impl_(std::make_unique<Impl>()) {}
Dfn3Denoiser::~Dfn3Denoiser() = default;

bool Dfn3Denoiser::initialize(AAssetManager* mgr, const char* assetDir) {
    if (initialized_) return true;
    if (!mgr || !assetDir) {
        DFN3_LOGE("initialize: null mgr or assetDir");
        return false;
    }

    std::string dir(assetDir);
    impl_->encSession = impl_->loadModel(mgr, dir + "/enc.onnx");
    if (!impl_->encSession) return false;

    impl_->erbDecSession = impl_->loadModel(mgr, dir + "/erb_dec.onnx");
    if (!impl_->erbDecSession) return false;

    // Log model info
    DFN3_LOGI("DFN3 OnnxRuntime initialized (enc + erb_dec)");
    DFN3_LOGI("  Encoder inputs: %zu, outputs: %zu",
              impl_->encSession->GetInputCount(),
              impl_->encSession->GetOutputCount());
    DFN3_LOGI("  ERB decoder inputs: %zu, outputs: %zu",
              impl_->erbDecSession->GetInputCount(),
              impl_->erbDecSession->GetOutputCount());

    impl_->ready = true;
    initialized_ = true;
    return true;
}

bool Dfn3Denoiser::processHop(float* hop) {
    if (!impl_->ready) return false;

    // 1. STFT analysis
    impl_->analysis(hop);

    // 2. Extract features
    impl_->extractErbFeatures();
    impl_->extractSpecFeatures();

    // 3. Run DNN inference (encoder + ERB decoder)
    float erbGains[kNbErb];
    if (!impl_->runInference(erbGains)) {
        return false;
    }

    // 4. Apply ERB mask to spectrum
    impl_->applyErbMask(erbGains);

    // 5. iSTFT synthesis → overwrite hop with enhanced audio
    impl_->synthesis(hop);

    ++processedFrames_;
    return true;
}

void Dfn3Denoiser::process(float* buffer, int blockSize) {
    if (!buffer || blockSize <= 0 || !initialized_) return;

    const bool wantEnabled = enabled_.load(std::memory_order_acquire);
    crossfadeTarget_ = wantEnabled ? 1.0f : 0.0f;

    // Full bypass — no processing needed
    if (crossfadeGain_ <= 0.0f && crossfadeTarget_ <= 0.0f) {
        residualCount_ = 0;
        return;
    }

    const float intensity = intensity_.load(std::memory_order_acquire);
    int pos = 0;

    while (pos < blockSize) {
        const int needed = kHopSize - residualCount_;
        const int available = blockSize - pos;
        const int toCopy = std::min(needed, available);

        std::memcpy(residual_ + residualCount_, buffer + pos,
                    toCopy * sizeof(float));
        residualCount_ += toCopy;
        pos += toCopy;

        if (residualCount_ == kHopSize) {
            // Save dry copy
            float dry[kHopSize];
            std::memcpy(dry, residual_, kHopSize * sizeof(float));

            // Process the hop through DFN3
            const bool processed = processHop(residual_);

            // Write back with crossfade and intensity mixing
            const int outStart = pos - toCopy;
            const int hopOffset = kHopSize - toCopy;

            for (int i = 0; i < toCopy; ++i) {
                const int hopIdx = hopOffset + i;
                const int bufIdx = outStart + i;

                // Advance crossfade
                if (crossfadeGain_ < crossfadeTarget_)
                    crossfadeGain_ = std::min(crossfadeGain_ + kCrossfadeStep,
                                              crossfadeTarget_);
                else if (crossfadeGain_ > crossfadeTarget_)
                    crossfadeGain_ = std::max(crossfadeGain_ - kCrossfadeStep,
                                              crossfadeTarget_);

                if (processed && crossfadeGain_ > 0.0f) {
                    float wet = residual_[hopIdx];
                    float d = dry[hopIdx];
                    float mixed = d * (1.0f - intensity) + wet * intensity;
                    buffer[bufIdx] = std::clamp(
                        d * (1.0f - crossfadeGain_) + mixed * crossfadeGain_,
                        -1.0f, 1.0f);
                }
                // else: buffer already has dry signal
            }

            effectiveIntensity_ = crossfadeGain_ * intensity;
            residualCount_ = 0;
        }
    }
}

void Dfn3Denoiser::setEnabled(bool enabled) {
    enabled_.store(enabled, std::memory_order_release);
    DFN3_LOGI("setEnabled(%s)", enabled ? "true" : "false");
}

void Dfn3Denoiser::setIntensity(float intensity) {
    intensity_.store(std::clamp(intensity, 0.0f, 1.0f),
                     std::memory_order_release);
}

void Dfn3Denoiser::reset() {
    residualCount_ = 0;
    crossfadeGain_ = 0.0f;
    crossfadeTarget_ = 0.0f;
    effectiveIntensity_ = 0.0f;
    processedFrames_ = 0;
    if (impl_) {
        std::memset(impl_->stftInBuf, 0, sizeof(impl_->stftInBuf));
        std::memset(impl_->olaBuf, 0, sizeof(impl_->olaBuf));
        std::memset(impl_->erbFeats, 0, sizeof(impl_->erbFeats));
    }
    DFN3_LOGI("reset()");
}

}  // namespace dfn3_denoiser

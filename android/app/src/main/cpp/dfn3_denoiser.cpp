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
#include <string>
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

/// Minimum ERB gain floor — never attenuate more than ~20 dB.
/// Protects voiced speech from excessive suppression.
static constexpr float kErbGainFloor = 0.1f;

/// Number of warmup hops where the denoiser does bypass/fade-in.
/// 10 hops = 100 ms @ 48 kHz — enough for ERB smoothing to stabilize.
static constexpr int kWarmupHops = 10;

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
        output[0] = {tmp_[0].r + tmp_[0].i, 0.0f};
        output[halfN_] = {tmp_[0].r - tmp_[0].i, 0.0f};
        for (int k = 1; k < halfN_; ++k) {
            Cpx zk = tmp_[k];
            Cpx znk = {tmp_[halfN_ - k].r, -tmp_[halfN_ - k].i}; // conj(Z[N/2-k])
            Cpx even = {0.5f * (zk.r + znk.r), 0.5f * (zk.i + znk.i)};
            Cpx odd  = {0.5f * (zk.r - znk.r), 0.5f * (zk.i - znk.i)};
            Cpx tw = unpackTw_[k];
            Cpx oddTw = {odd.r * tw.r - odd.i * tw.i,
                         odd.r * tw.i + odd.i * tw.r};
            output[k] = {even.r + oddTw.i, even.i - oddTw.r};
        }
    }

    /// Inverse real FFT: input[0..N/2] (N/2+1 bins) → output[0..N-1] reals.
    /// Does NOT divide by N — caller must scale.
    void inverse(const Cpx* input, float* output) {
        // Re-pack N/2+1 bins into N/2 complex for inverse FFT
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

/// Helper: convert a shape vector to a human-readable string for logging.
static std::string shapeToString(const std::vector<int64_t>& shape) {
    std::string s;
    for (size_t i = 0; i < shape.size(); ++i) {
        if (i > 0) s += ", ";
        s += std::to_string(shape[i]);
    }
    return s;
}

// ═════════════════════════════════════════════════════════════════════════════
// PIMPL — Implementation struct
// ═════════════════════════════════════════════════════════════════════════════

struct Dfn3Denoiser::Impl {
    // ─── OnnxRuntime state ───────────────────────────────────────────────
    Ort::Env env{ORT_LOGGING_LEVEL_WARNING, DFN3_TAG};
    Ort::SessionOptions sessionOpts;
    std::unique_ptr<Ort::Session> encSession;
    std::unique_ptr<Ort::Session> erbDecSession;
    std::unique_ptr<Ort::Session> dfDecSession;
    bool dfDecReady = false;
    Ort::MemoryInfo memInfo{Ort::MemoryInfo::CreateCpu(
        OrtArenaAllocator, OrtMemTypeDefault)};

    // ─── STFT state ─────────────────────────────────────────────────────
    RealFft fft;
    float hannWin[kFftSize];       ///< Hann analysis window (sqrt for COLA)
    float wolaDiv[kHopSize];       ///< WOLA normalization divisor per sample
    float stftInBuf[kFftSize];     ///< Sliding input buffer (last kFftSize samples)
    float olaBuf[kFftSize];        ///< Overlap-add output buffer
    Cpx   specBuf[kNbFreqs];       ///< Current frame spectrum (481 bins)

    // ─── Feature buffers ────────────────────────────────────────────────
    float erbFeats[kNbErb];        ///< ERB log-power features (temporally smoothed)
    float specFeatsRe[kNbDf];      ///< Spectral features (real part of first 96 bins)
    float specFeatsIm[kNbDf];      ///< Spectral features (imag part of first 96 bins)

    // ─── Encoder output caching ─────────────────────────────────────────
    std::vector<float> encOutputs;  ///< Flat concatenation of encoder outputs

    // ─── ERB decoder hidden state persistence ───────────────────────────
    /// If the ERB decoder has >1 output, the extras are hidden states that
    /// must be fed back as additional encoder inputs in the next frame.
    /// This gives the model temporal coherence (avoids "ronco" distortion).
    std::vector<Ort::Value> erbDecStates;  ///< Persistent decoder states
    bool hasDecoderStates = false;         ///< true if decoder outputs > 1

    /// Warmup counter: counts processed hops since reset/init.
    int warmupCounter = 0;

    bool ready = false;

    Impl() {
        sessionOpts.SetIntraOpNumThreads(1);
        sessionOpts.SetInterOpNumThreads(1);
        sessionOpts.SetGraphOptimizationLevel(
            GraphOptimizationLevel::ORT_ENABLE_ALL);

        // Ventana Vorbis (usada por DeepFilterNet3, no sqrt-Hann)
        // w[n] = sin(π/2 × sin²(π × (n + 0.5) / N))
        for (int i = 0; i < kFftSize; ++i) {
            float sin_arg = kPi * (static_cast<float>(i) + 0.5f) / static_cast<float>(kFftSize);
            float sin_sq = std::sin(sin_arg);
            sin_sq *= sin_sq;
            hannWin[i] = std::sin(0.5f * kPi * sin_sq);
        }

        // Compute WOLA normalization: sum of squared windows at each output
        // position. With 50% overlap (2 frames contribute), for sample n in
        // the output hop, the sum is win²[n] + win²[n + hop].
        // We normalize by this to get perfect reconstruction.
        for (int n = 0; n < kHopSize; ++n) {
            float sum = 0.0f;
            // How many overlapping frames contribute at position n of the
            // output hop? With hop=fftSize/2 (50% overlap), exactly 2 frames:
            // - Current frame: sample at index n
            // - Previous frame: sample at index n + kHopSize
            sum = hannWin[n] * hannWin[n]
                + hannWin[n + kHopSize] * hannWin[n + kHopSize];
            wolaDiv[n] = (sum > 1e-8f) ? (1.0f / sum) : 1.0f;
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
    /// Writes kHopSize samples to output with WOLA normalization.
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

        // Output the first kHopSize samples with WOLA normalization
        for (int i = 0; i < kHopSize; ++i) {
            output[i] = olaBuf[i] * wolaDiv[i];
        }

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
    /// across bins within each band. Floor at kErbGainFloor to protect voice.
    void applyErbMask(const float* gains) {
        for (int b = 0; b < kNbErb; ++b) {
            int start = kErbBands[b];
            int end   = kErbBands[b + 1];
            float g = std::max(kErbGainFloor, std::min(1.0f, gains[b]));
            for (int k = start; k < end; ++k) {
                specBuf[k].r *= g;
                specBuf[k].i *= g;
            }
        }
    }

    /// Run encoder + ERB decoder and return gains.
    /// Returns true on success (gains written to outGains[kNbErb]).
    ///
    /// Handles stateful models: if the encoder has >2 inputs, the extras
    /// are hidden states from previous frames. If the ERB decoder has >1
    /// output, the extras are hidden states to persist for next frame.
    bool runInference(float* outGains) {
        if (!encSession || !erbDecSession) return false;

        try {
            Ort::AllocatorWithDefaultOptions alloc;

            // ── Prepare encoder inputs ──────────────────────────────────
            // Always present: feat_erb [1, 1, 1, 32] + feat_spec [1, 2, 1, 96]
            std::vector<int64_t> erbShape = {1, 1, 1, kNbErb};
            auto erbTensor = Ort::Value::CreateTensor<float>(
                memInfo, erbFeats, kNbErb, erbShape.data(), erbShape.size());

            float specInput[2 * kNbDf];
            std::memcpy(specInput, specFeatsRe, kNbDf * sizeof(float));
            std::memcpy(specInput + kNbDf, specFeatsIm, kNbDf * sizeof(float));
            std::vector<int64_t> specShape = {1, 2, 1, kNbDf};
            auto specTensor = Ort::Value::CreateTensor<float>(
                memInfo, specInput, 2 * kNbDf,
                specShape.data(), specShape.size());

            // ── Query encoder input names ───────────────────────────────
            size_t numEncInputs = encSession->GetInputCount();
            std::vector<std::string> encInNames;
            std::vector<const char*> encInNamePtrs;
            for (size_t i = 0; i < numEncInputs; ++i) {
                auto name = encSession->GetInputNameAllocated(i, alloc);
                encInNames.push_back(name.get());
            }
            for (auto& s : encInNames) encInNamePtrs.push_back(s.c_str());

            // ── Build encoder input vector ──────────────────────────────
            // Order must match encInNames. First two are feat_erb, feat_spec.
            // Any additional inputs are hidden states from previous decoder.
            std::vector<Ort::Value> encInputVec;
            for (size_t i = 0; i < numEncInputs; ++i) {
                if (encInNames[i] == "feat_erb") {
                    encInputVec.push_back(std::move(erbTensor));
                } else if (encInNames[i] == "feat_spec") {
                    encInputVec.push_back(std::move(specTensor));
                } else {
                    // This is a hidden state input — feed from saved decoder
                    // states if available, otherwise create zero tensor.
                    bool fed = false;
                    if (hasDecoderStates) {
                        // Find matching state by name in erbDecStates
                        // Convention: encoder state input name matches
                        // decoder state output name (e.g. "e_h0" ↔ "e_h0")
                        for (size_t s = 0; s < erbDecStates.size(); ++s) {
                            // States are stored in order after the mask output
                            // We match positionally: extra enc inputs map 1:1
                            // to extra dec outputs (both ordered the same way).
                            // This is the standard ONNX export convention.
                        }
                        // Positional mapping: enc input i (i>=2) ↔ dec state i-2
                        size_t stateIdx = i - 2;
                        if (stateIdx < erbDecStates.size()) {
                            encInputVec.push_back(std::move(erbDecStates[stateIdx]));
                            fed = true;
                        }
                    }
                    if (!fed) {
                        // First frame or missing state: create zero tensor.
                        // Use OrtValue with allocator so ORT owns the memory.
                        auto typeInfo = encSession->GetInputTypeInfo(i);
                        auto tensorInfo = typeInfo.GetTensorTypeAndShapeInfo();
                        auto shape = tensorInfo.GetShape();
                        // Replace dynamic dims (-1) with 1
                        int64_t totalElems = 1;
                        for (auto& d : shape) {
                            if (d <= 0) d = 1;
                            totalElems *= d;
                        }
                        // Allocate via ORT allocator so tensor owns its memory
                        Ort::AllocatorWithDefaultOptions ortAlloc;
                        auto zeroTensor = Ort::Value::CreateTensor<float>(
                            ortAlloc, shape.data(), shape.size());
                        float* tensorData = zeroTensor.GetTensorMutableData<float>();
                        std::memset(tensorData, 0, totalElems * sizeof(float));
                        encInputVec.push_back(std::move(zeroTensor));
                        DFN3_LOGI("Encoder state input '%s' zero-initialized "
                                  "(shape[0]=%lld)", encInNames[i].c_str(),
                                  (long long)shape[0]);
                    }
                }
            }

            // Clear previous decoder states (already moved or stale)
            erbDecStates.clear();
            hasDecoderStates = false;

            // ── Query encoder output names ──────────────────────────────
            size_t numEncOutputs = encSession->GetOutputCount();
            std::vector<std::string> encOutNames;
            std::vector<const char*> encOutNamePtrs;
            for (size_t i = 0; i < numEncOutputs; ++i) {
                auto name = encSession->GetOutputNameAllocated(i, alloc);
                encOutNames.push_back(name.get());
            }
            for (auto& s : encOutNames) encOutNamePtrs.push_back(s.c_str());

            // ── Run encoder ─────────────────────────────────────────────
            auto encResults = encSession->Run(
                Ort::RunOptions{nullptr},
                encInNamePtrs.data(), encInputVec.data(), numEncInputs,
                encOutNamePtrs.data(), numEncOutputs);

            // ── Run ERB decoder ─────────────────────────────────────────
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
            std::vector<Ort::Value> erbInputVec;
            for (size_t i = 0; i < numErbInputs; ++i) {
                bool found = false;
                for (size_t j = 0; j < numEncOutputs; ++j) {
                    if (erbInNames[i] == encOutNames[j]) {
                        erbInputVec.push_back(std::move(encResults[j]));
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    DFN3_LOGW("ERB dec input '%s' not found in enc outputs",
                              erbInNames[i].c_str());
                    return false;
                }
            }

            auto erbResults = erbDecSession->Run(
                Ort::RunOptions{nullptr},
                erbInNamePtrs.data(), erbInputVec.data(), numErbInputs,
                erbOutNamePtrs.data(), numErbOutputs);

            // ── Extract mask output (first output: m [1, 1, 1, 32]) ─────
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

            // ── Persist decoder hidden states for next frame ────────────
            // If the ERB decoder has >1 output, extras are hidden states
            // that must feed back into the encoder on the next frame.
            if (numErbOutputs > 1) {
                hasDecoderStates = true;
                for (size_t i = 1; i < numErbOutputs; ++i) {
                    erbDecStates.push_back(std::move(erbResults[i]));
                }
                // Log once on first detection
                static bool loggedOnce = false;
                if (!loggedOnce) {
                    DFN3_LOGI("ERB decoder has %zu hidden state outputs — "
                              "persisting for temporal coherence",
                              numErbOutputs - 1);
                    loggedOnce = true;
                }
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

    // Log encoder input/output names for debugging stateful connections
    {
        Ort::AllocatorWithDefaultOptions alloc;
        size_t nEncIn = impl_->encSession->GetInputCount();
        for (size_t i = 0; i < nEncIn; ++i) {
            auto name = impl_->encSession->GetInputNameAllocated(i, alloc);
            DFN3_LOGI("    enc input[%zu]: '%s'", i, name.get());
        }
        size_t nEncOut = impl_->encSession->GetOutputCount();
        for (size_t i = 0; i < nEncOut; ++i) {
            auto name = impl_->encSession->GetOutputNameAllocated(i, alloc);
            DFN3_LOGI("    enc output[%zu]: '%s'", i, name.get());
        }
        size_t nDecIn = impl_->erbDecSession->GetInputCount();
        for (size_t i = 0; i < nDecIn; ++i) {
            auto name = impl_->erbDecSession->GetInputNameAllocated(i, alloc);
            DFN3_LOGI("    erb_dec input[%zu]: '%s'", i, name.get());
        }
        size_t nDecOut = impl_->erbDecSession->GetOutputCount();
        for (size_t i = 0; i < nDecOut; ++i) {
            auto name = impl_->erbDecSession->GetOutputNameAllocated(i, alloc);
            DFN3_LOGI("    erb_dec output[%zu]: '%s'", i, name.get());
        }
        if (nEncIn > 2) {
            DFN3_LOGI("  *** STATEFUL encoder detected (%zu extra state inputs)",
                      nEncIn - 2);
        }
        if (nDecOut > 1) {
            DFN3_LOGI("  *** STATEFUL decoder detected (%zu hidden state outputs)",
                      nDecOut - 1);
        }
    }

    // ── Attempt to load df_dec.onnx (deep filtering stage) ──────────
    impl_->dfDecSession = impl_->loadModel(mgr, dir + "/df_dec.onnx");
    if (impl_->dfDecSession) {
        DFN3_LOGI("DFN3 df_dec loaded — deep filtering enabled");
        impl_->dfDecReady = true;
        // Introspect: log inputs/outputs for debugging
        Ort::AllocatorWithDefaultOptions alloc;
        size_t numIn = impl_->dfDecSession->GetInputCount();
        size_t numOut = impl_->dfDecSession->GetOutputCount();
        DFN3_LOGI("  df_dec inputs: %zu, outputs: %zu", numIn, numOut);
        for (size_t i = 0; i < numIn; ++i) {
            auto name = impl_->dfDecSession->GetInputNameAllocated(i, alloc);
            auto info = impl_->dfDecSession->GetInputTypeInfo(i).GetTensorTypeAndShapeInfo();
            auto shape = info.GetShape();
            DFN3_LOGI("    input[%zu] '%s': [%s]", i, name.get(), shapeToString(shape).c_str());
        }
        for (size_t i = 0; i < numOut; ++i) {
            auto name = impl_->dfDecSession->GetOutputNameAllocated(i, alloc);
            auto info = impl_->dfDecSession->GetOutputTypeInfo(i).GetTensorTypeAndShapeInfo();
            auto shape = info.GetShape();
            DFN3_LOGI("    output[%zu] '%s': [%s]", i, name.get(), shapeToString(shape).c_str());
        }
    } else {
        DFN3_LOGW("df_dec.onnx not found — running ERB-only mode (degraded quality)");
        impl_->dfDecReady = false;
    }

    impl_->ready = true;
    initialized_ = true;
    return true;
}

bool Dfn3Denoiser::processHop(float* hop) {
    if (!impl_->ready) return false;

    // ─── Warmup: prime STFT + ERB state without modifying audio ──────
    // During warmup the ERB temporal smoothing (α=0.98) hasn't converged,
    // producing wrong gains → audible burst. We run analysis/features to
    // fill buffers but return false (= bypass, caller uses dry signal).
    impl_->warmupCounter++;
    if (impl_->warmupCounter <= kWarmupHops) {
        // Run analysis to prime stftInBuf (otherwise first real frames
        // would still see a half-zero buffer).
        impl_->analysis(hop);
        impl_->extractErbFeatures();  // accumulate smoothing state
        // Don't run synthesis — keep OLA buffer zeroed. Caller sees
        // "not processed" and keeps the dry signal.
        return false;
    }

    // 1. STFT analysis
    impl_->analysis(hop);

    // 2. Extract features
    impl_->extractErbFeatures();
    impl_->extractSpecFeatures();

    // 3. Run DNN inference (encoder + ERB decoder)
    float erbGains[kNbErb];
    if (!impl_->runInference(erbGains)) {
        // Inference failed — synthesize with unity mask (transparent pass)
        for (int i = 0; i < kNbErb; ++i) erbGains[i] = 1.0f;
        impl_->applyErbMask(erbGains);
        impl_->synthesis(hop);
        return false;
    }

    // 4. Apply ERB mask to spectrum (with floor protecting voice)
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
        impl_->warmupCounter = 0;
        impl_->erbDecStates.clear();
        impl_->hasDecoderStates = false;
    }
    DFN3_LOGI("reset()");
}

}  // namespace dfn3_denoiser

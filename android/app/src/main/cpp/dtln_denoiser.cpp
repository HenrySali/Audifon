/// @file dtln_denoiser.cpp
/// @brief DTLN denoiser implementation — dual ONNX model pipeline.
///
/// Architecture (Westhausen & Meyer 2020):
///   Core 1: input = STFT magnitude [1, 1, 257]
///           output = magnitude mask [1, 1, 257]
///           + LSTM hidden/cell states persisted between frames
///   Core 2: input = estimated signal block [1, 1, 512]
///           output = clean signal block [1, 1, 512]
///           + LSTM hidden/cell states persisted between frames
///
/// Pipeline per frame (shift=128 @16kHz):
///   1. Shift input buffer left by 128, append new 128 samples
///   2. FFT(512) on the 512-sample block
///   3. Core 1: magnitude(FFT) → mask; apply mask to complex FFT
///   4. iFFT → time-domain estimated signal (512 samples)
///   5. Core 2: estimated signal → clean signal (512 samples)
///   6. Overlap-add: output += clean[0:128] (the first shift samples)
///
/// Resampling: 48kHz → 16kHz (input) and 16kHz → 48kHz (output)
/// using the same Kaldi LinearResample as DPDFNet.

#include "dtln_denoiser.h"
#include "onnxruntime/onnxruntime_cxx_api.h"

#include <android/asset_manager.h>
#include <android/log.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <chrono>
#include <string>
#include <vector>

#define TAG "DTLN"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#ifndef M_2PI
#define M_2PI 6.283185307179586476925286766559005
#endif

namespace dtln_denoiser {
namespace {

// ═══════════════════════════════════════════════════════════════════════════════
// SIMPLE FFT — Cooley-Tukey radix-2 DIT for N=512
// ═══════════════════════════════════════════════════════════════════════════════

static void fft512(const float* in_re, float* out_re, float* out_im) {
    constexpr int N = 512;
    // Bit-reversal permutation
    float re[N], im[N];
    for (int i = 0; i < N; ++i) { re[i] = in_re[i]; im[i] = 0.0f; }
    for (int i = 1, j = 0; i < N; ++i) {
        int bit = N >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) { std::swap(re[i], re[j]); std::swap(im[i], im[j]); }
    }
    // Butterfly
    for (int len = 2; len <= N; len <<= 1) {
        float ang = -2.0f * static_cast<float>(M_PI) / len;
        float wRe = std::cos(ang), wIm = std::sin(ang);
        for (int i = 0; i < N; i += len) {
            float curRe = 1.0f, curIm = 0.0f;
            for (int j = 0; j < len / 2; ++j) {
                float tRe = curRe * re[i+j+len/2] - curIm * im[i+j+len/2];
                float tIm = curRe * im[i+j+len/2] + curIm * re[i+j+len/2];
                re[i+j+len/2] = re[i+j] - tRe;
                im[i+j+len/2] = im[i+j] - tIm;
                re[i+j] += tRe;
                im[i+j] += tIm;
                float nRe = curRe * wRe - curIm * wIm;
                float nIm = curRe * wIm + curIm * wRe;
                curRe = nRe; curIm = nIm;
            }
        }
    }
    for (int i = 0; i < N; ++i) { out_re[i] = re[i]; out_im[i] = im[i]; }
}

static void ifft512(const float* in_re, const float* in_im, float* out_re) {
    constexpr int N = 512;
    // Conjugate → FFT → conjugate → scale
    float re[N], im[N];
    for (int i = 0; i < N; ++i) { re[i] = in_re[i]; im[i] = -in_im[i]; }
    // Bit-reversal
    for (int i = 1, j = 0; i < N; ++i) {
        int bit = N >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) { std::swap(re[i], re[j]); std::swap(im[i], im[j]); }
    }
    // Butterfly
    for (int len = 2; len <= N; len <<= 1) {
        float ang = -2.0f * static_cast<float>(M_PI) / len;
        float wRe = std::cos(ang), wIm = std::sin(ang);
        for (int i = 0; i < N; i += len) {
            float curRe = 1.0f, curIm = 0.0f;
            for (int j = 0; j < len / 2; ++j) {
                float tRe = curRe * re[i+j+len/2] - curIm * im[i+j+len/2];
                float tIm = curRe * im[i+j+len/2] + curIm * re[i+j+len/2];
                re[i+j+len/2] = re[i+j] - tRe;
                im[i+j+len/2] = im[i+j] - tIm;
                re[i+j] += tRe;
                im[i+j] += tIm;
                float nRe = curRe * wRe - curIm * wIm;
                float nIm = curRe * wIm + curIm * wRe;
                curRe = nRe; curIm = nIm;
            }
        }
    }
    const float scale = 1.0f / N;
    for (int i = 0; i < N; ++i) out_re[i] = re[i] * scale;
}

// ═══════════════════════════════════════════════════════════════════════════════
// LINEAR RESAMPLE (Kaldi/sherpa-onnx style, same as dpdfnet_denoiser.cpp)
// ═══════════════════════════════════════════════════════════════════════════════

static int32_t Gcd(int32_t m, int32_t n) {
    while (n) { int32_t t = n; n = m % n; m = t; }
    return m > 0 ? m : -m;
}

class LinearResample {
public:
    LinearResample(int32_t sr_in, int32_t sr_out, float cutoff, int32_t num_zeros)
        : sr_in_(sr_in), sr_out_(sr_out), cutoff_(cutoff), nz_(num_zeros) {
        int32_t base = Gcd(sr_in_, sr_out_);
        in_unit_ = sr_in_ / base;
        out_unit_ = sr_out_ / base;
        SetIndexesAndWeights();
    }
    void Reset() { in_off_ = 0; out_off_ = 0; remainder_.clear(); }
    void Resample(const float* in, int32_t n, bool flush, std::vector<float>& out) {
        int64_t tot_in = in_off_ + n;
        int64_t tot_out = NumOut(tot_in, flush);
        out.resize(static_cast<size_t>(tot_out - out_off_));
        for (int64_t s = out_off_; s < tot_out; ++s) {
            int64_t first; int32_t wrapped;
            GetIdx(s, first, wrapped);
            const auto& w = weights_[wrapped];
            int32_t fi = static_cast<int32_t>(first - in_off_);
            float val = 0;
            for (int32_t i = 0; i < static_cast<int32_t>(w.size()); ++i) {
                int32_t idx = fi + i;
                if (idx < 0 && static_cast<int32_t>(remainder_.size()) + idx >= 0)
                    val += w[i] * remainder_[remainder_.size() + idx];
                else if (idx >= 0 && idx < n)
                    val += w[i] * in[idx];
            }
            out[static_cast<size_t>(s - out_off_)] = val;
        }
        if (flush) { Reset(); }
        else { SetRemainder(in, n); in_off_ = tot_in; out_off_ = tot_out; }
    }
private:
    float FilterFunc(float t) const {
        float win = 0, filt = 0;
        if (std::fabs(t) < nz_ / (2.0f * cutoff_))
            win = 0.5f * (1.0f + std::cos(static_cast<float>(M_2PI) * cutoff_ / nz_ * t));
        if (t != 0)
            filt = std::sin(static_cast<float>(M_2PI) * cutoff_ * t) / (static_cast<float>(M_PI) * t);
        else
            filt = 2.0f * cutoff_;
        return filt * win;
    }
    void SetIndexesAndWeights() {
        first_idx_.resize(out_unit_);
        weights_.resize(out_unit_);
        double ww = nz_ / (2.0 * cutoff_);
        for (int32_t i = 0; i < out_unit_; ++i) {
            double ot = i / static_cast<double>(sr_out_);
            int32_t mn = static_cast<int32_t>(std::ceil((ot - ww) * sr_in_));
            int32_t mx = static_cast<int32_t>(std::floor((ot + ww) * sr_in_));
            first_idx_[i] = mn;
            weights_[i].resize(mx - mn + 1);
            for (int32_t j = 0; j < static_cast<int32_t>(weights_[i].size()); ++j) {
                double dt = (mn + j) / static_cast<double>(sr_in_) - ot;
                weights_[i][j] = FilterFunc(static_cast<float>(dt)) / sr_in_;
            }
        }
    }
    int64_t NumOut(int64_t tot_in, bool flush) const {
        int32_t tf = sr_in_ / Gcd(sr_in_, sr_out_) * sr_out_;
        int32_t tpi = tf / sr_in_;
        int64_t il = tot_in * tpi;
        if (!flush) { il -= static_cast<int64_t>(std::floor(nz_ / (2.0 * cutoff_) * tf)); }
        if (il <= 0) return 0;
        int32_t tpo = tf / sr_out_;
        int64_t last = il / tpo;
        if (last * tpo == il) --last;
        return last + 1;
    }
    void GetIdx(int64_t s, int64_t& first, int32_t& wrapped) const {
        int64_t unit = s / out_unit_;
        wrapped = static_cast<int32_t>(s - unit * out_unit_);
        first = first_idx_[wrapped] + unit * in_unit_;
    }
    void SetRemainder(const float* in, int32_t n) {
        int32_t needed = static_cast<int32_t>(std::ceil(sr_in_ * nz_ / cutoff_));
        std::vector<float> old(remainder_);
        remainder_.resize(needed, 0.0f);
        for (int32_t idx = -needed; idx < 0; ++idx) {
            int32_t ii = idx + n;
            if (ii >= 0) remainder_[idx + needed] = in[ii];
            else if (static_cast<int32_t>(old.size()) + ii + n - n >= 0 &&
                     ii + static_cast<int32_t>(old.size()) >= 0)
                remainder_[idx + needed] = old[ii + old.size()];
            else remainder_[idx + needed] = 0;
        }
    }
    int32_t sr_in_, sr_out_, nz_, in_unit_, out_unit_;
    float cutoff_;
    std::vector<int32_t> first_idx_;
    std::vector<std::vector<float>> weights_;
    int64_t in_off_ = 0, out_off_ = 0;
    std::vector<float> remainder_;
};

} // anonymous namespace

// ═══════════════════════════════════════════════════════════════════════════════
// IMPL — DTLN dual-model pipeline
// ═══════════════════════════════════════════════════════════════════════════════

struct DtlnDenoiser::Impl {
    // ─── ONNX Runtime ──────────────────────────────────────────────────
    Ort::Env env{ORT_LOGGING_LEVEL_WARNING, TAG};
    Ort::SessionOptions opts;
    std::unique_ptr<Ort::Session> session1;  // Core 1 (STFT domain)
    std::unique_ptr<Ort::Session> session2;  // Core 2 (time domain)
    Ort::MemoryInfo memInfo{Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault)};

    // Core 1 I/O names (2 inputs: mag + states, 2 outputs: mask + states_out)
    std::vector<std::string> c1_inNames;
    std::vector<std::string> c1_outNames;
    std::vector<const char*> c1_inPtrs;
    std::vector<const char*> c1_outPtrs;

    // Core 2 I/O names (2 inputs: signal + states, 2 outputs: clean + states_out)
    std::vector<std::string> c2_inNames;
    std::vector<std::string> c2_outNames;
    std::vector<const char*> c2_inPtrs;
    std::vector<const char*> c2_outPtrs;

    // LSTM states — single tensor per model (shape determined at runtime)
    std::vector<float> c1_states;
    std::vector<float> c2_states;
    std::vector<int64_t> c1_stateShape;
    std::vector<int64_t> c2_stateShape;
    size_t c1_stateSize = 0;
    size_t c2_stateSize = 0;

    // Core 1 input shape: [1, 1, 257] (magnitude)
    std::array<int64_t, 3> magShape = {1, 1, kNBins};
    // Core 2 input shape: [1, 1, 512] (time block)
    std::array<int64_t, 3> blockShape = {1, 1, kBlockSize};

    bool modelReady = false;

    // ─── STFT buffers ──────────────────────────────────────────────────
    float inBuf[kBlockSize] = {};         // sliding input buffer @16kHz
    float fftRe[kFftSize] = {};           // FFT real part
    float fftIm[kFftSize] = {};           // FFT imag part
    float magnitude[kNBins] = {};         // |X|
    float mask[kNBins] = {};              // estimated mask
    float maskedRe[kFftSize] = {};        // masked complex (for iFFT)
    float maskedIm[kFftSize] = {};
    float estimated[kBlockSize] = {};     // iFFT output (time domain)
    float cleanBlock[kBlockSize] = {};    // Core 2 output

    // ─── Overlap-add output buffer ─────────────────────────────────────
    // OLA buffer holds pending output samples. Since shift=128 and block=512,
    // we have 4x overlap. Size = kBlockSize to hold accumulated output.
    float olaBuf[kBlockSize] = {};

    // ─── Resampler 48↔16 ──────────────────────────────────────────────
    std::unique_ptr<LinearResample> downsampler;
    std::unique_ptr<LinearResample> upsampler;

    // ─── Buffers for process() ─────────────────────────────────────────
    std::vector<float> ds16Buf;
    std::vector<float> pendingIn;
    std::vector<float> cleanOut16;
    std::vector<float> up48Buf;
    std::vector<float> wetRing;
    int wetW = 0, wetR = 0;
    static constexpr int kWetCap = 16384;
    static constexpr float kXfadeStep = 1.0f / kXfadeSamples;

    Impl() {
        opts.SetIntraOpNumThreads(1);
        opts.SetInterOpNumThreads(1);
        opts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        wetRing.resize(kWetCap, 0.0f);
    }

    bool loadModel(AAssetManager* mgr, const char* path,
                   std::unique_ptr<Ort::Session>& sess) {
        AAsset* asset = AAssetManager_open(mgr, path, AASSET_MODE_BUFFER);
        if (!asset) { LOGE("Cannot open %s", path); return false; }
        size_t sz = AAsset_getLength(asset);
        const void* buf = AAsset_getBuffer(asset);
        try {
            sess = std::make_unique<Ort::Session>(env, buf, sz, opts);
        } catch (const Ort::Exception& e) {
            LOGE("ORT load %s: %s", path, e.what());
            AAsset_close(asset);
            return false;
        }
        AAsset_close(asset);
        LOGI("Loaded %s (%zu bytes)", path, sz);
        return true;
    }

    bool loadAndInit(AAssetManager* mgr, const char* dir) {
        std::string path1 = std::string(dir) + "/model_1.onnx";
        std::string path2 = std::string(dir) + "/model_2.onnx";

        if (!loadModel(mgr, path1.c_str(), session1)) return false;
        if (!loadModel(mgr, path2.c_str(), session2)) return false;

        Ort::AllocatorWithDefaultOptions alloc;

        // Introspect Core 1 — get all input/output names dynamically
        {
            size_t nIn = session1->GetInputCount();
            size_t nOut = session1->GetOutputCount();
            LOGI("Core1: %zu inputs, %zu outputs", nIn, nOut);
            c1_inNames.resize(nIn);
            c1_inPtrs.resize(nIn);
            for (size_t i = 0; i < nIn; ++i) {
                auto n = session1->GetInputNameAllocated(i, alloc);
                c1_inNames[i] = n.get();
                c1_inPtrs[i] = c1_inNames[i].c_str();
                LOGI("  in[%zu] = '%s'", i, c1_inNames[i].c_str());
            }
            c1_outNames.resize(nOut);
            c1_outPtrs.resize(nOut);
            for (size_t i = 0; i < nOut; ++i) {
                auto n = session1->GetOutputNameAllocated(i, alloc);
                c1_outNames[i] = n.get();
                c1_outPtrs[i] = c1_outNames[i].c_str();
                LOGI("  out[%zu] = '%s'", i, c1_outNames[i].c_str());
            }
            // Determine state size from input[1] shape
            if (nIn >= 2) {
                auto typeInfo = session1->GetInputTypeInfo(1);
                auto tensorInfo = typeInfo.GetTensorTypeAndShapeInfo();
                c1_stateShape = tensorInfo.GetShape();
                c1_stateSize = 1;
                for (auto d : c1_stateShape) {
                    if (d <= 0) d = 1; // dynamic dim → assume 1
                    c1_stateSize *= static_cast<size_t>(d);
                }
                c1_states.assign(c1_stateSize, 0.0f);
                LOGI("  state1 size=%zu shape=[%s]", c1_stateSize,
                     std::to_string(c1_stateShape.size()).c_str());
            }
        }

        // Introspect Core 2
        {
            size_t nIn = session2->GetInputCount();
            size_t nOut = session2->GetOutputCount();
            LOGI("Core2: %zu inputs, %zu outputs", nIn, nOut);
            c2_inNames.resize(nIn);
            c2_inPtrs.resize(nIn);
            for (size_t i = 0; i < nIn; ++i) {
                auto n = session2->GetInputNameAllocated(i, alloc);
                c2_inNames[i] = n.get();
                c2_inPtrs[i] = c2_inNames[i].c_str();
                LOGI("  in[%zu] = '%s'", i, c2_inNames[i].c_str());
            }
            c2_outNames.resize(nOut);
            c2_outPtrs.resize(nOut);
            for (size_t i = 0; i < nOut; ++i) {
                auto n = session2->GetOutputNameAllocated(i, alloc);
                c2_outNames[i] = n.get();
                c2_outPtrs[i] = c2_outNames[i].c_str();
                LOGI("  out[%zu] = '%s'", i, c2_outNames[i].c_str());
            }
            if (nIn >= 2) {
                auto typeInfo = session2->GetInputTypeInfo(1);
                auto tensorInfo = typeInfo.GetTensorTypeAndShapeInfo();
                c2_stateShape = tensorInfo.GetShape();
                c2_stateSize = 1;
                for (auto d : c2_stateShape) {
                    if (d <= 0) d = 1;
                    c2_stateSize *= static_cast<size_t>(d);
                }
                c2_states.assign(c2_stateSize, 0.0f);
                LOGI("  state2 size=%zu", c2_stateSize);
            }
        }

        // Resamplers
        float minSr = std::min(48000, kModelSr) * 0.5f * 0.99f;
        downsampler = std::make_unique<LinearResample>(48000, kModelSr, minSr, 6);
        upsampler = std::make_unique<LinearResample>(kModelSr, 48000, minSr, 6);

        modelReady = true;
        LOGI("DTLN init OK (block=%d, shift=%d, fft=%d, bins=%d)",
             kBlockSize, kShift, kFftSize, kNBins);
        return true;
    }

    void resetState() {
        std::fill(c1_states.begin(), c1_states.end(), 0.0f);
        std::fill(c2_states.begin(), c2_states.end(), 0.0f);
        std::memset(inBuf, 0, sizeof(inBuf));
        std::memset(olaBuf, 0, sizeof(olaBuf));
        pendingIn.clear();
        downsampler->Reset();
        upsampler->Reset();
        wetW = wetR = 0;
        std::fill(wetRing.begin(), wetRing.end(), 0.0f);
    }

    /// Process one shift (128 samples) through the DTLN pipeline.
    /// Appends kShift output samples to cleanOut16.
    void processShift(const float* shiftData, DtlnDenoiser* owner) {
        auto t0 = std::chrono::steady_clock::now();

        // 1. Shift input buffer left by kShift, append new samples
        std::memmove(inBuf, inBuf + kShift, (kBlockSize - kShift) * sizeof(float));
        std::memcpy(inBuf + (kBlockSize - kShift), shiftData, kShift * sizeof(float));

        // 2. FFT of the 512-sample block
        fft512(inBuf, fftRe, fftIm);

        // 3. Compute magnitude for first 257 bins
        for (int i = 0; i < kNBins; ++i) {
            magnitude[i] = std::sqrt(fftRe[i] * fftRe[i] + fftIm[i] * fftIm[i]);
        }

        // 4. Core 1: magnitude → mask (2 inputs: mag + state, 2 outputs: mask + state_out)
        {
            Ort::Value inputs[2] = {Ort::Value{nullptr}, Ort::Value{nullptr}};
            inputs[0] = Ort::Value::CreateTensor<float>(
                memInfo, magnitude, kNBins, magShape.data(), magShape.size());
            inputs[1] = Ort::Value::CreateTensor<float>(
                memInfo, c1_states.data(), c1_stateSize,
                c1_stateShape.data(), c1_stateShape.size());

            std::vector<Ort::Value> outs;
            try {
                outs = session1->Run(Ort::RunOptions{nullptr},
                                     c1_inPtrs.data(), inputs, 2,
                                     c1_outPtrs.data(), c1_outPtrs.size());
            } catch (const Ort::Exception& e) {
                LOGE("Core1 Run: %s", e.what());
                return;
            }

            // Copy mask output
            const float* maskOut = outs[0].GetTensorData<float>();
            std::memcpy(mask, maskOut, kNBins * sizeof(float));

            // Update states from output[1]
            if (outs.size() > 1) {
                const float* sOut = outs[1].GetTensorData<float>();
                std::memcpy(c1_states.data(), sOut, c1_stateSize * sizeof(float));
            }
        }

        // 5. Apply mask to complex spectrum and reconstruct full spectrum
        for (int i = 0; i < kNBins; ++i) {
            maskedRe[i] = fftRe[i] * mask[i];
            maskedIm[i] = fftIm[i] * mask[i];
        }
        // Mirror for iFFT (conjugate symmetry)
        for (int i = kNBins; i < kFftSize; ++i) {
            maskedRe[i] = maskedRe[kFftSize - i];
            maskedIm[i] = -maskedIm[kFftSize - i];
        }

        // 6. iFFT → estimated time-domain signal
        ifft512(maskedRe, maskedIm, estimated);

        // 7. Core 2: estimated signal → clean signal (2 inputs: signal + state)
        {
            Ort::Value inputs[2] = {Ort::Value{nullptr}, Ort::Value{nullptr}};
            inputs[0] = Ort::Value::CreateTensor<float>(
                memInfo, estimated, kBlockSize, blockShape.data(), blockShape.size());
            inputs[1] = Ort::Value::CreateTensor<float>(
                memInfo, c2_states.data(), c2_stateSize,
                c2_stateShape.data(), c2_stateShape.size());

            std::vector<Ort::Value> outs;
            try {
                outs = session2->Run(Ort::RunOptions{nullptr},
                                     c2_inPtrs.data(), inputs, 2,
                                     c2_outPtrs.data(), c2_outPtrs.size());
            } catch (const Ort::Exception& e) {
                LOGE("Core2 Run: %s", e.what());
                return;
            }

            // Copy clean output
            const float* cleanOut = outs[0].GetTensorData<float>();
            std::memcpy(cleanBlock, cleanOut, kBlockSize * sizeof(float));

            // Update states from output[1]
            if (outs.size() > 1) {
                const float* sOut = outs[1].GetTensorData<float>();
                std::memcpy(c2_states.data(), sOut, c2_stateSize * sizeof(float));
            }
        }

        // 8. Overlap-add: shift olaBuf left by kShift, output the shifted-out,
        //    then add the new cleanBlock to olaBuf
        // Output the first kShift samples from olaBuf
        cleanOut16.insert(cleanOut16.end(), olaBuf, olaBuf + kShift);

        // Shift olaBuf left by kShift
        std::memmove(olaBuf, olaBuf + kShift, (kBlockSize - kShift) * sizeof(float));
        std::memset(olaBuf + (kBlockSize - kShift), 0, kShift * sizeof(float));

        // Add cleanBlock to olaBuf
        for (int i = 0; i < kBlockSize; ++i) {
            olaBuf[i] += cleanBlock[i];
        }

        owner->processedFrames_.fetch_add(1, std::memory_order_relaxed);

        auto t1 = std::chrono::steady_clock::now();
        uint32_t us = static_cast<uint32_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count());
        owner->lastInferenceUs_.store(us, std::memory_order_relaxed);
    }

    // Wet ring helpers @48k
    int wetAvail() const { int a = wetW - wetR; return a < 0 ? a + kWetCap : a; }
    void wetPush(float s) { wetRing[wetW] = s; wetW = (wetW + 1) % kWetCap; }
    float wetPop() { if (wetR == wetW) return 0; float s = wetRing[wetR]; wetR = (wetR + 1) % kWetCap; return s; }
};

// ═══════════════════════════════════════════════════════════════════════════════
// PUBLIC API
// ═══════════════════════════════════════════════════════════════════════════════

DtlnDenoiser::DtlnDenoiser() : impl_(std::make_unique<Impl>()) {}
DtlnDenoiser::~DtlnDenoiser() = default;

bool DtlnDenoiser::initialize(AAssetManager* mgr, const char* assetDir) {
    if (!impl_ || impl_->modelReady) return impl_ && impl_->modelReady;
    if (!mgr || !assetDir || !assetDir[0]) return false;
    bool ok = impl_->loadAndInit(mgr, assetDir);
    if (ok) active_.store(true, std::memory_order_release);
    return ok;
}

void DtlnDenoiser::setEnabled(bool e) {
    enabled_.store(e, std::memory_order_release);
    crossfadeTarget_ = e ? 1.0f : 0.0f;
}

void DtlnDenoiser::setIntensity(float v) {
    intensity_.store(std::clamp(v, 0.0f, 1.0f), std::memory_order_release);
}

void DtlnDenoiser::reset() {
    if (impl_) impl_->resetState();
    crossfadeGain_ = 0;
    crossfadeTarget_ = 0;
    effectiveIntensity_ = 0;
}

float DtlnDenoiser::getEffectiveIntensity() const { return effectiveIntensity_; }
uint64_t DtlnDenoiser::getProcessedFrames() const { return processedFrames_.load(std::memory_order_relaxed); }
uint64_t DtlnDenoiser::getDroppedFrames() const { return droppedFrames_.load(std::memory_order_relaxed); }
uint32_t DtlnDenoiser::getLastInferenceUs() const { return lastInferenceUs_.load(std::memory_order_relaxed); }

void DtlnDenoiser::process(float* buffer, int blockSize) {
    if (!buffer || blockSize <= 0) return;
    const bool enabled = enabled_.load(std::memory_order_acquire);
    const bool active = active_.load(std::memory_order_acquire);
    if (!enabled && crossfadeGain_ == 0.0f) return;
    if (!active) { crossfadeTarget_ = 0.0f; effectiveIntensity_ = 0.0f; return; }
    const float intensity = intensity_.load(std::memory_order_relaxed);

    // 1. Downsample 48→16
    impl_->downsampler->Resample(buffer, blockSize, false, impl_->ds16Buf);

    // 2. Feed pending + process shifts
    impl_->pendingIn.insert(impl_->pendingIn.end(),
                            impl_->ds16Buf.begin(), impl_->ds16Buf.end());
    impl_->cleanOut16.clear();
    int consumed = 0;
    while (static_cast<int>(impl_->pendingIn.size()) - consumed >= kShift) {
        impl_->processShift(impl_->pendingIn.data() + consumed, this);
        consumed += kShift;
    }
    if (consumed > 0) {
        impl_->pendingIn.erase(impl_->pendingIn.begin(),
                               impl_->pendingIn.begin() + consumed);
    }

    // 3. Upsample 16→48 and push to wet ring
    if (!impl_->cleanOut16.empty()) {
        impl_->upsampler->Resample(impl_->cleanOut16.data(),
                                   static_cast<int>(impl_->cleanOut16.size()),
                                   false, impl_->up48Buf);
        for (float s : impl_->up48Buf) impl_->wetPush(s);
    }

    // 4. Crossfade + intensity mix + clamp
    for (int i = 0; i < blockSize; ++i) {
        if (crossfadeGain_ < crossfadeTarget_)
            crossfadeGain_ = std::min(crossfadeGain_ + Impl::kXfadeStep, crossfadeTarget_);
        else if (crossfadeGain_ > crossfadeTarget_)
            crossfadeGain_ = std::max(crossfadeGain_ - Impl::kXfadeStep, crossfadeTarget_);
        float wet = impl_->wetPop();
        float dry = buffer[i];
        float gain = intensity * crossfadeGain_;
        buffer[i] = std::clamp(dry * (1.0f - gain) + wet * gain, -1.0f, 1.0f);
    }
    effectiveIntensity_ = intensity * crossfadeGain_;
}

} // namespace dtln_denoiser

/// @file dpdfnet_denoiser.cpp
/// @brief DPDFNet-4 denoiser — sherpa-onnx reference pipeline (validated).
///
/// Rewrite using the EXACT STFT/iSTFT/resampling logic from sherpa-onnx
/// (k2-fsa, Apache 2.0). The previous artisanal pipeline had bugs causing
/// hoarseness. This version ports:
///   - StreamingDft: DFT with double-precision tables (no float accumulation error)
///   - OnlineSpeechDenoiserStftImpl: shift buffer + window + DFT + model + iDFT + window + OLA
///   - LinearResample (Kaldi): high-quality sinc resampler for 48↔16 kHz
///   - Vorbis window: sin(pi/2 * sin(pi*(n+0.5)/N)^2)
///
/// Zero-dependency on sherpa-onnx library — all logic inlined here.
/// Model loaded via OnnxRuntime (already in the project).

#include "dpdfnet_denoiser.h"
#include "onnxruntime/onnxruntime_cxx_api.h"

#include <android/asset_manager.h>
#include <android/log.h>

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
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

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#ifndef M_2PI
#define M_2PI 6.283185307179586476925286766559005
#endif

namespace dpdfnet_denoiser {
namespace {

// ═══════════════════════════════════════════════════════════════════════════════
// VORBIS WINDOW (from sherpa-onnx/csrc/math.cc, Apache 2.0)
// ═══════════════════════════════════════════════════════════════════════════════
static std::vector<float> MakeVorbisWindow(int32_t N) {
    std::vector<float> w(N);
    const float half = N / 2.0f;
    for (int32_t i = 0; i < N; ++i) {
        float s = std::sin(0.5f * static_cast<float>(M_PI) * (i + 0.5f) / half);
        w[i] = std::sin(0.5f * static_cast<float>(M_PI) * s * s);
    }
    return w;
}

// ═══════════════════════════════════════════════════════════════════════════════
// STREAMING DFT (from sherpa-onnx, double-precision tables)
// ═══════════════════════════════════════════════════════════════════════════════
class StreamingDft {
public:
    explicit StreamingDft(int32_t n_fft)
        : n_(n_fft), nbins_(n_fft / 2 + 1),
          cos_f_(nbins_ * n_fft), sin_f_(nbins_ * n_fft),
          cos_i_(n_fft * nbins_), sin_i_(n_fft * nbins_) {
        for (int32_t k = 0; k < nbins_; ++k) {
            for (int32_t n = 0; n < n_; ++n) {
                double angle = M_2PI * k * n / n_;
                double c = std::cos(angle), s = std::sin(angle);
                cos_f_[k * n_ + n] = c;
                sin_f_[k * n_ + n] = s;
                cos_i_[n * nbins_ + k] = c;
                sin_i_[n * nbins_ + k] = s;
            }
        }
    }
    void Forward(const float* input, float* output) const {
        for (int32_t k = 0; k < nbins_; ++k) {
            double re = 0, im = 0;
            const double* pc = cos_f_.data() + k * n_;
            const double* ps = sin_f_.data() + k * n_;
            for (int32_t n = 0; n < n_; ++n) {
                double v = input[n];
                re += v * pc[n];
                im -= v * ps[n];
            }
            output[2 * k] = static_cast<float>(re);
            output[2 * k + 1] = static_cast<float>(im);
        }
    }
    void Inverse(const float* input, float* output) const {
        for (int32_t n = 0; n < n_; ++n) {
            double sum = input[0];  // DC real
            if (n_ % 2 == 0) {
                sum += input[2 * (nbins_ - 1)] * ((n & 1) ? -1.0 : 1.0);
            }
            const double* pc = cos_i_.data() + n * nbins_;
            const double* ps = sin_i_.data() + n * nbins_;
            for (int32_t k = 1; k < nbins_ - 1; ++k) {
                double re = input[2 * k], im = input[2 * k + 1];
                sum += 2.0 * (re * pc[k] - im * ps[k]);
            }
            output[n] = static_cast<float>(sum / n_);
        }
    }
private:
    int32_t n_, nbins_;
    std::vector<double> cos_f_, sin_f_, cos_i_, sin_i_;
};

// ═══════════════════════════════════════════════════════════════════════════════
// LINEAR RESAMPLE (from Kaldi/sherpa-onnx, Apache 2.0) — sinc interpolation
// Simplified for the 48↔16 kHz case (ratio 3:1, exact integer).
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
        int32_t tf = sr_in_ / Gcd(sr_in_, sr_out_) * sr_out_; // lcm
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
// IMPL — sherpa-onnx reference pipeline adapted to IDenoiserEngine
// ═══════════════════════════════════════════════════════════════════════════════

struct DpdfnetDenoiser::Impl {
    // ─── ONNX Runtime ──────────────────────────────────────────────────
    Ort::Env env{ORT_LOGGING_LEVEL_WARNING, TAG};
    Ort::SessionOptions opts;
    std::unique_ptr<Ort::Session> session;
    Ort::MemoryInfo memInfo{Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault)};
    std::string inName0, inName1, outName0, outName1;
    const char* inPtrs[2] = {nullptr, nullptr};
    const char* outPtrs[2] = {nullptr, nullptr};
    std::vector<int64_t> stateShape;
    std::vector<float> stateData;
    std::vector<float> stateInit;
    std::array<int64_t, 4> specShape = {1, 1, 161, 2};
    int stateSize = 0;
    int nBins = 161;
    int nFft = 320;
    int hopLen = 160;
    int modelSr = 16000;
    bool modelReady = false;

    // ─── STFT pipeline (sherpa-onnx style) ─────────────────────────────
    std::unique_ptr<StreamingDft> dft;
    std::vector<float> window;
    std::vector<float> analysisBuf;   // [nFft] shift buffer
    std::vector<float> olaBuf;        // [nFft] overlap-add buffer
    std::vector<float> fftIn;         // [nFft]
    std::vector<float> fftOut;        // [nBins*2]
    std::vector<float> enhOut;        // [nBins*2]
    std::vector<float> ifftOut;       // [nFft]
    bool started = false;

    // ─── Resampler 48↔16 ──────────────────────────────────────────────
    std::unique_ptr<LinearResample> downsampler;  // 48→16
    std::unique_ptr<LinearResample> upsampler;    // 16→48

    // ─── Buffers for process() ─────────────────────────────────────────
    std::vector<float> ds16Buf;       // downsampled input
    std::vector<float> pendingIn;     // pending @16k samples
    std::vector<float> cleanOut16;    // clean output @16k
    std::vector<float> up48Buf;       // upsampled output
    std::vector<float> wetRing;       // wet ring @48k
    int wetW = 0, wetR = 0;
    static constexpr int kWetCap = 16384;

    // ─── Crossfade ─────────────────────────────────────────────────────
    static constexpr int kXfade = 800;
    static constexpr float kXfadeStep = 1.0f / kXfade;

    Impl() {
        opts.SetIntraOpNumThreads(1);
        opts.SetInterOpNumThreads(1);
        opts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        wetRing.resize(kWetCap, 0.0f);
    }

    bool loadAndInit(AAssetManager* mgr, const char* path) {
        AAsset* asset = AAssetManager_open(mgr, path, AASSET_MODE_BUFFER);
        if (!asset) { LOGE("Cannot open %s", path); return false; }
        size_t sz = AAsset_getLength(asset);
        const void* buf = AAsset_getBuffer(asset);
        try { session = std::make_unique<Ort::Session>(env, buf, sz, opts); }
        catch (const Ort::Exception& e) { LOGE("ORT: %s", e.what()); AAsset_close(asset); return false; }
        AAsset_close(asset);
        LOGI("Loaded %s (%zu bytes)", path, sz);
        // Introspect
        Ort::AllocatorWithDefaultOptions alloc;
        if (session->GetInputCount() != 2 || session->GetOutputCount() != 2) return false;
        { auto n = session->GetInputNameAllocated(0, alloc); inName0 = n.get(); }
        { auto n = session->GetInputNameAllocated(1, alloc); inName1 = n.get(); }
        { auto n = session->GetOutputNameAllocated(0, alloc); outName0 = n.get(); }
        { auto n = session->GetOutputNameAllocated(1, alloc); outName1 = n.get(); }
        inPtrs[0] = inName0.c_str(); inPtrs[1] = inName1.c_str();
        outPtrs[0] = outName0.c_str(); outPtrs[1] = outName1.c_str();
        // Spec shape
        { auto info = session->GetInputTypeInfo(0).GetTensorTypeAndShapeInfo();
          auto sh = info.GetShape();
          if (sh.size() == 4) { nBins = static_cast<int>(sh[2]); specShape = {1,1,sh[2],2}; }
        }
        // State
        { auto info = session->GetInputTypeInfo(1).GetTensorTypeAndShapeInfo();
          stateShape = info.GetShape(); stateSize = 1;
          for (auto& d : stateShape) { if (d < 0) d = 1; stateSize *= static_cast<int>(d); }
        }
        // Metadata
        try {
            auto meta = session->GetModelMetadata();
            // Parse state init
            stateData.assign(stateSize, 0.0f);
            auto parseCSV = [](const char* csv, float* dst, int max) {
                int c = 0; const char* p = csv;
                while (*p && c < max) {
                    while (*p == ' ' || *p == ',' || *p == '[' || *p == ']') ++p;
                    if (!*p) break;
                    char* end; float v = std::strtof(p, &end);
                    if (end == p) break; dst[c++] = v; p = end;
                } return c;
            };
            int off = 0;
            try { auto v = meta.LookupCustomMetadataMapAllocated("erb_norm_init", alloc);
                  if (v) off += parseCSV(v.get(), stateData.data(), stateSize); } catch(...) {}
            try { auto v = meta.LookupCustomMetadataMapAllocated("spec_norm_init", alloc);
                  if (v) parseCSV(v.get(), stateData.data() + off, stateSize - off); } catch(...) {}
            // n_fft, hop_length from metadata
            try { auto v = meta.LookupCustomMetadataMapAllocated("n_fft", alloc);
                  if (v) nFft = std::atoi(v.get()); } catch(...) {}
            try { auto v = meta.LookupCustomMetadataMapAllocated("hop_length", alloc);
                  if (v) hopLen = std::atoi(v.get()); } catch(...) {}
            try { auto v = meta.LookupCustomMetadataMapAllocated("sample_rate", alloc);
                  if (v) modelSr = std::atoi(v.get()); } catch(...) {}
        } catch (...) { LOGW("Metadata read partial"); }
        stateInit = stateData;
        nBins = nFft / 2 + 1;
        specShape = {1, 1, nBins, 2};
        // Init STFT pipeline
        dft = std::make_unique<StreamingDft>(nFft);
        window = MakeVorbisWindow(nFft);
        analysisBuf.assign(nFft, 0.0f);
        olaBuf.assign(nFft, 0.0f);
        fftIn.resize(nFft); fftOut.resize(nBins * 2);
        enhOut.resize(nBins * 2); ifftOut.resize(nFft);
        started = false;
        // Resamplers (Kaldi-style sinc, 6 zeros, cutoff 0.99*min/2)
        float minSr = std::min(48000, modelSr) * 0.5f * 0.99f;
        downsampler = std::make_unique<LinearResample>(48000, modelSr, minSr, 6);
        upsampler = std::make_unique<LinearResample>(modelSr, 48000, minSr, 6);
        modelReady = true;
        LOGI("DPDFNet-4 init OK (sherpa-onnx pipeline, nfft=%d hop=%d sr=%d state=%d)",
             nFft, hopLen, modelSr, stateSize);
        return true;
    }

    void resetState() {
        stateData = stateInit;
        std::fill(analysisBuf.begin(), analysisBuf.end(), 0.0f);
        std::fill(olaBuf.begin(), olaBuf.end(), 0.0f);
        started = false;
        pendingIn.clear();
        downsampler->Reset(); upsampler->Reset();
        wetW = wetR = 0;
        std::fill(wetRing.begin(), wetRing.end(), 0.0f);
    }

    // Process one hop through STFT → model → iSTFT (sherpa-onnx style)
    // Appends output to cleanOut16 (or skips first frame for latency).
    void processHop(const float* hop, DpdfnetDenoiser* owner) {
        // Shift analysis buffer and insert new hop
        std::move(analysisBuf.begin() + hopLen, analysisBuf.end(), analysisBuf.begin());
        std::copy(hop, hop + hopLen, analysisBuf.end() - hopLen);
        // Window
        for (int i = 0; i < nFft; ++i) fftIn[i] = analysisBuf[i] * window[i];
        // Forward DFT
        dft->Forward(fftIn.data(), fftOut.data());
        // Run ONNX model
        Ort::Value inputs[2] = {Ort::Value{nullptr}, Ort::Value{nullptr}};
        inputs[0] = Ort::Value::CreateTensor<float>(memInfo, fftOut.data(),
                    nBins * 2, specShape.data(), specShape.size());
        inputs[1] = Ort::Value::CreateTensor<float>(memInfo, stateData.data(),
                    stateData.size(), stateShape.data(), stateShape.size());
        std::vector<Ort::Value> outs;
        try {
            outs = session->Run(Ort::RunOptions{nullptr}, inPtrs, inputs, 2, outPtrs, 2);
        } catch (const Ort::Exception& e) {
            LOGE("ONNX Run: %s", e.what()); return;
        }
        // Copy enhanced spec + update state
        const float* enh = outs[0].GetTensorData<float>();
        std::copy(enh, enh + nBins * 2, enhOut.data());
        const float* sout = outs[1].GetTensorData<float>();
        std::memcpy(stateData.data(), sout, stateData.size() * sizeof(float));
        owner->processedFrames_.fetch_add(1, std::memory_order_relaxed);
        // Inverse DFT
        dft->Inverse(enhOut.data(), ifftOut.data());
        // OLA (sherpa-onnx style: shift left, add windowed)
        std::move(olaBuf.begin() + hopLen, olaBuf.end(), olaBuf.begin());
        std::fill(olaBuf.end() - hopLen, olaBuf.end(), 0.0f);
        for (int i = 0; i < nFft; ++i) olaBuf[i] += ifftOut[i] * window[i];
        // Output: first frame is discarded (latency), then output hop samples
        if (!started) { started = true; return; }
        cleanOut16.insert(cleanOut16.end(), olaBuf.begin(), olaBuf.begin() + hopLen);
    }

    // Wet ring helpers @48k
    int wetAvail() const { int a = wetW - wetR; return a < 0 ? a + kWetCap : a; }
    void wetPush(float s) { wetRing[wetW] = s; wetW = (wetW+1)%kWetCap; }
    float wetPop() { if (wetR==wetW) return 0; float s=wetRing[wetR]; wetR=(wetR+1)%kWetCap; return s; }
};

// ═══════════════════════════════════════════════════════════════════════════════
// PUBLIC API
// ═══════════════════════════════════════════════════════════════════════════════

DpdfnetDenoiser::DpdfnetDenoiser() : impl_(std::make_unique<Impl>()) {}
DpdfnetDenoiser::~DpdfnetDenoiser() = default;

bool DpdfnetDenoiser::initialize(AAssetManager* mgr, const char* assetPath) {
    if (!impl_ || impl_->modelReady) return impl_ && impl_->modelReady;
    if (!mgr || !assetPath || !assetPath[0]) return false;
    bool ok = impl_->loadAndInit(mgr, assetPath);
    if (ok) active_.store(true, std::memory_order_release);
    return ok;
}

void DpdfnetDenoiser::setEnabled(bool e) {
    enabled_.store(e, std::memory_order_release);
    crossfadeTarget_ = e ? 1.0f : 0.0f;
}
void DpdfnetDenoiser::setIntensity(float v) {
    intensity_.store(std::clamp(v, 0.0f, 1.0f), std::memory_order_release);
}
void DpdfnetDenoiser::reset() { if (impl_) impl_->resetState(); crossfadeGain_=0; crossfadeTarget_=0; effectiveIntensity_=0; }
float DpdfnetDenoiser::getEffectiveIntensity() const { return effectiveIntensity_; }
uint64_t DpdfnetDenoiser::getProcessedFrames() const { return processedFrames_.load(std::memory_order_relaxed); }
uint64_t DpdfnetDenoiser::getDroppedFrames() const { return droppedFrames_.load(std::memory_order_relaxed); }
uint32_t DpdfnetDenoiser::getLastInferenceUs() const { return lastInferenceUs_.load(std::memory_order_relaxed); }

void DpdfnetDenoiser::process(float* buffer, int blockSize) {
    if (!buffer || blockSize <= 0) return;
    const bool enabled = enabled_.load(std::memory_order_acquire);
    const bool active = active_.load(std::memory_order_acquire);
    if (!enabled && crossfadeGain_ == 0.0f) return;
    if (!active) { crossfadeTarget_ = 0.0f; effectiveIntensity_ = 0.0f; return; }
    const float intensity = intensity_.load(std::memory_order_relaxed);

    // 1. Downsample 48→16
    impl_->downsampler->Resample(buffer, blockSize, false, impl_->ds16Buf);

    // 2. Feed pending + process hops
    impl_->pendingIn.insert(impl_->pendingIn.end(), impl_->ds16Buf.begin(), impl_->ds16Buf.end());
    impl_->cleanOut16.clear();
    int consumed = 0;
    while (static_cast<int>(impl_->pendingIn.size()) - consumed >= impl_->hopLen) {
        impl_->processHop(impl_->pendingIn.data() + consumed, this);
        consumed += impl_->hopLen;
    }
    if (consumed > 0) impl_->pendingIn.erase(impl_->pendingIn.begin(), impl_->pendingIn.begin() + consumed);

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

// Capture stubs (kept for API compat, actual capture now in DenoiserSelector)
bool DpdfnetDenoiser::startCapture(const char*) { return false; }
void DpdfnetDenoiser::stopCapture() {}
bool DpdfnetDenoiser::isCapturing() const { return false; }
bool DpdfnetDenoiser::isCaptureReady() const { return false; }

} // namespace dpdfnet_denoiser

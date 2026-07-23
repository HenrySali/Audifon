/// @file dtln_denoiser.cpp
/// @brief DTLN denoiser implementation (OnnxRuntime, 16 kHz, frame 512).

#include "dtln_denoiser.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <vector>

#include <android/asset_manager.h>
#include <android/log.h>
#include "dnn_denoiser/onnxruntime/onnxruntime_cxx_api.h"

#define LOG_TAG "DtlnDenoiser"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace dtln {

static constexpr int kFrame    = 512;
static constexpr int kFft      = 512;
static constexpr int kBins     = kFft / 2 + 1;  // 257
static constexpr int kHop      = 256;
static constexpr int kLstmSize = 128;
static constexpr int kLstmLayers = 2;
static constexpr int kStateElems = 1 * kLstmLayers * kLstmSize * 2; // 512
static constexpr int kRingCap  = 4096;
static constexpr int kRingMask = kRingCap - 1;

struct DtlnDenoiser::Impl {
    Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "dtln"};
    Ort::SessionOptions opts;
    std::unique_ptr<Ort::Session> session1;
    std::unique_ptr<Ort::Session> session2;

    std::vector<float> state1{kStateElems, 0.0f};
    std::vector<float> state2{kStateElems, 0.0f};

    float window[kFrame];

    // OLA
    float olaOut[kFrame] = {};

    // Ring buffers
    float inRing[kRingCap] = {};
    float outRing[kRingCap] = {};
    int inWr = 0, inRd = 0;
    int outWr = 0, outRd = 0;

    // Scratch
    float frameBuf[kFrame];
    float magBuf[kBins];
    float phaseBuf[kBins];
    float realBuf[kBins];
    float imagBuf[kBins];
    float enhancedFrame[kFrame];
    float outputFrame[kFrame];

    // Control
    std::atomic<bool>  active{false};
    std::atomic<bool>  enabled{false};
    std::atomic<float> intensity{1.0f};
    std::atomic<uint64_t> processedFrames{0};
    std::atomic<uint32_t> lastInferenceUs{0};

    float crossfadeGain = 0.0f;
    static constexpr float kCrossfadeStep = 1.0f / 80.0f;

    int inAvail() const { return (inWr - inRd) & kRingMask; }
    int outAvail() const { return (outWr - outRd) & kRingMask; }
    int outFree() const { return kRingCap - 1 - outAvail(); }

    void pushIn(const float* data, int n) {
        for (int i = 0; i < n; ++i) { inRing[inWr] = data[i]; inWr = (inWr + 1) & kRingMask; }
    }
    void popIn(float* dst, int n) {
        for (int i = 0; i < n; ++i) { dst[i] = inRing[inRd]; inRd = (inRd + 1) & kRingMask; }
    }
    void pushOut(const float* data, int n) {
        for (int i = 0; i < n; ++i) { outRing[outWr] = data[i]; outWr = (outWr + 1) & kRingMask; }
    }
    float popOutSample() {
        float s = outRing[outRd]; outRd = (outRd + 1) & kRingMask; return s;
    }

    void realFft(const float* input, float* re, float* im) {
        for (int k = 0; k < kBins; ++k) {
            double sumR = 0.0, sumI = 0.0;
            for (int n = 0; n < kFft; ++n) {
                double angle = 2.0 * M_PI * k * n / kFft;
                sumR += input[n] * std::cos(angle);
                sumI -= input[n] * std::sin(angle);
            }
            re[k] = static_cast<float>(sumR);
            im[k] = static_cast<float>(sumI);
        }
    }

    void realIfft(const float* re, const float* im, float* output) {
        for (int n = 0; n < kFft; ++n) {
            double sum = 0.0;
            for (int k = 0; k < kBins; ++k) {
                double angle = 2.0 * M_PI * k * n / kFft;
                double contrib = re[k] * std::cos(angle) - im[k] * std::sin(angle);
                if (k > 0 && k < kFft / 2) contrib *= 2.0;
                sum += contrib;
            }
            output[n] = static_cast<float>(sum / kFft);
        }
    }

    void processOneFrame() {
        popIn(frameBuf, kFrame);
        auto t0 = std::chrono::steady_clock::now();

        // Window + FFT
        float windowed[kFrame];
        for (int i = 0; i < kFrame; ++i) windowed[i] = frameBuf[i] * window[i];
        realFft(windowed, realBuf, imagBuf);
        for (int k = 0; k < kBins; ++k) {
            magBuf[k] = std::sqrt(realBuf[k] * realBuf[k] + imagBuf[k] * imagBuf[k]);
            phaseBuf[k] = std::atan2(imagBuf[k], realBuf[k]);
        }

        // Model 1
        float magIn[kBins];
        std::memcpy(magIn, magBuf, kBins * sizeof(float));
        const int64_t magShape[] = {1, 1, kBins};
        const int64_t stateShape[] = {1, kLstmLayers, kLstmSize, 2};
        Ort::MemoryInfo memInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

        std::vector<Ort::Value> inputs1;
        inputs1.reserve(2);
        inputs1.push_back(Ort::Value::CreateTensor<float>(memInfo, magIn, kBins, magShape, 3));
        inputs1.push_back(Ort::Value::CreateTensor<float>(memInfo, state1.data(), kStateElems, stateShape, 4));

        const char* inNames1[] = {"input_2", "input_3"};
        const char* outNames1[] = {"activation_2", "tf_op_layer_stack_2"};
        auto results1 = session1->Run(Ort::RunOptions{nullptr}, inNames1, inputs1.data(), 2, outNames1, 2);

        const float* maskedMag = results1[0].GetTensorData<float>();
        const float* newState1 = results1[1].GetTensorData<float>();
        std::memcpy(state1.data(), newState1, kStateElems * sizeof(float));

        // Reconstruct + iFFT
        float enhRe[kBins], enhIm[kBins];
        for (int k = 0; k < kBins; ++k) {
            enhRe[k] = maskedMag[k] * std::cos(phaseBuf[k]);
            enhIm[k] = maskedMag[k] * std::sin(phaseBuf[k]);
        }
        realIfft(enhRe, enhIm, enhancedFrame);

        // Model 2
        float frameIn[kFrame];
        std::memcpy(frameIn, enhancedFrame, kFrame * sizeof(float));
        const int64_t frameShape[] = {1, 1, kFrame};

        std::vector<Ort::Value> inputs2;
        inputs2.reserve(2);
        inputs2.push_back(Ort::Value::CreateTensor<float>(memInfo, frameIn, kFrame, frameShape, 3));
        inputs2.push_back(Ort::Value::CreateTensor<float>(memInfo, state2.data(), kStateElems, stateShape, 4));

        const char* inNames2[] = {"input_4", "input_5"};
        const char* outNames2[] = {"conv1d_3", "tf_op_layer_stack_5"};
        auto results2 = session2->Run(Ort::RunOptions{nullptr}, inNames2, inputs2.data(), 2, outNames2, 2);

        const float* outData = results2[0].GetTensorData<float>();
        const float* newState2 = results2[1].GetTensorData<float>();
        std::memcpy(state2.data(), newState2, kStateElems * sizeof(float));
        std::memcpy(outputFrame, outData, kFrame * sizeof(float));

        auto t1 = std::chrono::steady_clock::now();
        lastInferenceUs.store(static_cast<uint32_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count()),
            std::memory_order_relaxed);

        // Window output + OLA
        for (int i = 0; i < kFrame; ++i) outputFrame[i] *= window[i];
        float hopOut[kHop];
        for (int i = 0; i < kHop; ++i) hopOut[i] = olaOut[i] + outputFrame[i];
        std::memcpy(olaOut, &outputFrame[kHop], kHop * sizeof(float));
        pushOut(hopOut, kHop);
        processedFrames.fetch_add(1, std::memory_order_relaxed);
    }
};

// Public API

DtlnDenoiser::DtlnDenoiser() : impl_(std::make_unique<Impl>()) {
    for (int i = 0; i < kFrame; ++i)
        impl_->window[i] = std::sqrt(0.5f * (1.0f - std::cos(2.0f * static_cast<float>(M_PI) * i / kFrame)));
}
DtlnDenoiser::~DtlnDenoiser() = default;

bool DtlnDenoiser::initialize(AAssetManager* mgr) {
    if (!mgr) { LOGE("initialize: null AAssetManager"); return false; }
    impl_->opts.SetIntraOpNumThreads(1);
    impl_->opts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);

    auto loadAsset = [&](const char* path, std::vector<char>& buf) -> bool {
        AAsset* asset = AAssetManager_open(mgr, path, AASSET_MODE_BUFFER);
        if (!asset) { LOGE("Cannot open asset: %s", path); return false; }
        off_t size = AAsset_getLength(asset);
        buf.resize(static_cast<size_t>(size));
        AAsset_read(asset, buf.data(), buf.size());
        AAsset_close(asset);
        return true;
    };

    try {
        std::vector<char> buf1, buf2;
        if (!loadAsset("dtln/model_1.onnx", buf1)) return false;
        if (!loadAsset("dtln/model_2.onnx", buf2)) return false;
        impl_->session1 = std::make_unique<Ort::Session>(impl_->env, buf1.data(), buf1.size(), impl_->opts);
        impl_->session2 = std::make_unique<Ort::Session>(impl_->env, buf2.data(), buf2.size(), impl_->opts);
        LOGI("initialize: DTLN models loaded OK");
        impl_->active.store(true, std::memory_order_release);
        return true;
    } catch (const Ort::Exception& e) {
        LOGE("initialize: %s", e.what());
        return false;
    }
}

void DtlnDenoiser::process(float* buffer, int blockSize) {
    if (!impl_->active.load(std::memory_order_acquire) || blockSize <= 0 || !buffer) return;
    const bool wantEnabled = impl_->enabled.load(std::memory_order_acquire);
    const float userIntensity = impl_->intensity.load(std::memory_order_relaxed);

    impl_->pushIn(buffer, blockSize);
    while (impl_->inAvail() >= kFrame && impl_->outFree() >= kHop) {
        impl_->processOneFrame();
    }

    for (int i = 0; i < blockSize; ++i) {
        const float targetGain = wantEnabled ? 1.0f : 0.0f;
        if (impl_->crossfadeGain < targetGain)
            impl_->crossfadeGain = std::min(targetGain, impl_->crossfadeGain + Impl::kCrossfadeStep);
        else if (impl_->crossfadeGain > targetGain)
            impl_->crossfadeGain = std::max(targetGain, impl_->crossfadeGain - Impl::kCrossfadeStep);

        const float dry = buffer[i];
        float wet = (impl_->outAvail() > 0) ? impl_->popOutSample() : 0.0f;
        const float mix = impl_->crossfadeGain * userIntensity;
        buffer[i] = dry * (1.0f - mix) + wet * mix;
    }
}

void DtlnDenoiser::setEnabled(bool enabled) { impl_->enabled.store(enabled, std::memory_order_release); }
void DtlnDenoiser::setIntensity(float intensity) { impl_->intensity.store(std::max(0.0f, std::min(1.0f, intensity)), std::memory_order_relaxed); }

void DtlnDenoiser::reset() {
    std::fill(impl_->state1.begin(), impl_->state1.end(), 0.0f);
    std::fill(impl_->state2.begin(), impl_->state2.end(), 0.0f);
    std::memset(impl_->olaOut, 0, sizeof(impl_->olaOut));
    std::memset(impl_->inRing, 0, sizeof(impl_->inRing));
    std::memset(impl_->outRing, 0, sizeof(impl_->outRing));
    impl_->inWr = impl_->inRd = impl_->outWr = impl_->outRd = 0;
    impl_->crossfadeGain = 0.0f;
}

bool DtlnDenoiser::isActive() const { return impl_->active.load(std::memory_order_acquire); }
bool DtlnDenoiser::isEnabled() const { return impl_->enabled.load(std::memory_order_acquire); }
uint64_t DtlnDenoiser::getProcessedFrames() const { return impl_->processedFrames.load(std::memory_order_relaxed); }
uint32_t DtlnDenoiser::getLastInferenceUs() const { return impl_->lastInferenceUs.load(std::memory_order_relaxed); }
float DtlnDenoiser::getEffectiveIntensity() const { return impl_->crossfadeGain * impl_->intensity.load(std::memory_order_relaxed); }

} // namespace dtln

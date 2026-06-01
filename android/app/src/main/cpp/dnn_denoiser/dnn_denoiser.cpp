/// @file dnn_denoiser.cpp
/// @brief Implementación del wrapper GTCRN DNN denoiser (OnnxRuntime).
///
/// Diseño dataflow estilo LabVIEW (ver `dnn_denoiser.h` para la doc del SubVI).
///
/// Pipeline interno:
///
///   ┌───────────────┐        ┌───────────────┐        ┌─────────────┐
///   │ audio thread  │  push  │  inputRing    │  pop   │   worker    │
///   │  process()    │──────▶ │ (SPSC float)  │──────▶ │   thread    │
///   └───────────────┘        └───────────────┘        └─────┬───────┘
///        │                                                   │
///        │  (parallel: also pushes to dryDelayRing_)          ▼
///        ▼                                              STFT(512,Hann)
///   ┌───────────────┐                                        │
///   │ dryDelayRing_ │◀───────── time-aligned delay           ▼
///   │ (SPSC float)  │                                  ONNX session.Run()
///   └───────┬───────┘                                        │
///           │                                                ▼
///           │                                          iSTFT (OLA)
///           │                                                │
///           │             ┌───────────────┐                 │
///           └────────────▶│  outputRing   │◀────────────────┘
///                         │ (SPSC float)  │
///                         └──────┬────────┘
///                                │
///                                ▼
///                       audio thread pop + crossfade + intensity mix
///
/// Lock-free: audio thread NUNCA bloquea. Worker bloquea con CV cuando
/// no hay datos suficientes.

#include "dnn_denoiser.h"

#include "onnxruntime/onnxruntime_cxx_api.h"

#include <android/asset_manager.h>
#include <android/log.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

#define DNN_LOG_TAG "DnnDenoiser"
#define DNN_LOGI(...) __android_log_print(ANDROID_LOG_INFO,  DNN_LOG_TAG, __VA_ARGS__)
#define DNN_LOGW(...) __android_log_print(ANDROID_LOG_WARN,  DNN_LOG_TAG, __VA_ARGS__)
#define DNN_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, DNN_LOG_TAG, __VA_ARGS__)

namespace dnn_denoiser {

namespace {

constexpr float kPi = 3.14159265358979323846f;

// ─────────────────────────────────────────────────────────────────────────────
// SPSC ring buffer (single-producer, single-consumer, lock-free)
// ─────────────────────────────────────────────────────────────────────────────

/// Ring buffer SPSC para floats. Tamaño debe ser potencia de 2.
/// Productor (push) y consumidor (pop) están en hilos distintos.
/// No bloqueante en ambas direcciones (devuelve cuántos samples copió).
class SpscRing {
public:
    void init(int capacity) {
        capacity_ = capacity;
        mask_ = capacity - 1;
        buf_.assign(capacity, 0.0f);
        head_.store(0, std::memory_order_relaxed);
        tail_.store(0, std::memory_order_relaxed);
    }

    /// Espacio libre actual (visto por el productor).
    int freeSpace() const {
        const int head = head_.load(std::memory_order_relaxed);
        const int tail = tail_.load(std::memory_order_acquire);
        return capacity_ - (head - tail);
    }

    /// Samples disponibles (visto por el consumidor).
    int available() const {
        const int head = head_.load(std::memory_order_acquire);
        const int tail = tail_.load(std::memory_order_relaxed);
        return head - tail;
    }

    /// Productor: empuja hasta `n` samples. Devuelve cuántos efectivamente entraron.
    int push(const float* src, int n) {
        const int head = head_.load(std::memory_order_relaxed);
        const int tail = tail_.load(std::memory_order_acquire);
        const int free = capacity_ - (head - tail);
        const int toPush = std::min(n, free);
        for (int i = 0; i < toPush; ++i) {
            buf_[(head + i) & mask_] = src[i];
        }
        head_.store(head + toPush, std::memory_order_release);
        return toPush;
    }

    /// Consumidor: tira hasta `n` samples. Devuelve cuántos efectivamente leyó.
    int pop(float* dst, int n) {
        const int tail = tail_.load(std::memory_order_relaxed);
        const int head = head_.load(std::memory_order_acquire);
        const int avail = head - tail;
        const int toPop = std::min(n, avail);
        for (int i = 0; i < toPop; ++i) {
            dst[i] = buf_[(tail + i) & mask_];
        }
        tail_.store(tail + toPop, std::memory_order_release);
        return toPop;
    }

    /// Vacía completamente el buffer (desde el consumidor).
    /// SAFE solo cuando se sabe que el productor no está empujando.
    void clear() {
        tail_.store(head_.load(std::memory_order_acquire),
                    std::memory_order_release);
    }

private:
    std::vector<float>  buf_;
    int                 capacity_ = 0;
    int                 mask_     = 0;
    std::atomic<int>    head_{0};
    std::atomic<int>    tail_{0};
};

// ─────────────────────────────────────────────────────────────────────────────
// FFT radix-2 (in-place complex)
// ─────────────────────────────────────────────────────────────────────────────

/// FFT in-place compleja, decimación-en-tiempo, radix-2.
/// re/im: arrays de longitud N (potencia de 2). N=512 para nuestro caso.
/// Si invert=true → IFFT (escala por 1/N al final).
inline void fftRadix2(float* re, float* im, int N, bool invert) {
    // Bit-reversal permutation.
    int j = 0;
    for (int i = 1; i < N; ++i) {
        int bit = N >> 1;
        for (; j & bit; bit >>= 1) {
            j ^= bit;
        }
        j ^= bit;
        if (i < j) {
            std::swap(re[i], re[j]);
            std::swap(im[i], im[j]);
        }
    }

    // Cooley-Tukey butterflies.
    for (int len = 2; len <= N; len <<= 1) {
        const float ang = (invert ? 2.0f : -2.0f) * kPi / static_cast<float>(len);
        const float wReStep = std::cos(ang);
        const float wImStep = std::sin(ang);
        for (int i = 0; i < N; i += len) {
            float wRe = 1.0f;
            float wIm = 0.0f;
            const int half = len / 2;
            for (int k = 0; k < half; ++k) {
                const float xRe = re[i + k];
                const float xIm = im[i + k];
                const float yRe = re[i + k + half] * wRe - im[i + k + half] * wIm;
                const float yIm = re[i + k + half] * wIm + im[i + k + half] * wRe;
                re[i + k]        = xRe + yRe;
                im[i + k]        = xIm + yIm;
                re[i + k + half] = xRe - yRe;
                im[i + k + half] = xIm - yIm;
                const float nwRe = wRe * wReStep - wIm * wImStep;
                const float nwIm = wRe * wImStep + wIm * wReStep;
                wRe = nwRe;
                wIm = nwIm;
            }
        }
    }

    if (invert) {
        const float inv = 1.0f / static_cast<float>(N);
        for (int i = 0; i < N; ++i) {
            re[i] *= inv;
            im[i] *= inv;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers para describir/inspeccionar tensores ONNX.
// ─────────────────────────────────────────────────────────────────────────────

/// Calcula el número de elementos de un shape (todas las dims producto).
int64_t shapeNumel(const std::vector<int64_t>& shape) {
    int64_t n = 1;
    for (int64_t d : shape) {
        if (d <= 0) return 0;  // dim dinámica → no podemos pre-allocar
        n *= d;
    }
    return n;
}

}  // namespace

// ─────────────────────────────────────────────────────────────────────────────
// PIMPL: Impl
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

    /// Modelo cargado y listo para inferencia.
    bool modelReady = false;

    // ─── STFT state (worker thread only) ───────────────────────────────
    /// Ventana Hann de análisis y síntesis (root-Hann simétrica → COLA con hop=N/2).
    std::vector<float> hannWin;            // [kDnnFftSize]

    /// Buffer circular del STFT input: mantenemos los últimos kDnnFftSize samples,
    /// y desplazamos kDnnHopSize por frame.
    std::vector<float> stftInBuf;          // [kDnnFftSize]

    /// Buffer de overlap-add para reconstrucción del iSTFT.
    std::vector<float> olaBuf;             // [kDnnFftSize]

    /// Workspace para FFT (re/im).
    std::vector<float> fftRe;              // [kDnnFftSize]
    std::vector<float> fftIm;              // [kDnnFftSize]

    /// Buffer staging del frame de salida ya finalizado (kDnnHopSize samples).
    std::vector<float> outputFrame;

    /// Tensor staging para el input "mix" del modelo.
    std::vector<float> mixTensorData;

    /// Caches recurrentes (uno por input cache). Se actualizan tras cada Run().
    std::vector<std::vector<float>>   caches;
    /// Índices (en inputNames/outputNames) que corresponden a las caches.
    /// La convención GTCRN es: input[0] = "mix", input[1..] = caches en orden;
    /// output[0] = "enh", output[1..] = nuevas caches en MISMO orden.
    int                               mixInputIdx  = -1;
    int                               enhOutputIdx = -1;
    std::vector<int>                  cacheInputIdx;   // posiciones en inputNames
    std::vector<int>                  cacheOutputIdx;  // posiciones en outputNames

    // ─── Ring buffers (audio ↔ worker) ─────────────────────────────────
    SpscRing inputRing;     ///< audio_thread → worker
    SpscRing outputRing;    ///< worker → audio_thread (samples enhanced)
    SpscRing dryDelayRing;  ///< audio_thread → audio_thread (dry alineada en tiempo)

    // ─── Worker thread ─────────────────────────────────────────────────
    std::thread             worker;
    std::atomic<bool>       workerRun{false};
    std::atomic<bool>       resetRequested{false};
    std::mutex              workerMtx;
    std::condition_variable workerCv;

    /// Contadores expuestos (también espejados en atomics públicos del wrapper).
    std::atomic<uint64_t>   processedFramesLocal{0};
    std::atomic<uint64_t>   droppedFramesLocal{0};
    std::atomic<uint32_t>   lastInferenceUsLocal{0};

    Impl() {
        sessionOpts.SetIntraOpNumThreads(1);
        sessionOpts.SetInterOpNumThreads(1);
        sessionOpts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);

        hannWin.assign(kDnnFftSize, 0.0f);
        stftInBuf.assign(kDnnFftSize, 0.0f);
        olaBuf.assign(kDnnFftSize, 0.0f);
        fftRe.assign(kDnnFftSize, 0.0f);
        fftIm.assign(kDnnFftSize, 0.0f);
        outputFrame.assign(kDnnHopSize, 0.0f);

        // Hann window (sqrt-Hann es más común para COLA con OLA, pero Hann
        // simple también es perfect-reconstruction con hop=N/2 si se aplica
        // sólo en análisis; aplicamos en análisis y síntesis, así que usamos
        // sqrt-Hann para que el producto en el solapamiento sume a 1).
        for (int i = 0; i < kDnnFftSize; ++i) {
            const float w = 0.5f * (1.0f - std::cos(2.0f * kPi * i / (kDnnFftSize - 1)));
            hannWin[i] = std::sqrt(w);
        }

        inputRing.init(kDnnRingCapacity);
        outputRing.init(kDnnRingCapacity);
        dryDelayRing.init(kDnnRingCapacity);
    }

    ~Impl() {
        stopWorker();
    }

    /// Lee el modelo desde assets a un buffer en RAM (síncrono).
    /// Retorna vector vacío en caso de fallo.
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

    /// Inspecciona la sesión ONNX para descubrir nombres y shapes de I/O.
    /// Retorna true si el modelo cumple el contrato esperado (input "mix" 4D,
    /// el resto son cache tensors fijos; outputs en orden equivalente).
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

        // ── Inputs ────────────────────────────────────────────────────
        for (size_t i = 0; i < numIn; ++i) {
            auto name    = session->GetInputNameAllocated(i, allocator);
            std::string s(name.get());
            inputNames.push_back(s);

            auto info   = session->GetInputTypeInfo(i);
            auto tinfo  = info.GetTensorTypeAndShapeInfo();
            std::vector<int64_t> shape = tinfo.GetShape();
            // Reemplazar dims dinámicas (-1) por 1 (caso del time axis del mix).
            for (auto& d : shape) {
                if (d < 0) d = 1;
            }
            inputShapes.push_back(shape);

            DNN_LOGI("Input[%zu]: name=%s, shape=[%s]", i, s.c_str(), [&](){
                std::string r;
                for (auto d : shape) { r += std::to_string(d) + ","; }
                return r;
            }().c_str());
        }

        // ── Outputs ───────────────────────────────────────────────────
        for (size_t i = 0; i < numOut; ++i) {
            auto name    = session->GetOutputNameAllocated(i, allocator);
            std::string s(name.get());
            outputNames.push_back(s);

            auto info   = session->GetOutputTypeInfo(i);
            auto tinfo  = info.GetTensorTypeAndShapeInfo();
            std::vector<int64_t> shape = tinfo.GetShape();
            for (auto& d : shape) {
                if (d < 0) d = 1;
            }
            outputShapes.push_back(shape);

            DNN_LOGI("Output[%zu]: name=%s, shape=[%s]", i, s.c_str(), [&](){
                std::string r;
                for (auto d : shape) { r += std::to_string(d) + ","; }
                return r;
            }().c_str());
        }

        // ── Identificar "mix" / "enh" / caches ─────────────────────────
        // Heurística: el primer input cuyo nombre contenga "mix" o sea el
        // único 4D (batch, freq, time, complex) es el mix; los demás son caches.
        for (size_t i = 0; i < inputNames.size(); ++i) {
            const std::string& n = inputNames[i];
            if (n.find("mix") != std::string::npos) {
                mixInputIdx = static_cast<int>(i);
            } else {
                cacheInputIdx.push_back(static_cast<int>(i));
            }
        }
        for (size_t i = 0; i < outputNames.size(); ++i) {
            const std::string& n = outputNames[i];
            if (n.find("enh") != std::string::npos ||
                n == "out" || n == "output") {
                enhOutputIdx = static_cast<int>(i);
            } else {
                cacheOutputIdx.push_back(static_cast<int>(i));
            }
        }

        // Fallback: si no encontramos "mix"/"enh" por nombre, asumimos
        // input[0]/output[0] (convención GTCRN).
        if (mixInputIdx < 0)  mixInputIdx  = 0;
        if (enhOutputIdx < 0) enhOutputIdx = 0;

        // Re-armar caches si caímos al fallback.
        if (cacheInputIdx.empty() && inputNames.size() > 1) {
            cacheInputIdx.clear();
            for (size_t i = 0; i < inputNames.size(); ++i) {
                if (static_cast<int>(i) != mixInputIdx) {
                    cacheInputIdx.push_back(static_cast<int>(i));
                }
            }
        }
        if (cacheOutputIdx.empty() && outputNames.size() > 1) {
            cacheOutputIdx.clear();
            for (size_t i = 0; i < outputNames.size(); ++i) {
                if (static_cast<int>(i) != enhOutputIdx) {
                    cacheOutputIdx.push_back(static_cast<int>(i));
                }
            }
        }

        if (cacheInputIdx.size() != cacheOutputIdx.size()) {
            DNN_LOGE("Cache count mismatch: %zu inputs vs %zu outputs",
                     cacheInputIdx.size(), cacheOutputIdx.size());
            return false;
        }

        // ── Validar shape del input "mix" ─────────────────────────────
        if (mixInputIdx < 0 ||
            inputShapes[mixInputIdx].size() < 3) {
            DNN_LOGE("mix input has unexpected shape (need ≥3 dims)");
            return false;
        }

        // ── Pre-allocar caches con ceros ──────────────────────────────
        caches.clear();
        for (int idx : cacheInputIdx) {
            const int64_t numel = shapeNumel(inputShapes[idx]);
            if (numel <= 0) {
                DNN_LOGE("Cache input has dynamic shape, cannot pre-allocate");
                return false;
            }
            caches.emplace_back(static_cast<size_t>(numel), 0.0f);
        }

        // Pre-allocar buffer del mix tensor.
        const int64_t mixNumel = shapeNumel(inputShapes[mixInputIdx]);
        if (mixNumel <= 0) {
            DNN_LOGE("mix input has invalid total size");
            return false;
        }
        mixTensorData.assign(static_cast<size_t>(mixNumel), 0.0f);

        // Punteros C-string para Run().
        inputNameCStr.clear();
        outputNameCStr.clear();
        for (auto& s : inputNames)  inputNameCStr.push_back(s.c_str());
        for (auto& s : outputNames) outputNameCStr.push_back(s.c_str());

        DNN_LOGI("Model introspection OK: mix=%d, enh=%d, %zu caches",
                 mixInputIdx, enhOutputIdx, caches.size());
        return true;
    }

    /// Resetea caches y buffers STFT (a llamar cuando reset_requested).
    void resetWorkerState() {
        for (auto& c : caches) {
            std::fill(c.begin(), c.end(), 0.0f);
        }
        std::fill(stftInBuf.begin(),  stftInBuf.end(),  0.0f);
        std::fill(olaBuf.begin(),     olaBuf.end(),     0.0f);
        std::fill(fftRe.begin(),      fftRe.end(),      0.0f);
        std::fill(fftIm.begin(),      fftIm.end(),      0.0f);
        std::fill(outputFrame.begin(),outputFrame.end(),0.0f);
    }

    /// Ejecuta una inferencia GTCRN sobre un frame de kDnnHopSize samples
    /// nuevos provenientes de inputRing. Empuja kDnnHopSize samples al outputRing.
    /// Devuelve true si el frame se procesó OK (false → falla, el wrapper
    /// debería pasar a bypass).
    bool processOneFrame(const float* hopIn) {
        // ── 1. Desplazar stftInBuf a la izquierda por kDnnHopSize y append ──
        std::memmove(stftInBuf.data(),
                     stftInBuf.data() + kDnnHopSize,
                     (kDnnFftSize - kDnnHopSize) * sizeof(float));
        std::memcpy(stftInBuf.data() + (kDnnFftSize - kDnnHopSize),
                    hopIn, kDnnHopSize * sizeof(float));

        // ── 2. Aplicar ventana de análisis (sqrt-Hann) ───────────────────
        for (int i = 0; i < kDnnFftSize; ++i) {
            fftRe[i] = stftInBuf[i] * hannWin[i];
            fftIm[i] = 0.0f;
        }

        // ── 3. FFT → 257 bins complejos ──────────────────────────────────
        fftRadix2(fftRe.data(), fftIm.data(), kDnnFftSize, /*invert=*/false);

        // ── 4. Empacar en mixTensorData con shape esperada [1,257,1,2] ───
        // Asumimos [batch, freq, time, complex]. Si el modelo usa otro orden
        // (p.ej. [B, T, F, 2]) introspectModel lo aceptará pero el packing
        // será incorrecto y el output será inutilizable. En ese caso fallback.
        const auto& mixShape = inputShapes[mixInputIdx];
        const int nBins = kDnnFftSize / 2 + 1;  // 257
        // Heurística: ¿la dim con valor 257 es freq? Buscamos.
        int freqDim = -1;
        for (size_t i = 0; i < mixShape.size(); ++i) {
            if (mixShape[i] == nBins) {
                freqDim = static_cast<int>(i);
                break;
            }
        }
        if (freqDim < 0) {
            DNN_LOGE("Cannot find freq dim (expected size=%d) in mix shape", nBins);
            return false;
        }

        // Para simplicidad asumimos shape [1, 257, 1, 2] (caso GTCRN simple).
        // Si el orden es distinto, el packing puede estar mal — log y bypass.
        std::fill(mixTensorData.begin(), mixTensorData.end(), 0.0f);
        if (mixShape.size() == 4 && mixShape[0] == 1 && mixShape[1] == nBins &&
            mixShape[2] == 1 && mixShape[3] == 2) {
            // [1, 257, 1, 2] → idx = freq * 2 + complex
            for (int f = 0; f < nBins; ++f) {
                mixTensorData[f * 2 + 0] = fftRe[f];
                mixTensorData[f * 2 + 1] = fftIm[f];
            }
        } else {
            DNN_LOGE("Unsupported mix shape (expected [1,257,1,2])");
            return false;
        }

        // ── 5. Construir tensores ONNX ───────────────────────────────────
        std::vector<Ort::Value> inputs;
        inputs.reserve(inputNames.size());

        // Pre-asignar el slot del mix; vamos a llenar el array por índice.
        for (size_t i = 0; i < inputNames.size(); ++i) {
            inputs.push_back(Ort::Value(nullptr));  // placeholder
        }

        inputs[mixInputIdx] = Ort::Value::CreateTensor<float>(
            memInfo,
            mixTensorData.data(),
            mixTensorData.size(),
            inputShapes[mixInputIdx].data(),
            inputShapes[mixInputIdx].size());

        for (size_t k = 0; k < cacheInputIdx.size(); ++k) {
            const int idx = cacheInputIdx[k];
            inputs[idx] = Ort::Value::CreateTensor<float>(
                memInfo,
                caches[k].data(),
                caches[k].size(),
                inputShapes[idx].data(),
                inputShapes[idx].size());
        }

        // ── 6. Run() ─────────────────────────────────────────────────────
        std::vector<Ort::Value> outputs;
        const auto t0 = std::chrono::steady_clock::now();
        try {
            outputs = session->Run(
                Ort::RunOptions{nullptr},
                inputNameCStr.data(),  inputs.data(),  inputs.size(),
                outputNameCStr.data(), outputNameCStr.size());
        } catch (const Ort::Exception& e) {
            DNN_LOGE("OnnxRuntime Run failed: %s", e.what());
            return false;
        }
        const auto t1 = std::chrono::steady_clock::now();
        const auto us = std::chrono::duration_cast<std::chrono::microseconds>(
                            t1 - t0).count();
        lastInferenceUsLocal.store(static_cast<uint32_t>(us),
                                    std::memory_order_relaxed);

        if (outputs.size() != outputNames.size()) {
            DNN_LOGE("Run returned %zu outputs (expected %zu)",
                     outputs.size(), outputNames.size());
            return false;
        }

        // ── 7. Copiar caches actualizadas ────────────────────────────────
        for (size_t k = 0; k < cacheOutputIdx.size(); ++k) {
            const int idx = cacheOutputIdx[k];
            const float* p = outputs[idx].GetTensorData<float>();
            const size_t n = caches[k].size();
            std::memcpy(caches[k].data(), p, n * sizeof(float));
        }

        // ── 8. Desempacar enh tensor → fftRe/fftIm ───────────────────────
        const float* enhData = outputs[enhOutputIdx].GetTensorData<float>();
        std::fill(fftRe.begin(), fftRe.end(), 0.0f);
        std::fill(fftIm.begin(), fftIm.end(), 0.0f);
        // Asumimos misma shape [1,257,1,2] que el mix.
        for (int f = 0; f < nBins; ++f) {
            fftRe[f] = enhData[f * 2 + 0];
            fftIm[f] = enhData[f * 2 + 1];
        }
        // Simetría hermitica para reconstrucción real.
        for (int f = 1; f < kDnnFftSize / 2; ++f) {
            fftRe[kDnnFftSize - f] =  fftRe[f];
            fftIm[kDnnFftSize - f] = -fftIm[f];
        }

        // ── 9. iFFT → samples reales ─────────────────────────────────────
        fftRadix2(fftRe.data(), fftIm.data(), kDnnFftSize, /*invert=*/true);

        // ── 10. Aplicar ventana de síntesis (sqrt-Hann) y OLA ────────────
        for (int i = 0; i < kDnnFftSize; ++i) {
            fftRe[i] *= hannWin[i];
            olaBuf[i] += fftRe[i];
        }

        // ── 11. Extraer kDnnHopSize samples del inicio del olaBuf ────────
        std::memcpy(outputFrame.data(), olaBuf.data(),
                    kDnnHopSize * sizeof(float));

        // Shift olaBuf: descartar primeros kDnnHopSize, append zeros al final.
        std::memmove(olaBuf.data(),
                     olaBuf.data() + kDnnHopSize,
                     (kDnnFftSize - kDnnHopSize) * sizeof(float));
        std::fill(olaBuf.begin() + (kDnnFftSize - kDnnHopSize),
                  olaBuf.end(), 0.0f);

        // ── 12. Push outputFrame al outputRing ───────────────────────────
        // Si no hay espacio, descartamos el frame (drop counter).
        const int pushed = outputRing.push(outputFrame.data(), kDnnHopSize);
        if (pushed < kDnnHopSize) {
            droppedFramesLocal.fetch_add(1, std::memory_order_relaxed);
        }

        return true;
    }

    /// Loop principal del worker.
    void workerLoop() {
        DNN_LOGI("Worker thread started");
        std::vector<float> hopBuf(kDnnHopSize, 0.0f);

        while (workerRun.load(std::memory_order_acquire)) {
            // Reset si fue solicitado.
            if (resetRequested.exchange(false, std::memory_order_acq_rel)) {
                resetWorkerState();
                inputRing.clear();
                outputRing.clear();
                // dryDelayRing lo limpia el audio thread (nosotros no podemos).
            }

            // Esperar hasta tener kDnnHopSize samples disponibles.
            {
                std::unique_lock<std::mutex> lk(workerMtx);
                workerCv.wait_for(lk, std::chrono::milliseconds(50), [this] {
                    return !workerRun.load(std::memory_order_acquire) ||
                           inputRing.available() >= kDnnHopSize ||
                           resetRequested.load(std::memory_order_acquire);
                });
            }
            if (!workerRun.load(std::memory_order_acquire)) break;
            if (inputRing.available() < kDnnHopSize) continue;

            // Drain un hop.
            const int popped = inputRing.pop(hopBuf.data(), kDnnHopSize);
            if (popped < kDnnHopSize) continue;  // race extraño, reintentar.

            // Procesar.
            if (!modelReady) continue;
            const bool ok = processOneFrame(hopBuf.data());
            if (!ok) {
                DNN_LOGW("processOneFrame failed → flagging inactive");
                modelReady = false;  // bypass permanente hasta reset.
                continue;
            }
            processedFramesLocal.fetch_add(1, std::memory_order_relaxed);
        }
        DNN_LOGI("Worker thread exited");
    }

    void startWorker() {
        if (worker.joinable()) return;
        workerRun.store(true, std::memory_order_release);
        worker = std::thread([this]{ workerLoop(); });
    }

    void stopWorker() {
        workerRun.store(false, std::memory_order_release);
        workerCv.notify_all();
        if (worker.joinable()) worker.join();
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// DnnDenoiser methods
// ─────────────────────────────────────────────────────────────────────────────

DnnDenoiser::DnnDenoiser() : impl_(std::make_unique<Impl>()) {}

DnnDenoiser::~DnnDenoiser() = default;

bool DnnDenoiser::initialize(AAssetManager* assetMgr, const char* assetPath) {
    if (impl_->modelReady) {
        DNN_LOGW("initialize: already initialized, no-op");
        return true;
    }

    DNN_LOGI("initialize: loading %s", assetPath ? assetPath : "(null)");

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

    impl_->modelReady = true;
    active_.store(true, std::memory_order_release);
    impl_->startWorker();
    DNN_LOGI("initialize: OK, worker thread running");
    return true;
}

void DnnDenoiser::process(float* buffer, int blockSize) {
    if (buffer == nullptr || blockSize <= 0) return;

    const bool en  = enabled_.load(std::memory_order_acquire);
    const bool act = active_.load(std::memory_order_acquire);

    // Fast path 1: bypass total — sin modelo o sin enable + crossfade en 0.
    // Salimos sin tocar el buffer (bit-exact).
    if (!en && crossfadeGain_ <= 0.0f) {
        return;
    }

    // Si no estamos activos (modelo no cargado o falla), saltar la cola DSP
    // pero respetar el crossfade out (si venía siendo wet y ahora apagamos).
    if (!act) {
        // Si crossfadeGain_ > 0 (estábamos en wet) hacemos crossfade out con
        // dry buffer (que es el mismo que el input). Como no hay wet, el
        // resultado es simplemente el dry; sólo evolucionamos el gain.
        crossfadeTarget_ = 0.0f;
        if (crossfadeGain_ > 0.0f) {
            for (int i = 0; i < blockSize; ++i) {
                crossfadeGain_ = std::max(0.0f, crossfadeGain_ - kCrossfadeStep);
            }
        }
        return;
    }

    // Actualizar target del crossfade.
    crossfadeTarget_ = en ? 1.0f : 0.0f;

    // Empujar input al inputRing y al dryDelayRing simultáneamente.
    // Si el inputRing está lleno (worker congestionado), hacemos drop:
    // simplemente saltamos el push y contamos los frames perdidos.
    const int pushedIn  = impl_->inputRing.push(buffer, blockSize);
    const int pushedDry = impl_->dryDelayRing.push(buffer, blockSize);
    if (pushedIn < blockSize) {
        droppedFrames_.fetch_add(1, std::memory_order_relaxed);
    }
    // Notificar al worker (solo si recién llegamos al umbral).
    if (impl_->inputRing.available() >= kDnnHopSize) {
        impl_->workerCv.notify_one();
    }

    // Tirar wet samples del outputRing.
    // Si no hay suficientes (worker no alcanzó la tasa), usar dry como fallback
    // y NO consumir del dryDelayRing (eso ya lo hicimos como push, lo dejamos
    // ahí para el siguiente intento de mezcla). En ese caso simplemente dejamos
    // el buffer como está (passthrough) y la mezcla queda en dry.
    std::vector<float> wet(blockSize, 0.0f);
    std::vector<float> dry(blockSize, 0.0f);
    const int gotWet = impl_->outputRing.pop(wet.data(), blockSize);
    const int gotDry = impl_->dryDelayRing.pop(dry.data(), blockSize);

    if (gotWet < blockSize) {
        // Underrun: no hay suficiente wet → pasar dry, que ya tiene el delay
        // correcto. Las muestras dry leídas se descartan (los samples wet
        // futuros que las correspondan ya van a estar adelantadas).
        // Sync simple: consumir el resto del dry para mantener el alineamiento
        // 1:1, y emitir dry directamente.
        // (En este caso el dryDelayRing puede descalibrarse temporalmente,
        // pero converge en cuanto el worker se recupera porque ambos consumen
        // a la misma tasa cuando todo está estable.)
        for (int i = 0; i < blockSize; ++i) {
            // buffer[i] ya es dry (input original); mantener.
            // Avanzar el crossfade hacia el target.
            if (crossfadeGain_ < crossfadeTarget_) {
                crossfadeGain_ = std::min(crossfadeTarget_,
                                          crossfadeGain_ + kCrossfadeStep);
            } else if (crossfadeGain_ > crossfadeTarget_) {
                crossfadeGain_ = std::max(crossfadeTarget_,
                                          crossfadeGain_ - kCrossfadeStep);
            }
        }
        return;
    }

    // Mezcla normal: dry ↔ wet con intensity, modulada por crossfadeGain_.
    const float intensityVal = intensity_.load(std::memory_order_acquire);
    for (int i = 0; i < blockSize; ++i) {
        // Avanzar crossfade un sample.
        if (crossfadeGain_ < crossfadeTarget_) {
            crossfadeGain_ = std::min(crossfadeTarget_,
                                      crossfadeGain_ + kCrossfadeStep);
        } else if (crossfadeGain_ > crossfadeTarget_) {
            crossfadeGain_ = std::max(crossfadeTarget_,
                                      crossfadeGain_ - kCrossfadeStep);
        }

        // Mezcla: amount of DNN = crossfadeGain_ * intensity.
        const float dnnAmount = crossfadeGain_ * intensityVal;
        const float drySample = (gotDry > i) ? dry[i] : buffer[i];
        const float mixed     = drySample * (1.0f - dnnAmount) + wet[i] * dnnAmount;

        // Clamp ±1.0 por seguridad.
        buffer[i] = std::max(-1.0f, std::min(1.0f, mixed));
    }

    // Espejar contadores al wrapper público.
    processedFrames_.store(impl_->processedFramesLocal.load(std::memory_order_relaxed),
                            std::memory_order_relaxed);
    droppedFrames_.store(impl_->droppedFramesLocal.load(std::memory_order_relaxed) +
                            droppedFrames_.load(std::memory_order_relaxed),
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

void DnnDenoiser::reset() {
    if (impl_) {
        impl_->resetRequested.store(true, std::memory_order_release);
        impl_->workerCv.notify_one();
        // El audio thread también necesita limpiar el dryDelayRing.
        impl_->dryDelayRing.clear();
    }
    crossfadeGain_   = 0.0f;
    crossfadeTarget_ = enabled_.load(std::memory_order_acquire) ? 1.0f : 0.0f;
}

}  // namespace dnn_denoiser

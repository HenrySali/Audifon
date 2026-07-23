/// @file dfn3_onnx_denoiser.cpp
/// @brief Implementación del DFN3 ONNX autocontenido (torchDF streaming export).
///
/// Ver dfn3_onnx_denoiser.h para el contrato del modelo y el diseño.
///
/// Lógica de inferencia (equivalente al onnx_infer.py de referencia):
///   state = zeros(45304)
///   atten_lim_db = zeros(1)   # 0 dB = sin límite de atenuación
///   for hop in stream(480):
///       enh, state, lsnr = model(hop, state, atten_lim_db)
///
/// El modelo tiene 1 hop de latencia (enh[k] ≈ clean(hop[k-1])). Para mezclar
/// dry/wet sin comb filtering, el dry se retarda 1 hop (prevDry_).

#include "dfn3_onnx_denoiser.h"

#include "dnn_denoiser/onnxruntime/onnxruntime_cxx_api.h"

#include <android/asset_manager.h>
#include <android/log.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <string>
#include <vector>

#define DFNX_TAG "Dfn3OnnxDenoiser"
#define DFNX_LOGI(...) __android_log_print(ANDROID_LOG_INFO,  DFNX_TAG, __VA_ARGS__)
#define DFNX_LOGW(...) __android_log_print(ANDROID_LOG_WARN,  DFNX_TAG, __VA_ARGS__)
#define DFNX_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, DFNX_TAG, __VA_ARGS__)

namespace dfn3_onnx {

namespace {

/// Nombres de I/O del modelo DFN3-48k (torchDF export).
constexpr const char* kInFrame  = "input_frame";
constexpr const char* kInStates = "states";
constexpr const char* kInAtten  = "atten_lim_db";
constexpr const char* kOutEnh   = "enhanced_audio_frame";
constexpr const char* kOutState = "new_states";

/// Producto de las dims de un shape (dims <=0 se tratan como 1).
int64_t shapeNumel(const std::vector<int64_t>& shape) {
    int64_t n = 1;
    for (int64_t d : shape) n *= (d > 0 ? d : 1);
    return n;
}

}  // namespace

// ─────────────────────────────────────────────────────────────────────────────
// PIMPL
// ─────────────────────────────────────────────────────────────────────────────

struct Dfn3OnnxDenoiser::Impl {
    Ort::Env            env{ORT_LOGGING_LEVEL_WARNING, DFNX_TAG};
    Ort::SessionOptions sessionOpts;
    std::unique_ptr<Ort::Session> session;
    Ort::MemoryInfo     memInfo{Ort::MemoryInfo::CreateCpu(
                            OrtArenaAllocator, OrtMemTypeDefault)};

    bool ready = false;

    // Nombres reales introspectados (para Run()).
    std::vector<std::string> inputNames;
    std::vector<std::string> outputNames;
    std::vector<const char*> inputNameCStr;
    std::vector<const char*> outputNameCStr;

    // Índices resueltos por nombre (robusto ante reordenamiento del exporter).
    int idxInFrame = -1, idxInStates = -1, idxInAtten = -1;
    int idxOutEnh = -1, idxOutStates = -1;

    // Shapes de los inputs (con dims dinámicas reemplazadas por su valor fijo).
    std::vector<int64_t> frameShape;   // [480]
    std::vector<int64_t> statesShape;  // [45304]
    std::vector<int64_t> attenShape;   // [] o [1]

    // Buffers de trabajo (backing memory de los tensores; viven mientras Run()).
    std::vector<float> frameBuf;   // kHopSize
    std::vector<float> state;      // 45304 (estado recurrente arrastrado)
    std::vector<float> attenLim;   // 1 elemento (valor 0 = sin límite)

    Impl() {
        sessionOpts.SetIntraOpNumThreads(1);
        sessionOpts.SetInterOpNumThreads(1);
        sessionOpts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    }

    /// Lee un asset a un buffer en RAM (síncrono). Vacío si falla.
    std::vector<uint8_t> readAsset(AAssetManager* mgr, const char* path) {
        std::vector<uint8_t> data;
        if (!mgr || !path) {
            DFNX_LOGE("readAsset: mgr o path null");
            return data;
        }
        AAsset* asset = AAssetManager_open(mgr, path, AASSET_MODE_BUFFER);
        if (!asset) {
            DFNX_LOGE("readAsset: no se pudo abrir %s", path);
            return data;
        }
        const off_t sz = AAsset_getLength(asset);
        if (sz <= 0) {
            DFNX_LOGE("readAsset: %s tamaño inválido %ld", path, (long)sz);
            AAsset_close(asset);
            return data;
        }
        data.resize(static_cast<size_t>(sz));
        const int read = AAsset_read(asset, data.data(), data.size());
        AAsset_close(asset);
        if (read != static_cast<int>(data.size())) {
            DFNX_LOGE("readAsset: leí %d de %zu bytes", read, data.size());
            data.clear();
        }
        return data;
    }

    /// Introspecciona la sesión: resuelve nombres/índices por nombre y valida
    /// el contrato (input_frame=480, states presente). Prealoca buffers.
    bool introspect() {
        if (!session) return false;
        Ort::AllocatorWithDefaultOptions alloc;

        const size_t numIn  = session->GetInputCount();
        const size_t numOut = session->GetOutputCount();

        inputNames.clear();
        outputNames.clear();

        auto getShape = [](Ort::TypeInfo& info) {
            auto t = info.GetTensorTypeAndShapeInfo();
            std::vector<int64_t> s = t.GetShape();
            for (auto& d : s) if (d < 0) d = 1;  // dims dinámicas → 1
            return s;
        };

        for (size_t i = 0; i < numIn; ++i) {
            auto n = session->GetInputNameAllocated(i, alloc);
            std::string s(n.get());
            inputNames.push_back(s);
            auto info = session->GetInputTypeInfo(i);
            std::vector<int64_t> shape = getShape(info);

            if (s == kInFrame)  { idxInFrame  = (int)i; frameShape  = shape; }
            else if (s == kInStates) { idxInStates = (int)i; statesShape = shape; }
            else if (s == kInAtten)  { idxInAtten  = (int)i; attenShape  = shape; }

            std::string dbg;
            for (auto d : shape) dbg += std::to_string(d) + ",";
            DFNX_LOGI("Input[%zu]=%s shape=[%s]", i, s.c_str(), dbg.c_str());
        }

        for (size_t i = 0; i < numOut; ++i) {
            auto n = session->GetOutputNameAllocated(i, alloc);
            std::string s(n.get());
            outputNames.push_back(s);
            if (s == kOutEnh)   idxOutEnh    = (int)i;
            else if (s == kOutState) idxOutStates = (int)i;
            DFNX_LOGI("Output[%zu]=%s", i, s.c_str());
        }

        if (idxInFrame < 0 || idxInStates < 0 || idxOutEnh < 0 || idxOutStates < 0) {
            DFNX_LOGE("introspect: faltan I/O requeridos "
                      "(inFrame=%d inStates=%d outEnh=%d outStates=%d)",
                      idxInFrame, idxInStates, idxOutEnh, idxOutStates);
            return false;
        }

        // Validar hop = 480.
        const int64_t frameNumel = shapeNumel(frameShape);
        if (frameNumel != kHopSize) {
            DFNX_LOGE("introspect: input_frame numel=%lld, esperado %d",
                      (long long)frameNumel, kHopSize);
            return false;
        }

        // Prealocar buffers.
        frameBuf.assign(kHopSize, 0.0f);
        const int64_t statesNumel = shapeNumel(statesShape);
        state.assign(static_cast<size_t>(statesNumel), 0.0f);

        // atten_lim_db: puede ser escalar ([]) o [1]. Prealocar según su numel
        // (mínimo 1) y dejar el valor en 0 (0 dB = sin límite de atenuación,
        // procesamiento completo — igual que el onnx_infer.py de referencia).
        int64_t attenNumel = shapeNumel(attenShape);
        if (attenNumel < 1) attenNumel = 1;
        attenLim.assign(static_cast<size_t>(attenNumel), 0.0f);

        // Cachear punteros C-string para Run().
        inputNameCStr.clear();
        outputNameCStr.clear();
        for (auto& s : inputNames)  inputNameCStr.push_back(s.c_str());
        for (auto& s : outputNames) outputNameCStr.push_back(s.c_str());

        DFNX_LOGI("introspect OK: hop=%d states=%lld atten_numel=%lld",
                  kHopSize, (long long)statesNumel, (long long)attenNumel);
        return true;
    }

    /// Corre una inferencia sobre un hop de kHopSize samples.
    /// @param inHop  kHopSize samples de entrada (audio crudo).
    /// @param outEnh kHopSize samples de salida (realzado). Puede aliasar inHop.
    /// @param inferUs (out) microsegundos de la inferencia.
    /// @return true si Run() tuvo éxito.
    bool runHop(const float* inHop, float* outEnh, uint32_t& inferUs) {
        if (!ready) return false;

        std::memcpy(frameBuf.data(), inHop, kHopSize * sizeof(float));

        // Construir tensores. La memoria backing son los vectores miembro.
        // NOTA: Ort::Value solo es movible (copia borrada), así que NO se puede
        // usar el constructor de relleno vector(n, val); se hace reserve +
        // push_back (que mueve), igual que dnn_denoiser.cpp.
        std::vector<Ort::Value> inputs;
        inputs.reserve(inputNames.size());
        for (size_t i = 0; i < inputNames.size(); ++i) {
            inputs.push_back(Ort::Value(nullptr));
        }

        inputs[idxInFrame] = Ort::Value::CreateTensor<float>(
            memInfo, frameBuf.data(), frameBuf.size(),
            frameShape.data(), frameShape.size());

        inputs[idxInStates] = Ort::Value::CreateTensor<float>(
            memInfo, state.data(), state.size(),
            statesShape.data(), statesShape.size());

        if (idxInAtten >= 0) {
            inputs[idxInAtten] = Ort::Value::CreateTensor<float>(
                memInfo, attenLim.data(), attenLim.size(),
                attenShape.data(), attenShape.size());
        }

        std::vector<Ort::Value> outputs;
        const auto t0 = std::chrono::steady_clock::now();
        try {
            outputs = session->Run(
                Ort::RunOptions{nullptr},
                inputNameCStr.data(), inputs.data(), inputs.size(),
                outputNameCStr.data(), outputNameCStr.size());
        } catch (const Ort::Exception& e) {
            DFNX_LOGE("runHop: Run() falló: %s", e.what());
            return false;
        }
        const auto t1 = std::chrono::steady_clock::now();
        inferUs = static_cast<uint32_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count());

        if (outputs.size() != outputNames.size()) {
            DFNX_LOGE("runHop: %zu outputs (esperado %zu)",
                      outputs.size(), outputNames.size());
            return false;
        }

        // Copiar enhanced → outEnh.
        const float* enh = outputs[idxOutEnh].GetTensorData<float>();
        std::memcpy(outEnh, enh, kHopSize * sizeof(float));

        // Arrastrar el estado actualizado.
        const float* ns = outputs[idxOutStates].GetTensorData<float>();
        std::memcpy(state.data(), ns, state.size() * sizeof(float));

        return true;
    }

    void resetState() {
        std::fill(state.begin(), state.end(), 0.0f);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Dfn3OnnxDenoiser
// ─────────────────────────────────────────────────────────────────────────────

Dfn3OnnxDenoiser::Dfn3OnnxDenoiser() : impl_(std::make_unique<Impl>()) {}
Dfn3OnnxDenoiser::~Dfn3OnnxDenoiser() = default;

bool Dfn3OnnxDenoiser::initialize(AAssetManager* mgr, const char* assetPath) {
    if (impl_->ready) {
        DFNX_LOGW("initialize: ya inicializado, no-op");
        return true;
    }
    DFNX_LOGI("initialize: cargando %s", assetPath ? assetPath : "(null)");

    std::vector<uint8_t> bytes = impl_->readAsset(mgr, assetPath);
    if (bytes.empty()) {
        DFNX_LOGE("initialize: no se pudo leer el modelo desde assets");
        active_.store(false, std::memory_order_release);
        return false;
    }
    DFNX_LOGI("initialize: modelo leído (%zu bytes)", bytes.size());

    try {
        impl_->session = std::make_unique<Ort::Session>(
            impl_->env, bytes.data(), bytes.size(), impl_->sessionOpts);
    } catch (const Ort::Exception& e) {
        DFNX_LOGE("initialize: Ort::Session falló: %s", e.what());
        active_.store(false, std::memory_order_release);
        return false;
    }

    if (!impl_->introspect()) {
        DFNX_LOGE("initialize: introspección/contrato falló");
        impl_->session.reset();
        active_.store(false, std::memory_order_release);
        return false;
    }

    // Inicializar buffers de mezcla/latencia y anillo de salida.
    resetBuffers();

    impl_->ready = true;
    active_.store(true, std::memory_order_release);
    DFNX_LOGI("initialize: OK, DFN3 ONNX listo (48 kHz nativo, síncrono)");
    return true;
}

bool Dfn3OnnxDenoiser::processHop(float* hop) {
    // hop: kHopSize samples de entrada. Al salir, kHopSize samples de salida
    // (dry/wet ya mezclados). Devuelve false → hop sin tocar (bypass).
    if (!impl_->ready) return false;

    // Guardar copia cruda del hop actual (para usarla como dry del PRÓXIMO hop).
    float rawNow[kHopSize];
    std::memcpy(rawNow, hop, kHopSize * sizeof(float));

    // Inferencia: enh = clean(hop_{k-1}) por la latencia de 1 hop del modelo.
    float wet[kHopSize];
    uint32_t inferUs = 0;
    const bool ok = impl_->runHop(hop, wet, inferUs);
    if (!ok) {
        // Fallo de inferencia → dejar el hop crudo (bypass) y no avanzar dry.
        return false;
    }
    lastInferenceUs_.store(inferUs, std::memory_order_relaxed);

    const float intensity = intensity_.load(std::memory_order_acquire);

    // Mezcla dry/wet ALINEADA: wet corresponde a hop_{k-1}, y prevDry_ TAMBIÉN
    // es hop_{k-1}. La salida queda retrasada 1 hop (10 ms) de forma uniforme.
    for (int i = 0; i < kHopSize; ++i) {
        // Avanzar crossfade por-sample (anti-clic).
        if (crossfadeGain_ < crossfadeTarget_)
            crossfadeGain_ = std::min(crossfadeGain_ + kCrossfadeStep, crossfadeTarget_);
        else if (crossfadeGain_ > crossfadeTarget_)
            crossfadeGain_ = std::max(crossfadeGain_ - kCrossfadeStep, crossfadeTarget_);

        const float dry   = prevDry_[i];
        const float mixed = dry * (1.0f - intensity) + wet[i] * intensity;
        // Crossfade entre dry (bypass) y la mezcla denoised.
        const float out = dry * (1.0f - crossfadeGain_) + mixed * crossfadeGain_;
        hop[i] = std::max(-1.0f, std::min(1.0f, out));
    }

    effectiveIntensityAtomic_.store(crossfadeGain_ * intensity,
                                    std::memory_order_release);

    // El hop crudo actual pasa a ser el dry del próximo hop.
    std::memcpy(prevDry_, rawNow, kHopSize * sizeof(float));

    processedFrames_.fetch_add(1, std::memory_order_relaxed);
    return true;
}

void Dfn3OnnxDenoiser::resetBuffers() {
    hopBuf_count_ = 0;
    outHead_ = 0;
    outTail_ = 0;
    primed_ = false;
    std::fill(std::begin(hopBuf_), std::end(hopBuf_), 0.0f);
    std::fill(std::begin(prevDry_), std::end(prevDry_), 0.0f);
}

void Dfn3OnnxDenoiser::process(float* buffer, int blockSize) {
    if (!buffer || blockSize <= 0) return;

    const bool en  = enabled_.load(std::memory_order_acquire);
    const bool act = active_.load(std::memory_order_acquire);

    crossfadeTarget_ = en ? 1.0f : 0.0f;

    // Bypass bit-exact: sin enable y crossfade ya en 0. Limpia el estado para
    // que un re-enable arranque fresco (re-prime del anillo).
    if (!en && crossfadeGain_ <= 0.0f) {
        resetBuffers();
        return;
    }
    // Sin modelo (falla de carga/inferencia): bypass bit-exact.
    if (!act) {
        crossfadeGain_ = 0.0f;
        resetBuffers();
        return;
    }

    // Pre-rellenar el anillo con silencio en la primera pasada activa. Esto
    // fija la latencia (~20 ms) y garantiza que SIEMPRE haya >= blockSize
    // muestras para emitir, evitando underruns intermitentes que producirían
    // empalmes crudo/procesado (la causa del sonido "ronco").
    if (!primed_) {
        const int prefill = std::min(kOutRingPrefill, kOutRingCap - 1);
        for (int i = 0; i < prefill; ++i) outRing_[outHead_++ & kOutRingMask] = 0.0f;
        primed_ = true;
    }

    // ── Etapa A: acumular la entrada en hops de kHopSize y procesar COMPLETO ──
    // Cada hop procesado (mezcla dry/wet ya alineada) se empuja ENTERO al
    // anillo de salida. Nunca se trocea ni se mezcla crudo con procesado.
    for (int pos = 0; pos < blockSize; ++pos) {
        hopBuf_[hopBuf_count_++] = buffer[pos];
        if (hopBuf_count_ == kHopSize) {
            // processHop mezcla in-place; si la inferencia falla, se empuja el
            // hop crudo (dry) para no dejar un hueco (evento raro y puntual).
            processHop(hopBuf_);
            for (int i = 0; i < kHopSize; ++i)
                outRing_[outHead_++ & kOutRingMask] = hopBuf_[i];
            hopBuf_count_ = 0;
        }
    }

    // ── Etapa B: emitir blockSize muestras desde el anillo de salida ──────
    for (int pos = 0; pos < blockSize; ++pos) {
        if (outHead_ - outTail_ > 0) {
            buffer[pos] = outRing_[outTail_++ & kOutRingMask];
        }
        // Underrun (no debería ocurrir con el pre-relleno): deja el dry.
    }
}

void Dfn3OnnxDenoiser::setEnabled(bool enabled) {
    enabled_.store(enabled, std::memory_order_release);
    DFNX_LOGI("setEnabled(%s)", enabled ? "true" : "false");
}

void Dfn3OnnxDenoiser::setIntensity(float intensity) {
    intensity = std::max(0.0f, std::min(1.0f, intensity));
    intensity_.store(intensity, std::memory_order_release);
}

void Dfn3OnnxDenoiser::reset() {
    resetBuffers();
    crossfadeGain_ = 0.0f;
    crossfadeTarget_ = enabled_.load(std::memory_order_acquire) ? 1.0f : 0.0f;
    if (impl_) impl_->resetState();
    DFNX_LOGI("reset()");
}

}  // namespace dfn3_onnx

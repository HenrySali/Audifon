/// @file dfn3_onnx_denoiser.h
/// @brief DeepFilterNet3 denoiser — modelo ONNX autocontenido (audio crudo 48 kHz).
///
/// A diferencia de `dfn3_denoiser.{h,cpp}` (que hace la STFT/ERB/DF a mano en
/// C++ con 3 modelos ONNX separados), esta clase usa el export ONNX
/// "streaming" de DeepFilterNet3 (torchDF) que empaqueta TODO el pipeline
/// (STFT → ERB → deep filtering → iSTFT) DENTRO del grafo ONNX. Recibe y
/// devuelve audio crudo, por lo que:
///
///   - NO necesita resampler (48 kHz nativo, alineado con Oboe).
///   - NO necesita STFT/ERB en C++ (el modelo lo hace internamente).
///   - Un único vector de estado recurrente `states` se arrastra entre hops.
///
/// Contrato ONNX (verificado con el modelo denoiser_model.onnx, 48k):
///   inputs:
///     "input_frame"  [480]      — 1 hop de audio crudo @ 48 kHz (10 ms)
///     "states"       [45304]    — estado recurrente (arrastrado entre hops)
///     "atten_lim_db" [] o [1]   — límite de atenuación en dB (0 = sin límite)
///   outputs:
///     "enhanced_audio_frame" [480] — hop de audio realzado
///     "new_states"           [45304] — estado actualizado
///     "lsnr"                 [1]     — SNR local estimada (no usada aquí)
///
/// Latencia algorítmica del modelo: kFftSize - kHopSize = 480 samples (1 hop,
/// 10 ms). La salida del hop k corresponde al hop k-1 de la entrada. Por eso
/// el dry se retarda 1 hop (`prevDry_`) antes de mezclar, evitando el comb
/// filtering ("matraca") por desalineamiento dry/wet.
///
/// Posición en el pipeline (igual que los otros motores, vía DenoiserSelector):
///   Input → [DenoiserSelector → Dfn3OnnxDenoiser] → EQ → WDRC → MPO → Output
///
/// Thread safety:
///   - process(): SOLO audio thread. La inferencia ONNX corre de forma
///     SÍNCRONA en el audio thread (igual que dfn3_denoiser.cpp). DFN3 es
///     pesado (~gama alta); si el CPU no alcanza, el DenoiserSelector cae
///     automáticamente al fallback (RNNoise → GTCRN). Una versión con worker
///     thread (estilo dnn_denoiser.cpp) es el siguiente paso si hace falta.
///   - setEnabled/setIntensity/getters: thread-safe (atomics).
///   - initialize(): NO thread-safe — llamar UNA VEZ al startup.
///
/// Fail-safe: si el modelo no carga, la forma de I/O no coincide, o cualquier
/// excepción de OnnxRuntime ocurre, isActive() pasa a false y process() hace
/// bypass bit-exact. El selector lo detecta y usa el fallback.

#ifndef HEARING_AID_DFN3_ONNX_DENOISER_H
#define HEARING_AID_DFN3_ONNX_DENOISER_H

#include <atomic>
#include <cstdint>
#include <memory>

struct AAssetManager;

namespace dfn3_onnx {

/// Sample rate nativo del modelo DFN3-48k (sin resampler).
static constexpr int kSampleRate = 48000;

/// Tamaño de hop de inferencia en samples (10 ms @ 48 kHz).
static constexpr int kHopSize = 480;

/// Tamaño de ventana STFT interna del modelo (informativo).
static constexpr int kFftSize = 960;

/// Latencia algorítmica del modelo en samples (kFftSize - kHopSize = 480).
/// La salida del hop k corresponde a la entrada del hop k-1; el dry se
/// retarda exactamente 1 hop para alinear la mezcla dry/wet.
static constexpr int kModelLatency = kFftSize - kHopSize;

/// Crossfade al togglear enabled (50 ms @ 48 kHz = 2400 samples).
static constexpr int kCrossfadeSamples = 2400;
static constexpr float kCrossfadeStep =
    1.0f / static_cast<float>(kCrossfadeSamples);

/// Wrapper C++ del DFN3 ONNX autocontenido (torchDF streaming export).
/// Sigue el patrón de SubVI (process / setX / reset / isX) de los otros
/// motores para integrarse al DenoiserSelector vía Dfn3OnnxAdapter.
class Dfn3OnnxDenoiser {
public:
    Dfn3OnnxDenoiser();
    ~Dfn3OnnxDenoiser();

    Dfn3OnnxDenoiser(const Dfn3OnnxDenoiser&) = delete;
    Dfn3OnnxDenoiser& operator=(const Dfn3OnnxDenoiser&) = delete;

    /// Carga el modelo ONNX desde assets vía AAssetManager (sin extracción a
    /// filesystem — se lee a RAM y se pasa a OnnxRuntime).
    /// @param mgr AAssetManager Android (no-null).
    /// @param assetPath Ruta dentro de assets/, ej "dfn3_onnx/denoiser_model.onnx".
    /// @return true si el modelo cargó, la introspección validó el contrato,
    ///         y la sesión quedó lista. false → bypass permanente.
    /// NOTE: llamar UNA SOLA VEZ. Idempotente: llamadas siguientes no-op.
    bool initialize(AAssetManager* mgr, const char* assetPath);

    /// Procesa un bloque de audio in-place. SOLO desde audio thread.
    /// blockSize arbitrario (se buffea en hops de kHopSize internamente).
    /// @param buffer Float audio [-1,+1] @ 48 kHz. Modificado in-place.
    /// @param blockSize Número de samples.
    void process(float* buffer, int blockSize);

    /// Toggle ON/OFF con crossfade anti-clic de 50 ms.
    void setEnabled(bool enabled);

    /// Mezcla dry/wet [0..1]. 0.0 = dry puro, 1.0 = wet (denoised).
    void setIntensity(float intensity);

    /// Resetea estado interno (hop buffers, estado recurrente, crossfade).
    void reset();

    // ─── Getters (thread-safe) ──────────────────────────────────────────
    bool isEnabled() const { return enabled_.load(std::memory_order_acquire); }
    bool isActive() const { return active_.load(std::memory_order_acquire); }
    float getIntensity() const { return intensity_.load(std::memory_order_acquire); }
    float getEffectiveIntensity() const {
        return effectiveIntensityAtomic_.load(std::memory_order_acquire);
    }
    uint64_t getProcessedFrames() const {
        return processedFrames_.load(std::memory_order_relaxed);
    }
    uint64_t getDroppedFrames() const {
        return droppedFrames_.load(std::memory_order_relaxed);
    }
    uint32_t getLastInferenceUs() const {
        return lastInferenceUs_.load(std::memory_order_relaxed);
    }

private:
    /// PIMPL: oculta OnnxRuntime del header consumido por audio_engine.h.
    struct Impl;
    std::unique_ptr<Impl> impl_;

    std::atomic<bool>     enabled_{false};
    std::atomic<bool>     active_{false};
    std::atomic<float>    intensity_{0.8f};
    std::atomic<uint64_t> processedFrames_{0};
    std::atomic<uint64_t> droppedFrames_{0};
    std::atomic<uint32_t> lastInferenceUs_{0};

    /// Crossfade gain (0..1). 1.0 = wet, 0.0 = dry. Audio-thread-only.
    float crossfadeGain_ = 0.0f;
    float crossfadeTarget_ = 0.0f;

    /// Espejo atómico de la intensidad efectiva (crossfadeGain_ * intensity).
    std::atomic<float> effectiveIntensityAtomic_{0.0f};

    // ─── Buffering de hops (audio-thread-only) ──────────────────────────
    /// Acumulador de entrada: junta samples hasta completar un hop de 480.
    float hopBuf_[kHopSize] = {};
    int   hopBuf_count_ = 0;

    /// Dry retardado 1 hop: hop crudo anterior, usado para alinear la mezcla
    /// dry/wet (el modelo tiene kModelLatency = 1 hop de latencia).
    float prevDry_[kHopSize] = {};

    // ─── Anillo de salida (FIFO, audio-thread-only) ─────────────────────
    /// Los hops se procesan COMPLETOS y se empujan aquí; la salida se emite
    /// desde este anillo, desacoplando el blockSize de Oboe del hop de 480.
    /// Se pre-rellena con silencio (kOutRingPrefill) al activarse para
    /// establecer la latencia y evitar underruns intermitentes (que causarían
    /// empalmes crudo/procesado = voz robótica). Capacidad potencia de 2.
    static constexpr int kOutRingCap = 8192;
    static constexpr int kOutRingMask = kOutRingCap - 1;
    /// Pre-relleno de latencia (~20 ms @ 48 kHz). Cubre blockSize de Oboe
    /// típicos (96-480) sin underrun. El modelo ya añade 1 hop; total ~30 ms.
    static constexpr int kOutRingPrefill = 2 * kHopSize;
    float outRing_[kOutRingCap] = {};
    int   outHead_ = 0;   // escritura (push)
    int   outTail_ = 0;   // lectura  (pop); count = outHead_ - outTail_
    /// true tras pre-rellenar el anillo en la transición a activo.
    bool  primed_ = false;

    /// Limpia hop buffer, anillo de salida y prevDry_ (para bypass/re-enable).
    void resetBuffers();

    /// Procesa un hop de kHopSize samples in-place (audio crudo → realzado,
    /// ya mezclado dry/wet con crossfade). Usa prevDry_ para alinear el dry.
    /// @return true si la inferencia ONNX corrió OK; false → hop sin tocar.
    bool processHop(float* hop);
};

}  // namespace dfn3_onnx

#endif  // HEARING_AID_DFN3_ONNX_DENOISER_H

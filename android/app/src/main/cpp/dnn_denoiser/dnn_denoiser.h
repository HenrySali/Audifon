/// @file dnn_denoiser.h
/// @brief DNN-based speech denoiser wrapper (GTCRN via OnnxRuntime).
///
/// Posicionamiento en el pipeline DSP (estilo LabVIEW SubVI):
///
///   Input → [DnnDenoiser] → EQ → WDRC → Volume → MPO → Output
///                ↑
///         Reemplaza al NR Wiener clásico cuando enabled=true
///
/// CONTROLES (inputs configurables vía API):
///   ├─ enabled (bool)               — true: procesa con DNN, false: bypass bit-exact
///   ├─ intensity (float 0..1)       — mezcla dry/wet (0.0=dry, 1.0=wet)
///   ├─ inputSampleRate (int Hz)     — rate nativa de Oboe (default 16000):
///   │                                  • 16000 → bypass del resampler interno
///   │                                  • 48000 → polyphase 3:1 (down/up)
///   │                                  • otros → resampling lineal genérico
///   └─ initialize(AAssetManager)    — carga modelo desde assets (lazy)
///
/// ENTRADAS (signal wires):
///   └─ Audio In (float* buffer, int blockSize) — float [-1,+1] @ inputSampleRate
///
/// PROCESAMIENTO (algoritmo interno):
///   1. Si !enabled → bypass bit-exact (return inmediato, sin copia).
///   2. Si enabled y modelo no listo → bypass + isActive_=false.
///   3. Audio thread: si inputSr != 16000 → DOWNSAMPLE a 16 kHz (polyphase
///                     o lineal según rate). Empuja samples al input ring
///                     buffer (lock-free SPSC) en samples a 16 kHz.
///   4. Worker thread: drena 256 samples → STFT(512, hop 256, Hann periódica) →
///                     OnnxRuntime.run(mix, cache0, cache1, cache2)
///                     → enhanced spectrum → iSTFT/OLA → output ring buffer
///                     (también en samples a 16 kHz).
///   5. Audio thread: tira samples del output ring buffer (16 kHz),
///                     UPSAMPLE a inputSampleRate. dryDelayRing va en
///                     samples a la rate nativa (alineamiento 1:1).
///   6. Crossfade lineal de 30 ms al activar/desactivar (anti-clic).
///   7. Clamp final a ±1.0 por seguridad.
///
/// SALIDAS (signal wires):
///   └─ Audio Out (modificado in-place sobre el buffer de entrada)
///
/// INDICADORES (monitoring vía getters):
///   ├─ isEnabled() → bool         — flag de configuración
///   ├─ isActive()  → bool         — flag operacional (modelo listo + sin error)
///   ├─ getProcessedFrames() → uint64_t — total de frames de 256 procesados
///   ├─ getDroppedFrames()   → uint64_t — frames descartados por congestión
///   └─ getLastInferenceUs() → uint32_t — latencia última inferencia
///
/// THREAD SAFETY:
///   - process(): seguro de llamar SOLO desde audio thread (single-producer).
///   - setEnabled / setIntensity / getters: thread-safe (atomics).
///   - initialize(): NO thread-safe; llamar UNA VEZ al startup.
///
/// LATENCIA:
///   - GTCRN frame = 256 samples (16 ms) a 16 kHz.
///   - Latencia algorítmica STFT = hop_size = 256 samples = 16 ms.
///   - Resampler polyphase 48↔16 (96 taps, ratio 3): group delay ≈
///     (96-1)/2 / 48000 ≈ 0.99 ms en cada sentido → ~2 ms ida+vuelta.
///   - Latencia total esperada (con buffering + worker handoff) ≈ 22–27 ms.
///
/// FAIL-SAFE:
///   Si el modelo no carga, la API de input shape no coincide, o cualquier
///   excepción de OnnxRuntime ocurre, isActive_ pasa a false y todos los
///   callbacks subsiguientes hacen bypass bit-exact. setEnabled(true) puede
///   reintentarse después.

#ifndef HEARING_AID_DNN_DENOISER_H
#define HEARING_AID_DNN_DENOISER_H

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <thread>

// Forward declarations (evita arrastrar headers de OnnxRuntime al consumer).
struct AAssetManager;

namespace dnn_denoiser {

/// Sample rate nativo del modelo GTCRN.
static constexpr int kDnnSampleRate = 16000;

/// Tamaño de hop (frame de inferencia GTCRN) en samples a 16 kHz.
static constexpr int kDnnHopSize = 256;

/// Tamaño de ventana STFT del modelo GTCRN (FFT 512, ventana Hann).
static constexpr int kDnnFftSize = 512;

/// Crossfade lineal al togglear enabled (en samples a 16 kHz).
/// 30 ms × 16 000 Hz / 1000 = 480 samples.
static constexpr int kDnnCrossfadeSamples = 480;

/// Capacidad de cada ring buffer (input/output) en samples.
/// Debe ser potencia de 2 y >> kDnnHopSize para absorber jitter del worker.
/// 4096 = ~256 ms de buffer, suficiente para GC pauses ocasionales.
static constexpr int kDnnRingCapacity = 4096;

/// Wrapper C++ del denoiser GTCRN. Sigue el patrón de SubVI LabVIEW
/// (process / setX / reset / isX) para integrarse al DspPipeline.
///
/// Lifecycle:
///   1. Construcción: barata, no carga modelo.
///   2. initialize(AAssetManager*, "dnn_denoiser/gtcrn.onnx"):
///      carga el modelo, crea OnnxRuntime session, lanza worker thread.
///      Si falla, isActive_ queda en false y la clase actúa como bypass.
///   3. setEnabled(true): habilita el procesamiento (con crossfade).
///   4. process(buffer, N): llamado desde audio thread cada callback.
///   5. setEnabled(false): bypass con crossfade out.
///   6. Destrucción: detiene worker thread y libera la session.
class DnnDenoiser {
public:
    DnnDenoiser();
    ~DnnDenoiser();

    DnnDenoiser(const DnnDenoiser&) = delete;
    DnnDenoiser& operator=(const DnnDenoiser&) = delete;

    /// Carga el modelo ONNX desde assets y lanza el worker thread.
    /// @param assetMgr  Asset manager Android (puede ser nullptr → falla limpia)
    /// @param assetPath Ruta dentro de assets/, ej "dnn_denoiser/gtcrn.onnx"
    /// @return true si el modelo se cargó y la sesión está lista.
    ///         false → la clase queda en modo bypass permanente.
    /// NOTE: Llamar UNA SOLA VEZ. Idempotente: llamadas siguientes no-op.
    bool initialize(AAssetManager* assetMgr, const char* assetPath);

    /// Configura el sample rate nativo del audio que va a entrar a process().
    /// El modelo GTCRN trabaja siempre a 16 kHz; este wrapper inserta un
    /// resampler interno (downsample antes del worker, upsample después)
    /// cuando inputSr != 16000.
    ///
    /// Casos soportados:
    ///   - 16000      → bypass del resampler (rate nativa del modelo).
    ///   - 48000      → polyphase FIR 3:1 (96 taps prototipo, fc=7 kHz,
    ///                   transición ~1 kHz, ventana Kaiser β≈8).
    ///   - 22050/44100/otros → resampling lineal genérico (suficiente para
    ///                   denoising, no para audio crítico de calidad).
    ///
    /// Llamar en startup desde AudioEngine::start() cuando ya se conoce
    /// `effectiveSampleRate` reportado por Oboe. Idempotente: si el sr no
    /// cambió respecto a la última llamada, no reinicializa los filtros.
    /// Thread-safe (sólo se llama desde el hilo de control, no desde el
    /// audio callback).
    void setInputSampleRate(int sampleRateHz);

    /// Procesa un bloque de audio in-place. Llamar SOLO desde audio thread.
    /// Cuando enabled=false: bypass bit-exact (retorna sin tocar buffer).
    /// Cuando enabled=true y no activo: bypass con crossfade hacia bypass.
    /// Cuando enabled=true y activo: aplica DNN denoise + intensity mix.
    ///
    /// @param buffer Float audio in-place [-1,+1] (será modificado).
    /// @param blockSize Número de samples (típicamente 64 a 16 kHz).
    void process(float* buffer, int blockSize);

    /// Toggle ON/OFF. Inicia crossfade anti-clic de 30 ms.
    /// Thread-safe: lock-free. Puede llamarse desde cualquier hilo.
    void setEnabled(bool enabled);

    /// Mezcla dry/wet del denoising. Clampeada a [0,1].
    ///   0.0 → 100% dry (señal original limpia)
    ///   1.0 → 100% wet (denoised)
    ///   Valores intermedios → mezcla lineal.
    /// Thread-safe: lock-free.
    void setIntensity(float intensity);

    /// Resetea estado interno (ring buffers, model caches).
    /// SAFE: el worker thread maneja el reset internamente vía flag atómico.
    /// Llamar cuando hay un cambio brusco de contenido (skip, seek).
    void reset();

    /// @return último valor de enabled seteado.
    bool isEnabled() const {
        return enabled_.load(std::memory_order_acquire);
    }

    /// @return true si el denoiser está procesando audio en este momento
    ///         (modelo cargado, worker corriendo, sin errores).
    ///         false si está en bypass por config (enabled=false) o por error.
    bool isActive() const {
        return active_.load(std::memory_order_acquire);
    }

    /// @return intensidad actual (0..1).
    float getIntensity() const {
        return intensity_.load(std::memory_order_acquire);
    }

    /// @return total de frames de 256 samples procesados con DNN.
    uint64_t getProcessedFrames() const {
        return processedFrames_.load(std::memory_order_relaxed);
    }

    /// @return total de frames descartados (worker no alcanzó tasa).
    uint64_t getDroppedFrames() const {
        return droppedFrames_.load(std::memory_order_relaxed);
    }

    /// @return latencia de la última inferencia ONNX en microsegundos.
    uint32_t getLastInferenceUs() const {
        return lastInferenceUs_.load(std::memory_order_relaxed);
    }

private:
    /// Estructura PIMPL: oculta dependencias de OnnxRuntime y std::vector
    /// del header consumido por consumidores (audio_engine.h).
    struct Impl;
    std::unique_ptr<Impl> impl_;

    // Estado expuesto vía atomics (lectura desde getters, escritura desde setters/worker).
    std::atomic<bool>     enabled_{false};
    std::atomic<bool>     active_{false};
    std::atomic<float>    intensity_{1.0f};
    std::atomic<uint64_t> processedFrames_{0};
    std::atomic<uint64_t> droppedFrames_{0};
    std::atomic<uint32_t> lastInferenceUs_{0};

    /// Crossfade gain (0..1). 1.0 = wet (DNN), 0.0 = dry (bypass).
    /// Avanza linealmente al togglear enabled. Sólo escrito desde audio thread.
    float crossfadeGain_ = 0.0f;
    /// Objetivo del crossfade (1.0 cuando enabled, 0.0 cuando no).
    float crossfadeTarget_ = 0.0f;
    /// Step por sample del crossfade (1/kDnnCrossfadeSamples).
    static constexpr float kCrossfadeStep =
        1.0f / static_cast<float>(kDnnCrossfadeSamples);
};

}  // namespace dnn_denoiser

#endif  // HEARING_AID_DNN_DENOISER_H

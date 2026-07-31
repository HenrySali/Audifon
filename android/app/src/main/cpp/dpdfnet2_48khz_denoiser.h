/// @file dpdfnet2_48khz_denoiser.h
/// @brief DPDFNet-2 denoiser — 48 kHz nativo, OnnxRuntime backend, Deep Filtering complejo.
///
/// Quinto motor de denoising (kDPDFNet2 = 4) para el DenoiserSelector.
/// Modelo DPDFNet-2 (10.3 MB, sherpa-onnx) opera a 48 kHz NATIVO sin resampleo,
/// hop=480 (10 ms), ventana Hann periódica, spec shape [1,1,481,2].
///
/// Pipeline (sin resampleo — opera a 48 kHz nativo):
///   48kHz in → accum(480) → STFT(Hann,960,hop480) → ONNX Run(complex mask)
///            → complex deep filter → iSTFT/OLA → intensity mix dry/wet
///            → crossfade → clamp → 48kHz out
///
/// Diferencias clave vs DPDFNet-4 (kDPDFNet=3):
///   - Sin resampleo 48→16→48 (ahorra ~3 ms de latencia round-trip)
///   - FFT 960 → 481 bins complejos (vs FFT 512 → 161 bins)
///   - Hop 480 @ 48 kHz = 10 ms (mismo tiempo que DPDFNet-4 hop 160 @ 16 kHz)
///   - Calidad PESQ ~3.2 (vs ~3.0 de DPDFNet-4)
///   - Modelo 10.3 MB (vs 2.36 MB)
///
/// Thread safety:
///   - process(): audio thread only (never blocks, zero heap alloc)
///   - setEnabled/setIntensity/getters: thread-safe (atomics)
///   - initialize(): NOT thread-safe — call ONCE from main thread
///
/// Fail-safe:
///   Si el modelo no carga, la sesión ONNX falla, o la inferencia produce error,
///   isActive_ pasa a false y el audio pasa sin modificar (bypass). El
///   DenoiserSelector detecta isActive()==false y activa fallback a RNNoise.
///
/// Requirements: 1.1, 1.3, 2.3, 2.4, 6.1, 6.2

#ifndef HEARING_AID_DPDFNET2_48KHZ_DENOISER_H
#define HEARING_AID_DPDFNET2_48KHZ_DENOISER_H

#include <atomic>
#include <cstdint>
#include <memory>

// Forward declaration (evita arrastrar headers de Android al consumer).
struct AAssetManager;

namespace dpdfnet2_denoiser {

// ─── Constants ───────────────────────────────────────────────────────────────
/// Sample rate nativo del modelo DPDFNet-2 (opera sin resampleo).
static constexpr int kSampleRate       = 48000;

/// Hop size: 480 samples = 10 ms @ 48 kHz.
static constexpr int kHopSize          = 480;

/// FFT window size (2× hop para 50% overlap).
static constexpr int kFftSize          = 960;

/// Número de bins complejos en la STFT: kFftSize/2 + 1 = 481.
static constexpr int kNbFreqs          = kFftSize / 2 + 1;  // 481

/// Crossfade al togglear enabled: 960 samples = 20 ms @ 48 kHz.
static constexpr int kCrossfadeSamples = 960;

/// Step del crossfade por sample (1/960 ≈ 0.00104).
static constexpr float kCrossfadeStep  = 1.0f / static_cast<float>(kCrossfadeSamples);

// ─── Clase principal ─────────────────────────────────────────────────────────

/// DPDFNet-2 48 kHz denoiser — full pipeline con PIMPL.
///
/// STFT Hann → ONNX inference (complex deep filter mask) → iSTFT/OLA →
/// intensity mix dry/wet → crossfade. Zero heap allocations en process().
///
/// Lifecycle:
///   1. Construcción: barata, no carga modelo.
///   2. initialize(AAssetManager*, path): carga dpdfnet2_48khz_hr.onnx,
///      crea sesión ONNX, pre-asigna todos los buffers, pre-calcula ventana Hann.
///      Si falla → isActive_=false, clase actúa como bypass permanente.
///   3. setEnabled(true): habilita procesamiento (con crossfade 20 ms).
///   4. process(buffer, N): llamado desde audio thread cada callback.
///   5. setEnabled(false): bypass con crossfade out.
///   6. Destrucción: libera sesión ONNX y buffers.
class Dpdfnet2_48khzDenoiser {
public:
    Dpdfnet2_48khzDenoiser();
    ~Dpdfnet2_48khzDenoiser();

    // Non-copyable, non-movable
    Dpdfnet2_48khzDenoiser(const Dpdfnet2_48khzDenoiser&) = delete;
    Dpdfnet2_48khzDenoiser& operator=(const Dpdfnet2_48khzDenoiser&) = delete;

    /// Carga el modelo ONNX desde assets y pre-asigna buffers internos.
    /// Idempotente: segunda llamada retorna true sin recrear sesión.
    ///
    /// Validaciones internas:
    ///   - mgr != nullptr
    ///   - Modelo encontrado en assets
    ///   - Sesión ONNX creada sin error
    ///   - Input shape == [1,1,481,2] (real+imag)
    ///
    /// @param mgr Android AAssetManager (non-null).
    /// @param assetPath Ruta del modelo dentro de assets/
    ///        (default: "dpdfnet2/dpdfnet2_48khz_hr.onnx").
    /// @return true si el motor quedó listo; false → bypass permanente.
    bool initialize(AAssetManager* mgr,
                    const char* assetPath = "dpdfnet2/dpdfnet2_48khz_hr.onnx");

    /// Procesa audio in-place. Llamar SOLO desde el audio thread.
    ///
    /// Flujo interno por hop (480 samples):
    ///   1. Acumula samples en inputAccum_ hasta completar 1 hop
    ///   2. STFT: FFT-960 con ventana Hann periódica → 481 bins complejos
    ///   3. ONNX inference: input [1,1,481,2] → output [1,1,481,2] (complex mask)
    ///   4. Complex deep filter: aplica máscara sobre espectro (real+imag)
    ///   5. iSTFT/OLA: inverse FFT + overlap-add (50% overlap)
    ///   6. Intensity mix: output = dry*(1-intensity) + wet*intensity
    ///   7. Crossfade: rampa lineal al togglear enabled
    ///   8. Clamp: ±1.0 (protección NaN/Inf)
    ///
    /// ZERO heap allocations (todos los buffers pre-asignados en Impl).
    ///
    /// @param buffer Float audio [-1,+1] at 48 kHz. Modificado in-place.
    /// @param blockSize Número de samples (típicamente 240 = framesPerBurst).
    void process(float* buffer, int blockSize);

    /// Enable/disable con crossfade suave (960 samples = 20 ms @ 48 kHz).
    /// Thread-safe: lock-free via atomic.
    void setEnabled(bool enabled);

    /// Set intensity [0.0, 1.0] — mezcla dry/wet.
    /// Valores fuera de rango se clampean internamente.
    /// Thread-safe: lock-free via atomic.
    void setIntensity(float intensity);

    /// Resetea estado interno (buffers DSP + hidden states del modelo ONNX).
    /// Llamar cuando hay un cambio brusco de contenido (pausa/resume).
    void reset();

    // ─── Getters (thread-safe, lock-free) ────────────────────────────────────

    /// @return true si el flag enabled está seteado.
    bool isEnabled() const { return enabled_.load(std::memory_order_acquire); }

    /// @return true si el motor está procesando audio activamente
    ///         (modelo cargado, sesión ONNX lista, sin errores runtime).
    ///         false si está en bypass por error o no inicializado.
    bool isActive() const { return isActive_.load(std::memory_order_acquire); }

    /// Nombre legible del motor para UI/logs/telemetría.
    /// @return "DPDFNet-2 48k"
    const char* name() const { return "DPDFNet-2 48k"; }

    /// @return intensity efectiva actualmente aplicada en la mezcla dry/wet.
    float getEffectiveIntensity() const;

    /// @return total de hops (480 samples) procesados exitosamente con ONNX.
    uint64_t getProcessedFrames() const;

    /// @return total de hops descartados (overflow del acumulador de entrada).
    uint64_t getDroppedFrames() const;

    /// @return latencia de la última inferencia ONNX en microsegundos.
    uint32_t getLastInferenceUs() const;

private:
    /// Estructura PIMPL: oculta dependencias de OnnxRuntime, PFFFT, y buffers
    /// del header consumido por audio_engine.h. Definida en el .cpp.
    struct Impl;
    std::unique_ptr<Impl> impl_;

    // ─── Atomics (control ↔ audio thread communication) ─────────────────────
    /// Flag de habilitación (setEnabled ↔ process). memory_order_acquire/release.
    std::atomic<bool>  enabled_{false};

    /// Intensity de la mezcla dry/wet [0.0, 1.0]. Lock-free.
    std::atomic<float> intensity_{1.0f};

    /// Flag operacional: true = modelo cargado y funcionando.
    /// Pasa a false si initialize() falla o si la inferencia produce error.
    std::atomic<bool>  isActive_{false};

    // ─── Telemetry atomics (relaxed reads from any thread) ──────────────────
    std::atomic<uint64_t> processedFrames_{0};
    std::atomic<uint64_t> droppedFrames_{0};
    std::atomic<uint32_t> lastInferenceUs_{0};

    // ─── Crossfade state (audio-thread-only, no atomic needed) ──────────────
    /// Gain actual del crossfade (0.0 = bypass/dry, 1.0 = wet/DNN).
    float crossfadeGain_   = 0.0f;
    /// Target del crossfade (1.0 cuando enabled, 0.0 cuando disabled).
    float crossfadeTarget_ = 0.0f;
    /// Intensity efectiva tras clamping (audio-thread-only cache).
    float effectiveIntensity_ = 1.0f;
};

} // namespace dpdfnet2_denoiser

#endif // HEARING_AID_DPDFNET2_48KHZ_DENOISER_H

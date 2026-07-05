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
///   ├─ notifyVoiceActive(bool)      — feedback del VAD para modular intensity
///   │                                  con cap asimétrico (Paso 1, no amplifica)
///   ├─ setVoiceCap(float)           — cap aplicado a intensity con voz (default 0.7)
///   └─ initialize(AAssetManager)    — carga modelo desde assets (lazy)
///
/// MODULACIÓN VAD (spec dnn-voice-level-recovery, Paso 1):
///   El cap de intensity con voz activa NO viola el invariante "el DNN solo
///   atenúa". Bajar `intensity` aumenta el peso del dry (señal original) en
///   la mezcla `dry*(1 - dnnAmount) + wet*dnnAmount`; nunca amplifica nada.
///   El slider del usuario sigue siendo verdad ante la API: el cap es
///   interno y se expone vía `getEffectiveIntensity()` para telemetría.
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
///   4. Worker thread: drena 128 samples (kDnnHopSize, MEJORA #1) →
///                     STFT(512, hop 128, sqrt-Hann periódica, 75% overlap) →
///                     OnnxRuntime.run(mix, cache0, cache1, cache2)
///                     → enhanced spectrum → iSTFT/OLA → output ring buffer
///                     (también en samples a 16 kHz).
///   5. Audio thread: tira samples del output ring buffer (16 kHz),
///                     UPSAMPLE a inputSampleRate. dryDelayRing va en
///                     samples a la rate nativa (alineamiento 1:1).
///   6. Crossfade lineal de 50 ms (800 samples a 16 kHz, MEJORA #1 Tier 3 #12)
///                     al activar/desactivar (anti-clic).
///   7. Clamp final a ±1.0 por seguridad.
///
/// SALIDAS (signal wires):
///   └─ Audio Out (modificado in-place sobre el buffer de entrada)
///
/// INDICADORES (monitoring vía getters):
///   ├─ isEnabled() → bool         — flag de configuración
///   ├─ isActive()  → bool         — flag operacional (modelo listo + sin error)
///   ├─ getProcessedFrames() → uint64_t — total de hops (128 samples) procesados
///   ├─ getDroppedFrames()   → uint64_t — frames descartados por congestión
///   └─ getLastInferenceUs() → uint32_t — latencia última inferencia
///
/// THREAD SAFETY:
///   - process(): seguro de llamar SOLO desde audio thread (single-producer).
///   - setEnabled / setIntensity / getters: thread-safe (atomics).
///   - initialize(): NO thread-safe; llamar UNA VEZ al startup.
///
/// LATENCIA:
///   - GTCRN frame procesado en hops de kDnnHopSize samples a 16 kHz.
///   - MEJORA #1 (ruido-profundo.md): kDnnHopSize=128 → 8 ms de latencia
///     algorítmica STFT (antes era 256 = 16 ms). Esto pone el sistema por
///     debajo del umbral de comb-filter audible en open-fit (~5–7 ms).
///   - Resampler polyphase 48↔16 (72 taps, ratio 3, MEJORA #3): group delay ≈
///     (72-1)/2 / 48000 ≈ 0.74 ms en cada sentido → ~1.48 ms ida+vuelta
///     (antes 96 taps → ~2 ms).
///   - Latencia total esperada (con buffering + worker handoff) ≈ 14–18 ms
///     (antes ≈ 22–27 ms con hop=256 y proto de 96 taps).
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
///
/// MEJORA #1 (ruido-profundo.md): hop reducido de 256 → 128 (8 ms en vez de 16 ms).
/// Lleva el overlap STFT de 50% a 75% (con kDnnFftSize=512). Baja la latencia
/// algorítmica del paradigma STFT-DNN de 16 ms a 8 ms — el comb-filter en
/// open-fit deja de ser audible (umbral perceptual ~5–7 ms, Agnew/Stiefenhofer).
/// Costo: 2× inferencias por segundo (250 vs 125). Aceptable porque la inferencia
/// GTCRN simple corre en ~1.5 ms en arm64, así que 250 inferencias × 1.5 ms = 375 ms/s
/// = ~37% de un core, con margen suficiente.
static constexpr int kDnnHopSize = 128;

/// NOTE: kDnnDualBlock has been removed. The dual-channel path now operates
/// frame-by-frame at kDnnHopSize (128 samples = 8 ms), same as the mono path.
/// The WPE beamformer + ONNX GTCRN core replaces the LibTorch 3-second block.
/// Spec: gtcrn-dual-channel (Option D: WPE in C++ + ONNX core).

/// Tamaño de ventana STFT del modelo GTCRN (FFT 512, ventana Hann).
static constexpr int kDnnFftSize = 512;

/// Crossfade lineal al togglear enabled (en samples a 16 kHz).
///
/// MEJORA #1 (ruido-profundo.md, Tier 3 #12 “gratis”): crossfade subido de 30 ms a 50 ms.
/// 50 ms × 16 000 Hz / 1000 = 800 samples. Beneficio: transición ON/OFF aún más
/// suave (especialmente perceptible en habla con consonantes plosivas durante el
/// toggle). No afecta latencia de procesamiento; solo el ramp de la mezcla dry/wet.
static constexpr int kDnnCrossfadeSamples = 800;

/// Capacidad de cada ring buffer (input/output) en samples.
///
/// With frame-by-frame processing at kDnnHopSize=128, we only need enough
/// buffer to absorb jitter between audio thread and worker thread.
/// 4096 samples = ~256 ms at 16 kHz, which is more than sufficient for
/// frame-by-frame operation (each frame is only 8 ms). Power of 2 for
/// efficient SPSC ring buffer masking.
static constexpr int kDnnRingCapacity = 4096;

/// Cap por defecto aplicado a `intensity` cuando el VAD detecta voz activa.
/// Valor en [0,1]. 0.7 = mezcla 30% dry + 70% wet con voz, recuperando
/// energía de voz que el modelo atenúa, sin romper el invariante "DNN solo
/// atenúa" (la mezcla solo cambia el peso entre dry y wet).
/// Spec: dnn-voice-level-recovery (Paso 1).
static constexpr float kDefaultVoiceCap = 0.7f;

/// Constantes de la rampa asimétrica entre `intensity` del usuario y el cap.
/// Attack rápido (40 ms) cuando aparece voz; release lento (300 ms) cuando
/// desaparece. Estilo WDRC asimétrico para evitar fluctuación audible.
/// Spec: dnn-voice-level-recovery (Paso 1).
static constexpr float kVoiceCapAttackMs  = 40.0f;
static constexpr float kVoiceCapReleaseMs = 300.0f;

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

    /// Carga el modelo ONNX dual-channel (gtcrn_dual_core.onnx) desde assets
    /// y lanza el worker thread en modo dual (WPE beamformer + ONNX GTCRN core).
    ///
    /// Contrato del modelo: misma interfaz que el modelo mono GTCRN:
    ///   inputs[0] = "mix" [1,257,1,2] (real+imag per freq bin, single channel)
    ///   inputs[1..3] = recurrent caches (conv, tra, inter)
    ///   outputs[0] = "enh" [1,257,1,2] (enhanced spectrum)
    ///   outputs[1..3] = updated caches
    ///
    /// The dual-channel pipeline (Option D) works as follows:
    ///   1. STFT of both ch0 and ch1 (done in C++, kDnnFftSize=512)
    ///   2. WPE beamformer: combines 2ch spectra into 1ch enhanced spectrum
    ///   3. ONNX GTCRN core: processes the beamformed spectrum frame-by-frame
    ///   4. iSTFT/OLA: reconstructs time-domain output
    ///
    /// This replaces the LibTorch-based approach that ran STFT/WPE/IVA inside
    /// the .ptl model with 3-second blocks. Now operates frame-by-frame at
    /// kDnnHopSize=128 (8ms latency), same as the mono path.
    ///
    /// @param assetMgr  Asset manager Android (nullptr -> falla limpia).
    /// @param assetPath Ruta dentro de assets/, ej "dnn_denoiser/gtcrn_dual_core.onnx".
    /// @return true si el modelo cargo y la sesion esta lista.
    /// NOTE: Llamar UNA SOLA VEZ, en lugar de initialize() (no ambos).
    /// Spec: gtcrn-dual-channel (Option D: WPE C++ + ONNX core).
    bool initializeDual(AAssetManager* assetMgr, const char* assetPath);

    /// @return canales de entrada del modelo cargado (1 = mono, 2 = dual).
    /// Antes de initialize/initializeDual devuelve 1 (mono) por defecto.
    int inputChannels() const;

    /// Configura el sample rate nativo del audio que va a entrar a process().
    /// El modelo GTCRN trabaja siempre a 16 kHz; este wrapper inserta un
    /// resampler interno (downsample antes del worker, upsample después)
    /// cuando inputSr != 16000.
    ///
    /// Casos soportados:
    ///   - 16000      → bypass del resampler (rate nativa del modelo).
    ///   - 48000      → polyphase FIR 3:1 (72 taps prototipo, fc=7.5 kHz,
    ///                   transición ~1 kHz, ventana Kaiser β=8.5; MEJORA #3).
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

    /// Procesa un bloque ESTEREO hacia salida mono. Llamar SOLO desde audio
    /// thread (NO bloquea: la inferencia ONNX corre en el worker thread).
    ///
    /// Empuja ch0 y ch1 a dos ring buffers SPSC paralelos (tras remuestrear a
    /// 16 kHz). El worker ejecuta STFT(2ch) -> WPE beamformer -> ONNX GTCRN
    /// core -> iSTFT/OLA y deja la salida en el output ring. Este metodo tira
    /// la salida disponible, la upsamplea a la rate nativa, y la mezcla con
    /// ch0 (senal "dry") aplicando intensity, crossfade anti-clic y el cap de
    /// VAD (misma maquina que `process()`).
    ///
    /// Bypass (Bypass_Seguro): si el modelo no es dual, no esta activo, o hay
    /// underrun del worker, la salida es ch0 passthrough. Nunca corta el audio.
    ///
    /// @param ch0 Canal 0 (mic inferior), blockSize samples @ inputSampleRate.
    /// @param ch1 Canal 1 (mic superior), blockSize samples @ inputSampleRate.
    /// @param output Salida mono, blockSize samples (puede aliasar ch0).
    /// @param blockSize Numero de samples por canal.
    void processStereo(const float* ch0, const float* ch1,
                       float* output, int blockSize);

    /// Toggle ON/OFF. Inicia crossfade anti-clic de 50 ms (800 samples a 16 kHz;
    /// MEJORA #1 Tier 3 #12, antes 30 ms).
    /// Thread-safe: lock-free. Puede llamarse desde cualquier hilo.
    void setEnabled(bool enabled);

    /// Mezcla dry/wet del denoising. Clampeada a [0,1].
    ///   0.0 → 100% dry (señal original limpia)
    ///   1.0 → 100% wet (denoised)
    ///   Valores intermedios → mezcla lineal.
    /// Thread-safe: lock-free.
    void setIntensity(float intensity);

    /// Notifica el estado del VAD del bloque actual al denoiser.
    ///
    /// Cuando `active == true`, la `intensity` efectiva interna se modula
    /// hacia `kDefaultVoiceCap` (configurable vía `setVoiceCap`) con rampa
    /// asimétrica `kVoiceCapAttackMs` / `kVoiceCapReleaseMs`. Cuando
    /// `active == false`, la `intensity` efectiva vuelve al valor del
    /// usuario (set vía `setIntensity`).
    ///
    /// El cap NO viola el invariante "el DNN solo atenúa": al reducir
    /// `intensity` se mezcla más dry (señal original), nunca se amplifica.
    ///
    /// Lock-free, thread-safe. Llamar desde el audio callback después
    /// del `SceneAnalyzer::process()` que produce el flag.
    /// Spec: dnn-voice-level-recovery R1.1, R1.2.
    void notifyVoiceActive(bool active);

    /// Configura el cap aplicado a `intensity` cuando hay voz activa.
    /// Default `kDefaultVoiceCap = 0.7f`. Valores fuera de [0,1] se clampean.
    /// Setear `1.0f` desactiva la modulación (cap nunca aplica).
    /// Lock-free, thread-safe.
    /// Spec: dnn-voice-level-recovery R1.1, R5.3.
    void setVoiceCap(float cap);

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

    /// @return `intensity` efectiva post-VAD-cap (valor realmente aplicado
    /// en la mezcla dry/wet). Distinto de `getIntensity()` cuando el VAD
    /// está activo y `userIntensity > voiceCap`.
    /// Útil para telemetría / diagnóstico (ver R2.1 del spec).
    float getEffectiveIntensity() const {
        return effectiveIntensityAtomic_.load(std::memory_order_acquire);
    }

    /// @return cap actual aplicado a `intensity` cuando el VAD detecta voz.
    float getVoiceCap() const {
        return voiceCap_.load(std::memory_order_acquire);
    }

    /// @return total de hops (kDnnHopSize = 128 samples) procesados con DNN.
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

    /// Estado del VAD del último bloque procesado por el SceneAnalyzer.
    /// Lo escribe el caller vía `notifyVoiceActive`; lo lee el audio thread
    /// dentro de `process()` para calcular el target del cap.
    /// Spec: dnn-voice-level-recovery (Paso 1).
    std::atomic<bool>  voiceActive_{false};

    /// Cap aplicado a `intensity` cuando `voiceActive_` es true.
    /// Default `kDefaultVoiceCap`. Setter `setVoiceCap`.
    std::atomic<float> voiceCap_{kDefaultVoiceCap};

    /// `intensity` efectiva tras aplicar la rampa asimétrica.
    /// Sólo escrito desde el audio thread (process). Espejado al atomic
    /// `effectiveIntensityAtomic_` para `getEffectiveIntensity()`.
    /// Spec: dnn-voice-level-recovery (Paso 1).
    float effectiveIntensity_ = 1.0f;

    /// Espejo atómico de `effectiveIntensity_` para getters externos.
    std::atomic<float> effectiveIntensityAtomic_{1.0f};

    /// Pasos por sample de la rampa asimétrica del cap. Recalculados en
    /// `setInputSampleRate` (la mezcla corre a `inputSampleRate`, no a
    /// 16 kHz). Default a 0 hasta que `setInputSampleRate` se llame por
    /// primera vez; mientras tanto el cap aplica como step instantáneo
    /// (degeneración benigna).
    float stepAttackPerSample_  = 0.0f;
    float stepReleasePerSample_ = 0.0f;
};

}  // namespace dnn_denoiser

#endif  // HEARING_AID_DNN_DENOISER_H

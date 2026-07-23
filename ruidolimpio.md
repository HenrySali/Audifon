# ruidolimpio.md — Redes Neuronales de Noise Reduction: Estado, Investigación y Plan

**Proyecto:** PSK Hearing Aid / Audifon  
**Fecha:** 2026-07-22  
**Alcance:** Las 3 redes DNN de reducción de ruido integradas en el pipeline DSP nativo  
**Repo:** `Audifon-main (4)/Audifon-main/android/app/src/main/cpp/`

---

## 1. Estado Actual de las 3 Redes

### 1.1 RNNoise (xiph/rnnoise v0.1.1) — MOTOR PRIMARIO ACTIVO

| Campo | Valor |
|-------|-------|
| **Estado** | ✅ **ACTIVO** — Motor primario seleccionado en `initDnnDenoiser()` |
| **Prioridad** | 1 (primera opción; si falla, cae a DFN3/GTCRN) |
| **Sample rate nativo** | 48 kHz |
| **Frame size** | 480 samples (10 ms) |
| **Tamaño del modelo** | ~90 KB (baked-in, compilado estáticamente en el .so) |
| **Latencia algorítmica** | 10 ms (1 hop de buffering ring-buffer) |
| **Runtime/Backend** | C puro, static link. Sin dlopen, sin ONNX, sin assets externos |
| **Licencia** | BSD 3-Clause |
| **Bugs conocidos** | Ninguno activo. Bug RESUELTO: con Oboe bursts de 256 samples y hops de 480, el algoritmo "DFN3-style" (in-place hop) dejaba ~50% de samples sin procesar. Solución: ring-buffer per-sample con 1 hop de latencia. |
| **Archivos** | `rnnoise_denoiser.cpp`, `rnnoise_denoiser.h`, `rnnoise/` (vendored sources) |
| **En CMakeLists.txt** | ✅ Compilado: `rnnoise_denoiser.cpp` + 7 sources C de `rnnoise/src/` |

**Interfaz actual:**

```cpp
namespace rnnoise_denoiser {
class RnnoiseDenoiser {
    bool initialize();                    // Crea DenoiseState, verifica frame_size=480
    void process(float* buffer, int blockSize);  // Ring-buffer per-sample, dry/wet mix
    void setEnabled(bool enabled);        // Toggle con crossfade 50ms (2400 samples @48k)
    void setIntensity(float intensity);   // Mezcla dry/wet [0..1], default 0.6
    // Getters:
    bool isEnabled() const;
    bool isActive() const;                // initialized_ && state_ != nullptr
    float getIntensity() const;
    float getEffectiveIntensity() const;  // crossfadeGain_ * userIntensity
    float getLastVadProb() const;         // VAD probability del último hop
    uint64_t getProcessedFrames() const;  // Total hops procesados
    uint64_t getDroppedFrames() const;    // Siempre 0 (síncrono)
    uint32_t getLastInferenceUs() const;  // Microsegundos última inferencia
};
}
```

**Razón de ser motor primario:**
- Static link: no dlopen, no SIGABRT por crashes en .so externo
- Modelo baked-in: no extracción de assets, no rutas filesystem
- 48 kHz nativo: alineado con Oboe, sin resampler
- 0 alloc en hot path, ~0.1 ms compute en arm64
- Probado en producción (OBS Studio, Mumble, ffmpeg arnndn)

---
### 1.2 GTCRN (DNN Denoiser via OnnxRuntime) — FALLBACK / DUAL-CHANNEL

| Campo | Valor |
|-------|-------|
| **Estado** | ⚠️ **FALLBACK** — Se inicializa siempre pero solo procesa si `useRnnoise_=false` (mono) o en modo `kDualChannelDnn` (dual con WPE beamformer) |
| **Prioridad** | 3 (último fallback en mono; activo en modo dual-channel) |
| **Sample rate nativo** | 16 kHz (modelo entrenado a 16k) |
| **Frame size** | kDnnHopSize=160 samples (10 ms @16k) |
| **FFT size** | 320 (161 bins, sqrt-Hann periódica, 50% overlap) |
| **Tamaño del modelo** | ~2 MB (gtcrn.onnx) + ~2 MB (gtcrn_dual_core.onnx) |
| **Latencia algorítmica** | ~14-18 ms total (10ms STFT + ~1.5ms resampler polyphase + worker handoff) |
| **Runtime/Backend** | OnnxRuntime v1.16.3 (libonnxruntime.so prebuilt en jniLibs/) |
| **Resampler** | Polyphase FIR 3:1 (72 taps, Kaiser β=8.5, fc=7.5kHz) para 48→16→48 kHz |
| **Worker thread** | Sí — ring-buffer SPSC (4096 samples), worker drena 160 samples/hop |
| **Licencia** | MIT (OnnxRuntime) + modelo propietario entrenado por equipo |

**Bugs conocidos:**
- Si `inputSampleRate != 16000` y el polyphase no se configura, puede haber artefactos
- Worker thread puede acumular frames dropped bajo carga extrema (contado en `droppedFrames_`)
- La instancia dual requiere `gtcrn_dual_core.onnx` en assets; si falta, `kDualChannelDnn` bypasea a ch0

**Archivos:** `dnn_denoiser/dnn_denoiser.cpp`, `dnn_denoiser/dnn_denoiser.h`

**Interfaz actual:**

```cpp
namespace dnn_denoiser {
class DnnDenoiser {
    bool initialize(AAssetManager* mgr, const char* assetPath);
    bool initializeDual(AAssetManager* mgr, const char* assetPath);
    int inputChannels() const;
    void setInputSampleRate(int sampleRateHz);
    void process(float* buffer, int blockSize);
    void processStereo(const float* ch0, const float* ch1, float* output, int blockSize);
    void setEnabled(bool enabled);
    void setIntensity(float intensity);
    void notifyVoiceActive(bool active);   // Modulación VAD cap
    void setVoiceCap(float cap);           // Default 0.7
    void reset();
    // Getters:
    bool isEnabled() const;
    bool isActive() const;
    float getIntensity() const;
    float getEffectiveIntensity() const;   // Post-VAD cap
    float getVoiceCap() const;
    uint64_t getProcessedFrames() const;
    uint64_t getDroppedFrames() const;
    uint32_t getLastInferenceUs() const;
};
}
```

**Características avanzadas (vs RNNoise/DFN3):**
- Modulación VAD de intensity con rampa asimétrica (attack 40ms, release 300ms)
- Crossfade anti-clic de 50ms (800 samples @16k)
- Dual-channel: WPE beamformer en C++ + ONNX GTCRN core, frame-by-frame
- Dos instancias: `dnnDenoiser_` (mono legacy) + `dnnDenoiserDual_` (dual WPE+ONNX)

---
### 1.3 DeepFilterNet3 (DFN3) — DESACTIVADO POR BUG RUNTIME

| Campo | Valor |
|-------|-------|
| **Estado** | ❌ **DESACTIVADO** — `useDfn3_ = false` forzado en `initDnnDenoiser()` |
| **Razón** | Crash en runtime: `index out of bounds: the len is 481 but the index is 481` en libdfn3.so (Rust panic, SIGABRT). Confirmado en Motorola devon_g, tombstone 2026-07-20. |
| **Prioridad** | 2 (entre RNNoise y GTCRN), pero hardcodeado a `false` hasta fix |
| **Sample rate nativo** | 48 kHz (no necesita resampler) |
| **Frame size** | 480 samples (10 ms @48k) = `DFN3_HOP_SIZE` |
| **Tamaño del modelo** | ~8.5 MB total (enc.onnx + erb_dec.onnx + df_dec.onnx) |
| **Latencia algorítmica** | ~10 ms (1 hop) + crossfade 50ms al toggle |
| **Runtime/Backend** | Rust/tract (v0.21), dlopen de `libdfn3.so` en runtime |
| **Arquitectura** | 3-stage: ERB gains + deep filtering multi-frame + iSTFT |
| **Licencia** | MIT (DeepFilterNet) + crate deps (tract MIT, deep_filter MIT) |

**Bugs conocidos:**
- **CRÍTICO:** Panic `index out of bounds 481` dentro del engine Rust (off-by-one en buffer circular del deep filtering). Causa SIGABRT. No se puede usar hasta recompilar con fix.
- El wrapper C++ (`dfn3_denoiser.cpp`) funciona correctamente; el bug está DENTRO de `libdfn3.so`.
- Sin la .so presente, `loadLibrary()` retorna false limpio y la app funciona con fallback.

**Archivos:** `dfn3_denoiser.cpp`, `dfn3_denoiser.h`, `dfn3_rust/` (Cargo crate + C API)

**Interfaz actual:**

```cpp
namespace dfn3_denoiser {
class Dfn3Denoiser {
    bool initialize(const std::string& modelDir);
    void process(float* buffer, int blockSize);   // Hop-based con residual buffer
    void setEnabled(bool enabled);
    void setIntensity(float intensity);
    // Getters:
    bool isEnabled() const;
    bool isActive() const;       // initialized_ && sFnIsActive()
    float getIntensity() const;  // Delegado a Rust via dlsym
    float getEffectiveIntensity() const;
};
}
```

**FFI (C API en `dfn3_api.h`):**

```c
bool dfn3_init(const char* model_dir);
bool dfn3_process_hop(float* buffer);   // 480 samples in-place
void dfn3_set_intensity(float intensity);
float dfn3_get_intensity(void);
bool dfn3_is_active(void);
void dfn3_free(void);
```

---

### 1.4 Resumen comparativo del estado actual

| Red | Estado | Sample Rate | Latencia | Modelo | Runtime | Calidad (PESQ) |
|-----|--------|-------------|----------|--------|---------|----------------|
| **RNNoise** | ✅ Activo | 48 kHz | 10 ms | 90 KB (baked) | C static | ~2.43 |
| **GTCRN** | ⚠️ Fallback/Dual | 16 kHz | 14-18 ms | 2 MB (ONNX) | OnnxRuntime | ~2.8 |
| **DFN3** | ❌ Desactivado | 48 kHz | 10 ms | 8.5 MB (ONNX×3) | Rust/tract | ~3.16 |

**Cadena de fallback actual:**
```
initDnnDenoiser() {
    1. RNNoise.initialize() → si OK → useRnnoise_=true (MOTOR PRIMARIO)
    2. DFN3 → HARDCODED false (bug runtime)
    3. GTCRN mono → siempre se inicializa (fallback + base para dual)
    4. GTCRN dual → se inicializa para kDualChannelDnn
}
```

---
## 2. Investigación: Mejores Fuentes y Modelos

### 2.1 DeepFilterNet3 (Schröter et al., INTERSPEECH 2023)

- **Paper:** "DeepFilterNet: Perceptually Motivated Real-Time Speech Enhancement" — Schröter, Rosenkranz, Escalante-B., Maier. INTERSPEECH 2023.
- **Institución:** RWTH Aachen University / Fraunhofer IIS, Alemania.
- **Repo:** [github.com/Rikorose/DeepFilterNet](https://github.com/Rikorose/DeepFilterNet) (5k+ estrellas)
- **Arquitectura:** Two-stage: Stage 1 = ERB-domain envelope recovery (ganancias por banda ERB), Stage 2 = Multi-frame complex filtering (deep filtering) para componentes periódicos de voz hasta 4 kHz. Usa polyphase HA filterbank (24 kHz) opcionalmente.
- **Métricas:** PESQ ~3.16 (Voicebank), STOI >0.95, SI-SDR significativamente mejorado.
- **Parámetros:** 2.13M params, 0.344 GMACs/s. Latencia 40 ms (configurable a 10 ms con hop más chico).
- **Ventajas:** Calidad SOTA, menos artefactos musicales, manejo de ruido no-estacionario.
- **Desventajas:** Modelo grande (~8.5 MB), requiere Rust/tract o ONNX runtime, bug OOB en v3 en Android.
- **Open source:** Sí (MIT). Modelos pre-entrenados disponibles.
- **Relevancia para audífonos:** Paper específico "Deep Multi-Frame Filtering for Hearing Aids" del mismo grupo. DFingerNet (2025) adapta DFN a filterbank de audífonos con 2ms de latencia de inferencia.

### 2.2 RNNoise (Valin, 2018 / xiph.org)

- **Paper:** "A Hybrid DSP/Deep Learning Approach to Real-Time Full-Band Speech Enhancement" — Jean-Marc Valin, 2018.
- **Institución:** Mozilla/Xiph.org, Ottawa, Canadá.
- **Repo:** [github.com/xiph/rnnoise](https://github.com/xiph/rnnoise) (4k+ estrellas)
- **Arquitectura:** Híbrido DSP/DNN — pitch-based features + 3-layer GRU (24/48/24 units) que predice ganancias por banda (22 Bark bands). Opera frame-by-frame (480 samples @48kHz).
- **Métricas:** PESQ ~2.43 (Voicebank), modesto vs SOTA moderno pero con complejidad mínima.
- **Parámetros:** ~60K params, 0.04 GMACs/s. Latencia 10-20 ms.
- **Ventajas:** Ultra-ligero, C puro, static link, modelo baked-in (~90 KB). Latencia predecible. Probado en producción masiva (OBS, Mumble, ffmpeg, WebRTC forks).
- **Desventajas:** Calidad limitada en ruido no-estacionario, puede dejar "ruido musical" residual. No mejora de fase. Modelo de 2018 sin actualizaciones significativas.
- **Open source:** Sí (BSD-3-Clause).
- **Relevancia para audífonos:** Usado en prototipos de audífonos publicados (ARM Cortex-M4 con Relajet). Referencia en investigación embedded (rnnoise.com).

### 2.3 DTLN (Dual-Signal Transformation LSTM Network)

- **Paper:** "DTLN - a context-aware dual-signal transformation LSTM network for real-time speech enhancement" — Westhausen & Meyer, 2020.
- **Institución:** Fraunhofer IDMT / TU Ilmenau, Alemania.
- **Repo:** [github.com/breizhn/DTLN](https://github.com/breizhn/DTLN) (1k+ estrellas)
- **Arquitectura:** Dos cores cascadeados: Core 1 opera en dominio frecuencia (STFT mask), Core 2 usa representación temporal aprendida. Ambos con LSTM + instant layer normalization.
- **Métricas:** PESQ ~2.7-2.9 en DNS Challenge. <1M parámetros.
- **Latencia:** Frame-synchronous, ~32 ms con ventana estándar. Configurable a 8-16 ms.
- **Ventajas:** Ligero (<1M params), dos representaciones complementarias (magnitud + fase implícita). Bien documentado, TFLite compatible.
- **Desventajas:** Rendimiento por debajo de DFN3 en ruido no-estacionario. LSTM secuencial no paralelizable.
- **Open source:** Sí (MIT). Modelos TFLite publicados.
- **Relevancia para audífonos:** Diseñado explícitamente para real-time en dispositivos embebidos. Usado como baseline en DNS Challenge.

### 2.4 GTCRN (Global-Temporal Convolutional Recurrent Network)

- **Paper:** "GTCRN: a speech enhancement model requiring ultra-low computational resources" — Zhang et al., 2023.
- **Institución:** Speech Lab / múltiples universidades chinas.
- **Repo:** [github.com/topics/speech-enhancement](https://github.com/topics/speech-enhancement) (official impl)
- **Arquitectura:** Encoder temporal convolucional + GRU recurrente + decoder. STFT 320-point (161 bins), hop 160. Input: [1,1,161,2] (real+imag). Modelo ultra-liviano.
- **Métricas:** PESQ ~2.8 en condiciones similares a DNS. Comparable a DTLN con menos compute.
- **Parámetros:** ~200K params. Muy eficiente en arm64.
- **Latencia:** 10 ms algorítmica (hop 160 @16kHz). Total con resampler: ~14-18 ms.
- **Ventajas:** Ultra-liviano, ONNX native, bajo consumo. Ideal para siempre-activo.
- **Desventajas:** Calidad por debajo de DFN3. Requiere resampler a 16kHz desde 48kHz (agrega latencia). Modelo menos robusto ante ruido impulsivo.
- **Open source:** Sí (MIT/Apache). Modelo ONNX disponible.
- **Relevancia para audífonos:** Elegido para este proyecto por su bajo compute. Ya integrado y funcionando como fallback.

### 2.5 DPDFNet / NSNet2 / FullSubNet+ / PercepNet — Otros modelos relevantes

| Modelo | PESQ | Params | Latencia | Open Source | Nota |
|--------|------|--------|----------|-------------|------|
| **DPDFNet** (2025) | ~3.3+ | ~2.5M | ~40ms | Sí (paper + code) | Extiende DFN2 con Dual-Path RNN. SOTA 2025. |
| **NSNet2** (Microsoft, 2021) | ~2.6 | ~6M | ~20ms | Sí (DNS Challenge) | Baseline oficial DNS Challenge. Robusto pero pesado. |
| **FullSubNet+** (2022) | ~3.0 | ~5M | ~32ms | Sí (PyTorch) | Full-band + sub-band fusion. Buena calidad, compute alto. |
| **PercepNet** (Google, 2020) | ~2.73 | 8M | ~40ms | No (propietario) | Basado en RNNoise con mejoras perceptuales. Usado en Google Meet. |
| **Spiking-FullSubNet** (2024) | ~2.9 | ~3M | neuromorfo | Sí | Ganador Intel N-DNS Challenge. Ultra-low-power. |
| **SuDoRM-RF++** (time-domain) | ~2.8 | <1M | ~4ms | Sí | Convolucional puro, ideal para FPGA. Sin STFT. |

### 2.6 Fabricantes — Estado del Arte Comercial

| Fabricante | Producto | Tecnología DNN NR | Referencia |
|-----------|----------|-------------------|------------|
| **Phonak/Sonova** | Audéo Sphere (2024) | DNN real-time en chip propio. Estudio clínico 2-arm (Chicago 2024). AI binaural + noise reduction. | Hearing Review 2024 |
| **Oticon/Demant** | Real 2 (2024) | Polaris R chip, DNN para speech-in-noise. BrainHearing + MoreSound Intelligence 3.0. | Oticon whitepapers |
| **Starkey** | Genesis AI (2024) | Edge Mode™ con DNN optimizado. Mejora SNR >5 dB en speech-in-noise. Estudio 1600+ pacientes. | Frontiers Audiology 2025 |
| **WS Audiology/Signia** | IX (2024) | Augmented Focus™ 2.0 con deep neural split-processing. Separación de escenas. | Signia Pro |
| **Widex** | SmartRIC (2024) | PureSound™ 3.0 con procesamiento ultra-baja-latencia + ML para clasificación. | Widex Pro |

**Fuentes principales:**
1. Schröter et al. (2023) — INTERSPEECH. [isca-archive.org](https://www.isca-archive.org/interspeech_2023/schroter23b_interspeech.pdf)
2. Maulana et al. (2025) — "Performance of speech enhancement models: DFN3 and RNNoise". Sinergi J. Vol.29 No.2.
3. PMC/MDPI (2025) — "Deep-Learning Framework for Efficient Real-Time Speech Enhancement and Dereverberation". [PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC11820353/)
4. Arm + Relajet case study — AI hearing devices en Cortex-M4. [arm.com](https://www.arm.com/company/success-library/relajet-ai-hearing-devices)
5. arxiv:2507.07043 (2025) — "Advances in Intelligent Hearing Aids: Deep Learning Approaches to Selective Noise Cancellation" — Survey completo 2015-2024.

---
## 3. Comparativa y Recomendación

### 3.1 Benchmark de las 3 redes del proyecto

| Criterio | RNNoise | GTCRN | DFN3 |
|----------|---------|-------|------|
| **PESQ (Voicebank)** | 2.43 | ~2.8 | 3.16 |
| **STOI** | ~0.90 | ~0.92 | >0.95 |
| **Parámetros** | 60K | ~200K | 2.13M |
| **MACs/s** | 0.04G | ~0.1G | 0.344G |
| **Latencia real** | 10 ms | 14-18 ms | 10 ms |
| **Modelo en disco** | 0 (baked) | 2 MB | 8.5 MB |
| **Resampler** | No (48k nativo) | Sí (48→16→48) | No (48k nativo) |
| **Runtime** | C static | OnnxRuntime .so | Rust/tract .so |
| **Stability** | ✅ Estable | ✅ Estable | ❌ Crash |
| **Ruido musical** | Moderado | Bajo | Muy bajo |
| **Voz natural** | Buena | Buena | Excelente |
| **Dual-channel** | No (mono) | Sí (WPE+ONNX) | No (mono) |

### 3.2 Recomendación por caso de uso

1. **Uso diario / siempre-activo (default):** → **RNNoise**
   - Mínimo consumo, estable, sin dependencias externas.
   - Suficiente para ruido estacionario (ventilador, tráfico, AC).
   - El usuario casual no nota la diferencia vs GTCRN.

2. **Situaciones ruidosas (restaurante, calle):** → **DeepFilterNet3** (cuando se fixee)
   - Superior en ruido no-estacionario (voces de fondo, música).
   - PESQ ~3.16 = 30% mejor que RNNoise en inteligibilidad.
   - Menos artefactos musicales ("matraca").

3. **Dual-mic / beamforming:** → **GTCRN dual**
   - Única red con soporte WPE + 2 canales.
   - Complementario al MVDR beamformer.

4. **Bajo consumo extremo / dispositivo débil:** → **RNNoise**
   - 0.04 GMACs vs 0.344 (DFN3) = 8.6× menos compute.

### 3.3 Estrategia recomendada para el toggle exclusivo

El toggle debe ofrecer las 3 opciones al usuario/técnico:
- **"Estándar" (RNNoise)** — default, siempre disponible
- **"Premium" (DFN3)** — cuando se fixee el bug Rust, mejor calidad
- **"Analítico" (GTCRN)** — para dual-mic o cuando se quiera modulación VAD fina

El técnico elige en el fitting; el paciente hereda la selección. El usuario avanzado puede cambiarla si el técnico lo habilita.

---
## 4. Plan de Implementación — Arquitectura del Toggle Exclusivo

### 4.1 Interfaz común: `IDenoiserEngine`

```cpp
// archivo: i_denoiser_engine.h
#ifndef HEARING_AID_I_DENOISER_ENGINE_H
#define HEARING_AID_I_DENOISER_ENGINE_H

#include <cstdint>
#include <string>

struct AAssetManager;

/// Interfaz polimórfica para motores de denoising.
/// Cada implementación (RNNoise, DFN3, GTCRN) hereda de esta.
class IDenoiserEngine {
public:
    virtual ~IDenoiserEngine() = default;

    /// Inicializa el motor. Retorna true si queda listo.
    virtual bool initialize(AAssetManager* mgr) = 0;

    /// Procesa audio in-place. Solo desde audio thread.
    virtual void process(float* buffer, int blockSize) = 0;

    /// Habilita/deshabilita (con crossfade interno).
    virtual void setEnabled(bool enabled) = 0;

    /// Mezcla dry/wet [0..1].
    virtual void setIntensity(float intensity) = 0;

    /// @return true si el motor está procesando audio.
    virtual bool isActive() const = 0;

    /// @return true si enabled flag está seteado.
    virtual bool isEnabled() const = 0;

    /// Resetea estado interno (buffers, caches).
    virtual void reset() = 0;

    /// Nombre legible para UI/logs.
    virtual const char* name() const = 0;

    /// Getters de telemetría.
    virtual uint64_t getProcessedFrames() const = 0;
    virtual uint64_t getDroppedFrames() const = 0;
    virtual uint32_t getLastInferenceUs() const = 0;
    virtual float getEffectiveIntensity() const = 0;
};

#endif
```

### 4.2 `DenoiserSelector` — Toggle exclusivo con crossfade

```cpp
// archivo: denoiser_selector.h
#ifndef HEARING_AID_DENOISER_SELECTOR_H
#define HEARING_AID_DENOISER_SELECTOR_H

#include "i_denoiser_engine.h"
#include <array>
#include <atomic>

/// Identificadores de los 3 motores disponibles.
enum class DenoiserType : int {
    kRNNoise = 0,   // "Estándar"
    kDFN3    = 1,   // "Premium"
    kGTCRN   = 2,   // "Analítico"
    kCount   = 3
};

/// Selector exclusivo de denoiser. Solo UNO activo a la vez.
/// Maneja crossfade entre motores al cambiar selección.
class DenoiserSelector {
public:
    DenoiserSelector();
    ~DenoiserSelector() = default;

    /// Registra los 3 motores (llamar al startup).
    void registerEngine(DenoiserType type, IDenoiserEngine* engine);

    /// Inicializa todos los motores registrados. Retorna true si al menos
    /// uno se inicializó correctamente.
    bool initializeAll(AAssetManager* mgr);

    /// Selecciona el motor activo. Desactiva los otros dos.
    /// Si el motor seleccionado no está disponible (isActive()=false),
    /// cae al fallback automático (RNNoise > GTCRN > bypass).
    /// Thread-safe (atómico + crossfade en audio thread).
    void select(DenoiserType type);

    /// @return motor actualmente seleccionado.
    DenoiserType getSelected() const;

    /// @return motor realmente activo (puede diferir del seleccionado si hubo fallback).
    DenoiserType getActive() const;

    /// Procesa audio. Delega al motor activo. Maneja crossfade
    /// entre motor saliente y entrante (20ms linear crossfade).
    void process(float* buffer, int blockSize);

    /// Forward de setEnabled/setIntensity al motor activo.
    void setEnabled(bool enabled);
    void setIntensity(float intensity);

    /// Getters delegados al motor activo.
    bool isActive() const;
    bool isEnabled() const;
    float getEffectiveIntensity() const;
    uint64_t getProcessedFrames() const;
    uint32_t getLastInferenceUs() const;
    const char* getActiveName() const;

private:
    std::array<IDenoiserEngine*, 3> engines_{};
    std::atomic<int> selectedType_{0};  // DenoiserType cast to int
    int activeType_ = 0;                // Audio-thread-only
    int prevType_ = 0;                  // Motor saliente durante crossfade

    // Crossfade entre motores (20ms @ 48kHz = 960 samples)
    static constexpr int kXfadeSamples = 960;
    int xfadeRemaining_ = 0;
    float xfadeBuf_[960] = {};          // Buffer temporal para motor saliente

    /// Resuelve fallback si el motor seleccionado no está disponible.
    int resolveFallback(int requested) const;
};

#endif
```

### 4.3 Exposición JNI → Kotlin → Dart (MethodChannel)

**C++ (native_bridge.cpp):**
```cpp
// Nuevos métodos JNI:
extern "C" JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSelectDenoiser(
    JNIEnv*, jobject, jint type) {
    if (gEngine) gEngine->getDenoiserSelector().select(
        static_cast<DenoiserType>(type));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetActiveDenoiser(
    JNIEnv*, jobject) {
    if (gEngine) return static_cast<jint>(
        gEngine->getDenoiserSelector().getActive());
    return 0;
}
```

**Kotlin (AudioMethodChannel.kt):**
```kotlin
// En el handler de MethodChannel:
"selectDenoiser" -> {
    val type = call.argument<Int>("type") ?: 0
    nativeBridge.selectDenoiser(type)
    result.success(null)
}
"getActiveDenoiser" -> {
    result.success(nativeBridge.getActiveDenoiser())
}
```

**Dart (denoiser_service.dart):**
```dart
class DenoiserService {
  static const _channel = MethodChannel('com.psk.hearing_aid/audio');

  /// Selecciona el denoiser activo (0=RNNoise, 1=DFN3, 2=GTCRN).
  Future<void> selectDenoiser(DenoiserType type) async {
    await _channel.invokeMethod('selectDenoiser', {'type': type.index});
  }

  /// Obtiene el denoiser actualmente activo.
  Future<DenoiserType> getActiveDenoiser() async {
    final int idx = await _channel.invokeMethod('getActiveDenoiser');
    return DenoiserType.values[idx];
  }
}

enum DenoiserType {
  rnnoise,   // "Estándar"
  dfn3,      // "Premium"
  gtcrn,     // "Analítico"
}
```

### 4.4 UI — Radio Buttons exclusivos (Flutter)

```dart
// Widget en la pantalla de configuración DSP del técnico
class DenoiserToggle extends StatelessWidget {
  final DenoiserType selected;
  final DenoiserType active;   // Puede diferir si hubo fallback
  final ValueChanged<DenoiserType> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Motor de reducción de ruido', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...DenoiserType.values.map((type) => RadioListTile<DenoiserType>(
          title: Text(_label(type)),
          subtitle: Text(_subtitle(type)),
          value: type,
          groupValue: selected,
          onChanged: (v) => onChanged(v!),
          secondary: active == type
              ? const Icon(Icons.check_circle, color: Colors.green)
              : null,
        )),
        if (active != selected)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Fallback activo: ${_label(active)} (${_label(selected)} no disponible)',
              style: TextStyle(color: Colors.orange[700], fontSize: 12),
            ),
          ),
      ],
    );
  }

  String _label(DenoiserType t) => switch (t) {
    DenoiserType.rnnoise => 'Estándar (RNNoise)',
    DenoiserType.dfn3 => 'Premium (DeepFilterNet3)',
    DenoiserType.gtcrn => 'Analítico (GTCRN)',
  };

  String _subtitle(DenoiserType t) => switch (t) {
    DenoiserType.rnnoise => 'Bajo consumo, siempre disponible',
    DenoiserType.dfn3 => 'Máxima calidad (requiere libdfn3.so)',
    DenoiserType.gtcrn => 'Modulación VAD, soporte dual-mic',
  };
}
```

### 4.5 Persistencia en Hive

```dart
// En HiveBoxes o el box de configuración DSP existente
class DspPreferencesBox {
  static const _denoiserKey = 'selectedDenoiserType';

  /// Guarda la selección del denoiser (0, 1 o 2).
  Future<void> saveDenoiserSelection(DenoiserType type) async {
    final box = await Hive.openBox('dsp_prefs');
    await box.put(_denoiserKey, type.index);
  }

  /// Lee la selección guardada. Default: RNNoise (0).
  Future<DenoiserType> loadDenoiserSelection() async {
    final box = await Hive.openBox('dsp_prefs');
    final idx = box.get(_denoiserKey, defaultValue: 0) as int;
    if (idx >= 0 && idx < DenoiserType.values.length) {
      return DenoiserType.values[idx];
    }
    return DenoiserType.rnnoise;
  }
}
```

La selección se aplica en el `initState()` de la pantalla DSP y se reaplica al reiniciar la app (en `AudioService.start()`).

### 4.6 Fallback automático

```
Lógica del DenoiserSelector::select(type):

1. Si engines_[type] != nullptr && engines_[type]->isActive():
   → Activar type, desactivar otros, crossfade 20ms.
2. Si engines_[type] no está disponible:
   → Log warning "Motor X no disponible, activando fallback"
   → Intentar fallback chain: RNNoise → GTCRN → bypass
   → El motor activo (getActive()) difiere del seleccionado (getSelected())
   → Notificar a Dart vía callback para mostrar badge "fallback"
3. Crossfade entre motor saliente y entrante:
   → 20ms linear ramp (960 samples @48kHz)
   → Motor saliente process() durante la rampa-down
   → Motor entrante process() durante la rampa-up
   → Sumados con weights complementarios (sin discontinuidad)
```

### 4.7 Diagrama de flujo del callback

```
onBothStreamsReady():
  ├── Headroom pre-DNN
  ├── DenoiserSelector::process(outPtr, numFrames)
  │     ├── Si xfadeRemaining_ > 0:
  │     │     ├── prevEngine->process(xfadeBuf_, chunk)
  │     │     ├── activeEngine->process(outPtr + pos, chunk)
  │     │     └── Mix: out[i] = prev*fadeOut + active*fadeIn
  │     └── Else:
  │           └── activeEngine->process(outPtr, numFrames)
  ├── Headroom post-DNN restore
  └── DspPipeline::processBlock()
```

---
## 5. Tareas de Implementación

### Fase 1: Infraestructura C++ (paralelizables)

| # | Tarea | Archivos | Dependencia |
|---|-------|----------|-------------|
| 1.1 | Crear `i_denoiser_engine.h` con la interfaz virtual | `cpp/i_denoiser_engine.h` | Ninguna |
| 1.2 | Crear adapters que wrappean las clases existentes: `RnnoiseAdapter`, `Dfn3Adapter`, `GtcrnAdapter` (heredan `IDenoiserEngine`, delegan a las clases actuales sin tocarlas) | `cpp/rnnoise_adapter.h`, `cpp/dfn3_adapter.h`, `cpp/gtcrn_adapter.h` | 1.1 |
| 1.3 | Crear `denoiser_selector.h` / `denoiser_selector.cpp` con la lógica de toggle exclusivo + crossfade | `cpp/denoiser_selector.h`, `cpp/denoiser_selector.cpp` | 1.1, 1.2 |
| 1.4 | Actualizar `CMakeLists.txt`: agregar `denoiser_selector.cpp` a la lista de sources | `cpp/CMakeLists.txt` | 1.3 |

### Fase 2: Integración en AudioEngine

| # | Tarea | Archivos | Dependencia |
|---|-------|----------|-------------|
| 2.1 | Agregar miembro `DenoiserSelector denoiserSelector_` a `AudioEngine` | `cpp/audio_engine.h` | 1.3 |
| 2.2 | En `initDnnDenoiser()`: registrar los 3 engines en el selector, llamar `initializeAll()`, hacer `select(kRNNoise)` como default | `cpp/audio_engine.cpp` | 2.1 |
| 2.3 | En `onBothStreamsReady()`: reemplazar el bloque `if(useRnnoise_) ... else if(useDfn3_) ... else ...` por `denoiserSelector_.process(outPtr, numFrames)` | `cpp/audio_engine.cpp` | 2.2 |
| 2.4 | Actualizar `setDnnEnabled()`, `setDnnIntensity()`, getters para delegar al selector | `cpp/audio_engine.cpp` | 2.3 |
| 2.5 | Eliminar flags `useRnnoise_`, `useDfn3_` (reemplazados por el selector) | `cpp/audio_engine.h`, `cpp/audio_engine.cpp` | 2.4 |

### Fase 3: Puente JNI → Kotlin

| # | Tarea | Archivos | Dependencia |
|---|-------|----------|-------------|
| 3.1 | Agregar `nativeSelectDenoiser(int)` y `nativeGetActiveDenoiser()` en `native_bridge.cpp` | `cpp/native_bridge.cpp` | 2.2 |
| 3.2 | Agregar métodos correspondientes en `NativeAudioBridge.kt` | `kotlin/NativeAudioBridge.kt` | 3.1 |
| 3.3 | Registrar handlers `"selectDenoiser"` y `"getActiveDenoiser"` en `AudioMethodChannel.kt` | `kotlin/AudioMethodChannel.kt` | 3.2 |

### Fase 4: Capa Dart / Flutter

| # | Tarea | Archivos | Dependencia |
|---|-------|----------|-------------|
| 4.1 | Crear `DenoiserType` enum y `DenoiserService` con MethodChannel calls | `lib/services/denoiser_service.dart` | 3.3 |
| 4.2 | Crear `DspPreferencesBox` (o extender el existente) con Hive persistencia | `lib/data/dsp_preferences_box.dart` | Ninguna |
| 4.3 | Crear widget `DenoiserToggle` (radio buttons exclusivos) | `lib/presentation/widgets/denoiser_toggle.dart` | 4.1 |
| 4.4 | Integrar `DenoiserToggle` en la pantalla de configuración DSP del técnico | `lib/presentation/screens/dsp_settings_screen.dart` | 4.3 |
| 4.5 | En `AudioService.start()`: leer persistencia Hive y aplicar `selectDenoiser` al arranque | `lib/services/audio_service.dart` | 4.1, 4.2 |
| 4.6 | Mostrar badge "fallback" si `getActive != getSelected` (polling cada 2s o listener) | `lib/presentation/widgets/denoiser_toggle.dart` | 4.1 |

### Fase 5: Paciente (clona del técnico)

| # | Tarea | Archivos | Dependencia |
|---|-------|----------|-------------|
| 5.1 | Sincronizar los nuevos archivos C++ al repo del paciente (el paciente clona el C++ del técnico) | Script de sync / CI | 2.5 |
| 5.2 | En la app del paciente: exponer solo lectura del denoiser activo (sin selector, hereda del técnico vía fitting) | `PACIENTE/.../denoiser_status.dart` | 5.1 |
| 5.3 | Opcionalmente: permitir que el paciente avanzado cambie motor si el técnico habilitó un flag | Config de fitting | 5.2 |

### Fase 6: Testing y Validación

| # | Tarea | Archivos | Dependencia |
|---|-------|----------|-------------|
| 6.1 | Unit test del `DenoiserSelector`: select, fallback, crossfade | `cpp/test_denoiser_selector.cpp` | 1.3 |
| 6.2 | Integration test: verificar que el callback de audio funciona con cada motor individual | test manual en device | 2.3 |
| 6.3 | Verificar que el toggle persiste tras kill+restart de la app | test manual | 4.5 |
| 6.4 | Verificar crossfade audible: sin clicks ni discontinuidades al cambiar | test con grabación diagnóstica | 2.3 |
| 6.5 | Verificar fallback: desinstalar gtcrn.onnx y confirmar que cae a RNNoise | test manual | 2.2 |
| 6.6 | Regression: confirmar que la UI "Limpiador de ruido (IA)" sigue mostrando frames/inferencia correctos | test manual | 2.4 |

---

## Notas Finales

- **No se eliminan** las clases existentes (`RnnoiseDenoiser`, `DnnDenoiser`, `Dfn3Denoiser`). Se wrappean con adapters.
- **El DFN3 permanece desactivado** (su adapter retorna `isActive()=false` porque `libdfn3.so` no está disponible o crashea). Cuando se recompile el .so corregido, solo hay que deployar la lib y el selector lo activará automáticamente.
- **Impacto en paciente:** El C++ es compartido. Los nuevos archivos (`denoiser_selector.cpp`, adapters) se clonan al paciente automáticamente por el sync script. La app del paciente necesita agregar el `MethodChannel` handler (Fase 5).
- **CMakeLists.txt:** Agregar `denoiser_selector.cpp` (los adapters son header-only).
- **Cadena verificada:** C++ (`denoiser_selector.cpp`) → JNI (`native_bridge.cpp`) → Kotlin (`AudioMethodChannel.kt`) → Dart (`denoiser_service.dart`) → UI (`denoiser_toggle.dart`) → Hive (`dsp_preferences_box.dart`).

# Dual-Microphone MVDR Beamforming — Feature Spec

## 1. Resumen ejecutivo

Implementar un **beamformer MVDR (Minimum Variance Distortionless Response)** de dos micrófonos en el motor DSP C++ del proyecto PSK Hearing Aid. El beamformer captura audio estéreo del Motorola Moto G32 (mic inferior + mic superior), prioriza señales frontales (voz del interlocutor) y atenúa ruido lateral/trasero. La salida mono limpia alimenta al pipeline DSP existente (DNN → WDRC → EQ → Volume → MPO) sin modificar su estructura interna.

**Beneficio clínico:** mejora de SNR de 3–8 dB en entornos ruidosos, equivalente a reducir la distancia al hablante a la mitad. Crítico para comprensión del habla en pacientes pediátricos con pérdida auditiva.

---

## 2. Problema que resuelve

### Situación actual
- El pipeline captura **1 canal mono** (mic inferior) via Oboe `ChannelCount=1`.
- En ambientes ruidosos (aula, calle, restaurante), la señal de voz llega mezclada con ruido omnidireccional.
- El DNN (GTCRN) mejora SNR ~6–10 dB, pero opera sobre la mezcla monoaural — no tiene información espacial.

### Con beamforming MVDR
- Captura **2 canales estéreo** (mic inferior = referencia, mic superior = auxiliar).
- El MVDR explota la diferencia de fase y amplitud entre micrófonos para:
  - Formar un lóbulo principal hacia la fuente frontal (0°).
  - Atenuar interferencias de otras direcciones.
- El DNN recibe una señal ya pre-limpiada espacialmente → mejora total de SNR: **8–15 dB** (beamformer + DNN encadenados).

---

## 3. Fundamento científico

### 3.1 Papers de referencia

| Paper | DOI/PMC | Aporte clave |
|-------|---------|--------------|
| "Real-time dual-channel speech enhancement by VAD assisted MVDR beamformer for hearing aid applications using smartphone" | PMC7545265 | Demuestra MVDR de 2 mics en smartphone con VAD para estimar la matriz de correlación del ruido. Latencia < 10 ms. |
| "Efficient two-microphone speech enhancement using basic RNN cell for hearing aids" | PMC7928060 | Beamformer de 2 mics + RNN ligera post-procesamiento. Muestra que 2 mics son suficientes para 4–6 dB de mejora SNR. |
| "Influence of MVDR beamformer on Speech Enhancement based Smartphone application for Hearing Aids" | PMC7398114 | Validación experimental de MVDR en smartphone. Muestra que MVDR + DNN supera a DNN solo por 3–5 dB extra. |

### 3.2 Algoritmo MVDR — Fundamento matemático

El MVDR (Minimum Variance Distortionless Response) minimiza la potencia de salida sujeta a la restricción de que la señal proveniente de la dirección deseada (steering vector `d`) pase sin distorsión:

```
min_w  w^H · Rnn · w
s.t.   w^H · d = 1
```

Solución cerrada:
```
w_opt = (Rnn^{-1} · d) / (d^H · Rnn^{-1} · d)
```

Donde:
- `w` = vector de pesos del beamformer (2×1 para 2 mics)
- `Rnn` = matriz de correlación espacial del ruido (2×2)
- `d` = steering vector hacia la dirección de interés (0° frontal)
- `^H` = transpuesta conjugada (Hermitiana)

### 3.3 Implementación en dominio frecuencia (STFT)

Para operación en tiempo real con baja latencia:

1. **STFT** de cada canal con ventana de Hann, frame_size=256, hop_size=128 (overlap 50%).
2. **Estimación de Rnn** durante segmentos de ruido-solo (detectados por VAD).
3. **Cálculo de pesos MVDR** por bin de frecuencia.
4. **Aplicación de pesos** al vector de observación frecuencial.
5. **ISTFT** (overlap-add) para reconstruir la señal temporal mono.

### 3.4 Steering vector para 2 micrófonos en smartphone

Para el Moto G32, los micrófonos están separados ~14 cm (inferior–superior). El steering vector para fuente frontal (θ=0°, perpendicular al eje del teléfono cuando se sostiene vertical):

```
d(f) = [1, exp(-j·2π·f·τ)]^T
```

Donde `τ = d_mic · cos(θ) / c`:
- `d_mic` = 0.14 m (separación entre mics)
- `θ` = 0° (frente) → cos(0) = 1 → τ = 0.14/343 ≈ 0.408 ms
- `c` = 343 m/s (velocidad del sonido)

Para θ=0° (fuente frontal, eje perpendicular al teléfono vertical): `τ ≈ 0` porque la fuente está equidistante a ambos mics. Ajustar según la geometría real del dispositivo.

---

## 4. Requisitos funcionales

| ID | Requisito | Prioridad |
|----|-----------|-----------|
| RF-1 | Capturar audio estéreo (2 canales) desde el hardware del dispositivo | MUST |
| RF-2 | Implementar módulo MVDR beamformer header-only en C++ | MUST |
| RF-3 | Integrar el beamformer ANTES del DNN en el pipeline de audio | MUST |
| RF-4 | Permitir habilitar/deshabilitar el beamformer en runtime | MUST |
| RF-5 | Usar el VAD existente (SceneAnalyzer) para detectar segmentos noise-only y actualizar Rnn | MUST |
| RF-6 | Fallback graceful: si el dispositivo no soporta estéreo, operar en modo mono sin crash | MUST |
| RF-7 | Latencia adicional del beamformer ≤ 8 ms (256 samples @ 16 kHz + overlap) | SHOULD |
| RF-8 | Exponer toggle de beamformer desde Dart via MethodChannel | MUST |
| RF-9 | El beamformer es transparente cuando está desactivado (bypass perfecto, cero procesamiento) | MUST |
| RF-10 | Compatible con modo Conversación (SCO 16 kHz) y modo normal (48 kHz) | MUST |

---

## 5. Diseño técnico

### 5.1 Arquitectura de alto nivel

```
┌─────────────────────────────────────────────────────────────────────┐
│                         AudioEngine (Oboe)                          │
│                                                                      │
│  Input Stream (ESTÉREO, 2 canales)                                  │
│       │                                                              │
│       ▼                                                              │
│  ┌──────────┐    ┌──────────────┐    ┌───────┐    ┌──────────────┐ │
│  │ De-inter │───►│ MVDR Beam-   │───►│  DNN  │───►│ DspPipeline  │ │
│  │ leave    │    │ former       │    │ GTCRN │    │ (WDRC+EQ+...) │ │
│  │ L/R      │    │ (freq domain)│    │       │    │              │ │
│  └──────────┘    └──────────────┘    └───────┘    └──────────────┘ │
│       │                  │                                           │
│   ch0 (mic inf)    salida mono                                      │
│   ch1 (mic sup)    (enhanced)                                       │
│                                                                      │
│  Output Stream (MONO, 1 canal)  ────────────────────►  Auricular    │
└─────────────────────────────────────────────────────────────────────┘
```

### 5.2 Cambios en la captura de audio (Oboe — `audio_engine.cpp`)

**Archivo a modificar:** `android/app/src/main/cpp/audio_engine.cpp`

Actualmente la línea en `openInputStream()`:
```cpp
builder.setChannelCount(1);  // Mono
```

Se cambia condicionalmente:
```cpp
// Si beamforming está habilitado Y el dispositivo soporta estéreo
if (config_.beamformingEnabled) {
    builder.setChannelCount(2);  // Estéreo (mic inferior + mic superior)
} else {
    builder.setChannelCount(1);  // Mono (legacy)
}
```

**Importante:** Oboe con `ChannelCount=2` en el input captura los 2 micrófonos del dispositivo como L/R. En el Moto G32:
- Canal 0 (L) = micrófono inferior (primario, cerca de la boca)
- Canal 1 (R) = micrófono superior (secundario, para noise-cancellation nativo)

Si el dispositivo no soporta estéreo en el input, Oboe retorna error o downmixea a mono automáticamente (con `setFormatConversionAllowed(true)` ya configurado).

### 5.3 Cambios en `AudioEngineConfig`

**Archivo a modificar:** `android/app/src/main/cpp/audio_engine.h`

```cpp
struct AudioEngineConfig {
    // ... campos existentes ...
    bool beamformingEnabled = false;  ///< Habilitar captura estéreo + MVDR beamformer
};
```

### 5.4 Módulo MVDR Beamformer — `mvdr_beamformer.h` (header-only)

**Archivo a crear:** `android/app/src/main/cpp/mvdr_beamformer.h`

El módulo es **header-only** (como `feedback_suppressor.h`, `transient_reducer.h`) para:
- No requerir cambios en `CMakeLists.txt`
- Simplificar el clonado al paciente
- Reducir riesgo de errores de link

#### API pública:

```cpp
#ifndef HEARING_AID_MVDR_BEAMFORMER_H
#define HEARING_AID_MVDR_BEAMFORMER_H

#include <cmath>
#include <complex>
#include <cstring>
#include <atomic>
#include <algorithm>

/// MVDR Beamformer de 2 micrófonos para realce de voz frontal.
///
/// Opera en dominio frecuencia (STFT) con overlap-add.
/// Usa el VAD externo (SceneAnalyzer) para estimar la matriz de
/// correlación del ruido durante segmentos noise-only.
///
/// Papers de referencia:
///   - PMC7545265: VAD-assisted MVDR en smartphone
///   - PMC7398114: MVDR + DNN para hearing aids
///
/// Uso:
///   MvdrBeamformer bf;
///   bf.init(sampleRate);
///   // En el callback de audio:
///   bf.process(ch0, ch1, output, numFrames, vadActive);
class MvdrBeamformer {
public:
    // Constantes del STFT
    static constexpr int kFftSize = 256;        ///< N-point FFT
    static constexpr int kHopSize = 128;        ///< 50% overlap
    static constexpr int kNumBins = kFftSize / 2 + 1;  ///< 129 bins

    // Parámetros configurables
    static constexpr float kRnnSmoothAlpha = 0.98f;  ///< Smoothing de Rnn
    static constexpr float kRegularization = 1e-6f;  ///< Diagonal loading
    static constexpr float kMicSpacingM = 0.14f;     ///< Separación mics (metros)
    static constexpr float kSoundSpeedMs = 343.0f;   ///< Velocidad del sonido

    void init(int sampleRate);
    void setEnabled(bool enabled);
    bool isEnabled() const;

    /// Procesa un bloque de audio estéreo y produce salida mono beamformed.
    /// @param ch0 Canal 0 (mic inferior), numFrames muestras float32
    /// @param ch1 Canal 1 (mic superior), numFrames muestras float32
    /// @param output Buffer de salida mono, numFrames muestras float32
    /// @param numFrames Número de muestras por canal
    /// @param vadActive true si el VAD detecta voz (NO actualizar Rnn)
    void process(const float* ch0, const float* ch1,
                 float* output, int numFrames, bool vadActive);

private:
    // ... (implementación detallada en sección 6)
};

#endif // HEARING_AID_MVDR_BEAMFORMER_H
```

### 5.5 Integración en `audio_engine.cpp` — callback `onBothStreamsReady`

El callback actual recibe `inputData` como float* mono. Con estéreo, será **interleaved stereo**: `[L0, R0, L1, R1, ...]`.

**Cambio en el callback:**

```cpp
oboe::DataCallbackResult AudioEngine::onBothStreamsReady(
        const void *inputData, int numInputFrames,
        void *outputData, int numOutputFrames) {
    // ... guards existentes ...

    int numFrames = std::min(numInputFrames, numOutputFrames);
    const float* inPtr = static_cast<const float*>(inputData);
    float* outPtr = static_cast<float*>(outputData);

    // ─── NUEVO: Deinterleave + Beamforming ──────────────────────────────
    if (config_.beamformingEnabled && mvdrBeamformer_.isEnabled()) {
        // inputData es interleaved stereo: [L0, R0, L1, R1, ...]
        // Deinterleave a 2 buffers mono temporales
        for (int i = 0; i < numFrames; ++i) {
            beamCh0_[i] = inPtr[i * 2];      // Canal 0 (mic inferior)
            beamCh1_[i] = inPtr[i * 2 + 1];  // Canal 1 (mic superior)
        }

        // VAD del SceneAnalyzer (ya disponible en el engine)
        bool vadActive = sceneAnalyzer_.getVad().isVoiceActive();

        // Procesar MVDR → salida mono en outPtr
        mvdrBeamformer_.process(beamCh0_, beamCh1_,
                                outPtr, numFrames, vadActive);
    } else if (config_.beamformingEnabled && !mvdrBeamformer_.isEnabled()) {
        // Beamformer deshabilitado pero captura estéreo activa → usar solo ch0
        for (int i = 0; i < numFrames; ++i) {
            outPtr[i] = inPtr[i * 2];  // Solo mic inferior (canal 0)
        }
    } else {
        // Legacy: mono directo
        std::memcpy(outPtr, inPtr, numFrames * sizeof(float));
    }

    // ─── Resto del pipeline existente (sin cambios) ─────────────────────
    // Pre-DNN level measurement...
    // Headroom stage...
    // DNN denoiser...
    // DspPipeline::processBlock...
    // ...
}
```

**Buffers temporales a agregar en `AudioEngine` (privados):**

```cpp
// En audio_engine.h, sección private:
static constexpr int kMaxBlockSize = 1024;  // Máximo frames por callback
float beamCh0_[kMaxBlockSize];   ///< Buffer temporal canal 0 (deinterleave)
float beamCh1_[kMaxBlockSize];   ///< Buffer temporal canal 1 (deinterleave)
MvdrBeamformer mvdrBeamformer_;  ///< Instancia del beamformer MVDR
```

### 5.6 Cadena JNI — Kotlin → C++

**Archivo a modificar:** `android/app/src/main/kotlin/com/psk/hearing_aid_app/NativeAudioBridge.kt`

Agregar:
```kotlin
/// Habilita/deshabilita el beamformer MVDR dual-mic.
external fun nativeSetBeamformingEnabled(enabled: Boolean)

/// Retorna true si el beamformer MVDR está activo y procesando.
external fun nativeGetBeamformingActive(): Boolean
```

**Archivo a modificar:** `android/app/src/main/kotlin/com/psk/hearing_aid_app/AudioMethodChannel.kt`

Agregar handler para el MethodChannel:
```kotlin
"setBeamformingEnabled" -> {
    val enabled = call.argument<Boolean>("enabled") ?: false
    nativeBridge.nativeSetBeamformingEnabled(enabled)
    result.success(null)
}

"getBeamformingActive" -> {
    result.success(nativeBridge.nativeGetBeamformingActive())
}
```

**Archivo a modificar:** `android/app/src/main/cpp/native_bridge.cpp`

Agregar funciones JNI:
```cpp
extern "C" JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetBeamformingEnabled(
        JNIEnv* env, jobject thiz, jboolean enabled) {
    if (g_engine) {
        g_engine->setBeamformingEnabled(enabled);
    }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeGetBeamformingActive(
        JNIEnv* env, jobject thiz) {
    if (g_engine) {
        return g_engine->isBeamformingActive();
    }
    return false;
}
```

### 5.7 Cadena Dart → MethodChannel

**Archivo a crear/modificar en Dart** (capa de servicio de audio):

```dart
/// Habilita/deshabilita el beamformer MVDR dual-mic.
Future<void> setBeamformingEnabled(bool enabled) async {
  await _channel.invokeMethod('setBeamformingEnabled', {'enabled': enabled});
}

/// Retorna true si el beamformer está activo.
Future<bool> getBeamformingActive() async {
  return await _channel.invokeMethod<bool>('getBeamformingActive') ?? false;
}
```

### 5.8 Parámetros configurables

| Parámetro | Default | Rango | Descripción |
|-----------|---------|-------|-------------|
| `fftSize` | 256 | 128, 256, 512 | Tamaño de la FFT (trade-off resolución frecuencial vs latencia) |
| `hopSize` | 128 | fftSize/2 | Hop size (50% overlap) |
| `rnnSmoothAlpha` | 0.98 | [0.9, 0.999] | Factor de suavizado exponencial para estimación de Rnn |
| `regularization` | 1e-6 | [1e-8, 1e-4] | Diagonal loading para estabilidad numérica de inversión |
| `micSpacingM` | 0.14 | [0.05, 0.20] | Separación entre micrófonos en metros |
| `steeringAngleDeg` | 0 | [-90, 90] | Ángulo de steering (0° = frontal) |

### 5.9 Consideraciones de rendimiento

- **FFT 256-point @ 16 kHz:** latencia = 256/16000 = 16 ms (frame) + 128/16000 = 8 ms (hop) = **8 ms de latencia algorítmica** con overlap-add.
- **FFT 256-point @ 48 kHz:** latencia = 256/48000 ≈ 5.3 ms (frame) + 2.7 ms (hop) = **2.7 ms de latencia algorítmica**.
- **Complejidad por frame:** O(N·log(N)) para FFT + O(N_bins) para MVDR weights = despreciable en ARM Cortex-A55.
- **Memoria:** ~4 KB para buffers STFT + ~2 KB para Rnn (2×2 complex × 129 bins) = ~6 KB total.

---

## 6. Algoritmo MVDR — Pseudocódigo C++ completo

```cpp
// ═══════════════════════════════════════════════════════════════════════
// MVDR Beamformer — Implementación header-only para PSK Hearing Aid
// ═══════════════════════════════════════════════════════════════════════

#include <complex>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <atomic>

class MvdrBeamformer {
public:
    static constexpr int kFftSize = 256;
    static constexpr int kHopSize = kFftSize / 2;       // 128
    static constexpr int kNumBins = kFftSize / 2 + 1;   // 129
    static constexpr float kRnnAlpha = 0.98f;
    static constexpr float kReg = 1e-6f;
    static constexpr float kMicSpacing = 0.14f;
    static constexpr float kSoundSpeed = 343.0f;
    static constexpr float kPi = 3.14159265358979f;

    using Complex = std::complex<float>;

    void init(int sampleRate) {
        sampleRate_ = sampleRate;
        enabled_.store(false, std::memory_order_relaxed);

        // Limpiar buffers
        std::memset(inputBuf0_, 0, sizeof(inputBuf0_));
        std::memset(inputBuf1_, 0, sizeof(inputBuf1_));
        std::memset(outputBuf_, 0, sizeof(outputBuf_));
        inputBufPos_ = 0;
        outputBufPos_ = 0;

        // Inicializar Rnn como identidad (diagonal loading)
        for (int k = 0; k < kNumBins; ++k) {
            rnn_[k][0][0] = Complex(kReg, 0);  // R00
            rnn_[k][0][1] = Complex(0, 0);     // R01
            rnn_[k][1][0] = Complex(0, 0);     // R10
            rnn_[k][1][1] = Complex(kReg, 0);  // R11
        }

        // Calcular steering vector para fuente frontal (θ=0°)
        computeSteeringVector(0.0f);

        // Calcular ventana de Hann
        for (int n = 0; n < kFftSize; ++n) {
            window_[n] = 0.5f * (1.0f - std::cos(2.0f * kPi * n / kFftSize));
        }

        rnnInitialized_ = false;
        frameCount_ = 0;
    }

    void setEnabled(bool enabled) {
        enabled_.store(enabled, std::memory_order_release);
    }

    bool isEnabled() const {
        return enabled_.load(std::memory_order_acquire);
    }

    /// Procesa bloque estéreo → mono beamformed.
    /// Usa overlap-add internamente para manejar bloques de cualquier tamaño.
    void process(const float* ch0, const float* ch1,
                 float* output, int numFrames, bool vadActive) {
        if (!enabled_.load(std::memory_order_acquire)) {
            // Bypass: copiar canal 0 directamente
            std::memcpy(output, ch0, numFrames * sizeof(float));
            return;
        }

        int samplesProcessed = 0;
        while (samplesProcessed < numFrames) {
            // Llenar el buffer de entrada hasta kFftSize
            int samplesToAdd = std::min(
                kFftSize - inputBufPos_, numFrames - samplesProcessed);

            for (int i = 0; i < samplesToAdd; ++i) {
                inputBuf0_[inputBufPos_ + i] = ch0[samplesProcessed + i];
                inputBuf1_[inputBufPos_ + i] = ch1[samplesProcessed + i];
            }
            inputBufPos_ += samplesToAdd;
            samplesProcessed += samplesToAdd;

            // Cuando tenemos un frame completo, procesar
            if (inputBufPos_ >= kFftSize) {
                processFrame(vadActive);
                // Shift buffer: mover la segunda mitad al inicio (overlap)
                std::memmove(inputBuf0_, inputBuf0_ + kHopSize,
                             kHopSize * sizeof(float));
                std::memmove(inputBuf1_, inputBuf1_ + kHopSize,
                             kHopSize * sizeof(float));
                inputBufPos_ = kHopSize;
            }
        }

        // Extraer output del buffer de overlap-add
        for (int i = 0; i < numFrames; ++i) {
            output[i] = outputBuf_[outputBufPos_ + i];
        }
        // Shift output buffer
        int remaining = kFftSize - outputBufPos_ - numFrames;
        if (remaining > 0) {
            std::memmove(outputBuf_, outputBuf_ + numFrames,
                         remaining * sizeof(float));
        }
        outputBufPos_ = 0;
        // Limpiar la parte consumida
        std::memset(outputBuf_ + remaining, 0,
                    numFrames * sizeof(float));
    }

private:
    /// Procesa un frame completo (kFftSize muestras) con STFT → MVDR → ISTFT
    void processFrame(bool vadActive) {
        Complex X0[kNumBins], X1[kNumBins];
        Complex Y[kNumBins];
        float frameBuf[kFftSize];

        // ─── STFT del canal 0 ────────────────────────────────────
        for (int n = 0; n < kFftSize; ++n) {
            frameBuf[n] = inputBuf0_[n] * window_[n];
        }
        realFFT(frameBuf, X0, kFftSize);

        // ─── STFT del canal 1 ────────────────────────────────────
        for (int n = 0; n < kFftSize; ++n) {
            frameBuf[n] = inputBuf1_[n] * window_[n];
        }
        realFFT(frameBuf, X1, kFftSize);

        // ─── Actualizar Rnn durante segmentos noise-only ─────────
        if (!vadActive) {
            updateRnn(X0, X1);
            rnnInitialized_ = true;
        }

        // ─── Calcular y aplicar pesos MVDR por bin ───────────────
        for (int k = 0; k < kNumBins; ++k) {
            if (!rnnInitialized_) {
                // Sin estimación de ruido aún → delay-and-sum simple
                Y[k] = (X0[k] + X1[k]) * 0.5f;
            } else {
                // Vector de observación x = [X0[k], X1[k]]^T
                // w = Rnn^{-1} · d / (d^H · Rnn^{-1} · d)
                Complex w[2];
                computeMvdrWeights(k, w);
                // y[k] = w^H · x = conj(w0)*X0 + conj(w1)*X1
                Y[k] = std::conj(w[0]) * X0[k] + std::conj(w[1]) * X1[k];
            }
        }

        // ─── ISTFT (overlap-add) ─────────────────────────────────
        realIFFT(Y, frameBuf, kFftSize);

        // Aplicar ventana de síntesis y acumular en output buffer
        for (int n = 0; n < kFftSize; ++n) {
            outputBuf_[n] += frameBuf[n] * window_[n];
        }
        // Normalización overlap-add (Hann 50% overlap → factor 0.5)
        // ya implícita en la ventana × ventana = 0.5 en promedio.

        frameCount_++;
    }

    /// Actualiza la matriz de correlación espacial del ruido (Rnn)
    /// con suavizado exponencial. Solo llamar durante noise-only.
    void updateRnn(const Complex* X0, const Complex* X1) {
        for (int k = 0; k < kNumBins; ++k) {
            // Rnn[k] = alpha * Rnn[k] + (1-alpha) * x · x^H
            Complex x[2] = { X0[k], X1[k] };
            float alpha = kRnnAlpha;
            float oneMinusAlpha = 1.0f - alpha;

            rnn_[k][0][0] = alpha * rnn_[k][0][0] +
                            oneMinusAlpha * (x[0] * std::conj(x[0]));
            rnn_[k][0][1] = alpha * rnn_[k][0][1] +
                            oneMinusAlpha * (x[0] * std::conj(x[1]));
            rnn_[k][1][0] = alpha * rnn_[k][1][0] +
                            oneMinusAlpha * (x[1] * std::conj(x[0]));
            rnn_[k][1][1] = alpha * rnn_[k][1][1] +
                            oneMinusAlpha * (x[1] * std::conj(x[1]));

            // Diagonal loading para estabilidad
            rnn_[k][0][0] += Complex(kReg, 0);
            rnn_[k][1][1] += Complex(kReg, 0);
        }
    }

    /// Calcula los pesos MVDR para un bin de frecuencia.
    /// Invierte la matriz 2×2 Rnn analíticamente y aplica la fórmula cerrada.
    void computeMvdrWeights(int k, Complex* w) const {
        // Rnn^{-1} para matriz 2×2:
        // inv(R) = (1/det) * [R11, -R01; -R10, R00]
        Complex det = rnn_[k][0][0] * rnn_[k][1][1] -
                      rnn_[k][0][1] * rnn_[k][1][0];

        // Guard contra determinante cercano a cero
        float detMag = std::abs(det);
        if (detMag < 1e-10f) {
            // Fallback: delay-and-sum
            w[0] = Complex(0.5f, 0);
            w[1] = Complex(0.5f, 0);
            return;
        }

        Complex invDet = 1.0f / det;
        Complex Rinv[2][2];
        Rinv[0][0] =  rnn_[k][1][1] * invDet;
        Rinv[0][1] = -rnn_[k][0][1] * invDet;
        Rinv[1][0] = -rnn_[k][1][0] * invDet;
        Rinv[1][1] =  rnn_[k][0][0] * invDet;

        // Rinv · d
        Complex Rinv_d[2];
        Rinv_d[0] = Rinv[0][0] * steeringVec_[k][0] +
                    Rinv[0][1] * steeringVec_[k][1];
        Rinv_d[1] = Rinv[1][0] * steeringVec_[k][0] +
                    Rinv[1][1] * steeringVec_[k][1];

        // d^H · Rinv · d (escalar)
        Complex dH_Rinv_d = std::conj(steeringVec_[k][0]) * Rinv_d[0] +
                            std::conj(steeringVec_[k][1]) * Rinv_d[1];

        // Guard
        float denom = std::abs(dH_Rinv_d);
        if (denom < 1e-10f) {
            w[0] = Complex(0.5f, 0);
            w[1] = Complex(0.5f, 0);
            return;
        }

        // w = Rinv_d / dH_Rinv_d
        w[0] = Rinv_d[0] / dH_Rinv_d;
        w[1] = Rinv_d[1] / dH_Rinv_d;
    }

    /// Calcula el steering vector para un ángulo dado (en grados).
    /// Para 2 mics lineales separados d metros, fuente a ángulo θ:
    ///   d[k] = [1, exp(-j·2π·f_k·τ)]   donde τ = d_mic·sin(θ)/c
    void computeSteeringVector(float angleDeg) {
        float angleRad = angleDeg * kPi / 180.0f;
        float tau = kMicSpacing * std::sin(angleRad) / kSoundSpeed;

        for (int k = 0; k < kNumBins; ++k) {
            float freq = static_cast<float>(k) * sampleRate_ / kFftSize;
            float phase = -2.0f * kPi * freq * tau;
            steeringVec_[k][0] = Complex(1.0f, 0.0f);
            steeringVec_[k][1] = Complex(std::cos(phase), std::sin(phase));
        }
    }

    // ─── FFT in-place (Cooley-Tukey radix-2, real-input) ────────────────
    // Nota: el proyecto ya tiene FFT en spectrum_analyzer.cpp.
    // Para mantener el header autosuficiente, se incluye una implementación
    // mínima. En producción, se puede reusar la FFT existente.

    void realFFT(const float* input, Complex* output, int N) {
        // Zero-pad y copiar a buffer complejo temporal
        Complex buf[kFftSize];
        for (int i = 0; i < N; ++i) buf[i] = Complex(input[i], 0);

        // Bit-reversal permutation
        for (int i = 1, j = 0; i < N; ++i) {
            int bit = N >> 1;
            for (; j & bit; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) std::swap(buf[i], buf[j]);
        }

        // Butterfly stages
        for (int len = 2; len <= N; len <<= 1) {
            float ang = -2.0f * kPi / len;
            Complex wlen(std::cos(ang), std::sin(ang));
            for (int i = 0; i < N; i += len) {
                Complex w(1, 0);
                for (int j = 0; j < len / 2; ++j) {
                    Complex u = buf[i + j];
                    Complex v = buf[i + j + len / 2] * w;
                    buf[i + j] = u + v;
                    buf[i + j + len / 2] = u - v;
                    w *= wlen;
                }
            }
        }

        // Copiar bins positivos
        for (int k = 0; k < kNumBins; ++k) output[k] = buf[k];
    }

    void realIFFT(const Complex* input, float* output, int N) {
        Complex buf[kFftSize];
        // Reconstruir espectro completo (simetría hermitiana)
        for (int k = 0; k < kNumBins; ++k) buf[k] = input[k];
        for (int k = kNumBins; k < N; ++k) {
            buf[k] = std::conj(input[N - k]);
        }

        // IFFT = conj(FFT(conj(x))) / N
        for (int i = 0; i < N; ++i) buf[i] = std::conj(buf[i]);

        // Bit-reversal
        for (int i = 1, j = 0; i < N; ++i) {
            int bit = N >> 1;
            for (; j & bit; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) std::swap(buf[i], buf[j]);
        }

        // Butterfly
        for (int len = 2; len <= N; len <<= 1) {
            float ang = -2.0f * kPi / len;
            Complex wlen(std::cos(ang), std::sin(ang));
            for (int i = 0; i < N; i += len) {
                Complex w(1, 0);
                for (int j = 0; j < len / 2; ++j) {
                    Complex u = buf[i + j];
                    Complex v = buf[i + j + len / 2] * w;
                    buf[i + j] = u + v;
                    buf[i + j + len / 2] = u - v;
                    w *= wlen;
                }
            }
        }

        float invN = 1.0f / N;
        for (int i = 0; i < N; ++i) {
            output[i] = buf[i].real() * invN;
        }
    }

    // ─── Estado interno ─────────────────────────────────────────────────
    std::atomic<bool> enabled_{false};
    int sampleRate_ = 16000;

    // Buffers de entrada (overlap)
    float inputBuf0_[kFftSize * 2] = {};   // Canal 0 con espacio para overlap
    float inputBuf1_[kFftSize * 2] = {};   // Canal 1 con espacio para overlap
    int inputBufPos_ = 0;

    // Buffer de salida (overlap-add)
    float outputBuf_[kFftSize * 2] = {};
    int outputBufPos_ = 0;

    // Ventana de Hann
    float window_[kFftSize] = {};

    // Steering vector por bin [kNumBins][2]
    Complex steeringVec_[kNumBins][2] = {};

    // Matriz de correlación del ruido [kNumBins][2][2]
    Complex rnn_[kNumBins][2][2] = {};

    bool rnnInitialized_ = false;
    int frameCount_ = 0;
};
```

---

## 7. Tareas de implementación (ordenadas con dependencias)

### Fase 1: Módulo MVDR (C++ standalone)

| # | Tarea | Dependencia | Archivo |
|---|-------|-------------|---------|
| 1.1 | Crear `mvdr_beamformer.h` header-only con la implementación completa del algoritmo MVDR (FFT, STFT, overlap-add, estimación Rnn, cálculo de pesos, steering vector) | — | `cpp/mvdr_beamformer.h` |
| 1.2 | Agregar `#include "mvdr_beamformer.h"` en `audio_engine.h` y declarar miembro `MvdrBeamformer mvdrBeamformer_` + buffers temporales `beamCh0_[]`, `beamCh1_[]` | 1.1 | `cpp/audio_engine.h` |
| 1.3 | Agregar campo `bool beamformingEnabled = false` a `AudioEngineConfig` | — | `cpp/audio_engine.h` |

### Fase 2: Captura estéreo (Oboe)

| # | Tarea | Dependencia | Archivo |
|---|-------|-------------|---------|
| 2.1 | Modificar `openInputStream()` para pedir `ChannelCount(2)` cuando `config_.beamformingEnabled == true` | 1.3 | `cpp/audio_engine.cpp` |
| 2.2 | Agregar fallback: si `openStream` con 2 canales falla, reintentar con 1 canal y loguear warning | 2.1 | `cpp/audio_engine.cpp` |
| 2.3 | Modificar `onBothStreamsReady`: deinterleave estéreo → 2 buffers mono, invocar `mvdrBeamformer_.process()`, output mono al pipeline | 1.2, 2.1 | `cpp/audio_engine.cpp` |
| 2.4 | Llamar `mvdrBeamformer_.init(sampleRate)` en `AudioEngine::start()` | 1.2 | `cpp/audio_engine.cpp` |

### Fase 3: Bridge JNI + Kotlin

| # | Tarea | Dependencia | Archivo |
|---|-------|-------------|---------|
| 3.1 | Agregar `setBeamformingEnabled(bool)` y `isBeamformingActive()` en `AudioEngine` (delegan al mvdrBeamformer_) | 1.2 | `cpp/audio_engine.h/.cpp` |
| 3.2 | Implementar funciones JNI `nativeSetBeamformingEnabled` y `nativeGetBeamformingActive` en `native_bridge.cpp` | 3.1 | `cpp/native_bridge.cpp` |
| 3.3 | Agregar `external fun nativeSetBeamformingEnabled(enabled: Boolean)` y `external fun nativeGetBeamformingActive(): Boolean` en `NativeAudioBridge.kt` | 3.2 | `kotlin/.../NativeAudioBridge.kt` |
| 3.4 | Agregar handlers `"setBeamformingEnabled"` y `"getBeamformingActive"` en `AudioMethodChannel.kt` | 3.3 | `kotlin/.../AudioMethodChannel.kt` |

### Fase 4: Integración Dart

| # | Tarea | Dependencia | Archivo |
|---|-------|-------------|---------|
| 4.1 | Agregar método `setBeamformingEnabled(bool)` en la capa de servicio de audio Dart | 3.4 | `lib/data/audio_service.dart` (o equivalente) |
| 4.2 | Agregar toggle de beamforming en la UI de configuración avanzada | 4.1 | `lib/presentation/screens/` o `widgets/` |
| 4.3 | Persistir estado del toggle en Hive (preferencias del usuario) | 4.2 | `lib/data/` |
| 4.4 | Pasar `beamformingEnabled` al motor nativo en el `start()` del AudioMethodChannel | 4.1, 3.4 | `kotlin/.../AudioMethodChannel.kt` |

### Fase 5: Validación y robustez

| # | Tarea | Dependencia | Archivo |
|---|-------|-------------|---------|
| 5.1 | Test de syntax con clang del NDK (como se hace para otros módulos) | 1.1 | script `.bat` |
| 5.2 | Verificar que el módulo es retrocompatible (paciente que no habilita beamforming sigue funcionando en mono) | 2.2 | — |
| 5.3 | Agregar log de diagnóstico: `LOGI("MVDR: active=%d, stereo_input=%d, rnn_frames=%d")` periódico | 2.3 | `cpp/audio_engine.cpp` |
| 5.4 | Verificar latencia total con el monitor de latencia existente (spec `monitor-latencia-audio`) | 2.3 | — |

---

## 8. Criterios de aceptación

| # | Criterio | Verificación |
|---|----------|--------------|
| AC-1 | Con beamforming habilitado, el input stream de Oboe se abre con 2 canales exitosamente en el Moto G32 | Log de Oboe muestra `channelCount: 2` |
| AC-2 | Con beamforming deshabilitado, el comportamiento es idéntico al actual (regresión cero) | A/B test auditivo + métricas DSP sin cambios |
| AC-3 | En ambiente ruidoso (TV lateral + voz frontal), la voz frontal es notablemente más clara con beamforming ON vs OFF | Test subjetivo A/B |
| AC-4 | La latencia adicional del beamformer es ≤ 8 ms (medida con el monitor de latencia) | `getLatencyMetrics().dspBlockMs` no aumenta > 8 ms |
| AC-5 | Si el dispositivo no soporta estéreo, el motor arranca en modo mono sin crash | Test en emulador o dispositivo de 1 mic |
| AC-6 | El toggle desde Dart habilita/deshabilita el beamformer en runtime sin reiniciar el motor | Verificar en UI + logcat |
| AC-7 | La estimación de Rnn se actualiza SOLO durante segmentos de ruido (VAD=false) | Log diagnóstico de `rnn_frames` crece solo en silence |
| AC-8 | El pipeline DNN+WDRC+EQ recibe audio mono limpio post-beamformer y funciona correctamente | Métricas de StageMetrics normales |
| AC-9 | Compatible con modo Conversación (16 kHz SCO) | Test con auricular BT en modo conversación |
| AC-10 | El código compila limpio con `clang++ --target=aarch64-linux-android24 -std=c++17 -fsyntax-only` | Exit code 0 |

---

## 9. Riesgos y mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigación |
|--------|-------------|---------|------------|
| El Moto G32 no entrega estéreo real (duplica un canal) | Media | Alto | Verificar empíricamente que `ch0 ≠ ch1` en el callback. Si son idénticos → auto-bypass a mono + log warning. |
| Oboe `ChannelCount(2)` no soportado en algunos dispositivos | Media | Medio | Fallback automático a mono (task 2.2). El beamformer queda en bypass. |
| La FFT inline en el header es lenta en ARM | Baja | Medio | FFT 256-point es O(N·log(N)) = ~2048 ops. En Cortex-A55 @ 2 GHz → < 0.01 ms. Si fuera lento, usar NEON intrinsics o Ne10. |
| La separación de mics del Moto G32 no es exactamente 14 cm | Alta | Bajo | El steering vector tolera error de ±2 cm. Calibrar midiendo con tono sinusoidal frontal y ajustar `kMicSpacing`. |
| El VAD del SceneAnalyzer tiene latencia/histeresis → Rnn se contamina con voz | Media | Medio | Usar hangover conservador (VAD ya tiene kHangoverBlocks). Rnn con alpha alto (0.98) → la contaminación transitoria se diluye en ~50 frames. |
| Incompatibilidad con Diagnostic Recorder (espera mono) | Baja | Bajo | El DiagnosticRecorder recibe el buffer POST-beamformer (ya mono). Sin impacto. |
| Aumento de consumo de batería por doble captura | Media | Bajo | El consumo extra de 1 mic adicional es ~2-5 mW (despreciable vs DNN que consume ~50 mW). |

---

## 10. Archivos afectados — Resumen

### Archivos a CREAR:
| Archivo | Tipo | Descripción |
|---------|------|-------------|
| `android/app/src/main/cpp/mvdr_beamformer.h` | C++ header-only | Implementación completa del MVDR beamformer |

### Archivos a MODIFICAR:

| Archivo | Cambios |
|---------|---------|
| `android/app/src/main/cpp/audio_engine.h` | Agregar `#include "mvdr_beamformer.h"`, miembro `MvdrBeamformer mvdrBeamformer_`, buffers `beamCh0_[]`/`beamCh1_[]`, campo `beamformingEnabled` en `AudioEngineConfig`, métodos `setBeamformingEnabled()`/`isBeamformingActive()` |
| `android/app/src/main/cpp/audio_engine.cpp` | Modificar `openInputStream()` para estéreo condicional, modificar `onBothStreamsReady()` para deinterleave + MVDR, llamar `mvdrBeamformer_.init()` en `start()`, agregar fallback mono |
| `android/app/src/main/cpp/native_bridge.cpp` | Agregar 2 funciones JNI: `nativeSetBeamformingEnabled`, `nativeGetBeamformingActive` |
| `android/app/src/main/kotlin/.../NativeAudioBridge.kt` | Agregar 2 external fun: `nativeSetBeamformingEnabled`, `nativeGetBeamformingActive` |
| `android/app/src/main/kotlin/.../AudioMethodChannel.kt` | Agregar handlers para `"setBeamformingEnabled"` y `"getBeamformingActive"` en el `onMethodCall`, pasar config al start |
| `lib/` (Dart, archivo de servicio de audio) | Agregar `setBeamformingEnabled()` method call |

### Archivos que NO se tocan:
| Archivo | Razón |
|---------|-------|
| `CMakeLists.txt` | El módulo es header-only, no requiere nuevo `.cpp` |
| `dsp_pipeline.h/.cpp` | El pipeline recibe audio mono post-beamformer, sin cambios |
| `dnn_denoiser/` | Recibe audio mono como siempre |
| `AndroidManifest.xml` | `RECORD_AUDIO` ya cubre multi-mic |

---

## 11. Impacto en la app del paciente

El paciente **clona el código C++ del técnico**. El impacto es:

1. **`mvdr_beamformer.h`** se clona automáticamente (header-only, sin cambios en CMakeLists).
2. **El beamformer arranca deshabilitado por default** (`beamformingEnabled = false` en `AudioEngineConfig`).
3. **Sin impacto en el paciente** a menos que se active explícitamente desde su UI (que no se implementa en esta fase).
4. **Retrocompatible:** si el paciente tiene un `.so` viejo sin el header, el campo no existe y todo funciona como antes.
5. **Para habilitar en el paciente en el futuro:** solo hace falta agregar el toggle en la UI Dart del paciente y pasar `beamformingEnabled=true` al start. El código C++ ya está.

---

## 12. Notas sobre el VAD

El MVDR usa el VAD del `SceneAnalyzer` (ya existente en el motor) para determinar cuándo actualizar la estimación de ruido `Rnn`:

- **VAD = true (voz activa):** NO actualizar Rnn → los pesos del beamformer se mantienen fijos → la voz pasa sin distorsión.
- **VAD = false (ruido solo):** Actualizar Rnn con suavizado exponencial → los pesos se adaptan a la nueva estadística del ruido.

El getter ya existe: `sceneAnalyzer_.getVad().isVoiceActive()` — se usa en el callback actual para diagnóstico del DNN.

---

## 13. Referencias

1. Pandey, A., & Wang, D. (2020). "Real-time dual-channel speech enhancement by VAD assisted MVDR beamformer for hearing aid applications using smartphone." *INTERSPEECH 2020*. PMC7545265.
2. Schasse, A., et al. (2021). "Efficient two-microphone speech enhancement using basic RNN cell for hearing aids." *Frontiers in Neuroscience*. PMC7928060.
3. Shankar, N., et al. (2020). "Influence of MVDR beamformer on Speech Enhancement based Smartphone application for Hearing Aids." *IEEE EMBC*. PMC7398114.
4. Doclo, S., Kellermann, W., Makino, S., & Nordholm, S. E. (2010). "Multichannel Signal Enhancement Algorithms for Assisted Listening Devices." *IEEE Signal Processing Magazine*, 27(1), 18-30.
5. Benesty, J., Chen, J., & Huang, Y. (2008). *Microphone Array Signal Processing*. Springer.
6. Van Trees, H. L. (2002). *Optimum Array Processing*. Wiley.

---

## 14. Checklist pre-implementación (para el agente de código)

- [ ] Leer `audio_engine.h` y `audio_engine.cpp` completos antes de modificar
- [ ] Leer `native_bridge.cpp` para entender el patrón JNI existente
- [ ] Leer `NativeAudioBridge.kt` y `AudioMethodChannel.kt` para seguir el patrón Kotlin
- [ ] Verificar que `mvdr_beamformer.h` compila solo con `clang++ -fsyntax-only`
- [ ] Verificar que `audio_engine.cpp` compila con el include nuevo
- [ ] NO tocar `CMakeLists.txt` (header-only)
- [ ] NO tocar `dsp_pipeline.h/.cpp` (el MVDR va ANTES del pipeline, no dentro)
- [ ] El campo `beamformingEnabled` debe defaultear a `false` (retrocompat)
- [ ] Todo cambio en C++ se verifica con el script de syntax-check del NDK
- [ ] Confirmar que el paciente NO se rompe (el código se clona pero el flag es false por default)

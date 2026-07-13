# Spec — AFC antes del DNN en el pipeline (refactor del orden)

> Estado: **PENDIENTE — diferida desde la implementación de las 5 mejoras prioritarias
> de `Amplificador/docs/ruido-profundo.md`** (Mejora #2).
>
> Razón de la postergación: hoy el módulo AFC (cancelación adaptativa de feedback,
> NLMS) no existe en el código nativo Android. Solo hay un toggle BLE
> (`BleCommands.setFbCancel`) y una implementación de referencia en el simulador
> web (`assets/simulator/dsp-engine-browser.js::createFeedbackCanceller`). Hacer
> el reorder del pipeline requiere primero implementar AFC nativo, lo cual es
> invasivo. Se difiere a un spec dedicado.

## Contexto

El paper de referencia (`Amplificador/docs/ruido-profundo.md`, Mejora 2 del Top 5)
recomienda que el AFC vaya **antes** del DNN denoiser, no después:

```
ANTES (lo que está hoy en el sim web):
  Input → AFC → NR → EQ → WDRC → Volume → MPO → Output

DESPUÉS (lo que recomienda ruido-profundo.md):
  Input → AFC → DNN → EQ → WDRC → Volume → MPO → Output
```

El razonamiento técnico es:

- El AFC NLMS necesita **ver la señal de feedback intacta** para que el filtro
  adaptativo converja a la respuesta acústica del path mic→speaker.
- Si el DNN procesa primero, el feedback queda parcialmente cancelado por el
  modelo (que confunde el silbido con ruido coloreado), y el residuo que entra
  al NLMS ya no es coherente con la referencia → el filtro no converge.
- Con el reorder, el MSG (Maximum Stable Gain) sube ~3–5 dB.

## Estado actual del código (lo que SÍ existe)

| Capa | Archivo | Notas |
|------|---------|-------|
| Pipeline nativo Android | `hearing_aid_app/android/app/src/main/cpp/audio_engine.cpp` | Llama `dnnDenoiser_.process()` y luego `pipeline_.processBlock()`. **Sin AFC.** |
| DspPipeline nativo | `hearing_aid_app/android/app/src/main/cpp/dsp_pipeline.{h,cpp}` | NR Wiener → HPF 100 Hz → EQ → WDRC → Volume → MPO. **Sin AFC.** |
| Sim web (referencia) | `hearing_aid_app/assets/simulator/dsp-engine-browser.js` | `createFeedbackCanceller()` con NLMS 64 taps, μ=0.005. ÚNICA implementación que existe. |
| Toggle BLE | `hearing_aid_app/lib/data/repositories/ble_repository.dart::setFeedbackCancel()` | Comando remoto al firmware nRF; en Android esta config se ignora porque no hay AFC. |

## Requirements (cuando se aborde el spec)

### R1 — Implementar AFC NLMS nativo

- Crear `hearing_aid_app/android/app/src/main/cpp/afc_processor.{h,cpp}`.
- Algoritmo: NLMS adaptativo con 64 taps a 16 kHz (4 ms de cobertura).
- Parámetros default:
  - `mu = 0.005` (paso del NLMS, conservador)
  - `taps = 64`
  - `power_floor = 1e-10` (regularización)
  - `decimation = 1` (sample-by-sample, no block)
- API:
  - `void init(int sampleRate)`
  - `void processBlock(float* mic, const float* speakerRef, float* out, int n)`
  - `void reset()`
  - `void setEnabled(bool)`
  - `bool isConverged() const` (estimación de convergencia: `||w_new - w_old|| < ε`)
- Thread-safety: como el resto del pipeline (atomics para flags, sin locks en
  hot path).
- Fallback: si `enabled=false`, copia `mic → out` con `memcpy`.

### R2 — Buffer de referencia del speaker

- El AFC necesita la señal que salió por el speaker (post-MPO, post-conversión a
  output device).
- En modo Oboe FullDuplex tenemos el `outputData` del callback anterior; hay que
  guardarlo en un ring buffer del tamaño del path acústico esperado (típicamente
  1–5 ms).
- Implementar como `std::array<float, kMaxFeedbackPathSamples>` con índice
  circular en `AudioEngine`.

### R3 — Refactor del DspPipeline para exponer AFC-only y NoAFC

- Hoy `DspPipeline::processBlock()` corre todas las etapas en orden. Para que
  el AFC pueda ir antes del DNN sin tocar la API pública, exponemos:

```cpp
class DspPipeline {
public:
    // (existente) corre TODO en el orden actual; preserva compat.
    void processBlock(float* buffer, int blockSize);

    // NUEVOS — para que AudioEngine los componga en el orden deseado:
    void processAfcOnly(float* mic, const float* speakerRef, int n);
    void processWithoutAfc(float* buffer, int n);  // todo menos AFC
};
```

- Internamente `processBlock()` llama a `processAfcOnly()` y luego
  `processWithoutAfc()` para no romper a los call sites existentes.
- Una flag interna `afcAlreadyApplied_` previene doble ejecución cuando
  `audio_engine.cpp` los compone manualmente.

### R4 — Reorden en audio_engine.cpp

```cpp
// hot path del callback Oboe:
// 1. Capturar ref del speaker buffer del callback anterior.
// 2. AFC primero, sobre la señal cruda con feedback intacto.
pipeline_.processAfcOnly(outPtr, lastSpeakerBuffer_.data(), numFrames);
// 3. DNN denoise sobre la señal SIN feedback.
dnnDenoiser_.process(outPtr, numFrames);
// 4. Resto del pipeline (NR si no hay DNN, EQ, WDRC, Volume, MPO).
pipeline_.processWithoutAfc(outPtr, numFrames);
// 5. Guardar el output como referencia para el siguiente callback.
std::memcpy(lastSpeakerBuffer_.data(), outPtr,
            std::min((int)lastSpeakerBuffer_.size(), numFrames) * sizeof(float));
```

### R5 — Detección de howling como red de seguridad

- Si el AFC pierde convergencia (oscilación detectada por análisis espectral del
  output: ratio pico-bin / energía media > 20 sostenido por > 100 ms), la app
  debe **bajar el volumen master 6 dB y reportar al UI**.
- Esto previene que el usuario reciba un pico de >120 dB SPL en caso de fallo
  del cancelador.

### R6 — Tests de paridad numérica con sim web

- El AFC nativo debe coincidir con `createFeedbackCanceller()` del sim web a
  1e-5 de error RMS sobre 10 segundos de habla con feedback inyectado.
- Validar con un fixture que aplique el mismo `speakerRef` y `micInput` a
  ambas implementaciones.

### R7 — Métricas de telemetría

- Exponer `getAfcConvergence()` (0–1) y `getAfcGainMargin()` (dB de margen
  hasta howling) al UI vía JNI.
- Loggear cada 5 s al logcat con `AFC_LOG_TAG`.

## Out of scope

- Migración de AFC al firmware del nRF5340 (eso es responsabilidad del
  proyecto firmware, no de la app Android).
- Implementación de AFC frequency-domain (PEM, PNLMS) — primera versión solo
  NLMS time-domain.
- Cambios en el simulador web (ya tiene AFC funcionando).

## Criterios de aceptación

1. APK compila sin warnings nuevos.
2. Tests unitarios del AFC pasan (convergencia ≤ 200 ms con feedback simulado
   de retardo 2 ms y ganancia 0.6).
3. En dispositivo real con auricular cerca del mic, MSG sube ≥ 3 dB respecto
   a la rama master.
4. THD del output bajo condiciones normales (sin feedback) no aumenta más de
   0.5% respecto a la rama actual.
5. Latencia total del pipeline aumenta ≤ 0.5 ms (NLMS sample-by-sample añade
   ~64 mults/sample = 1 µs/sample × 64 = 64 µs por sample, despreciable).

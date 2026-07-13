# Design — AFC antes del DNN en el pipeline (refactor del orden)

> Estado: **PENDIENTE — diferida desde la implementación de las 5 mejoras prioritarias.**
> Lee `requirements.md` antes de este documento.

## Vista general

```
┌──────┐   ┌─────┐   ┌─────┐   ┌──────────┐   ┌────┐   ┌──────┐   ┌─────┐   ┌──────┐   ┌────────┐   ┌──────┐
│ Mic  │──▶│ HPF │──▶│ AFC │──▶│  DNN     │──▶│ NR │──▶│  EQ  │──▶│WDRC │──▶│Volume│──▶│  MPO   │──▶│ Spk  │
│Float │   │100Hz│   │NLMS │   │ GTCRN    │   │Wien│   │12Bnd │   │3-Reg│   │Master│   │PeakLim │   │Float │
└──────┘   └─────┘   └─────┘   └──────────┘   └────┘   └──────┘   └─────┘   └──────┘   └────────┘   └──────┘
                       ▲                                                                                  │
                       │                                                                                  │
                       └──────────────────────── speakerRef (delay 1 callback) ◀─────────────────────────┘
```

Notas clave:

- El **HPF 100 Hz** se mantiene antes del AFC para quitar DC y rumble (mejora
  la convergencia del NLMS al no perseguir DC).
- El **AFC** opera sample-by-sample con NLMS clásico de 64 taps.
- El **DNN GTCRN** ve la señal sin feedback, por eso no la confunde con ruido.
- Cuando DNN está activo, el **NR Wiener** queda bypassed (como hoy).
- El **NR Wiener** sigue como fallback cuando el DNN está apagado (toggle del
  usuario o modelo no cargado).
- El **MPO** sigue siendo la última red de seguridad sample-by-sample.

## Cambios por archivo

### `audio_engine.cpp`

```cpp
// Nuevo: ring buffer del último output enviado al speaker.
// Sirve como referencia para el AFC en el callback siguiente.
class AudioEngine : public oboe::FullDuplexStream {
private:
    // ...existing...

    // MEJORA #2 (ruido-profundo.md): buffer de referencia para AFC.
    // Tamaño = max delay del path acústico esperado (5 ms a 48 kHz = 240 samples).
    // Round-up a potencia de 2 → 256.
    static constexpr int kSpeakerRefSize = 256;
    std::array<float, kSpeakerRefSize> lastSpeakerBuffer_{};
    int lastSpeakerLen_ = 0;
};

oboe::DataCallbackResult AudioEngine::onBothStreamsReady(...) {
    // ...input → outPtr...

    // MEJORA #2 (ruido-profundo.md): AFC ANTES del DNN.
    // El NLMS necesita ver el feedback intacto para que el filtro adapte
    // al path acústico mic→speaker. Si el DNN procesara primero, el feedback
    // queda parcialmente cancelado y el residuo no es coherente con la
    // referencia → el filtro no converge → MSG queda 3–5 dB peor.
    pipeline_.processAfcOnly(outPtr,
                             lastSpeakerBuffer_.data(),
                             std::min(lastSpeakerLen_, numFrames));

    // DNN denoise sobre señal sin feedback.
    dnnDenoiser_.process(outPtr, numFrames);

    // Resto del pipeline (NR/EQ/WDRC/Volume/MPO) sin volver a aplicar AFC.
    pipeline_.processWithoutAfc(outPtr, numFrames);

    // Guardar el output como referencia para el callback siguiente.
    const int copyLen = std::min((int)kSpeakerRefSize, numFrames);
    std::memcpy(lastSpeakerBuffer_.data(),
                outPtr + (numFrames - copyLen),
                copyLen * sizeof(float));
    lastSpeakerLen_ = copyLen;

    // ...resto del callback...
}
```

### `dsp_pipeline.h`

```cpp
class DspPipeline {
public:
    // (compat — sigue corriendo TODO en el orden actual incluyendo AFC interno).
    void processBlock(float* buffer, int blockSize);

    // MEJORA #2 (ruido-profundo.md) — composición manual desde audio_engine.cpp:
    /// Solo aplica AFC sample-by-sample. Marca interno `afcAlreadyApplied_=true`
    /// para que `processBlock()` y `processWithoutAfc()` no lo repitan.
    void processAfcOnly(float* mic, const float* speakerRef, int n);

    /// Aplica todo el pipeline EXCEPTO AFC. Si `processAfcOnly` ya corrió en
    /// este block, simplemente continúa desde NR.
    void processWithoutAfc(float* buffer, int n);

private:
    AfcProcessor afc_;
    bool afcAlreadyApplied_ = false;  // reseteado al final de cada block
};
```

`processBlock()` queda así:

```cpp
void DspPipeline::processBlock(float* buffer, int blockSize) {
    // Compat: si nadie llamó processAfcOnly, lo aplicamos acá con un
    // speakerRef vacío (efectivamente no cancela, pero no rompe build).
    if (!afcAlreadyApplied_) {
        std::array<float, 256> emptyRef{};
        afc_.processBlock(buffer, emptyRef.data(),
                          std::min(blockSize, 256));
    }
    afcAlreadyApplied_ = false;  // reset para el próximo block

    // ... resto del pipeline (HPF → NR → EQ → WDRC → Volume → MPO).
}
```

### `afc_processor.h` (NUEVO)

```cpp
class AfcProcessor {
public:
    void init(int sampleRate);
    void processBlock(float* mic, const float* speakerRef, int n);
    void reset();
    void setEnabled(bool enabled) { enabled_.store(enabled); }
    bool isEnabled() const { return enabled_.load(); }

    /// Convergencia estimada (0=no convergido, 1=plenamente convergido).
    float getConvergence() const { return convergence_.load(); }

    /// Margen estimado al howling en dB.
    float getGainMargin() const { return gainMarginDb_.load(); }

private:
    static constexpr int kTaps = 64;
    static constexpr float kMu = 0.005f;
    static constexpr float kPowerFloor = 1e-10f;

    std::array<float, kTaps> w_{};      // pesos del filtro adaptativo
    std::array<float, kTaps> ref_{};    // delay line del speakerRef
    int writeIdx_ = 0;

    std::atomic<bool>  enabled_{true};
    std::atomic<float> convergence_{0.0f};
    std::atomic<float> gainMarginDb_{30.0f};
};
```

### `afc_processor.cpp` (NUEVO — algoritmo NLMS sample-by-sample)

Pseudocódigo del hot path:

```
para cada muestra n:
    // 1) Insertar speakerRef en delay line (FIFO circular)
    ref_[writeIdx_] = speakerRef[n]
    writeIdx_ = (writeIdx_ + 1) & (kTaps - 1)   // requiere kTaps potencia de 2

    // 2) Estimar feedback como producto interno de w_ con el delay line
    fb_est = Σ w_[k] * ref_[(writeIdx_ - 1 - k) & (kTaps - 1)]

    // 3) Error = mic[n] - fb_est (señal limpia estimada)
    err = mic[n] - fb_est

    // 4) Potencia de la referencia (suma cuadrada del delay line)
    power = Σ ref_[k]² + kPowerFloor

    // 5) Paso NLMS normalizado
    norm_mu = kMu / power

    // 6) Update de los pesos (gradiente descendente)
    para cada k:
        w_[k] += norm_mu * err * ref_[(writeIdx_ - 1 - k) & (kTaps - 1)]

    // 7) Output = err (señal con feedback cancelado)
    mic[n] = err

actualizar atomics convergencia / gainMargin cada N samples (block-rate).
```

## Test plan

### Unit tests (`afc_processor_test.cpp`)

1. **Convergencia con feedback estacionario:**
   - Señal: white noise + retardo de 32 samples × ganancia 0.5 (loop simulado).
   - Esperado: tras 200 ms (~3200 samples a 16k), `||error|| < 0.05 × ||mic||`.

2. **Estabilidad bajo cambio de path:**
   - Cambio abrupto de ganancia del feedback de 0.3 → 0.6 a la mitad del test.
   - Esperado: re-convergencia en < 500 ms, sin oscilación.

3. **Bypass bit-exact cuando enabled=false:**
   - `processBlock` con enabled=false debe ser memcpy mic→out.

4. **Paridad numérica con simulador web:**
   - Mismo input → mismo output a 1e-5 RMS sobre 10 s de habla con feedback.

### Integration test (`audio_engine_test.cpp`)

- Mock de `oboe::AudioStream` que inyecta feedback simulado en el input cuando
  el output anterior tuvo amplitud > umbral.
- Validar que con AFC habilitado el sistema NO entra en oscilación (peak <
  -3 dBFS sostenido por 5 segundos), mientras que sin AFC sí oscila.

### Validación auditiva

- Procesar `samples/feedback_test.wav` (audio con howling) y verificar que el
  output tiene `peakSpectralBin / avgSpectralEnergy < 10` (sin tono dominante).

## Riesgos

| Riesgo | Mitigación |
|--------|------------|
| NLMS diverge con habla muy correlacionada | μ pequeño (0.005), power floor 1e-10. Si pasa, fallback a desactivar AFC y reportar al UI. |
| Delay del speakerRef inconsistente entre devices | Hacer el `kSpeakerRefSize` configurable; default 256 samples cubre 5 ms a 48 kHz. |
| AFC añade latencia | NLMS sample-by-sample con 64 taps añade ~64 mults/sample. A 16 kHz = ~1 µs/sample en arm64; despreciable. |
| Doble cancelación si `processBlock` se llama después de `processAfcOnly` | Flag `afcAlreadyApplied_` lo previene. |

# Tasks — AFC antes del DNN en el pipeline (refactor del orden)

> Estado: **PENDIENTE.** Se difirió desde la implementación de las 5 mejoras
> prioritarias de `Amplificador/docs/ruido-profundo.md` (Mejora #2) porque AFC
> nativo no existe todavía y el refactor era demasiado invasivo para hacerse
> al mismo tiempo que las mejoras low-risk.
>
> Lee `requirements.md` y `design.md` antes de empezar.

## Fase 1 — AFC nativo standalone (sin tocar el pipeline todavía)

- [ ] 1.1 Crear `hearing_aid_app/android/app/src/main/cpp/afc_processor.h` con la API
      definida en `design.md` (init / processBlock / reset / setEnabled / getters).
      _Requirements: R1_

- [ ] 1.2 Crear `hearing_aid_app/android/app/src/main/cpp/afc_processor.cpp` con el
      algoritmo NLMS sample-by-sample de 64 taps, μ=0.005, power floor 1e-10.
      _Requirements: R1_

- [ ] 1.3 Agregar `afc_processor.cpp` al `CMakeLists.txt` para que se compile en
      `libhearing_aid.so`.
      _Requirements: R1_

- [ ] 1.4 Crear unit tests `hearing_aid_app/android/app/src/main/cpp/test/afc_processor_test.cpp`
      con los 4 casos de `design.md::Test plan::Unit tests`. Usar GoogleTest.
      _Requirements: R6_

- [ ] 1.5 Validar paridad numérica con `assets/simulator/dsp-engine-browser.js::createFeedbackCanceller`:
      generar fixture `test/fixtures/afc_paridad.json` con 1 segundo de mic+ref
      y output esperado del JS, comparar con AFC nativo a 1e-5 RMS.
      _Requirements: R6_

## Fase 2 — Speaker reference buffer

- [ ] 2.1 Agregar `lastSpeakerBuffer_` (std::array<float, 256>) y `lastSpeakerLen_`
      como miembros privados de `AudioEngine`.
      _Requirements: R2_

- [ ] 2.2 En `AudioEngine::onBothStreamsReady`, después de aplicar todo el pipeline,
      copiar los últimos `min(256, numFrames)` samples del output a `lastSpeakerBuffer_`.
      _Requirements: R2_

## Fase 3 — Refactor del DspPipeline para componibilidad

- [ ] 3.1 Agregar `processAfcOnly(mic, speakerRef, n)` y `processWithoutAfc(buffer, n)`
      a `DspPipeline`. Internamente usan el `AfcProcessor` recién creado.
      _Requirements: R3_

- [ ] 3.2 Agregar flag interna `afcAlreadyApplied_` para que `processBlock()` no
      vuelva a aplicar AFC si ya fue llamado por `processAfcOnly()` en el mismo
      block. Reset al inicio del próximo block.
      _Requirements: R3_

- [ ] 3.3 Mantener compatibilidad: `processBlock()` debe seguir funcionando para
      tests legacy (incluso si el speakerRef está vacío y el AFC no cancela nada).
      _Requirements: R3_

## Fase 4 — Reorden en audio_engine.cpp

- [ ] 4.1 En `onBothStreamsReady`, reemplazar la secuencia actual:

      ```cpp
      dnnDenoiser_.process(outPtr, numFrames);
      pipeline_.processBlock(outPtr, numFrames);
      ```

      por:

      ```cpp
      pipeline_.processAfcOnly(outPtr, lastSpeakerBuffer_.data(),
                               std::min(lastSpeakerLen_, numFrames));
      dnnDenoiser_.process(outPtr, numFrames);
      pipeline_.processWithoutAfc(outPtr, numFrames);
      ```

      Marcar el cambio con `// MEJORA #2 (ruido-profundo.md):`.
      _Requirements: R4_

- [ ] 4.2 Verificar que el orden NO rompe ningún invariante del steering
      `hearing-aid-dsp.md`: Volume sigue antes de MPO, MPO sigue siendo última
      etapa, ninguna etapa nueva amplifica.
      _Requirements: R4_

## Fase 5 — Howling detection como red de seguridad

- [ ] 5.1 Agregar `HowlingDetector` simple en `audio_engine.cpp` que en cada block
      mide ratio (peak FFT bin / avg FFT energy) y dispara si > 20 sostenido por
      > 100 ms.
      _Requirements: R5_

- [ ] 5.2 Cuando dispara, bajar volumen master 6 dB y postear evento al UI vía
      JNI callback `onHowlingDetected`.
      _Requirements: R5_

## Fase 6 — Telemetría y JNI

- [ ] 6.1 Agregar getters `getAfcConvergence()` y `getAfcGainMargin()` a
      `AudioEngine`. Cablear al JNI bridge.
      _Requirements: R7_

- [ ] 6.2 En Flutter, mostrar estos valores en el panel de diagnóstico del audífono
      (próximo a "DNN active" / "NR level").
      _Requirements: R7_

- [ ] 6.3 Loggear cada 5 s al logcat: `AFC: conv=%.2f gainMargin=%.1f dB`.
      _Requirements: R7_

## Fase 7 — Integración y validación

- [ ] 7.1 Build APK release y correr en dispositivo real con auricular cerca del mic.
      Medir MSG con AFC ON vs OFF; debe subir ≥ 3 dB.
      _Criterios: 3_

- [ ] 7.2 Procesar `samples/feedback_test.wav` y validar
      `peakSpectralBin / avgSpectralEnergy < 10`.
      _Criterios: 3_

- [ ] 7.3 Medir THD del output con tono 1 kHz @ 70 dB SPL. Debe estar ≤ THD
      actual + 0.5%.
      _Criterios: 4_

- [ ] 7.4 Medir latencia total del pipeline (end-to-end loopback). Debe estar ≤
      latencia actual + 0.5 ms.
      _Criterios: 5_

## Notas de implementación

- **Hot path:** ningún `new`/`malloc` en `AfcProcessor::processBlock`. Todos los
  buffers son `std::array<float, kTaps>` o miembros del Impl.
- **Thread safety:** mismo patrón que el resto del pipeline — `std::atomic<bool>`
  para `enabled`, `std::atomic<float>` para los getters de telemetría.
- **Reentrancia:** la pareja `processAfcOnly` + `processWithoutAfc` debe ser
  segura aunque se llamen en bloques pequeños diferentes (e.g. si Oboe da bursts
  de 64 vs 128 samples), porque el delay line del AFC y el state del MPO son
  miembros del Impl y se preservan entre llamadas.
- **Sin AFC en simulador Python:** `Amplificador/scripts/simulate_*.py` no usan
  feedback porque procesan archivos sin loop acústico. No hay que tocar nada ahí.

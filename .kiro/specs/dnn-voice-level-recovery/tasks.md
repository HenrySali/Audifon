# Implementation Plan: Recuperación de nivel de voz al activar el DNN denoiser

## Overview

Plan de trabajo para implementar el spec `dnn-voice-level-recovery`. El
Paso 1 es mandatorio. El Paso 2 sólo se ejecuta si la validación de
campo (Tarea 6) muestra que el Paso 1 no alcanza. Sin cambios en UI ni
BLE; cambios contenidos en el módulo DNN nativo y un cableo trivial en
`audio_engine.cpp`.

## Task Dependency Graph

```json
{
  "waves": [
    { "wave": 1, "tasks": ["1"] },
    { "wave": 2, "tasks": ["2"] },
    { "wave": 3, "tasks": ["3"] },
    { "wave": 4, "tasks": ["4"] },
    { "wave": 5, "tasks": ["5"] },
    { "wave": 6, "tasks": ["6"] },
    { "wave": 7, "tasks": ["7"] },
    { "wave": 8, "tasks": ["8"] },
    { "wave": 9, "tasks": ["9"] },
    { "wave": 10, "tasks": ["10"] }
  ]
}
```

Notas: T2 depende de T1 (no compila sin la API). T3 depende de T2 (sin
la rampa, el flag no hace nada). T4-T6 son secuenciales sobre el Paso 1.
T7-T10 sólo se ejecutan si T6 falla el criterio "voz no atenuada".

## Tasks

### Paso 1 — VAD-driven intensity cap (mandatorio)

- [x] 1. Extender la API del `DnnDenoiser`
  - 1.1 Agregar a `dnn_denoiser.h`:
    - `void notifyVoiceActive(bool active)` (atomic bool, lock-free).
    - `float getEffectiveIntensity() const` (atomic float, lock-free).
    - `void setVoiceCap(float cap)` con default `kDefaultVoiceCap = 0.7f`.
    - Constantes `kAttackMs = 40.0f`, `kReleaseMs = 300.0f`.
  - 1.2 Documentar en el comentario de cabecera que la modulación NO
        viola el invariante "DNN solo atenúa".
  - _Refs: R1.1, R1.2, R1.4, R5.3, R5.4_

- [x] 2. Implementar la rampa asimétrica en `dnn_denoiser.cpp`
  - 2.1 Agregar miembros internos: `effectiveIntensity_` (float,
        no atomic — solo escrito desde audio thread), `voiceActive_`
        (atomic bool), `voiceCap_` (atomic float),
        `stepAttackPerSample_`, `stepReleasePerSample_` (float, recalculados
        en `setInputSampleRate`).
  - 2.2 En `setInputSampleRate(int sr)`, recalcular
        `stepAttackPerSample_  = 1.0f / (kAttackMs  * (sr / 1000.0f))` y
        `stepReleasePerSample_ = 1.0f / (kReleaseMs * (sr / 1000.0f))`.
        Tener en cuenta que el loop de mezcla de
        `dnn_denoiser.cpp:~1320` corre a `inputSampleRate`, no a 16 kHz.
  - 2.3 En el loop de mezcla `for (int i = 0; i < blockSize; ++i)`
        de `dnn_denoiser.cpp:~1320`:
        - Calcular `target = voiceActive_.load() ? min(userIntensity, voiceCap_) : userIntensity`.
        - Aplicar rampa asimétrica per-sample sobre `effectiveIntensity_`.
        - Reemplazar `intensityVal` por `effectiveIntensity_` al
          calcular `dnnAmount`.
  - 2.4 Reflejar `effectiveIntensity_` en un atomic para `getEffectiveIntensity()`.
  - _Refs: R1.3, R1.5, R1.6, R1.7_

- [x] 3. Cablear el VAD en `audio_engine.cpp`
  - 3.1 Confirmar el getter disponible en `SceneAnalyzer` o en su VAD
        interno (`smart_scene/vad_detector.h`). Si el SceneAnalyzer no
        expone `isVoiceActive()`, agregar un getter trivial al
        SceneAnalyzer que delegue al VAD.
  - 3.2 En `onBothStreamsReady`, **después** de
        `sceneAnalyzer_.process(inPtr, numFrames)` (línea ~441), llamar
        `dnnDenoiser_.notifyVoiceActive(sceneAnalyzer_.isVoiceActive())`.
  - 3.3 Verificar mentalmente el orden: el `dnnDenoiser_.process()` del
        callback corriente usará `voice_active` del bloque anterior, lo
        cual está aceptado en el diseño (latencia 1 callback ≈ 5 ms,
        despreciable frente a la rampa de 40-300 ms).
  - _Refs: R1.1, R1.2, R5.2_

- [x] 4. Telemetría mínima
  - 4.1 En el bloque `Input diag` actual de
        `audio_engine.cpp` (~líneas 410-422), agregar log de:
        `userIntensity = dnnDenoiser_.getIntensity()`,
        `effectiveIntensity = dnnDenoiser_.getEffectiveIntensity()`,
        `vadActive = sceneAnalyzer_.isVoiceActive()`.
  - 4.2 Mantener cadencia ~2 s (no flood). Reusar el mismo `diagCounter`.
  - _Refs: R2.1, R2.2, R2.3_

- [x] 5. Sanity build y smoke test
  - 5.1 Compilar Android, verificar que no rompe la API existente
        (no se elimina ningún getter/setter actual del `DnnDenoiser`).
  - 5.2 Smoke test en silencio: con DNN ON e intensity 1.0, el log debe
        mostrar `vadActive=0` la mayor parte del tiempo, y
        `effectiveIntensity ≈ 1.0`. Sin cambios audibles vs estado actual.
  - 5.3 Smoke test con voz directa al mic: el log debe mostrar
        `vadActive=1` durante la voz, y `effectiveIntensity ≈ 0.7`.
        Voz menos atenuada que el estado actual; ruido residual
        prácticamente igual.

- [~] 6. **Validación de campo (criterio de avance al Paso 2)**
  - 6.1 El usuario captura una grabación corta (~30 s) en el ambiente
        ruidoso (tren) con DNN ON e intensity 1.0, una con la versión
        previa al cambio y otra con la nueva.
  - 6.2 Comparación A/B subjetiva por el usuario.
  - 6.3 Criterio de aceptación (R3.3):
        - Voz no se siente atenuada al activar el limpiador. ✓ / ✗
        - Ruido sigue bajando notoriamente. ✓ / ✗
        - Sin bombeo audible en pausas. ✓ / ✗
  - 6.4 **Si todos los criterios son ✓:** cerrar el spec, no implementar
        Paso 2.
  - 6.5 **Si "voz atenuada" sigue siendo ✗:** abrir tasks 7-10 (Paso 2).
  - 6.6 **Si "bombeo audible" pasa a ✗ (regresión):** subir
        `kReleaseMs` a 500 ms y reevaluar antes de pasar al Paso 2.
  - _Refs: R3.1, R3.2, R3.3_

### Paso 2 — Make-up gain por bandas (opcional)

> Solo si Tarea 6 muestra que voz sigue atenuada.

- [~] 7. Mapeo bin → banda EQ en el worker DNN
  - 7.1 Determinar el mapeo de bins FFT (FFT 512 a 16 kHz, ver
        `kDnnFftSize` en `dnn_denoiser.h`) a las bandas EQ usadas por el
        SceneAnalyzer / pipeline. Reusar el mapeo existente si lo hay,
        o tabular las bandas que cubren 2-8 kHz como un array
        `kMakeupBandRanges[2-8kHz]`.
  - _Refs: R4.1, R4.2_

- [~] 8. Implementar el make-up gain en el worker
  - 8.1 Agregar miembros: `gainDb_[NB]`, `eps = 1e-12f`,
        `makeupEnabled_` (atomic bool, default false).
  - 8.2 En el worker, antes del iSTFT (zona ~`dnn_denoiser.cpp:990`):
        - Calcular `drym2[b]` y `wetm2[b]` por banda en 2-8 kHz.
        - `ratioDb = 10*log10((drym2 + eps) / (wetm2 + eps))`.
        - `targetDb = clamp(ratioDb, 0, +4 dB)`.
        - Si `voiceActive_.load()`: aplicar rampa asimétrica
          (40 ms / 300 ms) sobre `gainDb_[b]` hacia `targetDb`.
        - Si no: dejar `gainDb_[b]` congelado.
        - Aplicar `gainLin = 10^(gainDb_[b]/20)` a los bins de la banda
          b en `enhanced[k]`.
  - 8.3 No tocar el COLA del Paso `MEJORA #1` posterior.
  - _Refs: R4.3, R4.4, R4.5, R4.6_

- [~] 9. API y default seguro
  - 9.1 Agregar `void setMakeupEnabled(bool)` y `bool isMakeupEnabled() const`.
  - 9.2 Default `false`: el comportamiento por defecto es Paso 1 puro.
  - 9.3 Documentar que el Paso 2 requiere validación específica antes
        de habilitarse en producción.
  - _Refs: R4.7_

- [~] 10. Validación específica del Paso 2
  - 10.1 Repetir grabación del tren con `setMakeupEnabled(true)`.
  - 10.2 Verificar:
         - Recuperación de inteligibilidad en agudos. ✓ / ✗
         - Sin saturación / clipping en transitorios. ✓ / ✗
         - Headroom MPO no comprometido (revisar logs de WDRC/MPO si
           hay límites alcanzados con frecuencia). ✓ / ✗
         - Sin bombeo audible. ✓ / ✗
  - 10.3 Si OK, dejar Paso 2 disponible vía setter; documentar default
         (true / false) en función del resultado.
  - 10.4 Si saturación: bajar `kMakeupClampDb` a `+3.0f` y reevaluar.

## Notes

- **Spec `afc-before-dnn-reorder/` (0/21 tasks):** no es prerequisito.
  Cuando se aborde, revisar si el make-up gain del Paso 2 necesita
  retunearse en el contexto del nuevo orden AFC → DNN (ver
  `design.md` sección "Riesgos del Paso 2 / Interacción con AFC futuro").
- **`tools/quality_eval/`:** sin CLI standalone hoy. La validación se
  hace por A/B subjetivo con grabación real. Si en algún momento se
  agrega CLI, repetir el A/B con PESQ/STOI sobre las mismas grabaciones.
- **No tocar:** el NR Wiener clásico (`noise_reduction.cpp`), el orden
  del pipeline, la API BLE, ni la UI Flutter. Cambios contenidos en el
  módulo nativo del DNN denoiser y un cableo trivial en `audio_engine.cpp`.

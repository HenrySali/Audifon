# Nota de verificación — Propagación MPO/UCL técnico → paciente (Tarea 7.2, R7.5)

> Verificación **por lectura de código** (no cambia código). Rutas relativas a
> `Repo Oir Pro2\Audifon\`. Objetivo: confirmar que los valores MPO/UCL que
> define el técnico llegan **sin alteración** al clon del paciente.

## Cadena completa (origen → motor nativo)

1. **UCL (origen clínico)** — `lib/domain/audiogram_driven_presets/ucl_estimator.dart`
   - `UclEstimator.estimate(audiogram, {measuredUcl})`: por banda usa el UCL
     medido en cabina si existe (verbatim, sin clamp), o la regresión
     `UCL = 100 + 0.15 × HL` (HL clampado a `[0,120]` → UCL ∈ `[100,118]`).

2. **Perfil MPO en el bundle** — `audiogram_driven_bundle.dart`
   - Campo `mpoProfileDbSpl` (12 bandas, dB SPL, rango validado `[80,132]`).
   - `toJson()` (línea ~314): `'mpoProfileDbSpl': List<double>.from(mpoProfileDbSpl)`
     → copia **verbatim**.
   - `fromJson()` (línea ~397): `mpoProfileDbSpl: _readDoubleList(json, 'mpoProfileDbSpl')`
     → lectura **verbatim**; la validación sólo verifica rango, **no altera** valores.
   - ⇒ El bundle que el técnico exporta y el paciente importa transporta el mismo
     vector MPO byte a byte (salvo formato de texto JSON).

3. **Resolución del MPO broadband enviado al motor** — `lib/presentation/bloc/amplification_bloc.dart`
   - `_resolveBroadbandMpo(bundle)` (línea ~3944): `min(bundle.mpoProfileDbSpl)`
     clampado a `[80,132]`. Es una función determinista y **read-only** sobre el
     bundle; misma entrada → misma salida en técnico y paciente.
   - Se envía con `_audioBridge.setMpoThresholdDbSpl(mpoBroadband)` en la secuencia
     atómica de `_onApplyBundle` (paso 1, línea ~3456) y en `_onUpdateEqGains`
     (línea ~1679) y `_reapplyClinicalChain` (línea ~1841).
   - El clamp por banda de las ganancias también usa `mpoProfileDbSpl[i]`
     (headroom `g ≤ mpoProfileDbSpl[i] − input − 3 dB`), idéntico en ambos.

4. **Puente nativo (JNI)** — `android/app/src/main/cpp/native_bridge.cpp`
   - `Java_..._nativeSetMpoThresholdDbSpl(...)` (línea ~695):
     `g_engine->setMpoThresholdDbSpl(thresholdDbSpl);` (línea ~704).
     Pasa el valor **sin alteración** al motor.
   - Conversión dB SPL → lineal ocurre en `DspPipeline::applyMpoThresholdFromDbSpl`
     con `kMpoSplOffset = 120` y techo `kMpoDigitalCeiling = 0.85` — **constantes de
     código**, iguales en el clon del paciente.
   - `MpoLimiter` (`mpo_limiter.h`) aplica el hard-clamp `|y| ≤ thresholdLinear`
     como última etapa (invariante R7 / Property 9).

## Conclusión

- El paciente **clona el C++ del técnico** ⇒ `native_bridge.cpp`, `dsp_pipeline.*`,
  `mpo_limiter.h` y sus constantes (`kMpoSplOffset`, `kMpoDigitalCeiling`) son
  **idénticos**. No hay divergencia posible en la etapa de seguridad.
- El valor MPO/UCL viaja por el **bundle Dart** (`mpoProfileDbSpl`), que se
  serializa/deserializa **verbatim** y se resuelve con una función determinista
  (`_resolveBroadbandMpo`). No hay escalado ni recálculo dependiente de rol
  (técnico vs paciente).
- **Resultado:** los límites MPO/UCL definidos por el técnico se propagan **sin
  alteración** al clon del paciente. Cumple R7.5.

## Alcance / límites

- Verificación **estática** (lectura). La equivalencia numérica en runtime debe
  confirmarse en dispositivo re-procesando grabaciones (validación complementaria
  del dev; ver `build_apk_mvdr_tuning.bat` y `run_mvdr_tuning_tests.bat`).
- **Validación clínica** (UCL real vs estimado, REM en oído real) requiere
  revisión audiológica humana; ningún test de software la sustituye.

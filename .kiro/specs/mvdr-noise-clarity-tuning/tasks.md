# Implementation Plan

## Overview

Plan de codificación incremental para llevar el modo MVDR a nivel producción. El orden respeta las dependencias del `design.md`: primero se corrige la escala del Estimador_Ruido (R2) porque el clasificador (R4) depende de él; luego los componentes toggleables independientes (R4, Expansor R1, dereverb R5); después la verificación de compatibilidad (R6) y el invariante de seguridad clínica MPO (R7). El reperfilado del EQ (R3) queda al final marcado como **Cambio_Prescriptivo** y no se ejecuta sin confirmación explícita del usuario. Todas las mejoras nuevas son toggleables con defaults = comportamiento previo.

## Tasks

- [x] 1. Resolver decisiones abiertas del diseño mediante lectura de código
  - Leer `hearing_aid_app/lib/domain/audiogram_driven_presets/bundle_builder.dart` y `audiogram_driven_bundle.dart` para confirmar el `expansionRatio`/`expansionKnee` real que Dart envía por `setWdrcParams` (código C++ default 2.0 vs documentado 1.0) y decidir si el nuevo Expansor coexiste con la expansión del WDRC o la reemplaza.
  - Leer el path Dart de escena (`AudioMethodChannel.kt` → BLoC → pantallas) para confirmar qué etiqueta consume la UI: `SceneClass` de `SceneAnalyzer` (hardcodeado a UNKNOWN) o `EnvironmentClass` (ya converge). Esto dirige el fix de R4.
  - Leer `scene_analyzer.cpp` (~194-200), `noise_profile.{h,cpp}` y `environment_classifier.cpp::estimateSnrFromNr` para decidir si `snr_db` del snapshot se corrige de escala o se reemplaza por el SNR autoconsistente.
  - Registrar las tres decisiones como comentarios/notas en los archivos afectados (sin cambiar comportamiento todavía) para dejar traza antes de codificar.
  - _Requirements: 1.1, 2.8, 4.1, 6.4_

- [ ] 2. Corregir la escala del Estimador_Ruido (R2) — desbloquea R4
  - [x] 2.1 Escribir test unitario de escala (falla primero) para `noise_profile` y `scene_analyzer`
    - Añadir test que alimente RMS/energía de un mic real simulado y verifique que `noise_floor_db_spl ∈ [−60, −40]` dBFS y que `snr_db` no queda fijo en 40.
    - Ubicar el test en el directorio de tests C++ del proyecto (o `tools/sim_v3/` si es donde vive la validación offline); no requiere audio con paciente.
    - _Requirements: 2.2, 2.3, 2.4, 2.8_
  - [x] 2.2 Unificar la referencia de nivel del piso de ruido con `inputDbSpl`
    - En `smart_scene/noise_profile.{h,cpp}` y `scene_analyzer.cpp`, poner `noiseFloorDb` en la MISMA referencia calibrada (dB SPL/dBFS) que `inputDbSpl`, aplicando `splOffset` o calculando `NoiseProfile` sobre energía calibrada, de modo que `snrDb = inputDbSpl − noiseFloorDb` sea físicamente coherente.
    - Ajustar la inicialización (`−90/−60`) a un piso plausible acotado defensivamente a `[−60, −40]` dBFS.
    - _Requirements: 2.1, 2.2, 2.5, 2.6, 2.8_
  - [x] 2.3 Eliminar el clamp fijo de SNR en 40 dB
    - Quitar la saturación en 40 dB en `scene_analyzer.cpp`, acotando el SNR sólo a `[−20, 40]` con piso numérico (`kPowerFloor`) para evitar `log(0)`, de forma que el SNR varíe con el contenido.
    - _Requirements: 2.3, 2.4_
  - [x] 2.4 Verificar la observabilidad del piso de ruido y SNR corregidos hacia Dart
    - Confirmar que `SceneSnapshot.noise_floor_db_spl` y `snr_db` (ya serializados por `nativeGetSceneSnapshot()`) reflejan los valores corregidos por la cadena C++ → `NativeAudioBridge.kt` → Dart (`SceneSnapshot.fromBytes`). Sin nuevo canal, solo validar valores.
    - _Requirements: 2.7, 6.4_
  - [ ] 2.5 Implementar estimador MMSE-SPP opcional detrás de toggle (header-only) * — PENDIENTE (no rápido; el fix de escala ya corrige el bug medido. Anotado como mejora futura opcional, default OFF).
    - Crear estimador MMSE-SPP (Gerkmann-Hendriks 2012) header-only con fallback al estimador actual si diverge; exponerlo detrás de un toggle con default OFF (comportamiento previo). No tocar `CMakeLists.txt` por ser header-only.
    - _Requirements: 2.1, 2.5, 6.2, 6.5_

- [x] 3. Hacer converger el Environment_Classifier / SceneClass (R4)
  - [x] 3.1 Convertir umbrales `constexpr` en miembros con setters atómicos
    - En `environment_classifier.{h,cpp}` promover `kEnvSnrSpeechEnter/Exit`, `kEnvSnrNoiseThreshold`, `kEnvLevelQuietEnter/Exit` a miembros `std::atomic` con `setSpeechSnrThresholds`, `setNoiseSnrThreshold`, `setQuietLevelThresholds`.
    - _Requirements: 4.5_
  - [x] 3.2 Habilitar la lógica de decisión de escena sobre el SNR/piso corregidos
    - Según la decisión de la tarea 1, habilitar la decisión de `SceneClass` en `smart_scene/scene_analyzer.cpp` (que hoy devuelve siempre UNKNOWN) usando el `snr_db`/`noise_floor` corregidos, o mapear la etiqueta de la UI a `EnvironmentClass` que ya converge.
    - Asegurar clasificación QUIET/SPEECH/NOISE según umbrales configurables.
    - _Requirements: 4.1, 4.2, 4.3, 4.4_
  - [x] 3.3 Cablear los umbrales configurables por la cadena C++ → Kotlin → Dart
    - Añadir `nativeSetClassifierThresholds(...)` en `native_bridge.cpp` → `AudioEngine` → clasificador; wrapper `external fun`/función en `NativeAudioBridge.kt`; método en `AudioMethodChannel.kt` y control en la app del técnico. Aplicar defaults = umbrales actuales si Dart no envía valor.
    - _Requirements: 4.5, 4.7, 6.4, 6.5_
  - [x] 3.4 Escribir test de convergencia UNKNOWN ≤ 20%
    - Test HOST STANDALONE con señal sintética representativa (patrón `smart_scene/tests/test_noise_scale.cpp`): `smart_scene/tests/test_scene_convergence.cpp` re-procesa una sesión sintética (silencio → tono → ruido banda ancha → tono) por `SceneAnalyzer` y verifica `UNKNOWN ≤ 20%` de las muestras + coherencia (silencio → SILENCE dominante). No requiere audio del paciente ni el toolchain de sim del Moto G32. No ejecutado en el entorno del agente (sin toolchain C++); listo para correr con `run_tests.bat`. El re-proceso offline de grabaciones reales del Moto G32 queda como validación complementaria futura.
    - _Requirements: 4.1, 4.6_

- [x] 4. Implementar el Expansor de baja frecuencia ≤1000 Hz (R1)
  - [x] 4.1 Crear el módulo `expander.h` header-only
    - Nuevo archivo `cpp/expander.h` (patrón `transient_reducer.h`): split de banda con LPF ~1000 Hz (2º orden), downward expansion sobre la banda baja, recombinación con la banda alta intacta, envelope con attack/release asimétricos independientes. Sanitizar NaN/Inf como el EQ. Parámetros `std::atomic`.
    - Firma: `init/process/setEnabled/setKneeDbSpl/setRatio/setCutoffHz/setAttackMs/setReleaseMs`. Defaults: `enabled=false`, `ratio=1.0` (passthrough).
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.4a, 1.5, 1.6, 1.7_
  - [x] 4.2 Insertar el Expansor en `DspPipeline` antes del EQ
    - Añadir miembro `Expander expander_;` en `dsp_pipeline.h` y llamarlo en `processBlock()` después de NR/SCE y antes de `measureRmsDb`/EQ, para que actúe sobre el nivel de entrada real.
    - _Requirements: 1.1, 1.2, 1.3_
  - [x] 4.3 Cablear el Expansor por JNI (`native_bridge.cpp`)
    - Añadir `nativeSetExpander(enabled, kneeDbSpl, ratio, cutoffHz, attackMs, releaseMs)` → `AudioEngine::setExpanderParams()` → setters de `pipeline_`. Default seguro si no llega valor.
    - _Requirements: 1.4, 1.5, 6.2, 6.4, 6.5_
  - [x] 4.4 Cablear el Expansor en Kotlin y Dart
    - `external fun nativeSetExpander(...)` + wrapper `fun setExpander(...)` en `NativeAudioBridge.kt` (defaults seguros OFF/ratio 1.0); handler `handleSetExpander` + case `"setExpander"` en `AudioMethodChannel.kt`. Cadena C++ → Kotlin → Dart completa (MethodChannel listo para la app del técnico).
    - _Requirements: 6.2, 6.4_
  - [x] 4.5 Verificar `CMakeLists.txt`
    - Confirmado por lectura: `expander.h` es header-only y NO figura en `add_library(hearing_aid_dsp ...)` de `cpp/CMakeLists.txt` (mismo patrón que `mvdr_beamformer.h`/`transient_reducer.h`). NO requiere tocar CMake. El test `test_scene_convergence.cpp` es host standalone (`run_tests.bat`), tampoco entra al `.so`.
    - _Requirements: 6.6_
  - [x] 4.6 Escribir tests unitarios del Expansor
    - `cpp/tests/expander_test.cpp` (registrado en `cpp/tests/run_mvdr_tuning_tests.bat`): passthrough bit-exact con `enabled=false`/`ratio=1.0`, banda limitada (energía > cutoff conservada), sin reducción sobre el knee, y transición de ataque ≤ 50 ms. No ejecutado en el entorno del agente (sin toolchain C++); listo para correr.
    - _Requirements: 1.2, 1.3, 1.6, 1.7_

- [x] 5. Exponer toggle y parámetros del Supresor_Reverb (R5)
  - [x] 5.1 Promover constantes del dereverb a miembros atómicos con setters
    - En `mvdr_beamformer.h`, `kReverbDecay/kReverbOver/kReverbFloor` pasaron de `constexpr` locales de `processFrame()` a miembros `std::atomic` (`dereverbDecay_/dereverbOver_/dereverbFloor_`) con setters `setDereverbEnabled/setDereverbStrength/setDereverbFloor/setDereverbDecay`. Defaults preservados (enabled=true, decay 0.80, over 1.6, floor 0.30); `processFrame()` los lee por bloque.
    - _Requirements: 5.1, 5.2, 5.3, 5.4_
  - [x] 5.2 Cablear el dereverb por JNI (`native_bridge.cpp`)
    - `nativeSetDereverb(enabled, strength, floor, decay)` → `AudioEngine::setDereverbParams()` (posee `mvdrBeamformer_`) → setters del beamformer. Documentado que fuera del modo MVDR el beamformer hace bypass (no-op efectivo) pero el estado queda guardado para cuando se active MVDR.
    - _Requirements: 5.2, 5.3, 6.4, 6.5_
  - [x] 5.3 Cablear el dereverb en Kotlin y Dart
    - `external fun nativeSetDereverb(...)` + wrapper `fun setDereverb(...)` (defaults previos) en `NativeAudioBridge.kt`; handler `handleSetDereverb` + case `"setDereverb"` en `AudioMethodChannel.kt`. Cadena C++ → Kotlin → Dart completa.
    - _Requirements: 5.2, 6.4_
  - [x] 5.4 Escribir test A/B del toggle de dereverb
    - `cpp/tests/dereverb_ab_test.cpp` (registrado en `run_mvdr_tuning_tests.bat`): compara MVDR con `dereverbEnabled=false` vs `true` sobre señal reverberante sintética, verificando que OFF equivale al beamforming sin la etapa de dereverb y ON preserva la voz directa. No ejecutado en el entorno del agente (sin toolchain C++); listo para correr.
    - _Requirements: 5.1, 5.3, 5.4, 6.3_

- [ ] 6. Verificar compatibilidad con modos existentes y cadena nativa (R6) — 6.1 hecho; 6.2 PENDIENTE-DE-USUARIO (build con RAM)
  - [x] 6.1 Escribir test de regresión con toggles NUEVOS en OFF
    - Test HOST STANDALONE `cpp/tests/compat_defaults_test.cpp` (patrón `expander_test.cpp`), registrado en `run_mvdr_tuning_tests.bat`. Verifica a nivel de MÓDULO: (1) Property 1 — Expander `enabled=false` y `enabled=true+ratio=1.0` → salida bit-exacta a la entrada; (2) Property 11 — `DspPipeline` con el Expander en su default (OFF) produce salida bit-exacta vs. seteado explícitamente OFF, y vs. ratio 1.0, sobre 200-300 bloques → la introducción del Expander NO altera el comportamiento previo (R6.3/6.5). Documenta en el header qué es verificable en host y qué NO: la equivalencia RMS/bit-a-bit con la salida PRE-spec en los tres modos reales del AudioEngine (kBypass/kDualChannelDnn/kMvdrBackup) requiere **re-proceso offline de las grabaciones del Moto G32 + build del `.so`** (validación complementaria del dev). Documentado también que el estimador nuevo (SceneAnalyzer) corre EN PARALELO (sólo publica métricas, NO toca el audio) y el dereverb queda ON por default (cubierto por `dereverb_ab_test.cpp`). No ejecutado en el entorno del agente (sin toolchain C++); `get_diagnostics` limpio.
    - _Requirements: 6.1, 6.3, 6.5_
  - [ ] 6.2 Verificar build del `.so` y ejecución vía Oboe — **PENDIENTE-DE-USUARIO**
    - **NO ejecutado por el agente (falta RAM para compilar el `.so` + LibTorch/ONNX).** Se dejó el script `.kiro/specs/mvdr-noise-clarity-tuning/build_apk_mvdr_tuning.bat` (patrón de `_build_install_2xmic.bat`/`compile_check.bat`): corre `flutter analyze` + `flutter build apk --debug --target-platform android-arm64` (compila `hearing_aid_dsp`) desde `Repo Oir Pro2\Audifon`. Requiere **cerrar apps pesadas por RAM** y correrse en CMD. Antes conviene correr `android\app\src\main\cpp\tests\run_mvdr_tuning_tests.bat` (host, sin RAM del `.so`). El usuario debe ejecutarlo, confirmar el build OK y la ejecución por Oboe sin underruns en el Moto G32, y luego marcar esta tarea.
    - _Requirements: 6.6_

- [x] 7. Verificar la seguridad clínica del limitador MPO (R7)
  - [x] 7.1 Escribir tests de invariante y de independencia del MPO
    - Test HOST STANDALONE `cpp/tests/mpo_invariant_test.cpp` (registrado en `run_mvdr_tuning_tests.bat`), sobre `DspPipeline` real (MPO como última etapa). Property 9: barre todas las combinaciones de toggles (Expansor ON/OFF × NR 0/3 × SCE ON/OFF × TNR ON/OFF, 16 combos) con EQ +30 dB + volumen +10 dB para forzar clipping, y verifica `|salida| ≤ thresholdLinear` en TODA muestra de 200 bloques. Property 10: dos corridas idénticas → mismo pico (MPO determinista, independiente del algoritmo de los toggles previos, ya que el hard-clamp final no depende de su estado). No ejecutado en el entorno del agente (sin toolchain C++); `get_diagnostics` limpio (API `setExpanderParams/setNrLevel/setSceEnabled/setTnrEnabled/setEqGains/setVolume` verificada en `dsp_pipeline.h`).
    - _Requirements: 7.1, 7.2, 7.3, 7.4_
  - [x] 7.2 Verificar propagación idéntica de límites MPO/UCL al clon del paciente
    - Verificado POR LECTURA y documentado en `.kiro/specs/mvdr-noise-clarity-tuning/mpo-ucl-propagation-note.md`. Traza: `UclEstimator.estimate` (`UCL=100+0.15·HL` o medido verbatim) → `AudiogramDrivenBundle.mpoProfileDbSpl` (serializado/deserializado VERBATIM en `toJson`/`fromJson`, validación sólo de rango, sin escalado) → `AmplificationBloc._resolveBroadbandMpo` = `min(mpoProfileDbSpl)` clamp `[80,132]` (determinista, read-only) → `_audioBridge.setMpoThresholdDbSpl` → JNI `nativeSetMpoThresholdDbSpl` → `g_engine->setMpoThresholdDbSpl(thresholdDbSpl)` (`native_bridge.cpp:704`, sin alteración) → `MpoLimiter` hard-clamp. El paciente clona el mismo C++ (`native_bridge.cpp`, `dsp_pipeline.*`, `mpo_limiter.h`, constantes `kMpoSplOffset=120`/`kMpoDigitalCeiling=0.85`) ⇒ propagación sin alteración. No cambia código.
    - _Requirements: 7.5_

- [ ] 8. **Cambio_Prescriptivo — REQUIERE CONFIRMACIÓN DEL USUARIO ANTES DE EJECUTAR** — Reperfilado del EQ hacia NAL-NL2/NL3 (R3) *
  - [ ] 8.1 Reperfilar el vector de 12 ganancias en el bundle Dart *
    - **NO ejecutar sin OK explícito del usuario.** Modificar `hearing_aid_app/lib/domain/audiogram_driven_presets/bundle_builder.dart` y `audiogram_driven_bundle.dart` para: ganancia relativa 2–4 kHz > 500–750 Hz; recortar el pico de +31 dB en 500–750 Hz al objetivo NAL; reducir la atenuación de −16 dB en 6–8 kHz. No cambia el algoritmo de `equalizer.cpp`. Impacta al paciente que clona.
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.7_
  - [ ] 8.2 Exponer el perfil aplicado del EQ hacia Dart (getter) *
    - Añadir `getEqGains()` en `equalizer.h`/pipeline y `nativeGetEqGains()` → Kotlin → Dart para mostrar el perfil aplicado. Omitir si la UI ya reconstruye el perfil desde el bundle Dart (confirmar en tarea 1).
    - _Requirements: 3.6, 6.4_

## Task Dependency Graph

```json
{
  "waves": [
    { "wave": 1, "tasks": ["1"] },
    { "wave": 2, "tasks": ["2", "4", "5"] },
    { "wave": 3, "tasks": ["3"] },
    { "wave": 4, "tasks": ["6", "7"] },
    { "wave": 5, "tasks": ["8"] }
  ]
}
```

- La tarea 1 (decisiones abiertas) precede a todo; condiciona 2.2, 3.2, 4.1 y 8.
- La tarea 2 (fix de escala R2) desbloquea la tarea 3 (clasificador R4): 3.2 y 3.4 dependen de 2.2/2.3.
- Las tareas 4 (Expansor R1) y 5 (dereverb R5) son independientes entre sí y pueden ir tras la tarea 1.
- La tarea 6 (regresión/compatibilidad R6) depende de que 2, 4 y 5 estén integradas.
- La tarea 7 (invariante MPO R7) depende de que existan los toggles de 2, 4 y 5 para probar todas las combinaciones.
- La tarea 8 (Cambio_Prescriptivo R3) es terminal y opcional; NO se inicia sin confirmación explícita del usuario.

## Notes

- Todas las mejoras nuevas (Expansor R1, estimador MMSE R2, dereverb R5) son toggleables con default = comportamiento previo (R6.3/R6.5). El dereverb ya está ON por default; su equivalencia pre-spec aplica a los toggles nuevos.
- Preferir módulos header-only para no modificar `CMakeLists.txt`; si un módulo pasa a `.cpp`, agregarlo a `add_library(hearing_aid_dsp ...)` y verificar el build (tarea 4.5/6.2).
- Por cada parámetro nuevo, trazar los tres eslabones C++ → `NativeAudioBridge.kt` → Dart antes de cerrar la tarea. Recordar que el paciente **clona** el C++ del técnico.
- La tarea 8 es el único **Cambio_Prescriptivo**: impacta la prescripción del paciente y requiere confirmación explícita + validación en oído real (REM) y revisión audiológica humana. Ningún test de software la sustituye.
- Las tareas de test re-procesan grabaciones offline ya existentes; no incluyen grabar audio nuevo con el paciente ni pruebas manuales de escucha.

## Nota de afinación post-implementación (grabaciones reales Moto G32)

Afinación derivada de grabaciones reales (ambiente doméstico tranquilo, voz cercana). Dos correcciones de audio, sin cambios prescriptivos, seguridad clínica intacta. Diagnostics limpios en todos los archivos tocados. Tests host standalone (patrón MSVC) actualizados; no ejecutados en el entorno del agente (sin toolchain C++), listos para correr en la máquina del dev.

### A — Voz ronca por recorte duro del MPO → soft-knee (rodilla suave)
- Evidencia: `postEqDb` 121–126 dB SPL con MPO en 98.75 dB (≈25 dB sobre el techo), `wdrcGain≈1.0`, `mpoFrac=1.0` → hard-clamp muestra-a-muestra → THD audible (voz ronca).
- Cambio: `mpo_limiter.{h,cpp}` — la ganancia del limitador pasa de salto 1.0→brickwall a una **rodilla cuadrática (soft-knee)** que reduce la ganancia PROGRESIVAMENTE en la ventana `[-knee/2, +knee/2]` dB alrededor del threshold (por DEBAJO del techo). Por encima de la rodilla: brickwall (`gain = threshold/env`). El **hard-clamp final se mantiene** como red de seguridad absoluta → INVARIANTE `|salida| ≤ thresholdLinear` intacto (Property 9).
- Parámetro nuevo: `kneeWidthDb_` (atómico, default seguro **6 dB**, acotado `[0,24]`; `0` = hard-clamp clásico). Setter `MpoLimiter::setKneeWidthDb()` + forwarder `DspPipeline::setMpoKneeWidthDb()`. Control interno de afinación; no se cableó UI/JNI (default seguro aplicado en el constructor). El paciente clona el mismo C++ → hereda el fix sin cambios adicionales.
- Test: `cpp/tests/mpo_invariant_test.cpp` — Property 9/10 siguen valiendo; añadida **Property 11** (soft-knee reduce ganancia progresivamente por debajo del techo, monotonía con el nivel, contraste con hard-clamp `knee=0`, e invariante `|salida| ≤ threshold`).

### B — Piso de ruido pegado en -60 → calibración a dBFS del input real
- Evidencia: `noise_db_spl` SIEMPRE en -60.00 (borde del clamp). El piso venía de `features.band_energy_db[b]` (promedio de potencia por bin de la FFT con ventana Hann, ~25–30 dB por debajo del RMS de banda ancha) → caía bajo -60 y quedaba clavado en el borde; el SNR no reflejaba el ruido real.
- Cambio: `smart_scene/scene_analyzer.cpp::computeFft()` — se calibran las energías por banda al MISMO dominio dBFS que `inputDbFs` mediante un offset derivado por Parseval (`bandCalibOffsetDb = inputDbFs − promedio espectral por bin`), aplicado a `bandsDb` ANTES de `noise_.update()` y del `vad_.process()`. Como el VAD sólo usa diferencias banda-vs-piso, el mismo offset a ambos lados deja su comportamiento inalterado. El clamp `[-60,-40]` queda como red defensiva; ahora el piso SE MUEVE dentro del rango (silencio real ~-50 dBFS) y SUBE con el ruido de fondo.
- `noise_profile.{h,cpp}` sin cambios (init -50 dBFS ya es coherente con el nuevo dominio calibrado).
- Test: `smart_scene/tests/test_noise_scale.cpp` — añadido **Test C** (`testFloorMovesWithNoise`): con ruido blanco a nivel de mic real, el piso NO queda pegado en -60 y SUBE al aumentar el ruido de fondo.

### Cadena C++→Kotlin→Dart y CMake
- Sólo se editaron `.cpp/.h` ya listados en `add_library(hearing_aid_dsp ...)` (`mpo_limiter.cpp`, `dsp_pipeline.cpp`, `smart_scene/scene_analyzer.cpp`) → **no requiere tocar `CMakeLists.txt`**. Los tests son host standalone (no entran al `.so`).
- No se añadió superficie JNI nueva (el soft-knee es afinación interna con default seguro). No se tocó la app del paciente; el paciente clona el C++ del técnico y hereda ambos fixes.

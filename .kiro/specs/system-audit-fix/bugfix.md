# Bugfix — Auditoría completa del sistema (junio 2026)

## Introduction

Tras correr el suite de tests completo (`flutter test` sin filtro) y una
auditoría profesional del workspace, se detectaron:

- **19 fallas activas** en tests reales (no las 4 ya resueltas de SafetyWarningWidget).
- **4 hallazgos CRÍTICOS** clínico-regulatorios (PIN hardcodeado, calibración con `Random()`,
  MethodChannels Dart sin handler nativo, BLE clamp fuera de rango).
- **10 hallazgos ALTO** (asserts de producción que se borran en release, modo CIN roto
  end-to-end, tabla NAL desviada, widgets clínicos orphan, etc.).
- Errores de compilación en `flutter analyze` por dependencia faltante
  (`flutter_blue_plus`) y target faltante (`integration_test`).

Reporte profesional completo en
`.kiro_tmp/auditoria-2026-06-05.md`. Output del suite full en
`.kiro_tmp/audit-fulltest.txt`. Output del analyze en
`.kiro_tmp/audit-analyze.txt`.

## Bug Analysis

### Current Behavior (Defects)

**Defectos clínicos activos:**

1. `mpo_limiter` no limita la salida cuando el input excede el threshold
   (property tests fallan con `Actual: 0.7448 > Expected: 0.3318`). Defecto
   clínico directo: el MPO no protege contra overshoot de 6+ dB.
2. `calibration_serializer.serialize` escribe 78 bytes en buffer de 75
   (`RangeError: byteOffset 78 < 75`). Toda la persistencia de calibración
   está rota.
3. `headphone_calibrator._measureMicLevel` cae a `Random()` cuando el canal
   nativo falla. El MethodChannel `getInputLevel` no existe en
   `AudioMethodChannel.kt` → siempre cae a la simulación.
4. `audio_bridge_impl.calibrateMicrophone` y `calibrateHeadphones` invocan
   métodos inexistentes en Kotlin → `MissingPluginException` en device.
5. `BleRepository.setMpoThreshold` clamps `[90, 110]` mientras todo el
   sistema usa `[80, 132]`; `assert` se borra en release; valor fuera de
   rango llega al firmware del audífono.

**Defectos de testing:**

6. 7 tests de `amplification_bloc_test.dart` fallan con
   `HiveError: You need to initialize Hive` (faltan setUp con tempPath).
7. 7 tests de `calibration_serializer_test.dart` fallan por el bug del
   buffer (defecto #2).
8. 3 tests de `hive_repositories_test.dart` y `custom_preset_repository_test.dart`
   fallan por lógica de detección de blobs corruptos.
9. 2 tests de `release_gate_test.dart` fallan.
10. `ble_repository_test.dart` no carga: dependencia `flutter_blue_plus`
    no está declarada en `pubspec.yaml`.
11. `integration_test/e2e_integration_test.dart` no carga: paquete
    `integration_test` no está en `dev_dependencies`.

**Hallazgos críticos de la auditoría (no son fallas de tests pero son riesgos clínicos):**

12. **C-1**: PIN `'1234'`/`'0000'` hardcodeado en `manual_calibration_screen.dart:74`
    y `loopback_qc_screen.dart:51`. La cadena de auditoría QC es trivialmente
    forjable.
13. **A-2**: 9 `assert(rango)` en código de producción
    (`audio_bridge_impl.dart`, `ble_repository.dart`, `gain_prescriber.dart`,
    `cin_module.dart`, `calibration_*.dart`). Se eliminan en release mode →
    valores fuera de rango llegan al engine nativo y al firmware.
14. **A-3 / M-8**: `BundleBuilder` y `gain_prescriber_nl3` rompen pureza
    documentada usando `DateTime.now()` directo. Determinismo solo se cumple
    en tests porque mockean `derivedAt`/`timestamp`. El bloc real no inyecta.
15. **A-4**: Modo CIN (`comfortInNoise`) **no aplica reducción non-speech band**
    en el camino del bundle. El chip dice "CIN" pero el motor recibe ganancias
    quiet. Feature documentada (Req 3.1-3.7 del spec NL3) rota end-to-end.
16. **A-7**: `_onChangeVolume` y `_onChangeProfile` tragan errores del bridge
    con `catch (_) {}`. State desincronizado del DSP real sin notificar.
17. **A-9**: 5 widgets clínicos completos sin integración a UI:
    `ManualEqOverlay`, `StalePresetList`, `GainScaleSlider`,
    `ClinicalInfoChips`, `ClampedBandsIndicator`. Wave 6 marcada `[x]` pero
    las features no son alcanzables. El slider de gainScale no aparece en
    Modo Amplificador.
18. **A-10**: Conversión HL→SPL real-ear es código muerto en runtime — el
    `RecdProvider` existe pero ningún sitio en `lib/` lo configura ni setea
    `ageYears`.

### Expected Behavior (Correct)

- Suite completa `flutter test` pasa con 0 fallas (1016/0 idealmente, o
  documentadas como skip).
- `flutter analyze` sin errors (warnings deprecated tolerables, pero no
  `undefined_class`/`uri_does_not_exist`).
- `mpo_limiter` limita output a ≤ threshold cuando se excede.
- MethodChannels invocados desde Dart existen en el handler nativo
  correspondiente.
- BLE rango alineado a `[80, 132]` con validación que no se borre en release.
- PIN de operador en Hive (configurable, no hardcodeado).
- Calibración nunca cae a `Random()`; propaga error si el canal falla.
- 9 asserts críticos convertidos a `if (...) throw ArgumentError(...)`.
- `BundleBuilder` y `gain_prescriber_nl3` no usan `DateTime.now()` directo;
  inyectan `Clock` por constructor.
- Modo CIN aplica `CinModule` en el path del bundle.
- `_onChangeVolume` y `_onChangeProfile` emiten `AmplificationError` cuando
  el bridge falla.
- 5 widgets orphan integrados a `MainScreen`.
- `RecdProvider` cableado en `_buildPatientProfile()` con `ageYears` desde
  `PatientProfile`.

### Unchanged Behavior (Regression Prevention)

- La tabla `_nalTable` NO se autocorrige (riesgo P0 abierto en
  `spec-review-pending.md`, requiere licencia NAL).
- Las propiedades clínicas validadas que ya pasan (UclEstimator, MpoDeriver,
  StyleApplicator, BundleBuilder field counts, NL3 prescription) no se tocan.
- Los 442 tests que ya pasaban (domain + widgets) siguen pasando.
- El comportamiento numérico del DSP (gains, ratios, knees, MPO derivado)
  no cambia.

## Plan de implementación

### Wave 0 — Fix tests rotos por entorno (sin tocar lógica)

- [ ] 1. Restaurar `flutter_blue_plus` en `pubspec.yaml`
  - [ ] 1.1 Agregar dependencia `flutter_blue_plus` con versión compatible (lanzada antes de junio 2026)
    - Editar `hearing_aid_app/pubspec.yaml` → `dependencies:` agregar `flutter_blue_plus: ^1.32.x` (versión estable más reciente compatible con Flutter del proyecto)
    - Correr `flutter pub get` para resolver
    - Verificar que `lib/data/repositories/ble_repository.dart` ya no tiene errors de compilación
    - _Files: pubspec.yaml_

  - [ ] 1.2 Restaurar `integration_test` en `dev_dependencies`
    - Editar `hearing_aid_app/pubspec.yaml` → `dev_dependencies:` agregar `integration_test:\n    sdk: flutter`
    - Correr `flutter pub get`
    - Verificar que `integration_test/e2e_integration_test.dart` compila
    - _Files: pubspec.yaml_

- [ ] 2. Fix Hive init en `amplification_bloc_test.dart`
  - [ ] 2.1 Agregar `setUpAll` con `path_provider_platform_interface` mock + `Hive.init(tempDir)`
    - Editar `test/presentation/bloc/amplification_bloc_test.dart`
    - Patrón: usar `Hive.init(Directory.systemTemp.createTempSync('hive_test_').path)` en `setUpAll`
    - `tearDownAll`: `await Hive.deleteFromDisk()` o `Hive.close()`
    - Verificar que los 7 tests que fallan con `HiveError` pasen
    - _Files: test/presentation/bloc/amplification_bloc_test.dart_

### Wave 1 — Fix defectos clínicos activos (orden de criticidad)

- [ ] 3. Fix `mpo_limiter` no limita la salida (defecto clínico mayor)
  - [ ] 3.1 Investigar y reparar la lógica del limitador
    - Test fallido: `mpo_limiter_property_test.dart` "no output sample exceeds threshold after attack time" → falla con `Actual: 0.7448` cuando esperado `≤ 0.3318`.
    - Test fallido: "sustained over-threshold signal is continuously limited" → `0.345 > 0.331`.
    - Inspeccionar `lib/domain/mpo_limiter*.dart` o el equivalente C++ en `android/app/src/main/cpp/mpo_limiter.cpp`
    - Verificar que el threshold se aplica correctamente al sample tras el attack time
    - El test es property-based: el contraejemplo es input `-0.1` shrink-eado 699 veces y `0.6` shrink-eado 1 vez
    - _Files: lib/domain/mpo_limiter*.dart, possibly cpp_

- [ ] 4. Fix `calibration_serializer.serialize` buffer overrun
  - [ ] 4.1 Recalcular tamaño correcto del buffer
    - `lib/data/serializers/calibration_serializer.dart:178` escribe `setUint32` en byteOffset 78 mientras buffer es 75 bytes
    - Ajustar tamaño del buffer al real (probablemente 78+ bytes) o al payload real
    - Verificar consistencia entre `serialize()` y `deserialize()`
    - Los 7 tests de `Property 9: Calibration Data Serialization Round-Trip` deben pasar
    - _Files: lib/data/serializers/calibration_serializer.dart_

- [ ] 5. Fix BLE clamp fuera de rango clínico (C-4)
  - [ ] 5.1 Alinear `BleRepository.setMpoThreshold` al rango sistema [80, 132]
    - `lib/data/repositories/ble_repository.dart:451-457`: cambiar `assert(thresholdDb >= 90 && thresholdDb <= 110)` por:
      ```dart
      if (thresholdDb < 80 || thresholdDb > 132) {
        throw ArgumentError.value(thresholdDb, 'thresholdDb',
          'Out of clinical range [80, 132] dB SPL');
      }
      ```
    - Documentar el rango real del firmware (consultar protocolo)
    - Reemplazar `assert` similares en métodos BLE adyacentes (ver A-2)
    - _Files: lib/data/repositories/ble_repository.dart_

- [ ] 6. Fix `headphone_calibrator` simulación con Random (C-2)
  - [ ] 6.1 Eliminar el fallback a Random
    - `lib/data/services/headphone_calibrator.dart:220-262`: si `_channel.invokeMethod('getInputLevel')` lanza `MissingPluginException` o `PlatformException`, propagar la excepción con mensaje claro
    - Eliminar el bloque `// Placeholder: simular medición basada en la amplitud emitida`
    - Eliminar el `Random()` y todo el cálculo de noise
    - El operador debe ver un error real si no hay canal nativo, no datos falsos
    - _Files: lib/data/services/headphone_calibrator.dart_

- [ ] 7. Implementar handlers nativos faltantes (C-3)
  - [ ] 7.1 Agregar handler `getInputLevel` en Kotlin
    - `android/app/src/main/kotlin/com/psk/hearing_aid_app/AudioMethodChannel.kt`: agregar case en el switch que retorne el nivel de input actual del engine en dB SPL
    - Si el método no es soportable en el plataforma actual, retornar `result.notImplemented()` documentado (no `result.success(null)`)
    - _Files: android/app/src/main/kotlin/com/psk/hearing_aid_app/AudioMethodChannel.kt_

  - [ ] 7.2 Agregar handler `calibrateMicrophone` en Kotlin
    - Mismo archivo: case que invoque la rutina de calibración del micrófono y retorne offset en dB SPL
    - _Files: android/app/src/main/kotlin/com/psk/hearing_aid_app/AudioMethodChannel.kt_

  - [ ] 7.3 Agregar handler `calibrateHeadphones` en Kotlin
    - Mismo archivo: case que invoque la rutina de calibración de auricular y retorne `Map<int,double>` con compensación per-banda
    - _Files: android/app/src/main/kotlin/com/psk/hearing_aid_app/AudioMethodChannel.kt_

### Wave 2 — Endurecimiento de validaciones (A-2)

- [ ] 8. Convertir asserts críticos a validaciones de runtime
  - [ ] 8.1 `audio_bridge_impl.dart`: 3 asserts → ArgumentError
    - Líneas 83 (`gains.length == 12`), 91 (`volumeDb` rango), 114 (`level` rango)
    - Patrón: `if (cond_invalida) throw ArgumentError.value(...)`
    - _Files: lib/data/bridges/audio_bridge_impl.dart_

  - [ ] 8.2 `ble_repository.dart`: 5 asserts → ArgumentError
    - Líneas 426-462: gains, volume, profileIndex, mpoThreshold (ya cubierto en task 5), nrLevel
    - _Files: lib/data/repositories/ble_repository.dart_

  - [ ] 8.3 `gain_prescriber.dart` y `cin_module.dart`: asserts de tamaño 12
    - `lib/domain/gain_prescriber.dart:159` `assert(prescribedGains.length == 12)`
    - `lib/domain/cin_module.dart:93-97` (2 asserts)
    - Convertir todos a `ArgumentError`
    - _Files: lib/domain/gain_prescriber.dart, lib/domain/cin_module.dart_

  - [ ] 8.4 `calibration_repository.dart` y `calibration_serializer.dart`: 3 asserts
    - `lib/data/repositories/calibration_repository.dart:233`
    - `lib/data/serializers/calibration_serializer.dart:99-100`
    - Convertir a `ArgumentError`
    - _Files: lib/data/repositories/calibration_repository.dart, lib/data/serializers/calibration_serializer.dart_

### Wave 3 — Pureza determinista (A-3, M-8)

- [ ] 9. Inyectar Clock en BundleBuilder y NL3
  - [ ] 9.1 Constructor de `BundleBuilder` acepta `DateTime Function()? clock` opcional
    - `lib/domain/audiogram_driven_presets/bundle_builder.dart`: agregar `final DateTime Function() _clock;` y constructor que lo defaultea a `DateTime.now`
    - Línea 413: `derivedAt: derivedAt ?? _clock().toUtc()` en lugar de `DateTime.now()`
    - _Files: lib/domain/audiogram_driven_presets/bundle_builder.dart_

  - [ ] 9.2 Constructor de `GainPrescriberNL3` acepta `DateTime Function()? clock`
    - `lib/domain/gain_prescriber_nl3.dart`: mismo patrón
    - Líneas 191, 237: usar `_clock()` en lugar de `DateTime.now()`
    - _Files: lib/domain/gain_prescriber_nl3.dart_

  - [ ] 9.3 Bloc instancia los dos pasando `clock` desde su constructor
    - `lib/presentation/bloc/amplification_bloc.dart`: agregar `final DateTime Function() clock;` al constructor del bloc, defaultearlo a `DateTime.now`
    - Pasarlo a `BundleBuilder` y `GainPrescriberNL3` en su construcción
    - Línea 1591 del bloc: el TODO `inyectar clock en wave 7` se cumple acá; usar `_clock().toUtc()` en `editedAt: ...`
    - _Files: lib/presentation/bloc/amplification_bloc.dart_

### Wave 4 — Modo CIN end-to-end (A-4)

- [ ] 10. Cablear CinModule al BundleBuilder
  - [ ] 10.1 BundleBuilder aplica CinModule cuando mode == comfortInNoise
    - `lib/domain/audiogram_driven_presets/bundle_builder.dart`: tras obtener `prescribedGains` del NL3, si `mode == PrescriptionMode.comfortInNoise`, llamar `CinModule.apply(gains)` antes del clamp final
    - _Files: lib/domain/audiogram_driven_presets/bundle_builder.dart_

  - [ ] 10.2 Eliminar invocaciones legacy de CinModule en el bloc
    - `lib/presentation/bloc/amplification_bloc.dart` líneas ~1249 y ~1323: simplificar `_onSceneClassUpdated` para que rebuild el bundle y lance `ApplyAudiogramDrivenBundle` (el camino atómico ya cubre rollback)
    - _Files: lib/presentation/bloc/amplification_bloc.dart_

  - [ ] 10.3 Test de integración que valida CIN end-to-end
    - Crear test que valide: dado un audiograma X, el bundle en modo `comfortInNoise` tiene ganancias non-speech band ≤ a las del mismo audiograma en modo `quiet` por al menos 3 dB
    - _Files: test/integration/cin_end_to_end_test.dart (nuevo)_

### Wave 5 — Manejo de errores del bridge (A-7)

- [ ] 11. Emitir AmplificationError en handlers que tragan errores
  - [ ] 11.1 `_onChangeVolume`: try/catch con emit
    - `lib/presentation/bloc/amplification_bloc.dart:466-476`: reemplazar `catch (_) {}` por `catch (e, st) { emit(AmplificationError(stage: 'updateVolume', message: e.toString())); return; }` antes del `emit(currentState.copyWith(...))`
    - _Files: lib/presentation/bloc/amplification_bloc.dart_

  - [ ] 11.2 `_onChangeProfile`: idem
    - Línea ~474 del mismo archivo
    - _Files: lib/presentation/bloc/amplification_bloc.dart_

### Wave 6 — Integración de widgets orphan (A-9)

- [ ] 12. Integrar widgets clínicos a la UI
  - [ ] 12.1 Integrar `GainScaleSlider` a `MainScreen` cuando OperatingMode == amplifier
    - `lib/presentation/screens/main_screen.dart`: agregar el slider visible solo en modo amplificador, debajo del volumen broadband
    - _Files: lib/presentation/screens/main_screen.dart_

  - [ ] 12.2 Integrar `ClinicalInfoChips` al header de MainScreen
    - Mostrar chips de LossType + PrescriptionMode cuando hay bundle activo
    - _Files: lib/presentation/screens/main_screen.dart_

  - [ ] 12.3 Integrar `StalePresetList` a la pantalla de presets custom
    - `lib/presentation/screens/custom_presets_screen.dart` o equivalente
    - _Files: pantalla de presets (a identificar)_

  - [ ] 12.4 Integrar `ClampedBandsIndicator` a la vista de bundle activo
    - Donde se muestre el bundle aplicado, agregar el indicador de bandas clamped
    - _Files: lib/presentation/screens/main_screen.dart o dsp_config_detail_screen.dart_

  - [ ] 12.5 Integrar `ManualEqOverlay` accesible desde un botón "EQ manual"
    - Botón en `MainScreen` que despliegue el overlay; despacha `ManualEqAdjust` y `ResetManualDelta` al bloc
    - _Files: lib/presentation/screens/main_screen.dart_

### Wave 7 — Conversión real-ear cableada (A-10)

- [ ] 13. Cablear RecdProvider con ageYears
  - [ ] 13.1 Bloc setea ageYears en `_buildPatientProfile()` desde Hive/PatientProfile
    - `lib/presentation/bloc/amplification_bloc.dart`: en el método `_buildPatientProfile()`, leer `ageYears` desde `PatientProfile` persistido o desde el state
    - Pasar `RecdProvider` instanciado al `BundleBuilder` cuando se construye el bundle
    - Si `ageYears` es null, no se invoca el RecdProvider (comportamiento actual)
    - _Files: lib/presentation/bloc/amplification_bloc.dart_

### Wave 8 — Seguridad de operador (C-1)

- [ ] 14. PIN de operador configurable
  - [ ] 14.1 Mover PIN a Hive `service_settings_box`
    - `lib/presentation/calibration/manual_calibration_screen.dart:74` y `lib/presentation/screens/loopback_qc_screen.dart:51`
    - Reemplazar literal por lectura desde `Hive.box('service_settings').get('operator_pin')`
    - Si la box no tiene PIN configurado al primer acceso: generar PIN aleatorio de 6 dígitos, mostrarlo en pantalla con instrucción "anotalo, no se vuelve a mostrar", persistir hash (no el plain) en Hive
    - Comparar hash en login: `if (sha256(pin_input) == stored_hash) { ... }`
    - _Files: lib/presentation/calibration/manual_calibration_screen.dart, lib/presentation/screens/loopback_qc_screen.dart, lib/data/repositories/operator_pin_repository.dart (nuevo)_

### Wave 9 — Wrap-up y verificación

- [ ] 15. Re-correr suite full + analyze
  - [ ] 15.1 `flutter test` debe pasar 0 fallas (skipped permitidos si están documentados en `spec-review-pending.md`)
  - [ ] 15.2 `flutter analyze` debe quedar sin errors (warnings deprecated tolerables)
  - [ ] 15.3 Actualizar `errores.md` con E-009 o superior si emergen nuevos bugs de Kiro
  - [ ] 15.4 Actualizar `memoria.md` con avance de la sesión

## Verificación

Cada wave debe terminar con:
- Tests específicos de la wave en verde.
- `flutter analyze` sin nuevos errors introducidos.
- `dart analyze` clean en los archivos tocados.

Verificación final (al cerrar wave 9):
- `flutter test` global: ≥ 1016 passed, 0 failed, skipped ≤ 58.
- `flutter analyze`: 0 errors (solo info/warnings deprecated tolerables).
- Compilación de `ble_repository.dart` sin errors.
- Suite de `mpo_limiter_property_test.dart` corre con 100 inputs sin fallar.
- Smoke test manual post-cambios documentado.

## Riesgos y rollback

- **Riesgo medio en Wave 1**: tocar `mpo_limiter` puede afectar la dinámica
  del audio. Validar con tests existentes y, si la falla está en C++, hacer
  el cambio en el cpp con review.
- **Riesgo medio en Wave 4**: cablear CinModule al BundleBuilder cambia el
  comportamiento clínico documentado en spec audiogram-driven-presets. Los
  tests existentes deben re-pasar; los nuevos deben validar el delta CIN vs
  quiet.
- **Riesgo bajo en Wave 8**: introducir PIN configurable rompe acceso a
  pantallas técnicas si la migración inicial falla. Documentar el flujo
  "primer arranque después del fix → PIN aleatorio mostrado y persistido".

Rollback: cada wave es un commit; revertir si hay regresión.

## Estado

- **Detectado:** 2026-06-05, durante auditoría profesional + suite full
  post-fix de SafetyWarningWidget.
- **Owner:** Run All Tasks orchestrator.
- **Prioridad:** P0 para Wave 1 (defectos clínicos activos),
  P1 para Wave 2-7, P2 para Wave 8-9.

## Pendientes para el equipo nativo (C-3, Wave 2 / Task 3.1)

La task **3.1** de `tasks.md` agregó tres handlers explícitos en
`android/app/src/main/kotlin/com/psk/hearing_aid_app/AudioMethodChannel.kt`
que retornan `result.notImplemented()` con `Log.e` SEVERE y bloque `TODO(C-3)`
documentado. El caller Dart ya maneja la excepción graciosamente (task 2.4
eliminó el fallback `Random()`), pero la **implementación real sigue pendiente**.

| MethodChannel        | Variante elegida          | Trabajo pendiente                                                                                                                                    |
| -------------------- | ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `getInputLevel`      | A — `notImplemented` stub | Exponer nivel de entrada PRE-EQ en **dBFS** (no dB SPL post-pipeline). Probable: nuevo `nativeGetInputLevelDbfs()` que lea `AudioRecord` directo, fuera del engine. El método existente `nativeGetInputLevel()` devuelve dB SPL con `splOffset` aplicado y sólo cuando el engine está corriendo, lo que causaría doble offset clínico si se cableara tal cual. |
| `calibrateMicrophone` | A — `notImplemented` stub | Implementar rutina nativa con `AudioRecord` + tono de referencia que retorne map con `splOffset`, `confidenceLevel`, `method`, `calibratedAtMs`, `deviceModel`. Contrato en `lib/data/bridges/audio_bridge_impl.dart::calibrateMicrophone`. |
| `calibrateHeadphones` | A — `notImplemented` stub | Implementar loopback (sweep + medición de respuesta) que retorne map con `frequencyResponse`, `compensation`, `headphoneId`, `headphoneName`, `calibratedAtMs`, `isBluetooth`. Contrato en `lib/data/bridges/audio_bridge_impl.dart::calibrateHeadphones`. |

**Comportamiento actual en device real (post task 3.1):**

- El canal Dart recibe ahora `MissingPluginException` con código canónico
  Flutter, no un crash silencioso ni datos inventados.
- `headphone_calibrator._measureMicLevel` (post task 2.4) propaga la
  excepción como `StateError` con mensaje claro. El operador ve el error;
  no se persisten compensaciones falsas en Hive.
- `audio_bridge_impl.calibrateMicrophone` y `calibrateHeadphones` propagan
  la `MissingPluginException` al bloc/UI con su mensaje canónico.

**No se modificó código C++ ni `NativeAudioBridge.kt`** — la regla del
orquestador prohíbe tocar `.cpp/.h` y otros `.kt` desde la task 3.1. La
implementación real entra como una task separada cuando el equipo nativo
retome la calibración.


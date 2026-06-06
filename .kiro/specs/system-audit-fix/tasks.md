# Implementation Plan: System Audit Fix

## Overview

Resolver las **19 fallas activas** del suite full de tests + los **4 hallazgos
CRÍTICOS** + **10 ALTO** + **10 MEDIO** identificados en la auditoría del
2026-06-05. Análisis completo en `.kiro_tmp/auditoria-2026-06-05.md` y
`.kiro_tmp/audit-fulltest.txt`.

Spec hermano: `bugfix.md` con análisis y racional. Este archivo es el
**plan ejecutable** por el orquestador "Run All Tasks".

Convenciones:
- `[ ]` task pendiente, `[x]` completada, `[ ]*` opcional.
- Cada subtarea cita los `Files:` que toca para que los subagentes acoten su scope.
- Las waves son disjuntas: dentro de una wave se puede paralelizar.

## Tasks

- [ ] 1. Wave 0 — Fix dependencias y entorno de tests
  - [x] 1.1 Restaurar dependencia `flutter_blue_plus` en pubspec.yaml
    - Agregar a `dependencies:` del archivo `hearing_aid_app/pubspec.yaml` la línea
      `flutter_blue_plus: ^1.32.12` (versión estable más reciente compatible).
    - Si la versión exacta no resuelve, probar `^1.31.x` o `^1.30.x`.
    - Correr `flutter pub get` y verificar que `lib/data/repositories/ble_repository.dart` compila.
    - Files: hearing_aid_app/pubspec.yaml
    - _Defectos: 10_

  - [x] 1.2 Restaurar `integration_test` en dev_dependencies
    - Agregar a `dev_dependencies:` del `pubspec.yaml`:
      ```yaml
      integration_test:
        sdk: flutter
      ```
    - Correr `flutter pub get`. Verificar que `integration_test/e2e_integration_test.dart` compila.
    - Files: hearing_aid_app/pubspec.yaml
    - _Defectos: 11_

  - [x] 1.3 Fix Hive init en amplification_bloc_test.dart
    - Agregar `setUpAll` que inicialice Hive en directorio temporal: `Hive.init(Directory.systemTemp.createTempSync('hive_amp_test_').path)`.
    - Agregar `tearDownAll` que cierre con `await Hive.close()`.
    - Verificar que los 7 tests que fallan con `HiveError: You need to initialize Hive` pasen.
    - Files: hearing_aid_app/test/presentation/bloc/amplification_bloc_test.dart
    - _Defectos: 6_

- [ ] 2. Wave 1 — Defectos clínicos activos (P0)
  - [x] 2.1 Reparar mpo_limiter (no limita output cuando excede threshold)
    - Inspeccionar primero `lib/domain/audiogram_driven_presets/` y `lib/dsp/` por archivos que contengan "MpoLimiter" o "mpo_limiter".
    - Si la lógica está en Dart: corregir el algoritmo para que tras el attack time, ningún sample exceda el threshold.
    - Si está en C++ (`android/app/src/main/cpp/mpo_limiter.cpp`): reportar al final con archivo:línea pero no modificar (requiere build nativo).
    - Test que debe pasar: `test/domain/audiogram_driven_presets/mpo_limiter_property_test.dart` ambas properties (no exceeds threshold + sustained over-threshold).
    - Files: a identificar (lib/domain/* o lib/dsp/*)
    - _Defectos: 1_

  - [x] 2.2 Fix calibration_serializer buffer overrun
    - El test indica `RangeError: Index out of range: index should be less than 75: 78`. El buffer fue dimensionado para 75 bytes pero se escribe en byteOffset 78.
    - Inspeccionar `lib/data/serializers/calibration_serializer.dart`. Probablemente la línea `final buffer = ByteData(75);` debe ser `ByteData(N)` con N suficiente para todos los `setUint32` y campos.
    - Recalcular el tamaño: contar bytes que escribe `serialize()` (1 versión + N campos). Asegurar que `deserialize()` lee del mismo offset.
    - Verificar 7 tests de `Property 9: Calibration Data Serialization Round-Trip`.
    - Files: hearing_aid_app/lib/data/serializers/calibration_serializer.dart
    - _Defectos: 2, 7_

  - [x] 2.3 Alinear BLE setMpoThreshold al rango clínico [80, 132]
    - En `lib/data/repositories/ble_repository.dart:451-457`, reemplazar:
      ```dart
      assert(thresholdDb >= 90 && thresholdDb <= 110);
      ```
      por:
      ```dart
      if (thresholdDb < 80 || thresholdDb > 132) {
        throw ArgumentError.value(thresholdDb, 'thresholdDb',
          'Out of clinical range [80, 132] dB SPL');
      }
      ```
    - Si el valor a enviar al firmware es 1 byte (`Uint8List`), agregar comentario explicando que el firmware soporta el rango y citar protocolo. Si no soporta 132, agregar clamp adicional con log warning.
    - Files: hearing_aid_app/lib/data/repositories/ble_repository.dart
    - _Defectos: 5, hallazgo C-4_

  - [x] 2.4 Eliminar fallback Random en headphone_calibrator
    - En `lib/data/services/headphone_calibrator.dart:220-262`, eliminar el bloque que simula con `Random()` cuando `MissingPluginException`/`PlatformException`.
    - Reemplazar por: propagar la excepción con mensaje claro indicando "Canal nativo getInputLevel no implementado en esta plataforma".
    - El operador ve un error real, no datos falsos.
    - Files: hearing_aid_app/lib/data/services/headphone_calibrator.dart
    - _Defectos: 3, hallazgo C-2_

- [ ] 3. Wave 2 — MethodChannels nativos faltantes (C-3)
  - [x] 3.1 Inspeccionar y reportar handlers nativos faltantes
    - Listar todos los `_channel.invokeMethod(...)` usados en `lib/` que no aparecen en `android/app/src/main/kotlin/com/psk/hearing_aid_app/AudioMethodChannel.kt`.
    - Métodos confirmados ausentes: `getInputLevel`, `calibrateMicrophone`, `calibrateHeadphones`.
    - Para cada método ausente:
      - Si es trivial (solo retorna un valor stub): agregar handler en Kotlin que retorne `result.notImplemented()` documentado o un valor de no-op.
      - Si requiere lógica real (acceso a AudioRecord, calibración): documentar en `bugfix.md` para implementación coordinada con el equipo nativo, y en Dart hacer que el caller maneje `MissingPluginException` graciosamente sin ocultar el error.
    - Files: android/app/src/main/kotlin/com/psk/hearing_aid_app/AudioMethodChannel.kt + lib/data/bridges/audio_bridge_impl.dart + lib/data/services/headphone_calibrator.dart
    - _Defectos: 4, hallazgo C-3_

- [ ] 4. Wave 3 — Asserts de producción → ArgumentError (A-2)
  - [x] 4.1 Convertir asserts de audio_bridge_impl.dart
    - Líneas 83, 91, 114: reemplazar `assert(cond)` por `if (!cond) throw ArgumentError.value(arg, name, 'msg')`.
    - Mantener los mensajes de error claros (incluir valor recibido).
    - Files: hearing_aid_app/lib/data/bridges/audio_bridge_impl.dart
    - _Defectos: hallazgo A-2_

  - [x] 4.2 Convertir asserts de ble_repository.dart
    - Líneas 426-462 (5 asserts: gains, volume, profileIndex, mpoThreshold ya cubierto en 2.3, nrLevel).
    - Mismo patrón: `if (!cond) throw ArgumentError(...)`.
    - Files: hearing_aid_app/lib/data/repositories/ble_repository.dart
    - _Defectos: hallazgo A-2_

  - [x] 4.3 Convertir asserts de gain_prescriber.dart y cin_module.dart
    - `lib/domain/gain_prescriber.dart:159` y `lib/domain/cin_module.dart:93-97`.
    - Files: hearing_aid_app/lib/domain/gain_prescriber.dart, hearing_aid_app/lib/domain/cin_module.dart
    - _Defectos: hallazgo A-2_

  - [x] 4.4 Convertir asserts de calibration_repository y calibration_serializer
    - `lib/data/repositories/calibration_repository.dart:233`.
    - `lib/data/serializers/calibration_serializer.dart:99-100`.
    - Files: hearing_aid_app/lib/data/repositories/calibration_repository.dart, hearing_aid_app/lib/data/serializers/calibration_serializer.dart
    - _Defectos: hallazgo A-2_

- [ ] 5. Wave 4 — Pureza determinista (A-3, M-8)
  - [x] 5.1 Inyectar Clock en BundleBuilder
    - Agregar `final DateTime Function() _clock;` al constructor de `BundleBuilder`, default `DateTime.now`.
    - Reemplazar `DateTime.now()` directo de la línea 413 por `_clock().toUtc()`.
    - Mantener `derivedAt` parameter override del método para tests.
    - Files: hearing_aid_app/lib/domain/audiogram_driven_presets/bundle_builder.dart
    - _Defectos: hallazgo A-3_

  - [x] 5.2 Inyectar Clock en GainPrescriberNL3
    - Mismo patrón: `final DateTime Function() _clock;` al constructor.
    - Reemplazar `DateTime.now()` líneas 191, 237 por `_clock()`.
    - Files: hearing_aid_app/lib/domain/gain_prescriber_nl3.dart
    - _Defectos: hallazgo M-8_

  - [x] 5.3 Bloc instancia con clock inyectable
    - `AmplificationBloc` constructor acepta `DateTime Function()? clock` (default `DateTime.now`).
    - Pasarlo a `BundleBuilder` y `GainPrescriberNL3` en su construcción.
    - Línea 1591 del bloc: cumplir el TODO `inyectar clock en wave 7`; usar `_clock().toUtc()` en `editedAt:`.
    - Actualizar tests del bloc para inyectar un clock fake si hay aserciones temporales.
    - Files: hearing_aid_app/lib/presentation/bloc/amplification_bloc.dart, hearing_aid_app/test/presentation/bloc/amplification_bloc_test.dart
    - _Defectos: hallazgo A-3, B-3_

- [ ] 6. Wave 5 — Modo CIN end-to-end (A-4)
  - [x] 6.1 BundleBuilder aplica CinModule cuando mode == comfortInNoise
    - Tras obtener `prescribedGains` del NL3 en `BundleBuilder.buildFromAudiogram`, si `mode == PrescriptionMode.comfortInNoise` invocar `CinModule.apply(gains)` antes del clamp final.
    - Asegurar que la lógica respete `gainScale` después de CinModule, no antes.
    - Files: hearing_aid_app/lib/domain/audiogram_driven_presets/bundle_builder.dart
    - _Defectos: hallazgo A-4_

  - [x] 6.2 Eliminar invocaciones legacy de CinModule en el bloc
    - `lib/presentation/bloc/amplification_bloc.dart` líneas ~1249 y ~1323 (handlers `_onSceneClassUpdated` y `_onSetExperienceMonths`): simplificar para que rebuild del bundle y dispatch `ApplyAudiogramDrivenBundle` (el camino atómico cubre rollback).
    - No tragar errores con `catch (_)` — emit `AmplificationError` consistente.
    - Files: hearing_aid_app/lib/presentation/bloc/amplification_bloc.dart
    - _Defectos: hallazgo A-4, M-5_

  - [x] 6.3 Test de integración CIN end-to-end
    - Crear `test/integration/cin_end_to_end_test.dart`.
    - Validar: dado `audiograma N3`, bundle en modo `comfortInNoise` tiene ganancias non-speech band (250, 500, 6000, 8000 Hz) ≤ a las del mismo audiograma en modo `quiet` por al menos 3 dB.
    - Validar también: `bundle.prescriptionMode == comfortInNoise` y `bundle.nrLevel == 2`.
    - Files: hearing_aid_app/test/integration/cin_end_to_end_test.dart
    - _Defectos: hallazgo A-4_

- [ ] 7. Wave 6 — Manejo de errores del bridge (A-7)
  - [x] 7.1 _onChangeVolume emite AmplificationError en falla
    - `lib/presentation/bloc/amplification_bloc.dart:466-476`: reemplazar `catch (_) {}` por
      ```dart
      catch (e, st) {
        log('Error in updateVolume: $e', name: 'AmplificationBloc', stackTrace: st);
        emit(AmplificationError(stage: 'updateVolume', message: e.toString()));
        return;
      }
      ```
      antes del `emit(currentState.copyWith(volumeDb: ...))`.
    - Files: hearing_aid_app/lib/presentation/bloc/amplification_bloc.dart
    - _Defectos: hallazgo A-7_

  - [x] 7.2 _onChangeProfile emite AmplificationError en falla
    - Mismo patrón en el handler `_onChangeProfile` (línea ~474).
    - Files: hearing_aid_app/lib/presentation/bloc/amplification_bloc.dart
    - _Defectos: hallazgo A-7_

- [ ] 8. Wave 7 — Integración de widgets clínicos (A-9)
  - [x] 8.1 Integrar GainScaleSlider en MainScreen (Modo Amplificador)
    - `lib/presentation/screens/main_screen.dart`: en el bloque que muestra el control de volumen, agregar un `GainScaleSlider` visible solo cuando `state is AmplificationActive && state.operatingMode == OperatingMode.amplifier`.
    - Files: hearing_aid_app/lib/presentation/screens/main_screen.dart
    - _Defectos: hallazgo A-9_

  - [x] 8.2 Integrar ClinicalInfoChips al header de MainScreen
    - Mismo archivo, en el header del `_ActiveView` (debajo del banner de modo): mostrar chips de LossType + PrescriptionMode cuando `state.bundle != null`.
    - Files: hearing_aid_app/lib/presentation/screens/main_screen.dart
    - _Defectos: hallazgo A-9_

  - [x] 8.3 Integrar ClampedBandsIndicator al panel de bundle activo
    - Si hay una pantalla `dsp_config_detail_screen.dart` o equivalente donde se muestra el bundle, agregar `ClampedBandsIndicator.fromPreset(...)`.
    - Si no hay esa pantalla, agregar al `MainScreen` debajo del slider de volumen.
    - Files: hearing_aid_app/lib/presentation/screens/main_screen.dart o dsp_config_detail_screen.dart
    - _Defectos: hallazgo A-9_

  - [x] 8.4 Integrar StalePresetList en pantalla de presets custom
    - Identificar la pantalla que lista presets custom (probablemente `lib/presentation/screens/custom_presets_screen.dart` o similar). Si no existe, crear ruta accesible desde MainScreen.
    - Reemplazar/complementar la lista actual con `StalePresetList`.
    - Files: hearing_aid_app/lib/presentation/screens/* (a identificar)
    - _Defectos: hallazgo A-9_

  - [x] 8.5 Integrar ManualEqOverlay accesible desde MainScreen
    - Botón "EQ manual" en `MainScreen` que despliegue el overlay en un `showModalBottomSheet` o pantalla dedicada.
    - El overlay despacha `ManualEqAdjust(bandIndex, deltaDelta)` y `ResetManualDelta()` al bloc.
    - Files: hearing_aid_app/lib/presentation/screens/main_screen.dart
    - _Defectos: hallazgo A-9_

- [ ] 9. Wave 8 — Conversión real-ear cableada (A-10)
  - [x] 9.1 Cablear ageYears en _buildPatientProfile()
    - `lib/presentation/bloc/amplification_bloc.dart`: en `_buildPatientProfile()`, leer `ageYears` desde Hive (probablemente `settings_box['patient_age_years']` o `PatientProfile` persistido en `audiogram_repository`).
    - Si no hay `ageYears` configurado, dejar null (comportamiento actual mantenido para retrocompatibilidad).
    - Pasar `RecdProvider()` al `BundleBuilder` cuando `ageYears != null`.
    - Files: hearing_aid_app/lib/presentation/bloc/amplification_bloc.dart
    - _Defectos: hallazgo A-10_

  - [x] 9.2 Test que valida el flujo end-to-end con ageYears
    - Crear test que: con un `PatientProfile(ageYears: 8)`, el bundle resultante invoca `_logRealEarConversion` (verificable por log o exponiendo un flag de auditoría).
    - Files: hearing_aid_app/test/integration/real_ear_conversion_test.dart
    - _Defectos: hallazgo A-10_

- [ ] 10. Wave 9 — PIN de operador configurable (C-1)
  - [x] 10.1 Crear OperatorPinRepository
    - Crear `lib/data/repositories/operator_pin_repository.dart` con métodos:
      - `Future<bool> hasPin()` — true si la box tiene PIN configurado.
      - `Future<String> generateAndStoreInitialPin()` — genera PIN aleatorio de 6 dígitos, lo retorna en plain (para mostrar al usuario una vez), persiste solo el SHA-256.
      - `Future<bool> verifyPin(String input)` — compara hash.
    - Hive box: `service_settings_box` (crear si no existe).
    - Files: hearing_aid_app/lib/data/repositories/operator_pin_repository.dart
    - _Defectos: hallazgo C-1_

  - [x] 10.2 manual_calibration_screen usa el repo
    - `lib/presentation/calibration/manual_calibration_screen.dart:74`: reemplazar `if (pin == '1234' || pin == '0000')` por `if (await _pinRepo.verifyPin(pin))`.
    - Si `!await _pinRepo.hasPin()` al primer arranque, mostrar diálogo "Genere su PIN inicial" → llamar `generateAndStoreInitialPin()` → mostrar PIN al operador con instrucción "anotalo, no se vuelve a mostrar".
    - Files: hearing_aid_app/lib/presentation/calibration/manual_calibration_screen.dart
    - _Defectos: hallazgo C-1_

  - [x] 10.3 loopback_qc_screen usa el repo
    - Mismo patrón en `lib/presentation/screens/loopback_qc_screen.dart:51`. Eliminar la constante `_kQcOperatorPin = '1234'`.
    - Files: hearing_aid_app/lib/presentation/screens/loopback_qc_screen.dart
    - _Defectos: hallazgo C-1, B-2_

  - [x] 10.4 Tests del repo
    - Crear `test/data/repositories/operator_pin_repository_test.dart` con casos: generación, verificación, primer-arranque, hash no reverso.
    - Files: hearing_aid_app/test/data/repositories/operator_pin_repository_test.dart
    - _Defectos: hallazgo C-1_

- [x] 11. Wave 10 — Verificación final
  - [x] 11.1 Re-correr suite full
    - `flutter test` debe quedar con 0 fallas. Skips permitidos solo si están documentados en `spec-review-pending.md`.
    - Generar archivo `.kiro_tmp/postfix-fulltest.txt` con el output.
    - Files: (test artifact)

  - [x] 11.2 Re-correr flutter analyze
    - `flutter analyze` debe quedar con 0 errors. Warnings deprecated permitidos.
    - Generar archivo `.kiro_tmp/postfix-analyze.txt`.
    - Files: (test artifact)
    - **Resultado**: PRE-FIX 20 errors / 24 warnings / 474 infos → POST-FIX **0 errors** / 25 warnings / 473 infos. Los 20 `uri_does_not_exist` y `undefined_*` (flutter_blue_plus + integration_test) quedaron resueltos por 1.1 y 1.2. Emergieron 2 warnings nuevos (no errors): `_lastNl3Result` unused_field y `_findEqPresetWdrcParams` unused_element en `lib/presentation/bloc/amplification_bloc.dart` (residuo de simplificación de la task 6.2). Tolerables — no son errors.

  - [x] 11.3 Actualizar memoria.md y errores.md
    - Agregar sección "Cierre 2026-06-XX — Auditoría system-audit-fix" al `memoria.md` con resumen de waves.
    - Si emergieron nuevos bugs de Kiro, agregar entradas E-009+ al `errores.md`.
    - Files: .kiro_tmp/memoria.md, .kiro_tmp/errores.md

## Dependency graph (waves)

- Wave 0 (1.1, 1.2, 1.3): pre-requisito de todo (sin dependencias compiladas, no se puede testear).
- Wave 1 (2.1, 2.2, 2.3, 2.4): defectos clínicos activos, paralelos entre sí. Depende de Wave 0.
- Wave 2 (3.1): MethodChannels. Depende de Wave 1 (2.4 toca `headphone_calibrator`).
- Wave 3 (4.1, 4.2, 4.3, 4.4): asserts → ArgumentError. Paralelos entre sí. Depende de Wave 1 (2.3).
- Wave 4 (5.1, 5.2, 5.3): clock inyectable. 5.3 depende de 5.1+5.2.
- Wave 5 (6.1, 6.2, 6.3): CIN end-to-end. 6.3 depende de 6.1+6.2.
- Wave 6 (7.1, 7.2): bridge errors. Paralelos.
- Wave 7 (8.1, 8.2, 8.3, 8.4, 8.5): widgets orphan. Paralelos.
- Wave 8 (9.1, 9.2): real-ear. 9.2 depende de 9.1.
- Wave 9 (10.1, 10.2, 10.3, 10.4): PIN. 10.2/10.3/10.4 dependen de 10.1.
- Wave 10 (11.1, 11.2, 11.3): verificación final. Depende de todo lo anterior.

## Notas para subagentes

1. **No autocorregir `_nalTable`** (riesgo P0 abierto, requiere licencia NAL).
   Si algún test toca esa tabla, escalar a `spec-review-pending.md`, no
   corregir.
2. **No romper los 442 tests verdes que ya pasaban** (domain + widgets,
   gain_prescriber, audiogram, bundle_builder, manual_adjustment_delta,
   nal_r_table_validation, mpo_deriver, etc.). Si un cambio rompe alguno,
   detener y reportar.
3. **No tocar la lógica numérica de DSP en C++** (`android/app/src/main/cpp/`)
   sin reportar al final. Si un fix necesita C++, reportar archivo:línea y
   continuar con la próxima task.
4. **Convención `errores.md`**: si emerge un bug del IDE Kiro durante la
   ejecución, agregar entrada E-XXX al `.kiro_tmp/errores.md` antes de cerrar
   la wave.
5. **Output verificable**: cada subtarea debe terminar con `flutter analyze`
   limpio para los archivos tocados (`getDiagnostics`) y, cuando aplique,
   los tests específicos en verde.

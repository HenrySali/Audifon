# Implementation Plan: Native Calibration Handlers

## Overview

Reemplazar los 3 handlers `notImplemented()` honestos del
`MethodChannel` `com.psk.hearing_aid/audio` con implementaciones reales
que cumplen las normas IEC 60942 (calibración mic), IEC 60318-4/5
(acoplador), IEC 61672-1 (sonómetro). Persistir audit trail con
SHA-256. Exponer un wizard guiado de 5 fases. Verificar con
property-based tests + golden vectors sintéticos (sin hardware
físico). El test integrado con calibrador real queda como "manual QC"
para el día que el usuario lo conecte.

Este plan cierra el P1 abierto en `.kiro_tmp/spec-review-pending.md`.

Convenciones:
- `[ ]` task pendiente, `[x]` completada.
- Cada subtarea cita los `Files:` que toca para que los subagentes acoten su scope.
- Las waves son disjuntas: dentro de una wave se puede paralelizar.

## Notes

- **Idioma:** español rioplatense en docs, mensajes UI y commits.
- **Sin hardware físico:** todos los tests deben funcionar 100% con
  golden vectors sintéticos. El usuario tiene calibrador en compra
  (cuando llegue ejecutará el "manual QC" documentado en design.md).
- **Cumplimiento IEC:** los valores numéricos vienen de
  `docs/03-investigacion/normas-calibracion-audifono.md` (1 kHz @ 94
  dB SPL, ±2 dB tolerancia, etc.).
- **No tocar `_nalTable`** ni la lógica DSP de C++ existente sin
  reportar. Los handlers nativos usan AudioRecord directo, NO el
  pipeline DSP del proyecto.
- **PowerShell + paths con espacios:** ver workaround E-007/E-011 en
  `.kiro_tmp/errores.md`. Usar `.cmd` intermedio con `cd /d "<absoluto>"`
  + redirección a path absoluto. Path al PATH:
  `set "PATH=C:\dev\flutter\bin;%PATH%"` antes de `call flutter test`.
- **Preservar 1096 tests existentes:** si un cambio rompe alguno,
  abortar y reportar.
- **Trazabilidad:** los handlers nativos loggean cada paso con
  `Log.i/e` y prefijo `<handlerName>:`. El audit trail Dart usa
  `developer.log` con `name: 'NativeCalibration'` y nivel INFO/SEVERE.
- **PBT con glados:** importar `package:glados/glados.dart` y ocultar
  los símbolos duplicados con flutter_test (ver patrón en
  `dnn_denoiser_controller_test.dart`).
- **Sin shortcuts en tests:** rechazar la tentación de aflojar los
  asserts. Si una property falla, diagnosticar la causa real, no
  debilitar el test.

## Tasks

- [x] 0. Wave 0 — Foundations (audit trail repository)
  - [x] 0.1 Crear `CalibrationAuditRecord` + subclases en `lib/domain/entities/calibration_audit_record.dart`
    - Clase abstracta con `type`, `timestampUtc`, `operatorId`, `deviceModel`, `sha256`, `toJson()`, `toJsonWithoutSha()`.
    - Subclase `MicCalibrationAudit` con campos del Req 4.6 (referenceSplLevel, rmsAvgDbfs, rmsStdDbfs, micOffsetDb, calibratorModel, expectedFreqHz, windowsUsed).
    - Subclase `HpCalibrationAudit` con campos del Req 4.7 (headphoneId, headphoneName, couplerModel, micOffsetDb, targetDbspl, frequenciesHz, splDbspl, hpOffsetDb).
    - `Equatable.props` completo en ambas.
    - Files: `hearing_aid_app/lib/domain/entities/calibration_audit_record.dart`
    - _Requirements: 4.5, 4.6, 4.7_

  - [x] 0.2 Crear `CalibrationAuditRepository` en `lib/data/services/calibration_audit_repository.dart`
    - Métodos públicos: `appendMicCalibration`, `appendHpCalibration`, `getAll({type})`, `getLatestMic`, `getLatestHp(headphoneId)`, `verifyIntegrity`, `clear({forTests})`.
    - Métodos estáticos: `computeSha256(payload)`, `canonicalJson(payload)` (orden alfabético recursivo, sin indentación, sin `sha256` en input).
    - Hive box `calibration_box`. Claves prefijadas `audit_mic_<iso8601>` / `audit_hp_<iso8601>`.
    - `verifyIntegrity` recomputa SHA-256 sobre `record.toJsonWithoutSha()` y compara con persistido.
    - Logs con `developer.log(name: 'NativeCalibration')` en cada operación crítica.
    - Files: `hearing_aid_app/lib/data/services/calibration_audit_repository.dart`
    - _Requirements: 4.1, 4.2, 4.3, 4.4_

  - [x] 0.3 Tests del repositorio
    - `test/data/services/calibration_audit_repository_test.dart`
    - 1) `canonicalJson` ordena claves alfabéticamente (test con map desordenado).
    - 2) `canonicalJson` es idempotente (`canonical(canonical(x)) == canonical(x)`).
    - 3) `computeSha256` retorna 64 chars hex.
    - 4) `appendMicCalibration` + `getLatestMic` round-trip.
    - 5) `appendHpCalibration` + `getLatestHp(id)` round-trip.
    - 6) `verifyIntegrity(record)` retorna `true` cuando se persistió y se re-lee sin tocar.
    - 7) `verifyIntegrity` retorna `false` cuando el JSON persistido fue manipulado (tampering en cualquier campo).
    - 8) `getAll(type: 'mic')` retorna solo records mic, ordenados cronológicamente.
    - 9) `clear(forTests: false)` lanza `StateError`.
    - 10) Property test (glados): `∀ payload → canonical(canonical(payload)) == canonical(payload)` (50 runs).
    - 11) Property test (glados): tampering en cualquier campo no-`sha256` invalida la integridad (30 runs).
    - Files: `hearing_aid_app/test/data/services/calibration_audit_repository_test.dart`
    - _Requirements: 4.1, 4.2, 4.3, 4.6, 4.7, 4.8_

- [x] 1. Wave 1 — `getInputLevel` (handler simple)
  - [x] 1.1 Crear `CalibrationAudioCapture.kt` en `android/app/src/main/kotlin/com/psk/hearing_aid_app/`
    - Wrapper de `AudioRecord` 48 kHz mono PCM_16, source `UNPROCESSED` (Android 24+) con fallback `MIC`.
    - Buffer 4096 samples, lectura por ventanas de 4800 samples (100 ms).
    - Función `computeRmsDbfs(ShortArray, count)`: `dbfs = 20*log10(max(rms,1.0)/32767.0)`, clamp a `[-120, 0]`.
    - Función `readWindowRmsDbfs(durationMs)` y `readManyWindowsRmsDbfs(durationMs, count, dropFirst)`.
    - Función `release()` con try/catch silenciosos.
    - Logs `Log.i(TAG, …)` en open/close/read.
    - Files: `hearing_aid_app/android/app/src/main/kotlin/com/psk/hearing_aid_app/CalibrationAudioCapture.kt`
    - _Requirements: 1.1, 1.2, 1.5, 1.6, 1.7, 8.1_

  - [x] 1.2 Implementar `handleGetInputLevel` en `AudioMethodChannel.kt`
    - Reemplazar el `result.notImplemented()` actual por la implementación real (ver design.md).
    - Abrir `CalibrationAudioCapture`, leer 1 ventana de 100 ms, computar dbfs.
    - Leer `mic_offset_db` desde Hive box `calibration_box` vía SharedPreferences nativos (ver task 1.3 sobre nativo) o aceptar como argumento `micOffsetDb` opcional desde Dart.
    - **Decisión arquitectónica:** el handler nativo NO accede a Hive directamente (Hive es Dart-only). El caller Dart pasa `micOffsetDb` como argumento opcional. Esto simplifica enormemente el flujo y evita acoplar Kotlin con Hive.
    - Retornar Map con `dbfs`, `dbSpl` (null si offset es null), `calibrated`, `micOffsetDb`, `durationMs=100`, `sampleRate=48000`.
    - Manejo de errores: `AUDIO_RECORD_FAILED`, `AUDIO_RECORD_READ_FAILED`, `PERMISSION_DENIED`.
    - Liberar `AudioRecord` en `finally`.
    - Files: `hearing_aid_app/android/app/src/main/kotlin/com/psk/hearing_aid_app/AudioMethodChannel.kt`
    - _Requirements: 1.1, 1.3, 1.4, 1.5, 1.6, 1.7, 5.1, 8.1_

  - [x] 1.3 Modificar `headphone_calibrator.dart::_measureMicLevel` para consumir el handler real
    - Pasar `micOffsetDb` desde el repositorio Dart cuando esté disponible (cargar desde `CalibrationAuditRepository.getLatestMic()` antes de invocar).
    - Leer la clave `dbSpl` del response cuando `calibrated == true`; sino caer a `dbfs + 120.0` (default `micOffsetDbSpl`) y loggear el camino tomado vía `developer.log(name: 'HeadphoneCalibrator', level: 800)`.
    - Mantener el manejo de `MissingPluginException` y `PlatformException` con `StateError` (no aflojarlo).
    - Files: `hearing_aid_app/lib/data/services/headphone_calibrator.dart`
    - _Requirements: 1.3, 1.4, 1.8, 7_

  - [x] 1.4 Tests Dart de `getInputLevel` con mock del MethodChannel
    - `test/data/bridges/audio_bridge_impl_get_input_level_test.dart` (NEW): mock channel que retorna Map golden, verificar parsing.
    - `test/data/services/headphone_calibrator_get_input_level_test.dart`: mock channel + offset persistido, verificar que `_measureMicLevel` retorna `dbfs + offset`.
    - Property test (glados): `∀ dbfs ∈ [-120, 0], offset ∈ [100, 130] → handler retorna dbSpl = dbfs + offset` (100 runs). Archivo: `test/data/bridges/get_input_level_linearity_property_test.dart`.
    - Files: 3 archivos en `hearing_aid_app/test/`
    - _Requirements: 1.3, 1.4, 1.8, 6.3_

- [x] 2. Wave 2 — `calibrateMicrophone`
  - [x] 2.1 Implementar captura de 5 segundos en `CalibrationAudioCapture.kt`
    - Función `readManyWindowsRmsDbfs(durationMs=100, count=50, dropFirst=5)` ya está en task 1.1; verificar que descarta correctamente las primeras 5 ventanas y retorna 45 valores.
    - Helper Kotlin `List<Double>.populationStandardDeviation()` (extension).
    - Files: `hearing_aid_app/android/app/src/main/kotlin/com/psk/hearing_aid_app/CalibrationAudioCapture.kt`
    - _Requirements: 2.2, 2.3, 2.4_

  - [x] 2.2 Implementar validación + cálculo en `handleCalibrateMicrophone` en `AudioMethodChannel.kt`
    - Leer args: `referenceSplLevel` (default 94.0), `calibratorModel`, `operatorId`, `expectedFreqHz`.
    - Capturar 50 ventanas de 100 ms (5 segundos), descartar primeras 5.
    - Calcular `rms_avg_dbfs = avg(windows)` y `rms_std_dbfs = stdDev(windows)`.
    - Validar `rms_std_dbfs ≤ 1.0` (sino → `result.error("UNSTABLE_SIGNAL", …)`).
    - Validar `rms_avg_dbfs ∈ [-40, -10]` (sino → `result.error("LEVEL_OUT_OF_RANGE", …)`).
    - `mic_offset_db = referenceSplLevel - rms_avg_dbfs`.
    - Retornar Map con `splOffset`, `confidenceLevel`, `method='external_ref'`, `calibratedAtMs`, `deviceModel`, `rmsAvgDbfs`, `rmsStdDbfs`, `referenceSplLevel`, `calibratorModel`, `operatorId`, `expectedFreqHz`, `windowsUsed`.
    - Logs estructurados (Req 8.2): `START`, `AUDIO_RECORD_OPENED`, `CAPTURE_BEGIN`, `CAPTURE_END(rms_avg, rms_std)`, `VALIDATION_PASS|FAIL(reason)`, `OFFSET_COMPUTED(value)`, `PERSIST_OK|FAIL`.
    - Liberar AudioRecord en `finally`.
    - Files: `hearing_aid_app/android/app/src/main/kotlin/com/psk/hearing_aid_app/AudioMethodChannel.kt`
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.9, 2.11, 5.2, 5.3, 8.2_

  - [x] 2.3 Persistir audit trail desde Dart en `audio_bridge_impl.dart::calibrateMicrophone`
    - Tras recibir el response del native, construir `MicCalibrationAudit` con todos los campos (incluyendo `sha256` computado vía `CalibrationAuditRepository.computeSha256`).
    - Inyectar la dependencia `CalibrationAuditRepository` al `AudioBridgeImpl` (via constructor opcional, para que tests lo puedan mockear).
    - Llamar `appendMicCalibration(audit)`. Si falla, propagar `PlatformException` con código `PERSIST_FAILED`.
    - También persistir el offset vivo: `box.put('mic_offset_db', offset)` y `box.put('last_calibrated_at_mic', timestamp.toIso8601String())`.
    - Files: `hearing_aid_app/lib/data/bridges/audio_bridge_impl.dart`
    - _Requirements: 2.7, 2.8, 2.10, 4.1_

  - [x] 2.4 Tests del flujo `calibrateMicrophone` con golden vectors
    - `test/data/bridges/audio_bridge_impl_calibrate_microphone_test.dart`:
      - 1) Golden: native retorna `rmsAvgDbfs=-20.0, rmsStdDbfs=0.3` → `splOffset=114.0, confidenceLevel=1.0`.
      - 2) Golden: native retorna `rmsStdDbfs=0.7` → `confidenceLevel=0.7`.
      - 3) Native retorna error `UNSTABLE_SIGNAL` → caller propaga `PlatformException`.
      - 4) Native retorna error `LEVEL_OUT_OF_RANGE` → caller propaga.
      - 5) Verificar que `appendMicCalibration` se llamó con el audit correcto y SHA-256 verificable.
    - Property test (glados) en `test/domain/property/mic_offset_inversion_property_test.dart`:
      - `∀ rms_avg_dbfs ∈ [-40, -10], ref ∈ [80, 100] → offset = ref - rms_avg_dbfs ∧ rms_avg_dbfs + offset = ref ± 0.001` (100 runs).
    - Property test (glados): estabilidad — dos llamadas con mismo input dan offsets dentro de ±0.001 dB (deterministic). En `test/domain/property/mic_offset_stability_property_test.dart`.
    - Files: 3 archivos en `hearing_aid_app/test/`
    - _Requirements: 2.7, P1, P3_

  - [x] 2.5 Test golden vector con señal sintética 1 kHz @ -20 dBFS → offset 114
    - Generar dart-side un buffer ShortArray sintético de 5 segundos, 48 kHz, senoide 1 kHz a amplitud que produzca `rms_dbfs = -20.0`.
    - Computar el RMS dBFS con la misma fórmula que el handler nativo (Dart port `_computeRmsDbfsDart` para test).
    - Verificar que `94 - rms_dbfs ≈ 114 ± 0.5` dB.
    - Archivo: `test/calibration/synthetic_calibration_signal_test.dart` (NEW).
    - Files: `hearing_aid_app/test/calibration/synthetic_calibration_signal_test.dart`
    - _Requirements: 2.7, 6.3_

- [x] 3. Wave 3 — `calibrateHeadphones`
  - [x] 3.1 Crear `CalibrationToneEmitter.kt` en `android/app/src/main/kotlin/com/psk/hearing_aid_app/`
    - Wrapper de `AudioTrack` 48 kHz mono PCM_16 stream MUSIC.
    - Generar samples sintéticos: `sin(2π·f·t) * amplitude` con `amplitude = 10^(levelDbfs/20) * 32767 * sqrt(2)` (peak para senoide RMS).
    - Cosine ramp de 20 ms en in/out para evitar clicks.
    - Función `playTone(freqHz, levelDbfs, durationMs)` bloqueante (Thread.sleep al final + 50 ms de buffer).
    - Files: `hearing_aid_app/android/app/src/main/kotlin/com/psk/hearing_aid_app/CalibrationToneEmitter.kt`
    - _Requirements: 3.3, 3.4_

  - [x] 3.2 Implementar `handleCalibrateHeadphones` en `AudioMethodChannel.kt`
    - Leer args: `headphoneId`, `headphoneName`, `couplerModel` (default `"HA-2"`), `operatorId`, `micOffsetDb` (Double, requerido — si null/missing → error `MIC_NOT_CALIBRATED`).
    - Frecuencias: `[250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000]` Hz.
    - Para cada frecuencia: lanzar `CalibrationToneEmitter.playTone(freq, -20.0, 1500)` en thread paralelo y simultáneamente capturar con `CalibrationAudioCapture` durante 1500 ms; descartar primeros 200 ms; computar RMS dBFS de los 1300 ms restantes.
    - Tras cada tono, esperar 500 ms de silencio antes del siguiente.
    - Calcular `spl_dbspl[f] = rms_dbfs[f] + micOffsetDb`.
    - Calcular `target_dbspl = -20.0 + micOffsetDb`.
    - Calcular `hp_offset_db[f] = spl_dbspl[f] - target_dbspl` para cada banda.
    - Validar `hp_offset_db[f] ∈ [-30, +30]` para cada banda; sino → `result.error("BAND_OUT_OF_RANGE", …)`.
    - Validar dispersión adyacente `|hp_offset_db[f_n+1] - hp_offset_db[f_n]| ≤ 15`; sino → `result.error("BAND_DISCONTINUITY", …)`.
    - Retornar Map con `frequencyResponse`, `compensation` (= `-hp_offset_db`), `headphoneId`, `headphoneName`, `calibratedAtMs`, `isBluetooth` (heurística: `headphoneId.matches("[0-9A-F]{2}(:[0-9A-F]{2}){5}")` con `RegexOption.IGNORE_CASE`), `couplerModel`, `operatorId`, `deviceModel`, `micOffsetDb`, `targetDbspl`, `frequenciesHz`, `splDbspl`, `hpOffsetDb`.
    - Logs estructurados (Req 8.3): `START`, `AUDIO_RECORD_OPENED`, `AUDIO_TRACK_OPENED`, `TONE_BEGIN(freq, expected_dbfs)` y `TONE_END(freq, rms_dbfs, spl, offset)` por banda, `PERSIST_OK|FAIL`.
    - Liberar AudioRecord y AudioTrack en `finally`.
    - Files: `hearing_aid_app/android/app/src/main/kotlin/com/psk/hearing_aid_app/AudioMethodChannel.kt`
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.11, 3.12, 3.13, 5.4, 5.5, 8.3_

  - [x] 3.3 Persistir audit trail desde Dart en `audio_bridge_impl.dart::calibrateHeadphones`
    - Tras recibir el response del native, construir `HpCalibrationAudit` con todos los campos + SHA-256.
    - Antes de invocar el handler, leer `mic_offset_db` desde Hive y pasarlo como argumento al call.
    - Llamar `appendHpCalibration(audit)`. Persistir también `hp_offset_table.<headphoneId>` como Map<String,Double> y `last_calibrated_at_hp.<headphoneId>` como ISO-8601 UTC.
    - Files: `hearing_aid_app/lib/data/bridges/audio_bridge_impl.dart`
    - _Requirements: 3.9, 3.10, 4.1_

  - [x] 3.4 Tests del flujo `calibrateHeadphones` con golden vectors
    - `test/data/bridges/audio_bridge_impl_calibrate_headphones_test.dart`:
      - 1) Golden: 12 frecuencias con `rms_dbfs ≈ -22 dBFS` (offset perfecto = 0 dB) y `mic_offset_db = 114` → tabla `hp_offset_db ≈ 0 ± 0.5` para todas las bandas, `compensation = ~0`.
      - 2) Golden con respuesta no plana (decline en agudos): `hp_offset[8000] = -10 dB`, validar que `compensation[8000] = +10 dB`.
      - 3) Native retorna error `MIC_NOT_CALIBRATED` (offset no pasado) → caller propaga.
      - 4) Native retorna error `BAND_OUT_OF_RANGE` → caller propaga con info de la banda.
      - 5) Native retorna error `BAND_DISCONTINUITY` → caller propaga.
      - 6) Verificar que `appendHpCalibration` se llamó con el audit correcto y SHA-256 verificable.
    - Property test (glados) en `test/domain/property/hp_offset_table_property_test.dart`:
      - Para 12 frecuencias y `hp_offset[f] ∈ [-15, +15]` dB, `(SPL_medido - offset) ≈ target` con tolerancia 2 dB (50 runs).
    - Files: 2 archivos en `hearing_aid_app/test/`
    - _Requirements: 3.7, 3.11, P2_

- [ ] 4. Wave 4 — Pantalla wizard de calibración
  - [ ] 4.1 Rediseñar `lib/presentation/screens/calibration_screen.dart` con flujo de 5 fases
    - Estado `_phase` con valores: `gate`, `mic`, `micDone`, `hp`, `done`.
    - **Fase `gate`:** pedir PIN del operador con `OperatorPinRepository.verifyPin`. Si no hay PIN configurado, ofrecer `generateAndStoreInitialPin` y mostrar el PIN una sola vez.
    - **Fase `mic`:** instrucciones (texto + ícono `Icons.graphic_eq`) para colocar el calibrador junto al micrófono. Inputs: `calibratorModel`, `calibratorSerial`. Botón "Iniciar" → invoca `audioBridge.calibrateMicrophone(referenceSplLevel: 94.0)`.
    - **Fase `micDone`:** mostrar `mic_offset_db`, `rmsAvgDbfs`, `rmsStdDbfs`, `confidenceLevel`. Botón "Continuar al auricular".
    - **Fase `hp`:** instrucciones para conectar auricular al acoplador. Inputs: `couplerModel`, `couplerSerial`, `headphoneId` (auto-detectado o `"wired_default"`), `headphoneName`. Botón "Iniciar sweep" → invoca `audioBridge.calibrateHeadphones(headphoneId)`. Mostrar progreso por banda.
    - **Fase `done`:** resumen (timestamp UTC, operador hash truncado, modelos, mic_offset, tabla hp con código de color verde/amarillo/rojo, hashes SHA-256 truncados). Botón "Exportar PDF" → llama `QcAuditRepository.generatePdf` con record sintético.
    - Cancelación en cualquier fase intermedia → vuelve a `gate` sin persistir parcial.
    - Mostrar mensajes de error en español rioplatense según Req 5.2–5.5.
    - Files: `hearing_aid_app/lib/presentation/screens/calibration_screen.dart`
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7, 7.8, 7.9, 5.2, 5.3, 5.4, 5.5_

  - [ ] 4.2 Widget tests del wizard (5 fases)
    - `test/presentation/screens/calibration_screen_wizard_test.dart`:
      - 1) `gate`: pedir PIN, validar OK → avanza a `mic`.
      - 2) `gate`: PIN inválido → permanece en `gate` con error visible.
      - 3) `mic`: input `calibratorModel` + botón Iniciar → invoca channel mock → `micDone`.
      - 4) `micDone`: muestra splOffset, hace tap "Continuar" → `hp`.
      - 5) `hp`: invoca channel mock con 12 bandas → `done`.
      - 6) `done`: tap "Exportar PDF" → llama `QcAuditRepository.generatePdf`.
      - 7) Cancelación en `mic` → vuelve a `gate`, no persiste nada.
      - 8) Error `UNSTABLE_SIGNAL` → muestra mensaje "Acercá el calibrador al micrófono…".
      - 9) Error `BAND_DISCONTINUITY` → muestra mensaje "Verificá que el auricular esté conectado al acoplador…".
    - Files: `hearing_aid_app/test/presentation/screens/calibration_screen_wizard_test.dart`
    - _Requirements: 7.1, 7.6, 7.8, 7.9_

- [ ] 5. Wave 5 — Property-based tests con glados
  - [ ] 5.1 Property: `mic_offset_db` reproduce 94 dB SPL para cualquier RMS dBFS válido
    - Archivo: `test/domain/property/mic_offset_inversion_property_test.dart` (creado en task 2.4 — esta sub-task valida que el archivo existe, está completo y se ejecuta correctamente con 100 runs).
    - Ejecutar: `flutter test test/domain/property/mic_offset_inversion_property_test.dart`.
    - Files: `hearing_aid_app/test/domain/property/mic_offset_inversion_property_test.dart`
    - _Requirements: P1_

  - [ ] 5.2 Property: tabla `hp_offset_table` aplicada al output reproduce SPL esperado ±2 dB
    - Archivo: `test/domain/property/hp_offset_table_property_test.dart` (creado en task 3.4 — esta sub-task valida ejecución).
    - Ejecutar: `flutter test test/domain/property/hp_offset_table_property_test.dart`.
    - Files: `hearing_aid_app/test/domain/property/hp_offset_table_property_test.dart`
    - _Requirements: P2_

  - [ ] 5.3 Property: dos calibraciones consecutivas con misma señal dan offsets dentro de ±0.5 dB
    - Archivo: `test/domain/property/mic_offset_stability_property_test.dart` (creado en task 2.4).
    - Ejecutar: `flutter test test/domain/property/mic_offset_stability_property_test.dart`.
    - Files: `hearing_aid_app/test/domain/property/mic_offset_stability_property_test.dart`
    - _Requirements: P3_

- [ ] 6. Wave 6 — Verificación final
  - [ ] 6.1 `flutter test` completo
    - Output a `c:\Users\Elsa y Henry\Pictures\Amplificador\.kiro_tmp\native-handlers-fulltest.txt`.
    - Comando: vía `.cmd` intermedio (workaround E-007/E-011).
    - Criterio de éxito: 0 fallas (preserva los 1096 que pasan + suma los nuevos).
    - Files: `c:\Users\Elsa y Henry\Pictures\Amplificador\.kiro_tmp\native-handlers-fulltest.txt`
    - _Requirements: ALL_

  - [ ] 6.2 `flutter analyze` completo
    - Output a `c:\Users\Elsa y Henry\Pictures\Amplificador\.kiro_tmp\native-handlers-analyze.txt`.
    - Criterio: 0 errors. Warnings < threshold del proyecto.
    - Files: `c:\Users\Elsa y Henry\Pictures\Amplificador\.kiro_tmp\native-handlers-analyze.txt`
    - _Requirements: ALL_

  - [ ] 6.3 Actualizar `.kiro_tmp/memoria.md` y cerrar P1 en `spec-review-pending.md`
    - Agregar sección "Cierre native-calibration-handlers" en `memoria.md` con: archivos creados/modificados, total de tests pasados, archivos no verificables sin hardware (manual QC documentado).
    - En `spec-review-pending.md`, cambiar la sección "P1 — Handlers nativos C-3 stubs" de `STUB HONESTO` a `✅ RESUELTO YYYY-MM-DD`. Agregar resumen del fix.
    - Files: `c:\Users\Elsa y Henry\Pictures\Amplificador\.kiro_tmp\memoria.md`, `c:\Users\Elsa y Henry\Pictures\Amplificador\.kiro_tmp\spec-review-pending.md`
    - _Requirements: ALL_

## Task Dependency Graph

```json
{
  "waves": [
    {
      "id": "wave-0",
      "tasks": ["0.1", "0.2", "0.3"],
      "dependencies": []
    },
    {
      "id": "wave-1",
      "tasks": ["1.1", "1.2", "1.3", "1.4"],
      "dependencies": ["wave-0"]
    },
    {
      "id": "wave-2",
      "tasks": ["2.1", "2.2", "2.3", "2.4", "2.5"],
      "dependencies": ["wave-0", "wave-1"]
    },
    {
      "id": "wave-3",
      "tasks": ["3.1", "3.2", "3.3", "3.4"],
      "dependencies": ["wave-0", "wave-1"]
    },
    {
      "id": "wave-4",
      "tasks": ["4.1", "4.2"],
      "dependencies": ["wave-0", "wave-1", "wave-2", "wave-3"]
    },
    {
      "id": "wave-5",
      "tasks": ["5.1", "5.2", "5.3"],
      "dependencies": ["wave-2", "wave-3"]
    },
    {
      "id": "wave-6",
      "tasks": ["6.1", "6.2", "6.3"],
      "dependencies": ["wave-0", "wave-1", "wave-2", "wave-3", "wave-4", "wave-5"]
    }
  ]
}
```

```
0.1 (CalibrationAuditRecord entities)
 │
 ▼
0.2 (CalibrationAuditRepository) ──▶ 0.3 (Repo tests)
 │
 ├──▶ 1.1 (CalibrationAudioCapture.kt) ──▶ 1.2 (handleGetInputLevel)
 │                                          │
 │                                          ▼
 │                                         1.3 (headphone_calibrator wire)
 │                                          │
 │                                          ▼
 │                                         1.4 (Dart tests getInputLevel)
 │
 ├──▶ 2.1 (5s capture in CalibrationAudioCapture) ──▶ 2.2 (handleCalibrateMicrophone)
 │                                                    │
 │                                                    ▼
 │                                                   2.3 (audio_bridge_impl wire + audit)
 │                                                    │
 │                                                    ├──▶ 2.4 (Dart tests + PBT)
 │                                                    │
 │                                                    └──▶ 2.5 (Synthetic 1kHz golden)
 │
 ├──▶ 3.1 (CalibrationToneEmitter.kt) ──▶ 3.2 (handleCalibrateHeadphones)
 │                                          │
 │                                          ▼
 │                                         3.3 (audio_bridge_impl wire + audit)
 │                                          │
 │                                          ▼
 │                                         3.4 (Dart tests + PBT)
 │
 ▼
4.1 (CalibrationScreen wizard) ──▶ 4.2 (Widget tests)
 │
 ▼
5.1, 5.2, 5.3 (Property tests final pass) ──▶ 6.1 (flutter test) ──▶ 6.2 (flutter analyze) ──▶ 6.3 (memoria + cierre P1)
```

**Waves disjoint set (paralelizables):**
- Wave 0: 0.1 → 0.2 → 0.3 (secuencial dentro de wave).
- Wave 1: 1.1 → 1.2 → 1.3 → 1.4 (secuencial).
- Wave 2: 2.1 → 2.2 → 2.3 → 2.4 / 2.5 (2.4 y 2.5 paralelizables).
- Wave 3: 3.1 → 3.2 → 3.3 → 3.4 (secuencial).
- Wave 4: 4.1 → 4.2.
- Wave 5: 5.1, 5.2, 5.3 (paralelizables, son sólo verificaciones).
- Wave 6: 6.1 → 6.2 → 6.3 (secuencial).

**Bloqueos cruzados:**
- Wave 1, 2, 3 dependen de Wave 0 (audit repository).
- Wave 1.1 (CalibrationAudioCapture) es prerequisito de Wave 2.1 y 3.2.
- Wave 4 depende de Wave 0, 1, 2, 3 completas (UI consume todos los handlers).
- Wave 5 depende de Wave 2 y 3 (los archivos de PBT se crean en 2.4 y 3.4).
- Wave 6 depende de TODO.

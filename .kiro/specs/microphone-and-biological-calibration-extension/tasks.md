# Implementation Plan: Calibración del Micrófono y Extensión de la Calibración Biológica

## Overview

Lista ejecutable de tareas para implementar el spec
`microphone-and-biological-calibration-extension`. Cada tarea debe poder
completarse en menos de 2 horas de trabajo concentrado. La numeración refleja
el orden recomendado de ejecución; las dependencias se documentan en el
Task Dependency Graph.

## Task Dependency Graph

```json
{
  "waves": [
    { "wave": 1, "tasks": ["1"], "description": "Modelos de datos base" },
    { "wave": 2, "tasks": ["2"], "description": "Persistencia Hive" },
    { "wave": 3, "tasks": ["3", "5"], "description": "Controladores y audit trail" },
    { "wave": 4, "tasks": ["4"], "description": "UI Flutter" },
    { "wave": 5, "tasks": ["6", "7"], "description": "Extensión biológica y native bridge" },
    { "wave": 6, "tasks": ["8"], "description": "Integración boot" },
    { "wave": 7, "tasks": ["9", "10"], "description": "Tests PBT e integration" },
    { "wave": 8, "tasks": ["11", "12"], "description": "Production mode + import/export" },
    { "wave": 9, "tasks": ["13", "14"], "description": "Documentación y QC" }
  ]
}
```

## Tasks

- [ ] 1. Modelos de datos
  - [x] 1.1 Crear `lib/mic_calibration/models/mic_calibration_result.dart` con campos del schema 2.0, `toJson()/fromJson()` y SHA-256 helper
  - [ ] 1.2 Extender `lib/biological_calibration/models/biological_calibration_result.dart` con campo opcional `inputCalibration: MicCalibrationResult?` manteniendo backwards compatibility en `fromJson` (lee schema 1.x sin error)
  - [ ] 1.3 Crear `lib/audit_trail/models/calibration_audit_entry.dart` con UUID v4 y serialización JSON
  - [ ] 1.4 Unit tests round-trip JSON para los 3 modelos
  _Requirements: R1, R5_

- [ ] 2. Capa de persistencia (Hive)
  - [ ] 2.1 Crear `lib/mic_calibration/store/mic_calibration_store.dart` con box `mic_calibration_box` y key format `${deviceModel}::${operatorId}`
  - [ ] 2.2 Crear `lib/audit_trail/store/audit_trail_store.dart` con box `calibration_audit_box`, rotación a 8000 al exceder 10000 entradas
  - [ ] 2.3 Modificar `lib/biological_calibration/store/biological_calibration_store.dart` para soportar el nuevo schema 2.0 sin romper carga de schema 1.x
  - [ ] 2.4 Tests de idempotencia save/load para los 3 stores
  - [ ] 2.5 Test de rotación del audit trail
  _Requirements: R1, R4, R10_

- [ ] 3. Controladores Dart
  - [ ] 3.1 Crear `lib/mic_calibration/controllers/mic_calibration_controller.dart` con phases: idle/manual/capturing/validating/saving/error/complete y stream de live SPL level
  - [ ] 3.2 Implementar `startManual()`, `updateOffset(double)`, `saveManual()` con validación de rango [60, 130]
  - [ ] 3.3 Implementar `startAutomatic({double referenceSpl, double frequencyHz = 1000})` con validación Quinn 2nd-order
  - [ ] 3.4 Implementar `startInline()` para uso desde el flujo biológico extendido
  - [ ] 3.5 Tests unitarios del controller con mock del audio bridge
  _Requirements: R2, R3, R5, R10_

- [ ] 4. UI Flutter — MicCalibrationScreen
  - [ ] 4.1 Crear `lib/mic_calibration/screens/mic_calibration_screen.dart` con selector de modo Manual / Automático / Producción
  - [ ] 4.2 Implementar widget de slider 60-130 dB con paso 0.5 dB y display del SPL en vivo
  - [ ] 4.3 Implementar widget de captura automática con countdown 5s y display de tono detectado
  - [ ] 4.4 Mostrar disclaimer permanente conforme R12, en español argentino y neutro
  - [ ] 4.5 Botón "Exportar audit trail" con selector de formato (JSON/PDF)
  - [ ] 4.6 Tabla histórica de calibraciones del device con opción de invalidar
  - [ ] 4.7 Widget tests para los principales flujos
  _Requirements: R2, R3, R9, R12_

- [ ] 5. Audit trail end-to-end
  - [ ] 5.1 Helper `lib/audit_trail/audit_trail_logger.dart` con métodos `logManualSaved()`, `logAutoCapture()`, `logExport()`, etc.
  - [ ] 5.2 Integrar logger en `MicCalibrationController` (todos los eventos críticos)
  - [ ] 5.3 Integrar logger en `BiologicalCalibrationController` para eventos del flujo bilateral
  - [ ] 5.4 Implementar `exportAsJson()` con esquema versionado y SHA-256 de cada entrada
  - [ ] 5.5 Implementar `exportAsPdf()` con formato compatible auditoría (encabezado con datos del titular del registro, tabla cronológica, pie de página con metadatos)
  - [ ] 5.6 Tests de export y verificación de hash
  _Requirements: R4, R9_

- [ ] 6. Extensión de la calibración biológica para incluir mic
  - [ ] 6.1 Modificar `BiologicalCalibrationController` para ofrecer "continuar con calibración del micrófono" tras audiometría
  - [ ] 6.2 Implementar guardado atómico bilateral (output + input) en una sola transacción Hive
  - [ ] 6.3 Manejar fallo del mic preservando la calibración de salida + flag en audit trail
  - [ ] 6.4 Test de regresión: flujo biológico actual sigue funcionando sin cambios
  - [ ] 6.5 Test del flujo bilateral con éxito y con fallo del mic
  _Requirements: R5, R6, R7_

- [ ] 7. Bridge nativo (Android JNI)
  - [ ] 7.1 Modificar `android/app/src/main/cpp/native_bridge.cpp` para exportar `nativeSetSplOffset(jfloat offset)` con validación de rango
  - [ ] 7.2 Modificar `android/app/src/main/cpp/audio_engine.{cpp,h}` para `setSplOffset()` que actualice `config_.splOffset` y propague al `DspPipeline` sin reiniciar el stream Oboe
  - [ ] 7.3 Exportar `nativeStartMicCalibration(jfloat freq, jfloat dur)` que devuelva `MicCalibrationCaptureResult` (rms_dbfs, freq_detected_hz, peak_dbfs)
  - [ ] 7.4 Wrapper Dart en `lib/data/bridges/audio_bridge_impl.dart` para los 2 nuevos métodos
  - [ ] 7.5 Smoke test de los nuevos calls JNI
  _Requirements: R1, R3, R8_

- [ ] 8. Integración con boot
  - [ ] 8.1 Modificar `lib/data/hive_initializer.dart` para abrir `mic_calibration_box` y `calibration_audit_box` al startup
  - [ ] 8.2 Implementar `lib/data/services/device_info_service.dart` que devuelva `deviceModel` (`Build.MODEL`) y `deviceId` (Android ID hash)
  - [ ] 8.3 En `AmplificationBloc.initialize()`, leer calibración persistida y aplicar via `audioBridge.setSplOffset()` antes de iniciar pipeline
  - [ ] 8.4 Si no hay calibración o tiene >12 meses, mostrar banner no-bloqueante con CTA a calibrar
  - [ ] 8.5 Si el `deviceModel` cambió desde último boot, mostrar pantalla bloqueante "Recalibrar"
  - [ ] 8.6 Tests de boot con/sin calibración persistida
  _Requirements: R1, R10_

- [ ] 9. Property-based tests (PBT)
  - [ ] 9.1 Configurar dependencia PBT en `pubspec.yaml` (sugerencia: `glados`)
  - [ ] 9.2 Test Property A — Idempotencia save/load
  - [ ] 9.3 Test Property B — Conversión bidireccional dBFS↔SPL
  - [ ] 9.4 Test Property D — Audit trail crece monotónicamente
  - [ ] 9.5 Test Property E — Validación de rango [60, 130]
  - [ ] 9.6 Test Property F — Atomicidad bilateral
  - [ ] 9.7 Test Property G — Compatibilidad schema versions
  _Requirements: Properties A, B, D, E, F, G_

- [ ] 10. Integration tests Flutter
  - [ ] 10.1 `integration_test/mic_calibration_full_flow_test.dart` — flujo manual completo
  - [ ] 10.2 `integration_test/mic_calibration_auto_flow_test.dart` — flujo automático con tono simulado
  - [ ] 10.3 `integration_test/biological_extended_test.dart` — flujo bilateral
  - [ ] 10.4 Test Property C — Monotonicidad del slider (con señal de referencia constante)
  _Requirements: R2, R3, R5, Property C_

- [ ] 11. Modo Production Calibration
  - [ ] 11.1 Crear `lib/mic_calibration/production/production_calibration_controller.dart` con guía paso a paso
  - [ ] 11.2 Implementar conexión a sonómetro Tipo 2 externo via Bluetooth (Nordic UART) — interface stub si no hay hardware aún
  - [ ] 11.3 Implementar sweep de frecuencias ANSI S3.22 (250, 500, 1000, 1600, 2500, 4000 Hz) con medición OSPL90 / FOG / RTG
  - [ ] 11.4 Implementar generación de QR firmado con resultado completo + lote/serial PCB
  - [ ] 11.5 UI distinta para producción con campos de operador, lote, serial, sonómetro de referencia
  - [ ] 11.6 Tests de validación de la curva contra especificación de referencia
  _Requirements: R8, R11_

- [ ] 12. Importación / Exportación de calibraciones
  - [ ] 12.1 Implementar `exportCalibration()` en `MicCalibrationStore` y en `BiologicalCalibrationStore` (incluye audit trail filtrado a la sesión)
  - [ ] 12.2 Implementar `importCalibration()` con validación de schemaVersion y SHA-256
  - [ ] 12.3 UI con file picker, vista previa diff, confirmación
  - [ ] 12.4 Bloqueo de import si `deviceModel` no coincide
  - [ ] 12.5 Tests de export+import round-trip
  _Requirements: R9, R10_

- [ ] 13. Documentación, disclaimer e internacionalización
  - [ ] 13.1 Agregar strings i18n en `assets/l10n/es_AR.arb` y `es_CO.arb` para todos los textos del módulo
  - [ ] 13.2 Crear `docs/calibration/manual-tecnico.md` con explicación completa del módulo (para auditoría)
  - [ ] 13.3 Crear `docs/calibration/disclaimer-legal.md` con texto exacto de disclaimers requeridos
  - [ ] 13.4 Crear `docs/calibration/audit-trail-spec.md` con descripción del esquema audit para auditores ANMAT/INVIMA
  - [ ] 13.5 Actualizar `Amplificador/docs/06-ruido-y-nitidez/ruido.md` para mencionar este nuevo módulo en sección 17.10
  _Requirements: R12_

- [ ] 14. Manual de fabricación / QC (Production)
  - [ ] 14.1 Crear `docs/manufacturing/calibration-procedure.md` con procedimiento paso a paso para QC en planta
  - [ ] 14.2 Plantilla de certificado de calibración (PDF generado por la app) firmable por el operador y verificable por inspector
  - [ ] 14.3 Especificación del setup del banco de calibración: acoplador IEC 60318-5 + sonómetro Tipo 2 + cabina anecoica
  - [ ] 14.4 Lista de chequeo (`checklist.md`) para acreditación bajo ISO 17025 (qué documentos necesita el laboratorio para auditar)
  _Requirements: R8, R11_

## Notes

- Total tasks (incluyendo sub-tasks): 67.
- Total tasks padre: 14.
- Estimación: ~80-100 horas de trabajo concentrado.
- Bloqueante para certificación: tasks 11 y 14 son críticas para Argentina ANMAT y Colombia INVIMA.
- Bloqueante para uso clínico funcional: tasks 1-9.
- Las tareas marcadas con dependencias hacia el firmware nRF5340 (BLE, conexión a sonómetro externo) requieren coordinación con el equipo de hardware. Si el firmware no está listo, implementar como interfaz stub con `MockSonometer` y dejar el TODO documentado.
- Antes de ejecutar la task 11, verificar qué normas IRAM (Argentina) y NTC (Colombia) son exactamente equivalentes a las IEC citadas. Esto puede requerir compra de las normas en IRAM e ICONTEC.
- La task 14.4 (checklist ISO 17025) requiere consulta con un consultor regulatorio especializado en Argentina/Colombia. La spec define el alcance pero la ejecución necesita expertise externa.

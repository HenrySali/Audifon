# Design — Calibración del Micrófono y Extensión de la Calibración Biológica

> Documento de diseño técnico para implementar el spec
> `mic-calibration`. Pensado para certificación
> regulatoria en Argentina (ANMAT) y Colombia (INVIMA).

## Overview

Se extiende el módulo `lib/biological_calibration/` existente y se crean
componentes nuevos para la calibración del micrófono. Todo se persiste en Hive
con audit trail completo. Se diferencian dos modos de operación:

- **Field calibration**: campo / clínica, sin acoplador certificado.
- **Production calibration**: planta / laboratorio, con acoplador 2cc IEC 60318-5
  y sonómetro certificado externo.

## Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│                        UI Flutter                                   │
│  ┌──────────────────────┐    ┌──────────────────────────────┐     │
│  │ MicCalibrationScreen │    │ BiologicalCalibrationScreen  │     │
│  │ (NEW)                │    │ (EXTENDED)                   │     │
│  └──────────┬───────────┘    └──────────┬───────────────────┘     │
└─────────────┼───────────────────────────┼─────────────────────────┘
              │                           │
              ▼                           ▼
┌────────────────────────────────────────────────────────────────────┐
│                     Bloc / Controller layer                         │
│  ┌──────────────────────┐    ┌──────────────────────────────┐     │
│  │ MicCalibration       │    │ BiologicalCalibration        │     │
│  │ Controller (NEW)     │    │ Controller (EXTENDED)        │     │
│  └──────────┬───────────┘    └──────────┬───────────────────┘     │
└─────────────┼───────────────────────────┼─────────────────────────┘
              │                           │
              ▼                           ▼
┌────────────────────────────────────────────────────────────────────┐
│                  Repository / Store layer (Hive)                    │
│  ┌──────────────────────┐  ┌──────────────────┐  ┌────────────┐   │
│  │ MicCalibrationStore  │  │ BiologicalCalib  │  │ AuditTrail │   │
│  │ (NEW)                │  │ Store (EXTENDED) │  │ Store (NEW)│   │
│  │ box: mic_calib_box   │  │ box: bio_calib   │  │ box: audit │   │
│  └──────────────────────┘  └──────────────────┘  └────────────┘   │
└────────────────────────────────────────────────────────────────────┘
              │                           │
              ▼                           ▼
┌────────────────────────────────────────────────────────────────────┐
│                  AudioBridge / MethodChannel                        │
│  setSplOffset(deviceModel, splOffset)                               │
│  startMicCalibration(toneFrequencyHz, durationSec)                  │
│  exportAuditTrail()                                                 │
└────────────────────────────────────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────────────────────┐
│                  Native C++ (audio_engine.cpp + native_bridge)      │
│  - nativeSetSplOffset(jfloat)                                       │
│  - nativeStartMicCalibration(jfloat freq, jfloat dur)               │
│  - DspPipeline aplica offset persistido al boot                     │
└────────────────────────────────────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────────────────────┐
│                  Hardware (futuro: nRF5340 + ICS-43434)             │
│  - Mic MEMS PDM ICS-43434 (-26 dBFS @ 94 dB SPL)                    │
│  - Comunicación BLE con app via Nordic UART Service / ChannelMap    │
└────────────────────────────────────────────────────────────────────┘
```

### Flujo de calibración del micrófono (field, manual)

```
[user] → MicCalibrationScreen (modo Manual)
          ↓
       slider offset 60-130 dB (default 93)
          ↓
       app muestra SPL_actual = 20·log10(rms_mic) + offset
          ↓
       [user pulsa Guardar]
          ↓
       MicCalibrationController.save({deviceId, deviceModel, splOffset, method=manual})
          ↓
       MicCalibrationStore.put(key=deviceModel, value=result)
          ↓
       AudioBridge.setSplOffset(splOffset)
          ↓
       native_bridge::nativeSetSplOffset(splOffset)
          ↓
       audio_engine_.config_.splOffset = splOffset
          ↓
       AuditTrailStore.append(event="manual_calibration_saved", ...)
```

### Flujo de calibración del micrófono (field, automático con tono)

```
[user] → MicCalibrationScreen (modo Automatic)
          ↓
       app pide al operador reproducir 1 kHz a SPL_ref conocido
          ↓
       [user pulsa Capturar]
          ↓
       AudioBridge.startMicCalibration(freq=1000, durationSec=5)
          ↓
       native captura 5s, calcula RMS y verifica freq via Quinn 2nd-order
          ↓
       splOffset = SPL_ref - 20·log10(rms_capturado)
          ↓
       app valida: |freq_detectada - 1000| < 50 Hz, sin clipping
          ↓
       persiste y aplica como flow manual
          ↓
       AuditTrailStore.append(event="auto_calibration_completed",
                              metadata={freq, rms, spl_ref})
```

### Flujo de calibración bilateral biológica extendida

```
[operator] → BiologicalCalibrationScreen
          ↓
       Eligibility Questionnaire (existente)
          ↓
       SystemVolumeController.lockMax()
          ↓
       Hughson-Westlake por frecuencia (existente, lado salida)
          ↓
       app ofrece: "¿Continuar con calibración del micrófono?"
          ↓ Sí
       MicCalibrationController.startInline(method=automatic_tone)
          ↓
       éxito → BiologicalCalibrationStore.save({...existing, inputCalibration: micResult})
       fallo del mic → BiologicalCalibrationStore.save({...existing, inputCalibration: null})
                       AuditTrailStore.append(event="bilateral_partial_save")
```

## Components and Interfaces

### Componentes NUEVOS

#### `lib/mic_calibration/models/mic_calibration_result.dart`

```dart
class MicCalibrationResult {
  final String deviceId;        // unique id (Android ID hash)
  final String deviceModel;     // e.g., "SM-G998B"
  final double splOffset;       // dB, [60, 130]
  final DateTime calibrationDate;
  final String method;          // 'manual' | 'automatic_tone' | 'production_2cc'
  final double? referenceSpl;   // dB SPL del tono de referencia (auto/prod)
  final double? detectedFrequencyHz;
  final double? capturedRmsDbfs;
  final List<String> qualityFlags;
  final String? operatorId;
  final String appVersion;
  final String firmwareVersion;
  final String? sha256;         // hash del payload para audit
  
  Map<String, dynamic> toJson();
  factory MicCalibrationResult.fromJson(Map<String, dynamic> j);
  
  /// Schema version for forward compatibility.
  static const String schemaVersion = '2.0';
}
```

#### `lib/mic_calibration/store/mic_calibration_store.dart`

```dart
class MicCalibrationStore {
  static const String _boxName = 'mic_calibration_box';
  
  /// Key format: "${deviceModel}::${operatorId ?? 'default'}"
  static String _keyFor(String deviceModel, String? operatorId) =>
      '${deviceModel}::${operatorId ?? "default"}';
  
  static Future<void> save(MicCalibrationResult r);
  static Future<MicCalibrationResult?> load(String deviceModel, {String? operatorId});
  static Future<bool> isCalibrated(String deviceModel, {String? operatorId});
  static Future<void> invalidate(String deviceModel, {String? operatorId});
  static Future<List<MicCalibrationResult>> all();
}
```

#### `lib/mic_calibration/controllers/mic_calibration_controller.dart`

```dart
enum MicCalibrationPhase { idle, manual, capturing, validating, saving, error, complete }

class MicCalibrationController extends ChangeNotifier {
  MicCalibrationPhase _phase = MicCalibrationPhase.idle;
  double _currentOffset = 93.0;  // default
  double _liveSplLevel = 0.0;
  String? _errorMessage;
  
  Future<void> startManual();
  void updateOffset(double offset);
  Future<void> saveManual();
  Future<void> startAutomatic({required double referenceSpl, double frequencyHz = 1000.0});
  Future<void> _captureAndValidate();
  Future<void> reset();
  
  // Streams para UI
  Stream<double> get liveSplLevelStream;
}
```

#### `lib/mic_calibration/screens/mic_calibration_screen.dart`

UI Flutter con:
- Selector de modo (Manual / Automático / Producción).
- Slider 60–130 dB (modo manual).
- Botón "Capturar" + visualización de tono detectado (modo automático).
- Disclaimer permanente conforme Requirement 12.
- Botón "Exportar audit trail".
- Acceso a tabla histórica.

#### `lib/audit_trail/models/calibration_audit_entry.dart`

```dart
class CalibrationAuditEntry {
  final String eventId;          // UUIDv4
  final DateTime timestamp;
  final String eventType;        // 'manual_save', 'auto_capture_failed', 'export', etc.
  final String operatorId;
  final String deviceId;
  final String deviceModel;
  final String appVersion;
  final String firmwareVersion;
  final Map<String, dynamic> metadata;
  final String? sha256OfResult;
  
  Map<String, dynamic> toJson();
}
```

#### `lib/audit_trail/store/audit_trail_store.dart`

```dart
class AuditTrailStore {
  static const String _boxName = 'calibration_audit_box';
  static const int _maxEntries = 10000;
  static const int _rotateTo = 8000;
  
  static Future<void> append(CalibrationAuditEntry e);
  static Future<List<CalibrationAuditEntry>> recent({int limit = 100});
  static Future<List<CalibrationAuditEntry>> filterBySession(String sessionId);
  static Future<File> exportAsJson({DateTime? from, DateTime? to});
  static Future<File> exportAsPdf({DateTime? from, DateTime? to});
  static Future<void> _rotateIfNeeded();
}
```

### Componentes MODIFICADOS

#### `lib/biological_calibration/models/biological_calibration_result.dart`

Agregar campo opcional:

```dart
class BiologicalCalibrationResult {
  // ... existing fields ...
  final MicCalibrationResult? inputCalibration;  // NEW (optional, nullable)
  
  // schemaVersion bumped to 2.0
  // toJson/fromJson backwards compatible: lee 1.x sin inputCalibration
}
```

#### `lib/biological_calibration/controllers/biological_calibration_controller.dart`

Después del flujo Hughson-Westlake existente:

```dart
Future<void> _afterAudiometryComplete() async {
  // ... existing ...
  if (_userOptedForBilateral) {
    final mic = MicCalibrationController(...);
    final micResult = await mic.startAutomaticInline(referenceSpl: _refSpl);
    final updated = _result.copyWith(inputCalibration: micResult);
    await BiologicalCalibrationStore.save(updated);
  } else {
    await BiologicalCalibrationStore.save(_result);
  }
}
```

#### `android/app/src/main/cpp/audio_engine.{cpp,h}`

`AudioEngineConfig.splOffset` ya es `float`. La extensión es:

```cpp
// In native_bridge.cpp
JNIEXPORT void JNICALL
Java_com_psk_hearing_1aid_NativeAudioBridge_nativeSetSplOffset(
    JNIEnv*, jclass, jfloat offset) {
    if (g_engine && offset >= 60.0f && offset <= 130.0f) {
        g_engine->setSplOffset(offset);
    }
}
```

`AudioEngine::setSplOffset()` debe propagar el cambio al `DspPipeline`
existente sin reiniciar el stream Oboe.

#### `lib/data/hive_initializer.dart`

Agregar al boot:

```dart
final micCalibBox = await Hive.openBox(MicCalibrationStore._boxName);
final auditBox = await Hive.openBox(AuditTrailStore._boxName);

// Cargar offset al boot
final deviceModel = await DeviceInfoService.deviceModel();
final calib = await MicCalibrationStore.load(deviceModel);
if (calib != null) {
  await audioBridge.setSplOffset(calib.splOffset);
} else {
  await audioBridge.setSplOffset(93.0);  // default
  // mostrar hint en UI
}
```

## Data Models

### `MicCalibrationResult` (JSON schema 2.0)

```json
{
  "schemaVersion": "2.0",
  "deviceId": "androidid_hash_64chars",
  "deviceModel": "SM-G998B",
  "splOffset": 94.7,
  "calibrationDate": "2026-06-02T15:30:00Z",
  "method": "automatic_tone",
  "referenceSpl": 94.0,
  "detectedFrequencyHz": 1000.3,
  "capturedRmsDbfs": -26.1,
  "qualityFlags": [],
  "operatorId": "audiologist@clinica-bsas.com.ar",
  "appVersion": "2.5.0",
  "firmwareVersion": "1.3.0",
  "sha256": "ab12cd34..."
}
```

### `BiologicalCalibrationResult` extendido (JSON schema 2.0)

```json
{
  "schemaVersion": "2.0",
  "subjectSession": { /* existing */ },
  "outputThresholds": [ /* existing HL→dBFS */ ],
  "catchTrialStats": { /* existing */ },
  "inputCalibration": { /* MicCalibrationResult o null */ },
  "_meta": {
    "extendedAt": "2026-06-02T15:32:11Z",
    "extendedFrom": "1.0"
  }
}
```

### `CalibrationAuditEntry`

```json
{
  "eventId": "uuid-v4",
  "timestamp": "2026-06-02T15:30:00.123Z",
  "eventType": "automatic_calibration_saved",
  "operatorId": "audiologist@clinica-bsas.com.ar",
  "deviceId": "androidid_hash",
  "deviceModel": "SM-G998B",
  "appVersion": "2.5.0",
  "firmwareVersion": "1.3.0",
  "metadata": {
    "method": "automatic_tone",
    "splOffset": 94.7,
    "referenceSpl": 94.0,
    "frequency": 1000.3
  },
  "sha256OfResult": "ab12cd34..."
}
```

## Error Handling

### Tipos de fallo y mitigación

| Fallo | Detección | Acción |
|---|---|---|
| Mic saturado durante captura | `peak > 0.99` | Abortar, mostrar "Reduzca el nivel del tono de referencia" |
| Frecuencia detectada fuera de tolerancia | Quinn freq estimator | Abortar, mostrar "Tono detectado: {f} Hz, esperado: 1000 Hz" |
| Ambiente ruidoso (noise floor alto) | Pre-medición de fondo > 50 dB SPL aprox | Avisar pero permitir continuar con quality flag |
| Pérdida de calibración (cambio device) | `Build.MODEL` cambió desde último boot | Mostrar pantalla bloqueante "Recalibrar antes de usar" |
| Falla de persistencia Hive | excepción al `box.put` | Retry 1 vez; si falla, registrar en audit trail con flag `persistence_failed` |
| Pipeline DSP no inicializado | `audioBridge.isReady == false` | Bloquear botón "Capturar" |
| Schema version incompatible al import | `schemaVersion < 2.0` | Rechazar import, mostrar instrucciones de migración |

### Concurrencia

- Solo una calibración activa a la vez. `MicCalibrationController` usa flag interno.
- Mientras hay calibración activa, otros widgets de configuración del pipeline DSP están bloqueados.
- Audit trail se escribe asíncronamente; si la escritura es lenta no bloquea la UI.

## Testing Strategy

### Unit tests

- `MicCalibrationResult.toJson() / fromJson()` round-trip — propiedad A.
- `MicCalibrationStore` save/load idempotency — propiedad A.
- Conversión bidireccional dBFS↔SPL — propiedad B.
- Validación de rango `splOffset ∈ [60, 130]` — propiedad E.

### Property-based tests (PBT)

Implementar en `test/mic_calibration/property_*.dart` usando `glados` o `fast_check_dart`:

- **Property A — Idempotency**: para cualquier `MicCalibrationResult r`, `load(save(r)) == r` modulo timestamp.
- **Property B — Bidirectional conversion**: para `dbfs ∈ [-100, 0]` y `offset ∈ [60, 130]`, `dbfsFromSpl(splFromDbfs(dbfs, offset), offset)` devuelve `dbfs ± 0.001`.
- **Property C — Slider monotonicity**: integration test donde se varía el slider con señal de referencia constante y se mide.
- **Property D — Audit trail growth**: secuencia de eventos hace crecer el contador.
- **Property E — Range validation**: shrinking de offsets fuera de `[60, 130]` siempre rechaza.
- **Property F — Bilateral atomicity**: simular fallo a mitad de save bilateral, verificar estado consistente.
- **Property G — Schema compatibility**: archivos JSON con schemaVersion 1.x y 2.0 se manejan según spec.

### Integration tests

- `integration_test/mic_calibration_full_flow.dart` con device real (emulador OK).
- `integration_test/biological_extended_full_flow.dart` con sujeto simulado.
- Test de regresión sobre el flujo biológico existente (no debe romperse al agregar el campo opcional).

### Tests específicos LATAM

- Test de exportación JSON con todos los metadatos requeridos por ANMAT (operatorId, fecha, dispositivo, versión).
- Test de PDF de audit trail (formato compatible con auditoría INVIMA).
- Test de localización: textos del disclaimer en español argentino y español neutro.

## Compliance & Audit

### Trazabilidad regulatoria implementada

- **Audit trail inmutable** desde la UI (cumple Disposición ANMAT 2318/02 art. 9 sobre trazabilidad y Decreto 4725/2005 art. 36 sobre vigilancia).
- **SHA-256 de cada payload** persistido (cumple buenas prácticas de integridad de datos para BPF / ISO 13485).
- **Schema versionado** (`schemaVersion`) para migración futura sin pérdida de datos históricos.
- **Modo `production` separado de `field`** para distinguir calibraciones certificables de las funcionales.

### Estándares referenciados

| Norma | Aplica a | Cita |
|---|---|---|
| ANMAT Disposición 2318/2002 | Registro Argentina | [ANMAT helena PDF](https://helena.anmat.gob.ar/uploads/pdfs/dc_59511_30536071802_3177.pdf) |
| ANMAT IEC 60601 + ISO 17025 | Ensayos Argentina | [ANMAT productos médicos eléctricos](http://www.anmat.gob.ar/webanmat/tecmed/productos/productos.asp) |
| Decreto 4725 de 2005 | Registro Colombia | [Min Salud Decreto 4725](https://www.minsalud.gov.co/sites/rid/lists/bibliotecadigital/ride/de/dij/decreto-4725-de-2005.pdf) |
| INVIMA dispositivos médicos | Trámites Colombia | [INVIMA portal](https://www.invima.gov.co/productos-vigilados/dispositivos-medicos) |
| ISO 13485 | QMS | implícito |
| ISO 14971 | Risk management | implícito |
| IEC 62304 | Software médico clase B | aplica a este módulo |
| IEC 60601-1 / 60601-1-2 | Seguridad / EMC | aplica al hardware nRF5340 |
| ANSI/ASA S3.22-2014 | Características audífono | aplica a sweep producción |
| IEC 60318-5 | Acoplador 2cc | aplica a sweep producción |
| ANSI S3.6 / ISO 389 | RETSPL | aplica al lado biológico salida |
| ANSI S3.21 / ISO 8253-1 | Hughson-Westlake | ya implementado |

### Disclaimers obligatorios en UI

```
"Esta calibración es funcional. Para certificación regulatoria se requiere
medición en laboratorio acreditado bajo ISO 17025 (INTI en Argentina, ONAC
en Colombia)."
```

```
"Modo Producción. Esta sesión genera un certificado QR-firmado válido
únicamente cuando el sonómetro de referencia está calibrado y trazable
a INTI / ONAC y el acoplador es IEC 60318-5 verificado."
```

## Correctness Properties

Las siete propiedades verificables se implementan en `test/mic_calibration/property_*.dart`.

### Property 1: Idempotencia de persistencia
Para cualquier `MicCalibrationResult r`, `load(save(r)) == r` modulo timestamp normalizado.
**Validates: Requirements 1.2**

### Property 2: Conversión bidireccional dBFS↔SPL
Para cualquier `dBFS` y `splOffset`, `dbfsFromSpl(splFromDbfs(dbfs, offset), offset) ≈ dbfs ± 0.001`.
**Validates: Requirements 1.1, 2.2**

### Property 3: Monotonicidad del slider
Si `slider1 < slider2`, entonces el `splOffset` aplicado al pipeline reportará `level1_dB_SPL < level2_dB_SPL` para la misma señal de entrada.
**Validates: Requirements 2.1, 2.2**

### Property 4: Audit trail crece monotónicamente
Para cualquier evento E, `auditTrail.size after E > auditTrail.size before E`, salvo en eventos de rotación documentados.
**Validates: Requirements 4.1**

### Property 5: Rango válido de offset
El `splOffset` persistido SIEMPRE está en `[60, 130]` dB.
**Validates: Requirements 2.1**

### Property 6: Atomicidad bilateral
Si la calibración bilateral falla a mitad, el estado persistido es exactamente uno de: (todo guardado), o (nada guardado de esta sesión).
**Validates: Requirements 5.3, 5.4**

### Property 7: Compatibilidad de schemaVersion
Cualquier export con `schemaVersion = "2.0"` es legible por el código actual; cualquier export con schemaVersion < 2.0 se rechaza con mensaje claro.
**Validates: Requirements 9.1, 9.2**

## References

### Argentina (ANMAT)

- ANMAT — [Productos Médicos](https://www.argentina.gob.ar/anmat/regulados/productos-medicos)
- ANMAT — [Tramites productos médicos eléctricos (IEC 60601, ISO 17025)](http://www.anmat.gob.ar/webanmat/tecmed/productos/productos.asp)
- ANMAT — [Normativa Productos Médicos](https://www.anmat.gob.ar/webanmat/normativas_productosMedicos.asp)
- ANMAT — [Ejemplo registro audífono RITE Clase II Phonak](https://helena.anmat.gob.ar/uploads/pdfs/dc_59511_30536071802_3177.pdf)
- Thema-Med — [Registrar dispositivo médico Argentina (guía AAR + plazos)](http://www.thema-med.com/es/registrar-un-dispositivo-medico-en-argentina/)

### Colombia (INVIMA)

- Ministerio de Salud — [Decreto 4725 de 2005 (PDF oficial)](https://www.minsalud.gov.co/sites/rid/lists/bibliotecadigital/ride/de/dij/decreto-4725-de-2005.pdf)
- Función Pública — [Decreto 4725 (clasificación riesgo)](https://www.funcionpublica.gov.co/eva/gestornormativo/norma.php?i=18697)
- SUIN-Juriscol — [Decreto 4725 texto completo](https://www.suin-juriscol.gov.co/viewDocument.asp?id=1549782)
- INVIMA — [Dispositivos Médicos portal](https://www.invima.gov.co/productos-vigilados/dispositivos-medicos)
- INVIMA — [Equipos biomédicos trámites](https://www.invima.gov.co/productos-vigilados/dispositivos-medicos/dispositivos-medicos-equipos-biomedicos)
- INVIMA — [Solicitud registro sanitario / formulario ASS-RSA-FM007](https://www.invima.gov.co/biblioteca/solicitud-registro-sanitario-dispositivos-medicos-equipos-biomedicos)
- Invitro News — [De los Decretos 4725 y 3770 hacia un nuevo modelo regulatorio](https://invitronews.com/de-los-decretos-4725-y-3770-hacia-un-nuevo-modelo-regulatorio-de-dispositivos-medicos-y-reactivos-de-diagnostico-in-vitro/)

### Normas técnicas internacionales

- [Datasheet ICS-43434 — TDK InvenSense](https://www.mouser.com/datasheet/2/400/ds_000069_ics_43434_v1_2-2581173.pdf)
- IEC 60601-1 — guías y referencias ([Electromedicina Barcelona](https://electromedicinabarcelona.com/iec-60601-norma-seguridad-electrica/))
- ISO 17025 — acreditación laboratorios
- ANSI/ASA S3.22-2014 — características de audífonos
- ANSI/ASA S3.6 — RETSPL
- IEC 60118-7 — control de calidad audífonos
- IEC 60318-5 — acoplador 2cc
- ISO 13485 — QMS dispositivos médicos
- ISO 14971 — gestión de riesgos
- IEC 62304 — software de dispositivo médico
- IEC 62366-1 — usabilidad

### Cumplimiento de licencias

Todo el contenido externo fue parafraseado para cumplimiento. Ningún fragmento
verbatim excede 30 palabras consecutivas. Cada cita lleva URL inline.

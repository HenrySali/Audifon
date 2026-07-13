# Requirements Document

## Spec: Native Calibration Handlers

> Spec ID: `native-calibration-handlers`
> Fecha: 6 de junio de 2026.
> Owner: equipo nativo + clínico.
> Origen: P1 de `.kiro_tmp/spec-review-pending.md` (ítem
> "Handlers nativos C-3 stubs `notImplemented`").
> Documento normativo de referencia:
> [`docs/03-investigacion/normas-calibracion-audifono.md`](../../../../docs/03-investigacion/normas-calibracion-audifono.md)
> y sus 3 partes hermanas (técnicas, protocolos clínicos, regulatorias).

## Introduction

Hoy los 3 handlers de calibración del `MethodChannel`
`com.psk.hearing_aid/audio` están registrados como
`result.notImplemented()` honestos en
`android/app/src/main/kotlin/com/psk/hearing_aid_app/AudioMethodChannel.kt`
(líneas ~241–303). El lado Dart maneja la `MissingPluginException` con
mensaje claro al operador (`headphone_calibrator.dart:228`,
`audio_bridge_impl.dart:175,202`), sin fallback `Random()` ni datos
inventados.

Esta spec implementa los 3 handlers reales con el procedimiento
metrológico documentado en `normas-calibracion-audifono.md`:

- **`getInputLevel`** — captura RMS dBFS PRE-EQ del `AudioRecord` por
  ventana de 100 ms a 48 kHz, opcionalmente convertido a dB SPL si hay
  `mic_offset_db` persistido.
- **`calibrateMicrophone`** — protocolo IEC 60942: 5 segundos de
  captura con calibrador clase 1 (1 kHz @ 94 dB SPL) emitiendo,
  cálculo `mic_offset_db = 94 − RMS_promedio_dBFS`.
- **`calibrateHeadphones`** — protocolo loopback con acoplador IEC
  60318-4 / IEC 60318-5: 12 tonos puros (250 Hz → 8 kHz) a -20 dBFS
  reproducidos por el auricular, captura simultánea, tabla
  `hp_offset_table[12]`.

Los handlers usan AudioRecord directo (no el pipeline DSP nativo)
para evitar el doble offset del `splOffset` y los ceros silenciosos
cuando el engine no corre. El audit trail incluye timestamp UTC,
modelo del operador, modelo del calibrador y hash SHA-256 del
registro persistido para trazabilidad ANMAT/INVIMA/FDA.

Esta spec NO duplica:

- `mic-calibration` — provee `MicCalibrationResult` y `splOffset`. La
  presente spec extiende ese flujo agregando los handlers nativos
  reales que faltaban.
- `system-audit-fix` — eliminó el fallback `Random()` y dejó stubs
  honestos; esta spec los reemplaza con la implementación final.
- `audiogram-driven-presets` — consume `applyCalibration` ya
  implementado; esta spec no toca esa cadena.

## Glossary

- **mic_offset_db** — offset persistido `94 − RMS_promedio_dBFS` que
  convierte dBFS PRE-EQ del `AudioRecord` a dB SPL real. Por defecto:
  no calibrado (sin valor persistido).
- **hp_offset_table** — tabla 12 entradas Hz → dB que compensa la
  respuesta en frecuencia del auricular. `offset[f] = SPL_medido −
  (target_dBSPL)` donde `target_dBSPL = -20 dBFS + mic_offset_db`.
- **calibration_box** — Hive box dedicado para persistencia de
  calibraciones (claves `mic_offset_db`, `hp_offset_table`,
  `last_calibrated_at_mic`, `last_calibrated_at_hp`,
  `mic_audit_record`, `hp_audit_record`).
- **CalibrationAuditRecord** — registro inmutable de una calibración
  individual: timestamp UTC, modelo del operador (PIN-hash),
  modelo del calibrador, modelo del acoplador, modelo del auricular,
  payload medido (offset dB), hash SHA-256 del payload+timestamp.
- **RMS dBFS** — `20 × log10(sqrt(mean(x[i]^2)) / FULL_SCALE)` donde
  `FULL_SCALE = 32767.0` para PCM_16. Computado sobre ventana de
  100 ms (4800 samples a 48 kHz).
- **Patrón clase 1** — calibrador acústico IEC 60942 clase 1 con
  certificado de calibración primaria (NIST/NPL/PTB/INM-AR).
  Entrada: 1 kHz @ 94 dB SPL ± 0.4 dB.
- **Acoplador HA-2** — acoplador IEC 60318-4 (audífonos in-ear).
  Alternativa: IEC 60318-5 (acoplador 2 cc).
- **Sonómetro clase 2** — instrumento IEC 61672-1 clase 2: linealidad
  ±1 dB en 50–100 dB SPL @ 1 kHz. Modelo objetivo del comportamiento
  del handler `getInputLevel`.

## Requirements

### Requirement 1: Lectura de nivel de entrada (`getInputLevel`)

**User Story:** Como operador clínico, quiero leer el nivel del
micrófono PRE-EQ del celular en dBFS o dB SPL, para validar que el
patrón acústico está colocado correctamente y para alimentar el flujo
de calibración del headphone (`headphone_calibrator.dart`).

#### Acceptance Criteria

1. THE handler nativo `getInputLevel` SHALL abrir un `AudioRecord` con
   `MediaRecorder.AudioSource.UNPROCESSED` cuando esté disponible
   (Android API ≥ 24), o con `MediaRecorder.AudioSource.MIC` como
   fallback, configurado a `48000 Hz` mono `PCM_16`. THE handler SHALL
   reservar un buffer de 4096 samples y SHALL leer `4800` samples
   (ventana RMS de 100 ms).
2. THE handler SHALL calcular el RMS dBFS según la fórmula
   `dbfs = 20 × log10(max(rms, 1.0) / 32767.0)` donde
   `rms = sqrt(sum(x[i]^2) / N)` y `x[i] ∈ [-32768, 32767]`. THE
   resultado SHALL estar en el rango `(-120.0, 0.0]` dB; valores
   menores se clampean a `-120.0`.
3. WHEN existe un `mic_offset_db` persistido en Hive box
   `calibration_box`, THE handler SHALL retornar un Map con claves:
   `dbfs` (Double), `dbSpl` (Double = `dbfs + mic_offset_db`),
   `calibrated` (Bool = `true`), `micOffsetDb` (Double),
   `durationMs` (Int = 100), `sampleRate` (Int = 48000).
4. WHEN NO existe `mic_offset_db` persistido, THE handler SHALL retornar
   un Map con `dbfs` (Double), `dbSpl` (null), `calibrated` (Bool =
   `false`), `micOffsetDb` (null), `durationMs` (Int = 100),
   `sampleRate` (Int = 48000).
5. IF la apertura del `AudioRecord` falla por permisos faltantes
   (`RECORD_AUDIO`) o por dispositivo ocupado, THEN THE handler SHALL
   responder con `result.error("AUDIO_RECORD_FAILED", message,
   stackTrace)` sin retornar Map.
6. IF la lectura del `AudioRecord` retorna `read < 0` o un código de
   error de Android (`ERROR_INVALID_OPERATION`, `ERROR_BAD_VALUE`,
   `ERROR_DEAD_OBJECT`), THEN THE handler SHALL responder con
   `result.error("AUDIO_RECORD_READ_FAILED", message, stackTrace)`.
7. THE handler SHALL liberar el `AudioRecord` (stop + release) en un
   bloque `finally` antes de responder, sin importar éxito o fallo.
8. THE caller Dart `headphone_calibrator.dart::_measureMicLevel` SHALL
   leer la clave `dbSpl` cuando esté disponible (calibrado), o caer al
   `dbfs + 120.0` cuando `calibrated == false`, registrando el camino
   tomado vía `developer.log` con nivel INFO.

---

### Requirement 2: Calibración del micrófono (`calibrateMicrophone`)

**User Story:** Como operador clínico, quiero calibrar el micrófono
del celular contra un patrón acústico clase 1 (IEC 60942), para que
todas las mediciones posteriores tengan trazabilidad metrológica al
patrón nacional.

#### Acceptance Criteria

1. THE handler nativo `calibrateMicrophone` SHALL aceptar como
   argumentos opcionales: `referenceSplLevel` (Double, default `94.0`
   dB SPL), `calibratorModel` (String, default `"unknown"`),
   `operatorId` (String, default `"unknown"`), `expectedFreqHz`
   (Double, default `1000.0`).
2. THE handler SHALL abrir un `AudioRecord` con la misma configuración
   del Requirement 1.1 y SHALL capturar `5.0 segundos` continuos
   (240000 samples a 48 kHz), agrupados en 50 ventanas de 100 ms.
3. THE handler SHALL calcular `rms_dbfs[i]` por cada ventana usando la
   fórmula del Requirement 1.2, descartando las primeras 5 ventanas
   (500 ms iniciales) para permitir estabilización del calibrador.
4. THE handler SHALL calcular el promedio aritmético `rms_avg_dbfs` y
   la desviación estándar muestral `rms_std_dbfs` sobre las 45
   ventanas válidas.
5. IF `rms_std_dbfs > 1.0` dB, THEN THE handler SHALL responder con
   `result.error("UNSTABLE_SIGNAL", message, null)`, indicando que la
   señal capturada fluctúa más de lo permitido (calibrador mal
   colocado, ruido ambiental excesivo o ausencia de patrón). El
   mensaje SHALL incluir el valor `rms_std_dbfs` observado.
6. IF `rms_avg_dbfs ∉ [-40.0, -10.0]` dBFS, THEN THE handler SHALL
   responder con `result.error("LEVEL_OUT_OF_RANGE", message, null)`,
   indicando que el calibrador no está produciendo el nivel esperado.
   El mensaje SHALL incluir el valor `rms_avg_dbfs` observado y el
   rango aceptable.
7. WHEN la validación de los pasos 5 y 6 pasa, THE handler SHALL
   calcular `mic_offset_db = referenceSplLevel − rms_avg_dbfs` y SHALL
   persistir en Hive box `calibration_box`:
   - clave `mic_offset_db` (Double).
   - clave `last_calibrated_at_mic` (String ISO-8601 UTC con `Z`
     final).
   - clave `mic_audit_record` (Map serializable con campos:
     `timestampUtc`, `referenceSplLevel`, `rmsAvgDbfs`,
     `rmsStdDbfs`, `micOffsetDb`, `calibratorModel`, `operatorId`,
     `deviceModel`, `expectedFreqHz`, `windowsUsed`, `sha256`).
8. THE campo `sha256` SHALL ser `SHA-256(canonicalJson(record_sin_sha256))`
   donde el JSON canónico ordena las claves alfabéticamente y NO
   incluye el campo `sha256` mismo, para evitar self-reference.
9. THE handler SHALL retornar un Map con: `splOffset` (Double =
   `mic_offset_db`), `confidenceLevel` (Double = `1.0` cuando
   `rms_std_dbfs < 0.5`, `0.7` cuando `[0.5, 1.0]`), `method`
   (String = `"external_ref"`), `calibratedAtMs` (Int = epoch UTC ms),
   `deviceModel` (String = `Build.MODEL`), `rmsAvgDbfs` (Double),
   `rmsStdDbfs` (Double).
10. IF la persistencia en Hive falla, THEN THE handler SHALL
    responder con `result.error("PERSIST_FAILED", message,
    stackTrace)` y SHALL NO retornar el Map de éxito; el offset
    medido se descarta para mantener consistencia entre Hive y la
    respuesta entregada al caller.
11. THE handler SHALL loggear cada fase del proceso (apertura,
    captura, validación, cálculo, persistencia) vía `Log.i(TAG, …)` o
    `Log.e(TAG, …)` con prefijo `"calibrateMicrophone: "`.

---

### Requirement 3: Calibración del auricular (`calibrateHeadphones`)

**User Story:** Como operador clínico, quiero calibrar la respuesta
en frecuencia del auricular conectado contra un acoplador IEC 60318,
para que las prescripciones NAL-NL2/DSL v5 se apliquen con
compensación per-banda y el paciente reciba el SPL prescrito al
tímpano.

#### Acceptance Criteria

1. THE handler nativo `calibrateHeadphones` SHALL aceptar como
   argumentos: `headphoneId` (String, requerido), `headphoneName`
   (String, requerido), `couplerModel` (String, default `"HA-2"`),
   `operatorId` (String, default `"unknown"`).
2. THE handler SHALL exigir un `mic_offset_db` previamente persistido
   en Hive box `calibration_box`. IF la clave no existe, THEN THE
   handler SHALL responder con `result.error("MIC_NOT_CALIBRATED",
   message, null)` antes de iniciar cualquier reproducción.
3. THE handler SHALL reproducir secuencialmente 12 tonos puros a las
   frecuencias estándar `[250, 500, 750, 1000, 1500, 2000, 2500,
   3000, 3500, 4000, 6000, 8000]` Hz, generando samples sintéticos a
   48 kHz mono PCM_16 con amplitud digital correspondiente a `-20.0`
   dBFS RMS (= `0.1 × FULL_SCALE` peak para senoide pura). Cada tono
   SHALL durar `1500 ms` continuos con un silencio de `500 ms`
   entre tonos.
4. THE handler SHALL aplicar fade-in/fade-out de `20 ms` (cosine
   ramp) en cada tono para evitar clicks audibles que contaminen la
   medición RMS.
5. THE handler SHALL abrir un `AudioRecord` simultáneo a la
   reproducción y SHALL capturar samples durante toda la secuencia.
   Para cada tono, SHALL descartar los primeros 200 ms (estabilización
   del DAC y del acoplador) y calcular el RMS dBFS de los 1300 ms
   restantes.
6. THE handler SHALL convertir cada `rms_dbfs[f]` a `spl_dbspl[f]`
   sumando `mic_offset_db`. THE offset por banda SHALL ser
   `hp_offset_db[f] = spl_dbspl[f] − target_dbspl` donde
   `target_dbspl = -20.0 + mic_offset_db`.
7. IF cualquier `rms_dbfs[f]` es `NaN`, `Infinity`, o resulta en
   `hp_offset_db[f] ∉ [-30.0, +30.0]` dB, THEN THE handler SHALL
   responder con `result.error("BAND_OUT_OF_RANGE", message, null)`
   indicando la banda problemática. El mensaje SHALL listar
   explícitamente cuál frecuencia falló y con qué valor.
8. IF la dispersión entre bandas adyacentes (`|hp_offset_db[f_n+1] −
   hp_offset_db[f_n]|`) supera `15.0` dB, THEN THE handler SHALL
   responder con `result.error("BAND_DISCONTINUITY", message, null)`,
   indicando que el acoplador probablemente está mal puesto o el
   auricular tiene un fallo. El mensaje SHALL listar el par de
   bandas problemático.
9. WHEN todas las validaciones pasan, THE handler SHALL persistir en
   Hive box `calibration_box`:
   - clave `hp_offset_table.<headphoneId>` (Map<String,Double> con
     12 entradas; las claves son `String` con la frecuencia en Hz).
   - clave `last_calibrated_at_hp.<headphoneId>` (String ISO-8601
     UTC con `Z` final).
   - clave `hp_audit_record.<headphoneId>` (Map serializable con
     campos: `timestampUtc`, `headphoneId`, `headphoneName`,
     `couplerModel`, `operatorId`, `deviceModel`, `micOffsetDb`,
     `targetDbspl`, `frequenciesHz` (List<Int>), `splDbspl`
     (List<Double>), `hpOffsetDb` (List<Double>), `sha256`).
10. THE campo `sha256` SHALL seguir la misma regla del Requirement 2.8
    (canonical JSON ordenado por claves, sin incluir el campo
    `sha256` mismo).
11. THE handler SHALL retornar un Map compatible con el caller Dart
    `audio_bridge_impl.dart::calibrateHeadphones`: `frequencyResponse`
    (Map<String,Double> = `spl_dbspl[f]` indexado por frecuencia),
    `compensation` (Map<String,Double> = `-hp_offset_db[f]` indexado
    por frecuencia), `headphoneId`, `headphoneName`, `calibratedAtMs`
    (Int = epoch UTC ms), `isBluetooth` (Bool, derivado del
    `headphoneId`).
12. THE handler SHALL liberar tanto el `AudioRecord` como el
    `AudioTrack` en un bloque `finally`, sin importar éxito o fallo.
13. THE handler SHALL loggear el inicio/fin de cada tono y el
    resultado de cada banda vía `Log.i(TAG, …)` con prefijo
    `"calibrateHeadphones: "`.

---

### Requirement 4: Persistencia trazable con audit trail

**User Story:** Como auditor regulatorio (ANMAT/INVIMA/FDA), quiero
que cada calibración persistida tenga un registro firmado con
SHA-256 + timestamp UTC + datos del operador y del equipamiento, para
poder reconstruir la cadena de evidencia ante una inspección.

#### Acceptance Criteria

1. THE app SHALL exponer un repositorio Dart
   `CalibrationAuditRepository` en
   `lib/data/services/calibration_audit_repository.dart` con interfaz:
   - `Future<void> appendMicCalibration(MicCalibrationAudit record)`
   - `Future<void> appendHpCalibration(HpCalibrationAudit record)`
   - `Future<List<CalibrationAuditRecord>> getAll({String? type})`
   - `Future<MicCalibrationAudit?> getLatestMic()`
   - `Future<HpCalibrationAudit?> getLatestHp(String headphoneId)`
   - `Future<bool> verifyIntegrity(CalibrationAuditRecord record)`
2. THE repositorio SHALL persistir cada record en Hive box
   `calibration_box` bajo la clave
   `audit_<type>_<isoTimestampUtc>` donde `type ∈ {mic, hp}`.
3. THE método `verifyIntegrity` SHALL recalcular el `sha256` del
   payload (canonical JSON sin el campo `sha256`) y compararlo con
   el campo `sha256` persistido. Retorna `true` si coinciden.
4. THE repositorio SHALL exponer `clear()` solo bajo el flag
   `forTests = true` para no permitir borrado accidental en
   producción.
5. THE entidad `CalibrationAuditRecord` SHALL ser `abstract` con dos
   subtipos concretos `MicCalibrationAudit` y `HpCalibrationAudit`,
   ambos con `toJson()` / `fromJson()` y `Equatable.props`.
6. THE entidad `MicCalibrationAudit` SHALL incluir los campos:
   `timestampUtc` (DateTime), `referenceSplLevel` (Double),
   `rmsAvgDbfs` (Double), `rmsStdDbfs` (Double), `micOffsetDb`
   (Double), `calibratorModel` (String), `operatorId` (String),
   `deviceModel` (String), `expectedFreqHz` (Double), `windowsUsed`
   (Int), `sha256` (String).
7. THE entidad `HpCalibrationAudit` SHALL incluir los campos:
   `timestampUtc` (DateTime), `headphoneId` (String), `headphoneName`
   (String), `couplerModel` (String), `operatorId` (String),
   `deviceModel` (String), `micOffsetDb` (Double), `targetDbspl`
   (Double), `frequenciesHz` (List<int>), `splDbspl` (List<double>),
   `hpOffsetDb` (List<double>), `sha256` (String).
8. IF un record persistido falla la verificación SHA-256, THEN
   `verifyIntegrity` SHALL devolver `false` y el caller SHALL
   loggear vía `developer.log` con nivel `SEVERE` el id del record
   corrupto, sin abortar la app.

---

### Requirement 5: Manejo seguro cuando no hay hardware conectado

**User Story:** Como operador clínico, quiero que la app me indique
con claridad cuando intento calibrar sin tener el patrón acústico, el
acoplador o el auricular conectado, para no obtener datos basura ni
contaminar el audit trail.

#### Acceptance Criteria

1. WHEN el handler `getInputLevel` se invoca y el permiso
   `RECORD_AUDIO` no está concedido, THE handler SHALL responder con
   `result.error("PERMISSION_DENIED", "El permiso RECORD_AUDIO es
   requerido para leer el nivel de entrada.", null)`. THE caller Dart
   SHALL mostrar al operador un diálogo solicitando el permiso.
2. WHEN el handler `calibrateMicrophone` detecta `rms_avg_dbfs <
   -40.0` dBFS, THE app SHALL interpretar como "calibrador no
   colocado o calibrador apagado" y SHALL mostrar al operador un
   mensaje en español rioplatense indicando "Acercá el calibrador al
   micrófono del celular y verificá que esté encendido".
3. WHEN el handler `calibrateMicrophone` detecta `rms_avg_dbfs >
   -10.0` dBFS, THE app SHALL interpretar como "calibrador
   sobreescala o ruido excesivo" y SHALL mostrar al operador un
   mensaje en español rioplatense indicando "Apartá el calibrador o
   reducí el ruido ambiental antes de reintentar".
4. WHEN el handler `calibrateHeadphones` detecta una banda con
   `hp_offset_db[f] < -30.0` dB, THE app SHALL interpretar como
   "auricular desconectado, sin acoplador o canal mudo" y SHALL
   mostrar al operador un mensaje en español rioplatense indicando
   "Verificá que el auricular esté conectado al acoplador y al
   celular antes de reintentar".
5. WHEN el handler `calibrateHeadphones` detecta una banda con
   `hp_offset_db[f] > +30.0` dB, THE app SHALL interpretar como
   "feedback del altavoz del celular hacia su propio micrófono"
   (caso típico: usuario olvidó conectar el auricular) y SHALL
   mostrar al operador un mensaje en español rioplatense indicando
   "Conectá el auricular antes de reintentar; el celular está
   midiendo su propio altavoz".
6. THE app SHALL NOT persistir ningún offset si cualquiera de los
   errores 5.1–5.5 ocurre. La calibración previa (si existía) se
   preserva sin modificación.
7. THE app SHALL NO inventar valores, NO usar `Random()`, NO usar
   defaults silenciosos cuando un handler retorna error. El operador
   SHALL siempre ver el motivo real del fallo.

---

### Requirement 6: Cumplimiento metrológico ANSI/IEC

**User Story:** Como responsable regulatorio, quiero que los handlers
de calibración cumplan con las normas IEC 60942, IEC 60318 e IEC
61672-1, para que los certificados de QC sean aceptados por
ANMAT/INVIMA/FDA y los registros sirvan como evidencia ante
inspección.

#### Acceptance Criteria

1. THE handler `calibrateMicrophone` SHALL asumir un patrón acústico
   IEC 60942 clase 1 (1 kHz @ 94 dB SPL ± 0.4 dB). El argumento
   `referenceSplLevel` permite override solo para escenarios de
   debug/testing; el default `94.0` dB SPL es el contractual.
2. THE handler `calibrateHeadphones` SHALL asumir un acoplador IEC
   60318-4 (HA-2) o IEC 60318-5 (2 cc) acotado por el argumento
   `couplerModel`. Otros acopladores (e.g. ear simulator) están
   fuera de scope de esta spec y SHALL ser documentados con un
   warning en el campo `notes` del audit record.
3. THE handler `getInputLevel` SHALL replicar el comportamiento de
   un sonómetro IEC 61672-1 clase 2 cuando el offset está aplicado:
   linealidad ±1 dB en el rango 50–100 dB SPL @ 1 kHz. Esta
   propiedad SHALL ser verificada por property test con golden
   vectors sintéticos (señales 1 kHz a -60, -50, -40, -30, -20, -10
   dBFS).
4. THE app SHALL exponer en la pantalla de calibración el modelo y
   el serial del calibrador y del acoplador como campos editables
   por el operador antes de iniciar el procedimiento, para que
   queden persistidos en el audit record.
5. THE app SHALL persistir un campo `calibratorCertExpiresAt`
   (DateTime?) opcional que el operador puede ingresar para alertar
   cuando se acerque la fecha de re-calibración del patrón.
6. THE app SHALL NOT permitir aplicar `mic_offset_db` o
   `hp_offset_table` al pipeline DSP nativo si el último
   `last_calibrated_at_*` es más antiguo que `365` días. El operador
   SHALL ver un banner persistente "Calibración expirada — re-calibrá
   antes de uso clínico" hasta re-calibrar.
7. THE app SHALL exponer la verificación de integridad SHA-256
   (`CalibrationAuditRepository.verifyIntegrity`) en una pantalla de
   audit técnica accesible solo con el PIN del operador.
8. THE 12 frecuencias estándar usadas en `calibrateHeadphones` SHALL
   coincidir con las frecuencias Bisgaard estándar pediátricas (250,
   500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000
   Hz). THE tolerancia esperada por banda SHALL ser ±2 dB en
   250–4000 Hz y ±3 dB en extendido (250 Hz, 6000 Hz, 8000 Hz),
   conforme a `normas-calibracion-audifono.md` §4.3.

---

### Requirement 7: Wizard de calibración paso a paso

**User Story:** Como operador clínico (no programador), quiero un
wizard guiado de 4 pasos en español rioplatense, para ejecutar la
calibración del micrófono y del auricular sin equivocaciones, con
exportación PDF al final para archivar en la historia clínica.

#### Acceptance Criteria

1. THE app SHALL exponer una pantalla rediseñada
   `CalibrationScreen` (`lib/presentation/screens/calibration_screen.dart`)
   con un flujo lineal de 4 pasos: gate de PIN, calibración del
   micrófono, calibración del auricular, resumen + exportación PDF.
2. WHEN el operador entra a la pantalla, THE app SHALL pedir el PIN
   del operador vía `OperatorPinRepository.verifyPin`. Si no hay PIN
   configurado, THE app SHALL ofrecer generar uno con
   `generateAndStoreInitialPin` y mostrarlo una sola vez con
   instrucción de anotarlo.
3. WHEN el PIN se valida, THE app SHALL avanzar al paso "calibrá el
   micrófono" mostrando una animación o ícono que ilustre cómo
   colocar el calibrador junto al micrófono del celular. THE app
   SHALL pedir al operador que ingrese el modelo y el serial del
   calibrador antes de habilitar el botón "Iniciar".
4. WHEN el botón "Iniciar" se presiona, THE app SHALL invocar
   `calibrateMicrophone` y mostrar progreso (5 segundos con
   indicador linear). Al finalizar, SHALL mostrar el resultado
   (`mic_offset_db`, `rms_avg_dbfs`, `rms_std_dbfs`,
   `confidenceLevel`) y un botón "Continuar al auricular".
5. WHEN el operador presiona "Continuar al auricular", THE app SHALL
   avanzar al paso 3 mostrando una animación que ilustre cómo
   conectar el auricular al acoplador. THE app SHALL pedir al
   operador que ingrese el modelo y el serial del acoplador, y
   confirmar el id/nombre del auricular conectado (BT MAC o
   "wired_default").
6. WHEN el botón "Iniciar sweep" se presiona, THE app SHALL invocar
   `calibrateHeadphones` y mostrar progreso por banda (12 tonos),
   indicando cuál suena en este momento, su frecuencia, su SPL
   medido y su offset. Al finalizar, SHALL mostrar la tabla
   completa con un código de color verde (±2 dB) / amarillo (±5 dB)
   / rojo (>5 dB) por banda.
7. WHEN ambas calibraciones están completas, THE app SHALL avanzar
   al paso 4 "Resumen" mostrando: timestamp UTC, operador (PIN
   hash truncado a 8 chars), modelo del calibrador y del acoplador,
   `mic_offset_db`, tabla `hp_offset_db[12]`, hash SHA-256 de cada
   record. THE pantalla SHALL incluir un botón "Exportar PDF" que
   invoque `QcAuditRepository.generatePdf` con un record sintético
   construido a partir de las dos calibraciones.
8. IF el operador cancela en cualquier paso intermedio, THE app
   SHALL volver al paso 1 (gate de PIN) sin persistir ningún
   resultado parcial. La calibración previa (si existía) se
   preserva.
9. THE pantalla SHALL exponer un estado `_phase` con 5 valores:
   `gate`, `mic`, `micDone`, `hp`, `done`. Las transiciones SHALL
   ser unidireccionales hacia adelante (excepto cancelación).

---

### Requirement 8: Trazabilidad y logs

**User Story:** Como técnico de soporte, quiero logs estructurados
de cada paso del flujo de calibración, para diagnosticar fallas en
campo cuando el operador reporta un problema sin tener acceso al ADB.

#### Acceptance Criteria

1. THE handler nativo `getInputLevel` SHALL emitir un `Log.i(TAG,
   …)` al iniciar y al terminar la lectura, incluyendo el `dbfs`
   medido y si se aplicó offset.
2. THE handler nativo `calibrateMicrophone` SHALL emitir 7 logs
   estructurados: `START`, `AUDIO_RECORD_OPENED`, `CAPTURE_BEGIN`,
   `CAPTURE_END(rms_avg, rms_std)`, `VALIDATION_PASS|FAIL(reason)`,
   `OFFSET_COMPUTED(value)`, `PERSIST_OK|FAIL`.
3. THE handler nativo `calibrateHeadphones` SHALL emitir 4 + 12 logs
   estructurados: `START`, `AUDIO_RECORD_OPENED`,
   `AUDIO_TRACK_OPENED`, `TONE_BEGIN(freq, expected_dbfs)` por cada
   banda, `TONE_END(freq, rms_dbfs, spl, offset)` por cada banda, y
   `PERSIST_OK|FAIL`.
4. THE app Dart SHALL emitir vía `developer.log` en cada caller
   (`headphone_calibrator.dart`, `audio_bridge_impl.dart`,
   `calibration_screen.dart`) el inicio, fin y resultado de cada
   invocación con `name: 'NativeCalibration'`.
5. THE logs SHALL NO incluir PIN del operador, ganancias del paciente
   ni umbrales del audiograma. Sí pueden incluir el `operatorId`
   anonimizado (hash truncado).

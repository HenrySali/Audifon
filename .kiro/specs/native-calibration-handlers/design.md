# Design Document

> Spec ID: `native-calibration-handlers`
> Fecha: 6 de junio de 2026.
> Basado en: requirements.md (8 requirements, ~50 acceptance criteria).
> Dependencias: `mic-calibration` (entidades), `system-audit-fix`
> (stubs honestos), `audiogram-driven-presets` (consume
> `applyCalibration`).

## Overview

Este documento describe el diseño técnico de los 3 handlers nativos
que reemplazan los `notImplemented()` actuales en
`AudioMethodChannel.kt`:

1. **`getInputLevel`** — lectura RMS dBFS PRE-EQ del micrófono con
   ventana de 100 ms a 48 kHz. Aplica `mic_offset_db` cuando está
   persistido para reportar dB SPL.
2. **`calibrateMicrophone`** — protocolo IEC 60942: 5 segundos de
   captura contra patrón clase 1 (1 kHz @ 94 dB SPL), validación de
   estabilidad y rango, cálculo y persistencia de
   `mic_offset_db`.
3. **`calibrateHeadphones`** — protocolo loopback con acoplador IEC
   60318: 12 tonos puros a -20 dBFS, captura simultánea, tabla
   `hp_offset_db[12]` con validación per-banda.

Los handlers usan **AudioRecord directo** (no el pipeline DSP nativo)
para evitar el doble offset del `splOffset` post-pipeline y el
problema de "ceros silenciosos cuando el engine no corre".

### Objetivos de diseño

1. **Honestidad metrológica** — los handlers reportan lo que realmente
   midieron; sin Random fallback, sin defaults silenciosos.
2. **Trazabilidad SHA-256** — cada calibración persistida tiene un
   audit record con timestamp UTC, operador, equipamiento y hash
   verificable.
3. **Detección de fallas** — validación de estabilidad
   (`rms_std_dbfs ≤ 1.0` dB) y rango (`-40 ≤ rms_avg ≤ -10` dBFS para
   mic, `±30` dB de offset para hp) para flaggear hardware mal
   conectado.
4. **Cumplimiento IEC** — `getInputLevel` se comporta como sonómetro
   clase 2 (IEC 61672-1, ±1 dB en 50–100 dB SPL), `calibrateMicrophone`
   asume patrón clase 1 (IEC 60942), `calibrateHeadphones` asume
   acoplador IEC 60318-4/5.
5. **Wizard guiado** — pantalla rediseñada con 5 fases (gate, mic,
   micDone, hp, done) para que el operador clínico ejecute sin
   equivocaciones.
6. **Audit trail** — repositorio Dart `CalibrationAuditRepository`
   persiste cada calibración con SHA-256 verificable.

### Decisiones clave

| Decisión | Justificación |
|----------|---------------|
| AudioRecord 48 kHz mono PCM_16 | Sample rate más alto soportado por la mayoría de dispositivos Android. PCM_16 es suficiente para RMS dB SPL (rango dinámico 96 dB). |
| Buffer 4096 samples, lectura 4800 | Buffer mayor a la lectura para evitar `ERROR_BAD_VALUE` en dispositivos exóticos. 4800 samples = 100 ms exactos. |
| Ventana RMS 100 ms | Compatible con sonómetro IEC 61672 "Fast" (125 ms aprox). Ofrece resolución temporal sin ruido excesivo. |
| 5 segundos de captura mic | Conforme a IEC 60942 (la mayoría de calibradores piden ≥3 s). 5 s permite descartar 500 ms iniciales y tener 45 ventanas para promediar. |
| Tono headphone -20 dBFS | Margen de 20 dB con full-scale evita clipping del DAC y deja headroom para ruido del acoplador. |
| 1500 ms tono + 500 ms silencio | Total 12 × 2 s = 24 s de calibración hp. Aceptable para un wizard clínico. |
| Bisgaard 12 frecuencias | Estándar pediátrico. Coincide con `kCalibrationFrequencies` ya definido en `calibration_screen.dart`. |
| SHA-256 sobre canonical JSON | Comparable entre dispositivos. Sin self-reference (campo `sha256` excluido del input del hash). |
| MediaRecorder.AudioSource.UNPROCESSED | Bypass del DSP del SoC (NS, AGC del fabricante). Fallback a `MIC` si no está disponible. |

### Flujos no soportados

- **Calibración con micrófono externo USB**: AudioRecord captura del
  default route. Se documenta como future scope.
- **Sample rate dinámico**: handlers fijan 48 kHz; no se renegocia con
  el dispositivo. Si el celular no soporta, falla con
  `ERROR_BAD_VALUE` (caso muy raro post-Android 7).
- **Calibración multi-tono simultánea**: la spec usa secuencial. Un
  sweep multi-tono requeriría FFT y queda fuera de scope.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Dart (Flutter)                                │
│                                                                        │
│  ┌─────────────────────────┐  ┌───────────────────────────────────┐  │
│  │  CalibrationScreen      │  │  CalibrationAuditRepository       │  │
│  │  (wizard 5 fases)       │  │  (SHA-256 + Hive persistencia)    │  │
│  └────────┬────────────────┘  └──────────────┬────────────────────┘  │
│           │                                   │                       │
│           │ invoca                            │ getLatest{Mic,Hp}     │
│           ▼                                   ▼                       │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │  AudioBridgeImpl + HeadphoneCalibrator                        │    │
│  │  - calibrateMicrophone(referenceSpl)                          │    │
│  │  - calibrateHeadphones(headphoneId)                           │    │
│  │  - getInputLevel()                                            │    │
│  └────────────────────────┬─────────────────────────────────────┘    │
└───────────────────────────┼──────────────────────────────────────────┘
                            │ MethodChannel "com.psk.hearing_aid/audio"
                            ▼
┌──────────────────────────────────────────────────────────────────────┐
│                     Kotlin (Android Native)                           │
│                                                                        │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │  AudioMethodChannel.kt                                        │    │
│  │  - handleGetInputLevel(result)                                │    │
│  │  - handleCalibrateMicrophone(call, result)                    │    │
│  │  - handleCalibrateHeadphones(call, result)                    │    │
│  └────────────────────────┬─────────────────────────────────────┘    │
│                           │                                           │
│                           ▼                                           │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │  CalibrationAudioCapture (NEW)                                │    │
│  │  - openAudioRecord(sampleRate=48000, src=UNPROCESSED|MIC)     │    │
│  │  - readWindowRmsDbfs(durationMs)                              │    │
│  │  - captureStereoWithToneSequence(freqs, levelDbfs)            │    │
│  └────────────────────────┬─────────────────────────────────────┘    │
│                           │                                           │
│                           ▼                                           │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │  CalibrationStore (NEW)                                       │    │
│  │  - persistMicOffset(offsetDb, audit)                          │    │
│  │  - persistHpOffsetTable(headphoneId, table, audit)            │    │
│  │  - getMicOffset() → Double?                                   │    │
│  │  - getHpOffsetTable(headphoneId) → Map<Int, Double>?          │    │
│  │  ▶ usa SharedPreferences/jsonl para persistencia nativa       │    │
│  │    PERO la fuente de verdad es Hive en lado Dart.             │    │
│  └──────────────────────────────────────────────────────────────┘    │
│                                                                        │
│  Nota arquitectónica: el handler nativo computa el offset y lo        │
│  retorna al lado Dart. La persistencia OFICIAL ocurre en Dart vía     │
│  CalibrationAuditRepository sobre Hive. El handler nativo NO          │
│  persiste; solo computa y reporta.                                    │
└──────────────────────────────────────────────────────────────────────┘
                            │
                            │ AudioRecord (read PCM_16 raw)
                            │ AudioTrack (write PCM_16 sintético)
                            ▼
                   ┌─────────────────────┐
                   │  Android AudioFlinger│
                   │   ↑              ↓   │
                   │  Mic         Speaker │
                   │ (UNPROCESSED) (Stream│
                   │              MUSIC)  │
                   └─────────────────────┘
```

### Dependency Graph

```
native-calibration-handlers
├── system-audit-fix (sustituye notImplemented stubs por implementación real)
├── mic-calibration (entidad MicCalibrationResult ya existe)
├── audiogram-driven-presets (consumidor de applyCalibration)
└── OperatorPinRepository (gate de seguridad de la pantalla)
```

## Components and Interfaces

### `CalibrationAuditRepository` (Dart)

**Location:** `lib/data/services/calibration_audit_repository.dart`

```dart
class CalibrationAuditRepository {
  static const String boxName = 'calibration_box';
  static const String _micPrefix = 'audit_mic_';
  static const String _hpPrefix = 'audit_hp_';

  Future<void> appendMicCalibration(MicCalibrationAudit record);
  Future<void> appendHpCalibration(HpCalibrationAudit record);
  Future<List<CalibrationAuditRecord>> getAll({String? type});
  Future<MicCalibrationAudit?> getLatestMic();
  Future<HpCalibrationAudit?> getLatestHp(String headphoneId);
  Future<bool> verifyIntegrity(CalibrationAuditRecord record);
  Future<void> clear({required bool forTests});

  /// SHA-256 sobre canonical JSON sin el campo `sha256`.
  static String computeSha256(Map<String, dynamic> payload);

  /// Canonical JSON: claves ordenadas alfabéticamente, sin
  /// indentación, sin espacios innecesarios.
  static String canonicalJson(Map<String, dynamic> payload);
}
```

**Reglas:**
- Hive box compartido `calibration_box`. Una clave por audit
  record con prefijo `audit_mic_` o `audit_hp_`. La clave incluye
  el timestamp UTC ISO-8601 para orden cronológico natural.
- Los offsets vivos también se guardan: `mic_offset_db`,
  `last_calibrated_at_mic`, `hp_offset_table.<id>`,
  `last_calibrated_at_hp.<id>`.
- `verifyIntegrity` recomputa el SHA-256 sobre `record.toJson()`
  excluyendo el campo `sha256` y compara con el persistido.

### `CalibrationAuditRecord` + subclases (Dart)

**Location:** `lib/domain/entities/calibration_audit_record.dart`

```dart
abstract class CalibrationAuditRecord extends Equatable {
  String get type; // "mic" | "hp"
  DateTime get timestampUtc;
  String get operatorId;
  String get deviceModel;
  String get sha256;
  Map<String, dynamic> toJson();
  Map<String, dynamic> toJsonWithoutSha();
}

class MicCalibrationAudit extends CalibrationAuditRecord {
  // campos por Req 4.6
}

class HpCalibrationAudit extends CalibrationAuditRecord {
  // campos por Req 4.7
}
```

### `AudioMethodChannel.kt` — Handlers (Kotlin)

**Location:**
`android/app/src/main/kotlin/com/psk/hearing_aid_app/AudioMethodChannel.kt`

```kotlin
private fun handleGetInputLevel(call: MethodCall, result: MethodChannel.Result) {
    val capture = CalibrationAudioCapture.create(context)
        ?: return result.error("AUDIO_RECORD_FAILED", "No se pudo abrir AudioRecord", null)
    try {
        val window = capture.readWindowRmsDbfs(durationMs = 100)
        val store = CalibrationStore(context)
        val offset = store.getMicOffsetDb()
        val response = mutableMapOf<String, Any?>(
            "dbfs" to window.dbfs.toDouble(),
            "durationMs" to 100,
            "sampleRate" to 48000,
            "calibrated" to (offset != null),
            "micOffsetDb" to offset,
            "dbSpl" to offset?.let { it + window.dbfs.toDouble() },
        )
        result.success(response)
    } catch (e: Throwable) {
        result.error("AUDIO_RECORD_READ_FAILED", e.message, e.stackTraceToString())
    } finally {
        capture.release()
    }
}

private fun handleCalibrateMicrophone(call: MethodCall, result: MethodChannel.Result) {
    val refSpl = (call.argument<Double>("referenceSplLevel") ?: 94.0)
    val calibratorModel = call.argument<String>("calibratorModel") ?: "unknown"
    val operatorId = call.argument<String>("operatorId") ?: "unknown"
    val expectedFreq = (call.argument<Double>("expectedFreqHz") ?: 1000.0)

    val capture = CalibrationAudioCapture.create(context)
        ?: return result.error("AUDIO_RECORD_FAILED", "No se pudo abrir AudioRecord", null)
    try {
        val windows = capture.readManyWindowsRmsDbfs(
            durationMs = 100, count = 50, dropFirst = 5
        )
        val rmsAvg = windows.average()
        val rmsStd = windows.populationStandardDeviation()
        if (rmsStd > 1.0) {
            return result.error(
                "UNSTABLE_SIGNAL",
                "Señal inestable: rms_std_dbfs=$rmsStd > 1.0 dB",
                null,
            )
        }
        if (rmsAvg !in -40.0..-10.0) {
            return result.error(
                "LEVEL_OUT_OF_RANGE",
                "Nivel fuera de rango: rms_avg_dbfs=$rmsAvg ∉ [-40, -10] dBFS",
                null,
            )
        }
        val micOffset = refSpl - rmsAvg
        val response = mapOf(
            "splOffset" to micOffset,
            "confidenceLevel" to (if (rmsStd < 0.5) 1.0 else 0.7),
            "method" to "external_ref",
            "calibratedAtMs" to System.currentTimeMillis(),
            "deviceModel" to Build.MODEL,
            "rmsAvgDbfs" to rmsAvg,
            "rmsStdDbfs" to rmsStd,
            "referenceSplLevel" to refSpl,
            "calibratorModel" to calibratorModel,
            "operatorId" to operatorId,
            "expectedFreqHz" to expectedFreq,
            "windowsUsed" to windows.size,
        )
        result.success(response)
    } catch (e: Throwable) {
        result.error("AUDIO_RECORD_READ_FAILED", e.message, e.stackTraceToString())
    } finally {
        capture.release()
    }
}

private fun handleCalibrateHeadphones(call: MethodCall, result: MethodChannel.Result) {
    // ver implementación en tasks 3.x
}
```

### `CalibrationAudioCapture.kt` (Kotlin, NEW)

**Location:** `android/app/src/main/kotlin/com/psk/hearing_aid_app/CalibrationAudioCapture.kt`

```kotlin
class CalibrationAudioCapture private constructor(
    private val record: AudioRecord,
) {
    companion object {
        const val TAG = "CalibrationAudioCapture"
        const val SAMPLE_RATE = 48000
        const val FRAME_SAMPLES = 4800   // 100 ms a 48 kHz
        const val BUFFER_SAMPLES = 4096

        fun create(context: Context): CalibrationAudioCapture? {
            val audioSource = if (Build.VERSION.SDK_INT >= 24) {
                MediaRecorder.AudioSource.UNPROCESSED
            } else {
                MediaRecorder.AudioSource.MIC
            }
            val minBuffer = AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            val bufferBytes = max(minBuffer, BUFFER_SAMPLES * 2)
            val record = AudioRecord(
                audioSource, SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferBytes,
            )
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                record.release()
                return null
            }
            record.startRecording()
            return CalibrationAudioCapture(record)
        }
    }

    fun readWindowRmsDbfs(durationMs: Int = 100): RmsWindow {
        val samplesNeeded = SAMPLE_RATE * durationMs / 1000
        val buffer = ShortArray(samplesNeeded)
        var read = 0
        while (read < samplesNeeded) {
            val n = record.read(buffer, read, samplesNeeded - read)
            if (n < 0) error("AudioRecord.read returned $n")
            read += n
        }
        val dbfs = computeRmsDbfs(buffer, read)
        return RmsWindow(dbfs)
    }

    fun readManyWindowsRmsDbfs(
        durationMs: Int, count: Int, dropFirst: Int = 0,
    ): List<Double> = (0 until count).map { readWindowRmsDbfs(durationMs).dbfs }
        .drop(dropFirst)

    fun release() {
        try { record.stop() } catch (_: Throwable) {}
        try { record.release() } catch (_: Throwable) {}
    }
}

data class RmsWindow(val dbfs: Double)

private fun computeRmsDbfs(buffer: ShortArray, count: Int): Double {
    if (count == 0) return -120.0
    var sumSq = 0.0
    for (i in 0 until count) {
        val v = buffer[i].toDouble()
        sumSq += v * v
    }
    val rms = sqrt(sumSq / count)
    val safeRms = max(rms, 1.0)  // floor para evitar -∞
    val dbfs = 20.0 * log10(safeRms / 32767.0)
    return max(dbfs, -120.0)
}
```

### `CalibrationToneEmitter.kt` (Kotlin, NEW)

**Location:** `android/app/src/main/kotlin/com/psk/hearing_aid_app/CalibrationToneEmitter.kt`

```kotlin
class CalibrationToneEmitter {
    companion object { const val SAMPLE_RATE = 48000 }
    private var track: AudioTrack? = null

    fun playTone(freqHz: Double, levelDbfs: Double, durationMs: Int) {
        val nSamples = SAMPLE_RATE * durationMs / 1000
        val amplitude = 10.0.pow(levelDbfs / 20.0) * 32767.0 * sqrt(2.0)  // peak para senoide RMS
        val fadeMs = 20
        val fadeSamples = SAMPLE_RATE * fadeMs / 1000
        val data = ShortArray(nSamples)
        for (i in 0 until nSamples) {
            val t = i.toDouble() / SAMPLE_RATE
            var s = sin(2.0 * Math.PI * freqHz * t) * amplitude
            // cosine ramp
            val rampIn = if (i < fadeSamples) (1.0 - cos(Math.PI * i / fadeSamples)) * 0.5 else 1.0
            val rampOut = if (i > nSamples - fadeSamples) {
                (1.0 - cos(Math.PI * (nSamples - i) / fadeSamples)) * 0.5
            } else 1.0
            s *= rampIn * rampOut
            data[i] = s.toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        }
        val track = AudioTrack(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build(),
            AudioFormat.Builder()
                .setSampleRate(SAMPLE_RATE)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build(),
            data.size * 2,
            AudioTrack.MODE_STATIC,
            AudioManager.AUDIO_SESSION_ID_GENERATE,
        )
        track.write(data, 0, data.size)
        track.play()
        Thread.sleep(durationMs.toLong() + 50)
        track.stop()
        track.release()
    }
}
```

## Data Models

### Hive `calibration_box` schema

```
calibration_box:
  mic_offset_db          : Double           // -20.0 a +30.0 típico
  last_calibrated_at_mic : String (ISO-8601 UTC, with `Z`)
  audit_mic_<iso8601>    : Map (MicCalibrationAudit.toJson())

  hp_offset_table.<id>      : Map<String,Double>   // freq Hz → offset dB
  last_calibrated_at_hp.<id>: String (ISO-8601 UTC, with `Z`)
  audit_hp_<iso8601>        : Map (HpCalibrationAudit.toJson())
```

### Contratos JSON de los handlers

#### `getInputLevel` → response

```json
{
  "dbfs": -28.5,           // float64, dBFS RMS
  "dbSpl": 91.5,           // float64 | null
  "calibrated": true,      // bool
  "micOffsetDb": 120.0,    // float64 | null
  "durationMs": 100,       // int (sigueremos 100)
  "sampleRate": 48000      // int
}
```

#### `calibrateMicrophone` → response

```json
{
  "splOffset": 114.2,
  "confidenceLevel": 1.0,
  "method": "external_ref",
  "calibratedAtMs": 1748150400000,
  "deviceModel": "Pixel 7",
  "rmsAvgDbfs": -20.2,
  "rmsStdDbfs": 0.32,
  "referenceSplLevel": 94.0,
  "calibratorModel": "B&K 4231",
  "operatorId": "PIN_HASH_PREFIX_8",
  "expectedFreqHz": 1000.0,
  "windowsUsed": 45
}
```

#### `calibrateHeadphones` → response

```json
{
  "frequencyResponse": {"250": 87.3, "500": 89.1, ..., "8000": 86.2},
  "compensation":      {"250": -0.3, "500": -2.1, ..., "8000":  0.8},
  "headphoneId": "AA:BB:CC:DD:EE:FF",
  "headphoneName": "Sony WH-1000XM4",
  "calibratedAtMs": 1748150500000,
  "isBluetooth": true,
  "couplerModel": "HA-2",
  "operatorId": "PIN_HASH_PREFIX_8",
  "deviceModel": "Pixel 7",
  "micOffsetDb": 114.2,
  "targetDbspl": 94.2,
  "frequenciesHz": [250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000],
  "splDbspl": [87.3, 89.1, 91.5, 92.0, 93.8, 94.2, 94.0, 93.7, 93.0, 92.1, 88.3, 86.2],
  "hpOffsetDb": [-6.9, -5.1, -2.7, -2.2, -0.4, 0.0, -0.2, -0.5, -1.2, -2.1, -5.9, -8.0]
}
```

## Error Handling

### Tabla de errores

| Code                    | Origen                  | Significado                                                                 |
|-------------------------|-------------------------|-----------------------------------------------------------------------------|
| `AUDIO_RECORD_FAILED`   | `getInputLevel`, mic, hp | No se pudo crear/iniciar el `AudioRecord` (permiso, dispositivo ocupado).   |
| `AUDIO_RECORD_READ_FAILED` | id.                  | `read()` retornó código de error del framework.                             |
| `PERMISSION_DENIED`     | id.                     | `RECORD_AUDIO` no concedido.                                                |
| `UNSTABLE_SIGNAL`       | `calibrateMicrophone`   | `rms_std_dbfs > 1.0` dB en las 45 ventanas válidas.                         |
| `LEVEL_OUT_OF_RANGE`    | `calibrateMicrophone`   | `rms_avg_dbfs ∉ [-40, -10]` dBFS.                                           |
| `MIC_NOT_CALIBRATED`    | `calibrateHeadphones`   | No hay `mic_offset_db` previo persistido.                                   |
| `BAND_OUT_OF_RANGE`     | `calibrateHeadphones`   | Banda con NaN/Inf o `hp_offset[f] ∉ [-30, +30]` dB.                         |
| `BAND_DISCONTINUITY`    | `calibrateHeadphones`   | Bandas adyacentes con diferencia > 15 dB.                                   |
| `PERSIST_FAILED`        | mic, hp                 | Hive box write falló (raro: disco lleno, box corrupto).                     |
| `INVALID_ARGS`          | mic, hp                 | Argumentos inválidos (e.g. `referenceSplLevel < 0`).                        |

### Política de errores

1. Errores nativos se propagan al lado Dart como `PlatformException`
   con `code`, `message`, `details`.
2. El caller Dart traduce a `StateError` con mensaje en español
   rioplatense para mostrar al operador.
3. La pantalla `CalibrationScreen` muestra el mensaje en un
   `SnackBar` o diálogo con botón "Reintentar".
4. Ningún error parcial persiste en Hive: o el record completo se
   escribe (con SHA-256) o nada se escribe.

## Testing Strategy

### Unit tests (golden vectors sintéticos)

- `calibration_audit_repository_test.dart` — round-trip de SHA-256,
  ordenamiento de claves, integridad detectable.
- `audio_bridge_impl_calibrate_microphone_test.dart` — mock del
  MethodChannel, response golden con
  `rms_avg_dbfs = -20.0, mic_offset_db = 114.0`.
- `audio_bridge_impl_calibrate_headphones_test.dart` — mock del
  MethodChannel, response golden con 12 frecuencias y offsets dentro
  de tolerancia.
- `headphone_calibrator_get_input_level_test.dart` — mock del
  MethodChannel, response con `calibrated=true` y `dbfs=-30,
  dbSpl=84` cuando offset=114.

### Property tests (glados)

1. **Property: `mic_offset_db` reproduce 94 dB SPL**
   `∀ rms_dbfs ∈ [-40, -10] → mic_offset = 94 − rms_dbfs ∧
   rms_dbfs + mic_offset = 94 ± 0.001`. ExploreConfig: 100 runs.

2. **Property: la tabla `hp_offset_table` aplicada al output
   reproduce el SPL esperado ±2 dB**
   Para 12 frecuencias y `hp_offset[f] ∈ [-15, +15]` dB,
   `(SPL_medido − offset) ≈ target` con tolerancia 2 dB. 50 runs.

3. **Property: dos calibraciones consecutivas con la misma señal
   dan offsets dentro de ±0.5 dB** (estabilidad).
   Simulamos `rms_dbfs[i] ~ N(μ, σ=0.3)` y verificamos que
   `|offset_run1 − offset_run2| ≤ 0.5`. 30 runs.

4. **Property: `getInputLevel` lineal en 50–100 dB SPL @ 1 kHz** —
   cualquier `dbfs ∈ [-44, -14]` con `mic_offset = 120` produce
   `dbSpl ∈ [76, 106]` y la conversión es lineal. 100 runs.

5. **Property: SHA-256 detecta tampering** — modificar cualquier
   campo del audit record cambia el hash. 50 runs.

6. **Property: canonical JSON es idempotente** — `canonical(canonical(x))
   == canonical(x)`. 50 runs.

7. **Property: clamp del dBFS floor** — para cualquier buffer ShortArray
   con `count > 0`, `computeRmsDbfs(buffer, count) ≥ -120.0`. (Test
   en Kotlin con instrumentación, o test Dart sobre la fórmula).

### Widget tests

- `calibration_screen_wizard_test.dart` — verifica los 5 estados
  `gate`, `mic`, `micDone`, `hp`, `done` con MethodChannel mockeado
  para retornar responses golden.

### Manual QC (con hardware físico)

Documentado como procedimiento manual cuando el operador tenga el
calibrador en mano:

1. Conectar acoplador HA-2 al micrófono del celular y al patrón
   IEC 60942 clase 1.
2. Encender el patrón a 1 kHz @ 94 dB SPL.
3. Abrir CalibrationScreen, ingresar PIN, ejecutar paso 2 del
   wizard.
4. Verificar que `mic_offset_db ∈ [110, 130]` dB para un celular
   estándar.
5. Repetir 3 veces; verificar que la dispersión es `< 1.0` dB.
6. Conectar el auricular al acoplador, ejecutar paso 3 del wizard.
7. Verificar que la tabla `hp_offset_db[12]` está dentro de
   tolerancia ±5 dB en todas las bandas.
8. Exportar PDF y archivar.

## Correctness Properties

### Property 1: mic_offset reproduce 94 dB SPL

**Validates: Requirements 2.7, 6.3**

`mic_offset_db = 94 − rms_avg_dbfs` reproduce 94 dB SPL al sumar de
vuelta. Para todo `rms_avg_dbfs ∈ [-40, -10]`, `rms_avg_dbfs +
mic_offset_db = 94 ± 0.001`. Test file:
`mic_offset_inversion_property_test.dart`. Cobertura: 100 runs.

### Property 2: hp_offset_table reproduce target ± 2 dB

**Validates: Requirements 3.6, 6.8**

`hp_offset_table[f]` aplicado al output reproduce el SPL esperado
con tolerancia ±2 dB. Para 12 frecuencias y `hp_offset[f] ∈ [-15, +15]`
dB, `(SPL_medido − hp_offset[f]) ≈ target_dbspl` con tolerancia 2 dB.
Test file: `hp_offset_table_property_test.dart`. Cobertura: 50 runs.

### Property 3: estabilidad de calibraciones consecutivas

**Validates: Requirements 2.4, 2.5**

Dos calibraciones consecutivas con la misma señal de entrada producen
offsets dentro de ±0.5 dB. Para señal sintética con `rms_dbfs ~ N(μ,
σ=0.3)`, `|offset_run1 − offset_run2| ≤ 0.5 dB`. Test file:
`mic_offset_stability_property_test.dart`. Cobertura: 30 runs.

### Property 4: getInputLevel lineal en 50–100 dB SPL @ 1 kHz

**Validates: Requirements 1.2, 1.3, 6.3**

`getInputLevel` se comporta como sonómetro IEC 61672-1 clase 2:
linealidad ±1 dB en 50–100 dB SPL @ 1 kHz. Para cualquier `dbfs ∈
[-44, -14]` con `mic_offset = 120`, `dbSpl = dbfs + offset` y la
conversión es lineal. Test file:
`get_input_level_linearity_property_test.dart`. Cobertura: 100 runs.

### Property 5: SHA-256 detecta tampering

**Validates: Requirements 4.3, 4.8**

Modificar cualquier campo no-`sha256` del audit record cambia el
hash. `verifyIntegrity` retorna `false` para records manipulados.
Test file: `calibration_audit_repository_test.dart` (subgroup PBT).
Cobertura: 30 runs.

### Property 6: canonicalJson es idempotente

**Validates: Requirements 2.8, 3.10, 4.3**

`canonical(canonical(x)) == canonical(x)` para cualquier payload
JSON-serializable. Test file: `calibration_audit_repository_test.dart`
(subgroup PBT). Cobertura: 50 runs.

### Property 7: RMS dBFS floor a -120 dB

**Validates: Requirements 1.2**

Para cualquier buffer ShortArray con `count > 0`, `computeRmsDbfs ≥
-120.0`. Test file: `rms_dbfs_floor_property_test.dart` (Dart-side
fórmula port). Cobertura: 100 runs.

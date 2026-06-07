# Design — Oír Pro Paciente: APK independiente con bundle JSON firmado

> Estado: **diseño aprobado**, sin implementación.

## Overview

Tres componentes:

1. **APK técnico** (existente) — agrega botón "Exportar para paciente" que
   genera un `.oirpro.json` firmado con HMAC.
2. **APK paciente** (nuevo, proyecto Flutter aparte) — recibe el JSON,
   valida firma, aplica config y opera con DSP recortado.
3. **Backend** (existente, ampliar) — soporta dos `appId` distintos
   (`oirpro-tech`, `oirpro-patient`) con configuraciones separadas.

```
┌─────────────────────────┐                    ┌─────────────────────────┐
│ APK Técnico             │                    │ APK Paciente            │
│ (hearing_aid_app)       │   .oirpro.json    │ (PACIENTE/...)          │
│                         │   firmado HMAC    │                         │
│ Servicio Técnico        │  ───────────────▶ │ Importar configuración  │
│ → Exportar paciente     │  (WhatsApp, etc.) │ → Validar firma         │
│   - audiograma          │                    │ → Aplicar al DSP        │
│   - presets             │                    │                         │
│   - WDRC, MPO           │                    │ UI recortada:           │
│   - MHL flag            │                    │ - Presets               │
│   - signature HMAC      │                    │ - Smart                 │
└─────────────────────────┘                    │ - AutoTNR               │
                                               │ - DSP Test              │
                                               │ - Config avanzada       │
                                               │ - Modo MHL              │
                                               └────────┬────────────────┘
                                                        │
                                                        ▼
                                              ┌─────────────────────┐
                                              │ Backend remoto      │
                                              │ (oirpro/api/check)  │
                                              │ appId=oirpro-patient│
                                              └─────────────────────┘
```

## Architecture

### Carpetas

```
c:\Users\Elsa y Henry\Pictures\Amplificador\
├── hearing_aid_app\                  ← APK Técnico (existente)
│   └── lib\bundle_export\            ← NUEVO: genera .oirpro.json firmado
│
├── PACIENTE\                         ← Carpeta raíz para paciente
│   └── oir_pro_patient_app\          ← Proyecto Flutter NUEVO
│       ├── lib\                      ← Código Dart paciente (recortado)
│       ├── android\                  ← Config Android, package distinto
│       │   └── app\src\main\jniLibs\arm64-v8a\
│       │       ├── libnative-lib.so       ← Copiado del técnico
│       │       ├── libonnxruntime.so      ← Copiado del técnico
│       │       └── liboboe.so             ← Copiado del técnico
│       ├── pubspec.yaml
│       └── README.md
│
└── oirpro-server\                    ← Backend (existente, se amplía)
    └── db\schema.sql                 ← Migración para split appId
```

### Package names y firmas

| App | applicationId | Label | Keystore |
|---|---|---|---|
| Técnico | `com.psk.hearing_aid_app` | "Oír Pro" | `oirpro-release.jks` |
| Paciente | `com.psk.oir_pro_patient` | "Oír Pro" | `oirpro-release.jks` (misma) |

Misma keystore = mismo certificado = ambas firmadas como tuyas. Distinto
applicationId = Android las trata como apps separadas, conviven en el
mismo celu.

## Components and Interfaces

### 1. APK Técnico — Exportar bundle

Archivo nuevo: `hearing_aid_app/lib/bundle_export/bundle_exporter.dart`.

```dart
class BundleExporter {
  static const String _kSchemaVersion = '1.0.0';
  static const int _kKeyVersion = 1;

  /// Clave HMAC compartida con la APK paciente. NO commitear este string
  /// — se genera con el script `tools/generate_hmac_secret.dart` y se
  /// inyecta vía `--dart-define=HMAC_SECRET=...` al hacer build.
  static const String _hmacSecret =
      String.fromEnvironment('HMAC_SECRET', defaultValue: '');

  /// Construye el JSON, firma, y dispara share sheet o save-to-disk.
  Future<File> exportBundle({
    required Audiogram audiogram,
    required List<EqPreset> presets,
    required WdrcParams wdrc,
    required double mpoThresholdDbSpl,
    required bool mhlEnabled,
    required String defaultPresetName,
    String? patientName,
    String? notes,
  }) async {
    final body = <String, dynamic>{
      'schemaVersion': _kSchemaVersion,
      'keyVersion': _kKeyVersion,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'patient': {
        'name': patientName ?? '',
        'notes': notes ?? '',
      },
      'audiogram': audiogram.toJson(),
      'presets': presets.map((p) => p.toJson()).toList(),
      'wdrc': wdrc.toJson(),
      'mpo': { 'thresholdDbSpl': mpoThresholdDbSpl },
      'mhl': { 'enabled': mhlEnabled },
      'defaults': { 'presetName': defaultPresetName },
    };

    final canonical = _canonicalJson(body);
    final signature = _hmacSha256(canonical, _hmacSecret);
    final wrapped = { ...body, 'signature': { 'algo': 'HMAC-SHA256', 'value': signature } };

    final json = jsonEncode(wrapped);
    final filename = _buildFilename(patientName);
    final file = await _saveToDownloads(json, filename);
    await Share.shareXFiles([XFile(file.path)], text: 'Configuración Oír Pro');
    return file;
  }

  // ...
}
```

UI: en `technical_service_screen.dart`, agregar tarjeta "Exportar
configuración del paciente" que abre `BundleExportScreen` con form
(nombre, notas, preset default) y botón "Generar y compartir".

### 2. APK Paciente — Estructura

Proyecto Flutter nuevo, mínimo:

```
oir_pro_patient_app/
├── lib/
│   ├── main.dart                      ← BiometricGate opcional + RemoteConfigGate
│   ├── core/
│   │   ├── audio_bridge.dart          ← Reusado del técnico (MethodChannel a DSP)
│   │   ├── hive_initializer.dart      ← Boxes propias
│   │   └── theme.dart                 ← Mismo dark theme
│   ├── bundle/
│   │   ├── bundle_importer.dart       ← Lee + verifica HMAC
│   │   ├── bundle_data.dart           ← Modelo del JSON
│   │   └── pending_setup_screen.dart  ← Pantalla "primero importá tu config"
│   ├── presentation/
│   │   ├── home_screen.dart           ← Pantalla principal recortada
│   │   ├── presets_panel.dart         ← Solo presets (no edita)
│   │   ├── smart_toggle.dart
│   │   ├── auto_tnr_toggle.dart
│   │   ├── advanced_config_screen.dart ← 4 sliders
│   │   ├── dsp_test_screen.dart
│   │   └── mhl_toggle.dart            ← Solo si bundle.mhl.enabled
│   └── data/
│       ├── remote_config_service.dart ← Copy del técnico, appId=oirpro-patient
│       └── settings_repository.dart   ← Persistencia local
├── android/
│   └── app/
│       ├── build.gradle               ← Config con applicationId diferente
│       ├── proguard-rules.pro         ← Mismas reglas que el técnico
│       └── src/main/
│           ├── AndroidManifest.xml    ← Permisos + label "Oír Pro"
│           ├── kotlin/.../MainActivity.kt   ← Bridge MethodChannel al .so
│           └── jniLibs/arm64-v8a/     ← .so prebuilt copiados
└── pubspec.yaml
```

### 3. Backend — Split por appId

Schema MySQL ampliado:

```sql
-- antes: app_config singleton id=1
-- ahora: app_config con FK lógica a appId
ALTER TABLE app_config DROP COLUMN id;
ALTER TABLE app_config ADD COLUMN app_id VARCHAR(64) NOT NULL PRIMARY KEY;

INSERT INTO app_config (app_id, tech_code, latest_version, min_version)
VALUES
  ('oirpro-tech', 'OirProTec2026', '1.0.0', '1.0.0'),
  ('oirpro-patient', '', '1.0.0', '1.0.0');
```

Endpoint `POST /api/check` ya recibe `appId`. Cambio mínimo:
- Filtrar por `app_id` en el SELECT.
- Si no existe la fila → devolver defaults seguros 404.

Endpoints admin: agregar query `?appId=...` para `GET/PUT /config`. Si no
viene, default `oirpro-tech`.

UI admin: dos tabs arriba — "Técnico" y "Paciente". Cada tab edita su
propia config. Visualmente igual.

### 4. Bundle JSON — Schema

```json
{
  "schemaVersion": "1.0.0",
  "keyVersion": 1,
  "createdAt": "2026-06-08T12:34:56Z",
  "patient": {
    "name": "Juan Pérez",
    "notes": "Hipoacusia bilateral simétrica, pérdida moderada"
  },
  "audiogram": {
    "left":  [25, 30, 35, 40, 50, 55, 60, 65, 70, 75, 80, 85],
    "right": [25, 30, 35, 40, 50, 55, 60, 65, 70, 75, 80, 85],
    "frequencies": [125, 250, 500, 750, 1000, 1500, 2000, 3000, 4000, 6000, 8000, 12000]
  },
  "presets": [
    {
      "name": "Smart NL3",
      "gains": [0, 5, 10, 15, 20, 25, 25, 20, 15, 10, 5, 0],
      "isDefault": true
    },
    {
      "name": "Conversación tranquila",
      "gains": [...],
      "isDefault": false
    }
  ],
  "wdrc": {
    "comfortLevel": 0.5
  },
  "mpo": {
    "thresholdDbSpl": 95.0
  },
  "mhl": {
    "enabled": false
  },
  "defaults": {
    "presetName": "Smart NL3"
  },
  "signature": {
    "algo": "HMAC-SHA256",
    "value": "a3f7c89..."
  }
}
```

### 5. HMAC validation

Tanto técnico como paciente comparten la **clave HMAC**. Se inyecta en
build via `--dart-define=HMAC_SECRET=...`. NO se commitea al repo. Vive
en GitHub Secrets para los workflows.

Algoritmo:

```
canonical_json = jsonEncode(body sin "signature")
                  .ordenado (claves alfabéticas en cada nivel)
signature = base64(hmac_sha256(canonical_json, HMAC_SECRET))
```

Paciente:

```dart
bool verifyBundle(Map<String, dynamic> wrapped) {
  final body = Map<String, dynamic>.from(wrapped)..remove('signature');
  final canonical = _canonicalJson(body);
  final expected = _hmacSha256(canonical, _hmacSecret);
  return _constantTimeEquals(expected, wrapped['signature']?['value']);
}
```

## Data Models

### Bundle (paciente)

```dart
class FittingBundle {
  final String schemaVersion;
  final int keyVersion;
  final DateTime createdAt;
  final String patientName;
  final String notes;
  final Audiogram audiogram;
  final List<EqPreset> presets;
  final WdrcParams wdrc;
  final double mpoThresholdDbSpl;
  final bool mhlEnabled;
  final String defaultPresetName;
}
```

### Hive boxes (paciente)

| Box | Contenido |
|---|---|
| `patient_bundle` | Snapshot del último bundle importado |
| `patient_settings` | Preset activo, volumen actual, AutoTNR on/off |
| `oirpro_remote_cache` | Cache del backend (igual que técnico) |
| `security_settings` | Si se activa biometría también en paciente (R1.6) |

## Correctness Properties

### Property 1: Bundle modificado se rechaza

Cualquier byte cambiado en el JSON post-firma rompe el HMAC. La APK
paciente no aplica la config y muestra error.

**Validates: Requirements 3.4**

### Property 2: Audiograma no visible al paciente

No existe widget en la APK paciente que renderice el audiograma como
gráfico. Se guarda en Hive y se pasa al DSP, nada más.

**Validates: Requirements 3.6, 2.7**

### Property 3: Sin código del técnico en la APK paciente

Búsqueda por strings en la APK paciente final NO encuentra: nombres de
pantallas técnicas (CalibrationStep, AudiometryScreen,
TechnicalServiceScreen, FeedbackExportScreen, etc.).

**Validates: Requirements 1.7**

### Property 4: Coexistencia técnico+paciente en mismo celu

`adb install` de ambas APKs en el mismo dispositivo no produce conflicto.
Aparecen como 2 íconos distintos en el launcher.

**Validates: Requirements 1.3**

### Property 5: Re-fitting reemplaza, no acumula

Importar un bundle nuevo sobrescribe el anterior limpiamente — no
quedan presets viejos sumándose.

**Validates: Requirements 3.5**

## Error Handling

- **JSON corrupto**: parser falla → "Archivo inválido".
- **HMAC mismatch**: → "Archivo modificado o de otra clave".
- **schemaVersion no soportado**: → "Configuración generada con versión
  más nueva. Actualizá la app." (NO descartar el bundle, queda en cache).
- **keyVersion no soportado**: → "Esta versión de la app no acepta este
  archivo. Pedile uno nuevo al técnico."
- **Bundle sin presets**: rechazar — sin presets no opera.
- **Audiograma fuera de rango** (>120 dB HL): rechazar.
- **Pérdida de bundle** (Hive corrupto): vuelve a "Pendiente de
  configuración inicial". El paciente pide bundle nuevo al técnico.

## Testing Strategy

### Unit tests (técnico)

- `bundle_exporter_test.dart`: genera bundle, parsea, firma, verifica.
- HMAC determinismo: mismo input → mismo signature.
- Canonical JSON: ordenado de claves consistente.

### Unit tests (paciente)

- `bundle_importer_test.dart`: lee JSON válido, lo aplica.
- Bundle modificado byte a byte → rechaza.
- Schema version desconocida → mensaje correcto.

### Smoke test manual

1. APK técnico → exportar bundle con audiograma "test123".
2. Pasar archivo al celu paciente (USB / WhatsApp / email).
3. APK paciente → "Cargar configuración" → seleccionar archivo.
4. Validar SnackBar "Configuración aplicada".
5. Pantalla principal aparece con presets del bundle.
6. Probar audio → DSP procesa con el audiograma test123 detrás.
7. Editar el JSON manualmente con Notepad → re-importar → tiene que
   rechazar.

## Notes

- **Generar HMAC_SECRET**: una sola vez. Comando:
  ```
  node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
  ```
  Lo agregás como `HMAC_SECRET` a los GitHub Secrets de ambos repos
  (técnico y paciente) y como variable de build.
- **Repo paciente** se va a llamar igual `Audifono` o nuevo
  `Audifono-paciente`. Decisión cuando armemos.
- **Workflow CI** del paciente espejo del técnico, con su propio
  `build-patient-apk.yml`.
- **Tamaño estimado APK paciente**: ~22-25 MB (DSP `.so` pesa lo mismo
  pero código Dart es la mitad).

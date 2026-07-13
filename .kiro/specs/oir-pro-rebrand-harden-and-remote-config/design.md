# Design — Oír Pro: rebrand, endurecimiento y configuración remota

> Estado: **diseño aprobado**, sin implementación.
> Lee `requirements.md` antes de este documento.

## Overview

Cinco fases ordenadas de menor a mayor riesgo. Cada fase es un **commit
aparte** así si una rompe el build, las anteriores ya están estables.

```
Fase 1  →  Rebrand              (label, archivo, release)        15 min
Fase 2  →  Endurecimiento       (R8 minify + Dart obfuscate)     45 min
Fase 3  →  Biometría            (local_auth + splash gate)        2 h
Fase 4  →  Keystore             (jks + GitHub secrets)            30 min
Fase 5  →  Backend remoto       (Node.js + DB + admin UI + cli)   1 día
```

El diseño respeta tres invariantes:

- La **app nunca depende del server** para operar el audífono. Server
  caído = app sigue funcionando.
- Los datos clínicos (audiograma, presets, calibración) **nunca se envían
  al server**. Solo metadata: `appId`, `deviceId`, `currentVersion`.
- El **kill switch es no destructivo**: si el server bloquea la app, no
  borra ni corrompe datos del paciente; muestra una pantalla y se sale.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ Celular Android (Oír Pro Técnico)                                   │
│                                                                     │
│  ┌────────┐   ┌──────────────┐   ┌────────┐   ┌─────────────────┐   │
│  │ Splash │──▶│  Biometría   │──▶│ Server │──▶│ MainScreen del   │  │
│  │        │   │ (local_auth) │   │ check  │   │ técnico (toda    │  │
│  └────────┘   └──────────────┘   │  3 s   │   │ la app actual)   │  │
│                                  └────┬───┘   └─────────────────┘   │
│                                       │                             │
│                                       ▼                             │
│                                ┌──────────────┐                     │
│                                │ Hive cache   │                     │
│                                │ 7 días       │                     │
│                                └──────────────┘                     │
└─────────────────────────────────────┬───────────────────────────────┘
                                      │ HTTPS / HTTP plano
                                      │ POST /api/check
                                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 149.50.137.2 — VPS privado                                          │
│                                                                     │
│  ┌──────────────────────────┐         ┌──────────────────────────┐  │
│  │  PM2 app: server         │         │  PM2 app: oirpro-server  │  │
│  │  /var/www/server7.js     │         │  /var/www/oirpro/        │  │
│  │  puerto 8055 (SmartTemp) │         │  puerto 8060 (Oír Pro)   │  │
│  └──────────────────────────┘         └──────────┬───────────────┘  │
│                                                  │                  │
│  ┌──────────────────────────┐         ┌──────────▼───────────────┐  │
│  │  MySQL                   │         │  /var/www/oirpro/public  │  │
│  │  ├── Medicion (SmartTemp)│         │  ├── admin/   (UI HTML)  │  │
│  │  └── oirpro (NUEVA)      │◀────────┤  └── apk/     (APK files)│  │
│  └──────────────────────────┘         └──────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘

                    Mosquitto MQTT (de SmartTemp): no se toca.
```

## Components and Interfaces

### Fase 1 — Rebrand

Archivos:

- `hearing_aid_app/android/app/src/main/AndroidManifest.xml`
- `hearing_aid_app/.github/workflows/build-apk.yml`

Cambios:

```xml
<!-- AndroidManifest.xml -->
<application
    android:label="Oír Pro"   <!-- antes "PSK Hearing Aid" -->
    ...>
```

```yaml
# build-apk.yml — paso "Build APK"
- name: Build APK
  run: flutter build apk --release --obfuscate --split-debug-info=build/debug-info

- name: Rename APK
  run: mv build/app/outputs/flutter-apk/app-release.apk build/app/outputs/flutter-apk/oir-pro.apk

- name: Upload APK artifact
  uses: actions/upload-artifact@v4
  with:
    name: oir-pro-apk
    path: build/app/outputs/flutter-apk/oir-pro.apk

- name: Create Release with APK
  uses: softprops/action-gh-release@v2
  with:
    tag_name: build-${{ github.run_number }}
    name: Oír Pro v${{ github.run_number }}
    files: |
      build/app/outputs/flutter-apk/oir-pro.apk
      build/debug-info/**/*
    body: |
      Oír Pro — APK de Servicio Técnico generada automáticamente.
      Bajá `oir-pro.apk` al celular e instalá.
```

`applicationId` se mantiene en `com.psk.hearing_aid_app` para no perder
updates de instalaciones existentes.

### Fase 2 — Endurecimiento

Archivos:

- `hearing_aid_app/android/app/build.gradle`
- `hearing_aid_app/android/app/proguard-rules.pro`
- `hearing_aid_app/.github/workflows/build-apk.yml` (ya cubierto en Fase 1)

Cambios `build.gradle`:

```groovy
buildTypes {
    release {
        signingConfig = signingConfigs.release   // ver Fase 4
        minifyEnabled = true                      // antes false
        shrinkResources = true                    // antes false
        proguardFiles(
            getDefaultProguardFile("proguard-android-optimize.txt"),
            "proguard-rules.pro"
        )
    }
}
```

`proguard-rules.pro` se extiende con:

```
# JNI nativos — no renombrar
-keepclasseswithmembernames class * { native <methods>; }
-keep class com.psk.hearing_aid_app.** { *; }

# Oboe callbacks
-keep class com.google.oboe.** { *; }

# Plugins Flutter críticos
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }

# Bluetooth Low Energy plugin
-keep class com.lib.flutter_blue_plus.** { *; }

# Audio plugins
-keep class com.ryanheise.just_audio.** { *; }
-keep class com.ryanheise.audio_session.** { *; }

# permission_handler
-keep class com.baseflow.permissionhandler.** { *; }

# Hive (lazy classes)
-keep class **$HiveFieldAdapter { *; }

# crypto / cookies
-keep class javax.crypto.** { *; }

# Reflection y annotations
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
```

### Fase 3 — Biometría

Archivos nuevos / modificados:

- `pubspec.yaml` — agregar `local_auth: ^2.3.0`.
- `lib/security/biometric_gate.dart` — nuevo widget que envuelve la app.
- `lib/security/pin_fallback_screen.dart` — pantalla de PIN si no hay
  biometría disponible.
- `lib/security/security_settings_repository.dart` — guarda PIN hash y
  flag "biometría requerida" en Hive box `security_settings`.
- `lib/main.dart` — montar `BiometricGate(child: HearingAidApp())`.

Flujo:

```
App start
  │
  ▼
SplashScreen (azul marino + logo)
  │
  ▼
BiometricGate.check()
  ├─ ¿biometría enrolada en el dispositivo?
  │     ├─ Sí  → local_auth.authenticate("Identificate para abrir Oír Pro")
  │     │         ├─ Éxito → continúa
  │     │         └─ Falla 5 veces → exit(0)
  │     └─ No  → ¿hay PIN guardado?
  │              ├─ Sí → PinFallbackScreen
  │              └─ No → SetupPinScreen (primer arranque)
  │
  ▼
HearingAidApp (resto del flujo)
```

Setting "Pedir biometría al abrir" vive en Servicio Técnico → Seguridad,
default ON.

### Fase 4 — Keystore

Archivos:

- `hearing_aid_app/android/app/build.gradle` — agregar `signingConfigs`.
- `hearing_aid_app/android/key.properties.example` — template de doc.
- `hearing_aid_app/android/.gitignore` — agregar `key.properties` y `*.jks`.
- `hearing_aid_app/.github/workflows/build-apk.yml` — paso de decodificar
  secret antes del build.

Cambios `build.gradle`:

```groovy
def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}

android {
    ...
    signingConfigs {
        release {
            keyAlias       keystoreProperties['keyAlias']
            keyPassword    keystoreProperties['keyPassword']
            storeFile      keystoreProperties['storeFile'] ?
                              file(keystoreProperties['storeFile']) : null
            storePassword  keystoreProperties['storePassword']
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.release
            ...
        }
    }
}
```

Workflow:

```yaml
- name: Decode keystore
  env:
    KEYSTORE_BASE64: ${{ secrets.KEYSTORE_BASE64 }}
  run: |
    if [ -z "$KEYSTORE_BASE64" ]; then
      echo "::error::Falta secret KEYSTORE_BASE64"
      exit 1
    fi
    echo "$KEYSTORE_BASE64" | base64 -d > android/app/oirpro-release.jks

- name: Create key.properties
  env:
    KEYSTORE_PASSWORD: ${{ secrets.KEYSTORE_PASSWORD }}
    KEY_ALIAS: ${{ secrets.KEY_ALIAS }}
    KEY_PASSWORD: ${{ secrets.KEY_PASSWORD }}
  run: |
    cat <<EOF > android/key.properties
    storePassword=$KEYSTORE_PASSWORD
    keyPassword=$KEY_PASSWORD
    keyAlias=$KEY_ALIAS
    storeFile=oirpro-release.jks
    EOF
```

### Fase 5 — Backend remoto

Estructura:

```
/var/www/oirpro/                ← copiar al VPS por SCP
├── server.js                    ← punto de entrada Express
├── package.json
├── .env                         ← variables (no commitear)
├── .env.example
├── ecosystem.snippet.js         ← entry para PM2
├── routes/
│   ├── public.js                ← /api/check, /api/health
│   └── admin.js                 ← /api/admin/* (autenticado)
├── db/
│   ├── pool.js                  ← mysql2/promise singleton
│   ├── schema.sql               ← migración inicial
│   └── seed.sql                 ← admin user inicial
├── middleware/
│   ├── auth.js                  ← JWT validation
│   └── upload.js                ← multer para APK
├── public/
│   ├── admin/
│   │   ├── index.html           ← login + form config
│   │   ├── style.css
│   │   └── app.js               ← vanilla JS, fetch
│   └── apk/                     ← donde quedan las APKs subidas
└── README.md                    ← cómo instalar en el VPS
```

#### Schema MySQL

```sql
CREATE DATABASE oirpro CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE oirpro;

CREATE TABLE app_config (
    id              INT PRIMARY KEY DEFAULT 1,
    tech_code       VARCHAR(64) NOT NULL,
    latest_version  VARCHAR(32) NOT NULL,
    min_version     VARCHAR(32) NOT NULL,
    apk_url         VARCHAR(512),
    blocked         TINYINT(1) NOT NULL DEFAULT 0,
    blocked_reason  VARCHAR(512),
    updated_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
                              ON UPDATE CURRENT_TIMESTAMP,
    CHECK (id = 1)
);

CREATE TABLE admin_users (
    id            INT AUTO_INCREMENT PRIMARY KEY,
    username      VARCHAR(64) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE activity_log (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    actor       VARCHAR(64),
    action      VARCHAR(128),
    detail      JSON,
    created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX (created_at DESC)
);

CREATE TABLE check_log (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    app_id          VARCHAR(64),
    device_id       VARCHAR(64),
    current_version VARCHAR(32),
    ip              VARCHAR(45),
    created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX (device_id, created_at DESC)
);

INSERT INTO app_config (id, tech_code, latest_version, min_version)
VALUES (1, 'CHANGE_ME_AT_FIRST_LOGIN', '1.0.0', '1.0.0');
```

`admin_users` se siembra desde una variable `.env` la primera vez que el
server arranca: si la tabla está vacía, crea `admin` con
`bcrypt(ADMIN_INITIAL_PASSWORD)` y loguea el detalle a stdout.

#### Endpoint público (`POST /api/check`)

Request:

```json
{ "appId": "oirpro-tech", "deviceId": "abc123", "currentVersion": "1.0.0" }
```

Response (200):

```json
{
  "techCode": "1234",
  "latestVersion": "1.2.0",
  "minVersion": "1.0.0",
  "apkUrl": "https://149.50.137.2:8060/apk/oir-pro-1.2.0.apk",
  "blocked": false,
  "blockedReason": null,
  "serverTime": "2026-06-08T12:34:56Z"
}
```

Loggea la request en `check_log` (con IP) y devuelve la fila singleton de
`app_config`. Sin cache, query directa.

#### Endpoint admin (`PUT /api/admin/config`)

Request (con header `Authorization: Bearer <jwt>`):

```json
{
  "techCode": "9876",
  "latestVersion": "1.3.0",
  "minVersion": "1.0.0",
  "apkUrl": "https://149.50.137.2:8060/apk/oir-pro-1.3.0.apk",
  "blocked": false,
  "blockedReason": null
}
```

Response: `{ ok: true, updatedAt: "..." }`. Loguea en `activity_log`.

#### Endpoint admin (`POST /api/admin/upload-apk`)

Multipart con campo `apk` (archivo). Servidor:
1. Valida que sea `.apk` y < 100 MB.
2. Lo guarda en `/var/www/oirpro/public/apk/<filename>`.
3. Devuelve `{ ok: true, url: "https://149.50.137.2:8060/apk/<filename>" }`.
4. Loguea en `activity_log`.

#### UI admin (`/var/www/oirpro/public/admin/index.html`)

Página simple, vanilla JS. Login → tabla con valores actuales →
inputs para editar → botón "Guardar". Botón "Subir APK" abre file picker.

### Fase 5b — Cliente remoto en Flutter

Archivo nuevo: `lib/data/services/remote_config_service.dart`.

```dart
class RemoteConfigService {
  static const String _endpoint =
      'http://149.50.137.2:8060/api/check';
  static const Duration _timeout = Duration(seconds: 3);
  static const Duration _cacheTtl = Duration(days: 7);

  // Defaults seguros embebidos. Se usan SOLO si no hay cache disponible.
  static const String _kFallbackTechCode = 'OIRPRO_TECH_DEFAULT';

  final HiveBoxProvider _hive;
  RemoteConfigService(this._hive);

  Future<RemoteConfig> fetch({required String currentVersion}) async {
    try {
      final body = jsonEncode({
        'appId': 'oirpro-tech',
        'deviceId': await _deviceId(),
        'currentVersion': currentVersion,
      });
      final res = await http
          .post(Uri.parse(_endpoint),
              headers: {'Content-Type': 'application/json'},
              body: body)
          .timeout(_timeout);
      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        await _saveCache(json);
        return RemoteConfig.fromJson(json);
      }
    } catch (e) {
      debugPrint('[RemoteConfig] error: $e');
    }
    return _readCacheOrFallback(currentVersion);
  }

  // ...
}
```

La pantalla principal monta este service en su `initState` y reacciona al
resultado:

- `blocked == true` → push de `BlockedScreen` (no destructivo).
- `latestVersion > currentVersion` → diálogo `UpdateAvailableDialog`.
- `minVersion > currentVersion` → diálogo modal sin opción de cancelar.
- `techCode` se guarda en `SettingsRepository` para que el código en
  Servicio Técnico use ese valor.

## Data Models

### Fase 5 — Backend

| Tabla | Filas | Propósito |
|---|---|---|
| `app_config` | 1 (singleton) | Configuración remota |
| `admin_users` | N | Auth de admin (bcrypt + JWT) |
| `activity_log` | N | Auditoría de cambios admin |
| `check_log` | N | Log de checks de la app (rate limit) |

### Fase 5b — Cliente

```dart
class RemoteConfig {
  final String techCode;
  final String latestVersion;
  final String minVersion;
  final String? apkUrl;
  final bool blocked;
  final String? blockedReason;
  final DateTime fetchedAt;
  final bool isFromCache;
}
```

Persistencia: Hive box `oirpro_remote_cache` con clave `last`.

## Correctness Properties

### Property 1: La app no se bloquea por falta de internet

Si el server `/api/check` no responde dentro de 3 s o devuelve error,
`RemoteConfigService` cae al cache (≤ 7 días) o defaults seguros. La app
abre normalmente.

**Validates: Requirements 6.4, 6.5**

### Property 2: El kill switch no destruye datos

Cuando `blocked == true`, la app muestra `BlockedScreen` pero NO borra:
audiograma, settings, presets custom, calibración, historial de feedback.
Si el bloqueo se levanta, la app vuelve a operar normalmente sin pérdida.

**Validates: Requirements 6.3, 8.1**

### Property 3: El server check no envía datos clínicos

El `POST /api/check` solo manda `{appId, deviceId, currentVersion}`. NO
manda audiograma, presets, ni datos del paciente.

**Validates: Requirements 6.6**

### Property 4: La keystore protege la cadena de update

Una APK firmada con la keystore debug NO puede sobrescribir una APK
firmada con la keystore release en el celular del usuario, lo cual
impide que un atacante distribuya updates "como Oír Pro".

**Validates: Requirements 4.1, 4.2, 4.6**

### Property 5: Minify no rompe JNI ni reflection

`proguard-rules.pro` preserva todos los símbolos consumidos por JNI,
Oboe, plugins Flutter críticos y clases referenciadas por reflection
(Hive adapters, crypto). El smoke test post-Fase 2 valida que la app
arranca, conecta BLE, captura audio, aplica DSP y reproduce.

**Validates: Requirements 2.2, 2.5**

## Error Handling

- **Server caído / timeout:** cache 7 días → defaults. Sin diálogo de
  error al usuario en producción. Logcat tag `RemoteConfig`.
- **JWT expirado en admin:** UI muestra "Sesión expirada, ingresá de
  nuevo" y redirige a login. Token nuevo, 24 h.
- **Subida de APK supera 100 MB:** rechazo con 413. Log + alerta en UI.
- **Schema mismatch entre app y server (futuro):** server siempre
  devuelve campos extra que la app no entiende los ignora; campos
  faltantes que la app espera caen al default.
- **Keystore rota o secret faltante en CI:** workflow falla con error
  explícito. Sin fallback a debug key (silenciosamente firmar con la
  debug arruinaría la cadena de updates).
- **Biometría: usuario sin huella + sin PIN seteado:** flujo de setup
  PIN de 4-6 dígitos en primer arranque. Si rechaza setear, la app sale.
- **Hive corrupto:** fallback a defaults seguros. Servicio Técnico tiene
  botón "Resetear cache remoto" que limpia y reintenta.

## Testing Strategy

### Unit / widget tests (Flutter)

- `remote_config_service_test.dart` — mocks de `http.Client`:
  timeout, 200 OK, 500, JSON inválido, blocked, update.
- `biometric_gate_test.dart` — mocks de `local_auth.LocalAuthentication`:
  éxito, falla, no enrolado.
- `update_dialog_test.dart` — UI de update notification.

### Backend tests (vitest, ya está en SmartTemp)

- `routes/public.test.js` — `/api/check` con DB mock: blocked, version
  comparison, malformed body.
- `routes/admin.test.js` — login, JWT expirado, autorización 403.
- `db/pool.test.js` — connection pool, retry, leak.

### Smoke tests manuales

1. Build Fase 2 → instalar → app arranca, conecta BLE, audio fluye.
2. Build Fase 3 → primer arranque pide setup PIN, segundo arranque
   pide huella, tercer arranque background → vuelve sin pedir.
3. Build Fase 4 → instalar sobre versión vieja → update funciona.
4. Build Fase 5 → server local → app pega, recibe tech code, lo usa.
5. Backend admin → cambiar techCode → reabrir app → tech code nuevo
   funciona.
6. Backend admin → blocked=true → reabrir app → BlockedScreen.
7. Backend admin → subir APK nueva, latest_version=1.1 → reabrir app
   1.0 → diálogo update con link al APK.
8. Cortar internet → reabrir app → arranca con cache.

### Validación contra paridad (importante)

Fase 2 puede romper sutilmente cosas. Antes y después del minify, validar:

- Audiometría se renderiza igual.
- Cálculo NL3 produce los mismos números.
- BLE descubre y conecta el audífono físico.
- DSP test reproduce el tono correcto a 1 kHz.

## Notes

- **Modo paciente** queda en spec separado `oir-pro-patient-mode/` que
  arranca cuando este cierre. Ese spec será el que use APK distinta con
  funciones recortadas + import de JSON firmado por el técnico.
- **Reverse proxy nginx** queda como mejora futura. Si lo implementás,
  agregá una task al spec siguiente que mueva las URLs de `:8060` a
  `/oirpro/*` sin tocar el código del backend.
- **Carpeta del código del backend** vive en
  `c:\Users\Elsa y Henry\Pictures\Amplificador\oirpro-server\` localmente
  (espejo del que se sube a `/var/www/oirpro/`). Sin repo Git separado por
  ahora; cuando esté maduro se puede meter en GitHub.

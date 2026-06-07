# Implementation Plan: Oir Pro - rebrand, endurecimiento y configuracion remota

## Overview

Plan de trabajo en 5 fases. Cada fase termina en un commit estable que
puede mergearse a main por separado. Si una fase rompe el build, las
anteriores quedan firmes.

Tareas mandatorias salvo que digan "(opcional)".

## Task Dependency Graph

```json
{
  "waves": [
    { "wave": 1,  "tasks": ["0"] },
    { "wave": 2,  "tasks": ["1.1", "1.2", "1.3"] },
    { "wave": 3,  "tasks": ["2.1", "2.2", "2.3"] },
    { "wave": 4,  "tasks": ["3.1", "3.2", "3.3", "3.4"] },
    { "wave": 5,  "tasks": ["4.1", "4.2", "4.3"] },
    { "wave": 6,  "tasks": ["5.1", "5.2", "5.3"] },
    { "wave": 7,  "tasks": ["5.4", "5.5", "5.6", "5.7"] },
    { "wave": 8,  "tasks": ["5.8"] },
    { "wave": 9,  "tasks": ["6.1", "6.2", "6.3"] },
    { "wave": 10, "tasks": ["7"] }
  ]
}
```

Notas:
- Fase 0 (tarjetas Plano/Silencio) ya está hecha localmente, solo falta
  push.
- Fases 1-4 son de la app; pueden hacerse sin tocar el backend.
- Fase 5 es el backend; se puede arrancar en paralelo a 3-4 si querés.
- Fase 6 (cliente Flutter del backend) depende de 5 lista para pegar.
- Fase 7 (smoke + release) solo después de todo lo anterior.

## Tasks

### Fase 0 — Tarjetas Plano/Silencio (ya hecho local)

- [ ] 0. Push del commit de tarjetas
  - 0.1 Verificar `git status` — `clinical_info_chips.dart` modificado.
  - 0.2 `git add lib/presentation/widgets/clinical_info_chips.dart`.
  - 0.3 Commit `fix(ui): tarjetas clinical info al tema oscuro (chips
        dark con cyan translúcido, ocultas en modo amplificador)`.
  - 0.4 Push solo a `memomedix3-commits/Audifono` (NO a `henrysalinas`).
  - _Refs: R7.1, R7.2, R7.3_

### Fase 1 — Rebrand a "Oír Pro"

- [ ] 1.1 Cambiar `android:label` en AndroidManifest.xml
  - 1.1.1 De `"PSK Hearing Aid"` a `"Oír Pro"` en
          `hearing_aid_app/android/app/src/main/AndroidManifest.xml`.
  - 1.1.2 Verificar que la tilde se persiste correctamente (UTF-8 BOM
          NO debe existir en este archivo).
  - _Refs: R1.1, R1.5_

- [ ] 1.2 Renombrar APK del workflow
  - 1.2.1 En `.github/workflows/build-apk.yml`, agregar paso "Rename APK"
          después de "Build APK" que mueve `app-release.apk` a
          `oir-pro.apk`.
  - 1.2.2 Actualizar `path:` del artifact a `oir-pro.apk`.
  - 1.2.3 Actualizar `files:` del release a `oir-pro.apk`.
  - 1.2.4 Cambiar `name:` del release a `Oír Pro v${{ github.run_number }}`.
  - 1.2.5 Cambiar `body:` del release para no decir "PSK Hearing Aid".
  - _Refs: R1.2, R1.3, R1.4_

- [ ] 1.3 Commit + push Fase 1
  - 1.3.1 Commit `feat(rebrand): app pasa a llamarse "Oír Pro"`.
  - 1.3.2 Push a `memomedix3-commits/Audifono`.
  - 1.3.3 Esperar build APK. Verificar que el archivo descargado se
          llama `oir-pro.apk` y el launcher dice "Oír Pro".

### Fase 2 — Endurecimiento

- [ ] 2.1 Activar minify + shrinkResources
  - 2.1.1 En `android/app/build.gradle`, `buildTypes.release`:
          `minifyEnabled = true`, `shrinkResources = true`.
  - 2.1.2 Mantener `signingConfig = signingConfigs.debug` por ahora
          (Fase 4 lo cambia a release). El minify no requiere keystore
          propia, funciona sobre cualquier APK firmada.
  - _Refs: R2.1_

- [ ] 2.2 Extender `proguard-rules.pro`
  - 2.2.1 Agregar reglas para JNI, Oboe, plugins Flutter críticos,
          BLE, audio, permission_handler, Hive, crypto, reflection.
  - 2.2.2 Ver lista completa en `design.md` sección
          "Fase 2 — Endurecimiento → proguard-rules.pro".
  - 2.2.3 Validar que `getDiagnostics` sobre `proguard-rules.pro` no
          tira warnings.
  - _Refs: R2.2_

- [ ] 2.3 Activar ofuscación Dart en workflow
  - 2.3.1 En `build-apk.yml`, paso "Build APK", agregar flags:
          `--obfuscate --split-debug-info=build/debug-info`.
  - 2.3.2 En "Create Release with APK", agregar `build/debug-info/**/*`
          al campo `files:` del release para no perder los símbolos.
  - 2.3.3 Commit + push. Esperar build. **Smoke test crítico**:
          instalar, abrir, conectar BLE, capturar audio, aplicar
          preset, validar que el DSP responde igual. Si algo falla,
          rollback de 2.1 y agregar la regla faltante en 2.2.
  - _Refs: R2.3, R2.4, R2.5_

### Fase 3 — Biometría al abrir

- [ ] 3.1 Agregar dependencia local_auth
  - 3.1.1 En `pubspec.yaml`, agregar `local_auth: ^2.3.0`.
  - 3.1.2 En `android/app/build.gradle`, asegurar `minSdkVersion >= 23`
          (ya está en 24, OK).
  - 3.1.3 En `AndroidManifest.xml`, agregar
          `<uses-permission android:name="android.permission.USE_BIOMETRIC"/>`.
  - 3.1.4 `MainActivity` debe extender `FlutterFragmentActivity` (no
          `FlutterActivity`) para que local_auth pueda mostrar el
          diálogo. Si no lo es, cambiar.
  - _Refs: R3.2_

- [ ] 3.2 Crear módulo de seguridad
  - 3.2.1 `lib/security/security_settings_repository.dart` con métodos
          `setPin(String)`, `verifyPin(String)`, `isBiometricRequired`,
          `setBiometricRequired(bool)`. Box Hive: `security_settings`.
          PIN guardado como `bcrypt` hash con `package:crypto`.
  - 3.2.2 `lib/security/biometric_gate.dart` widget que envuelve la app
          y muestra splash + auth.
  - 3.2.3 `lib/security/pin_setup_screen.dart` y `pin_fallback_screen.dart`.
  - _Refs: R3.1, R3.2, R3.3, R3.5_

- [ ] 3.3 Toggle "Pedir biometría al abrir" en Servicio Técnico
  - 3.3.1 Agregar SwitchListTile en la pantalla de Servicio Técnico,
          sección "Seguridad". Persiste vía
          `SecuritySettingsRepository.setBiometricRequired`.
  - 3.3.2 Default ON.
  - _Refs: R3.4_

- [ ] 3.4 Integrar BiometricGate en main.dart
  - 3.4.1 Modificar `lib/main.dart` para envolver `HearingAidApp` con
          `BiometricGate(child: HearingAidApp())`.
  - 3.4.2 Si el setting está OFF, el gate hace passthrough.
  - 3.4.3 Commit + push.
  - 3.4.4 Smoke test: setear PIN en primer arranque, segundo arranque
          pide huella, toggle OFF y reabrir → no pide nada.
  - _Refs: R3.1, R3.5_

### Fase 4 — Keystore propia

- [ ] 4.1 Generar keystore (esto lo hacés vos en tu PC)
  - 4.1.1 Comando:
    ```
    keytool -genkey -v -keystore oirpro-release.jks -keyalg RSA \
            -keysize 2048 -validity 10000 -alias oirpro
    ```
    Te pide pass del store, pass de la key, y datos del owner. Anotá
    todo en un lugar seguro — perderlo significa no poder hacer
    updates de la app nunca más.
  - 4.1.2 Convertir a base64:
    `cmd /c "certutil -encode oirpro-release.jks oirpro-release.b64"`
    Editar el `.b64` y borrar las líneas BEGIN/END.
  - 4.1.3 Subir como GitHub Secret (cuenta `memomedix3-commits`):
    - `KEYSTORE_BASE64` = contenido del b64 sin BEGIN/END.
    - `KEYSTORE_PASSWORD` = pass del store.
    - `KEY_ALIAS` = `oirpro`.
    - `KEY_PASSWORD` = pass de la key.
  - _Refs: R4.1, R4.2_

- [ ] 4.2 Configurar build.gradle
  - 4.2.1 En `android/app/build.gradle`, agregar carga de
          `key.properties` y `signingConfigs.release`.
  - 4.2.2 En `buildTypes.release`,
          `signingConfig = signingConfigs.release`.
  - 4.2.3 Crear `android/key.properties.example` con la plantilla.
  - 4.2.4 En `android/.gitignore`, agregar `key.properties` y `*.jks`.
  - _Refs: R4.4, R4.5_

- [ ] 4.3 Modificar workflow para decodificar keystore
  - 4.3.1 Agregar pasos "Decode keystore" y "Create key.properties"
          ANTES de "Build APK". Ver snippet en `design.md`.
  - 4.3.2 Validar que el workflow falla limpio si los secrets faltan.
  - 4.3.3 Commit + push. **Verificar que la APK descargada tiene fingerprint
          de la keystore nueva**:
          `apksigner verify --print-certs oir-pro.apk`.
  - _Refs: R4.3, R4.6_

### Fase 5 — Backend remoto Oír Pro

> Carpeta destino local: `c:\Users\Elsa y Henry\Pictures\Amplificador\oirpro-server\`
> Carpeta destino remota: `/var/www/oirpro/` (vía SCP).

- [ ] 5.1 Estructura del proyecto Node
  - 5.1.1 Crear `oirpro-server/` con `package.json`, `.env.example`,
          `server.js`, `routes/`, `db/`, `middleware/`, `public/`.
  - 5.1.2 Stack: Node 20, Express, mysql2/promise, dotenv, bcrypt,
          jsonwebtoken, multer, helmet, cors.
  - 5.1.3 `npm init` + `npm i` localmente.
  - _Refs: R5.4_

- [ ] 5.2 Schema MySQL + migración inicial
  - 5.2.1 `db/schema.sql` con `CREATE DATABASE oirpro` y las 4 tablas
          (`app_config`, `admin_users`, `activity_log`, `check_log`).
  - 5.2.2 `db/seed.sql` con la fila singleton inicial de `app_config`
          y `admin` user (password leída de `.env`, hasheada con bcrypt).
  - 5.2.3 Script `db/migrate.js` que aplica `schema.sql` y `seed.sql`
          contra la DB del `.env`.
  - _Refs: R5.3_

- [ ] 5.3 Endpoint `/api/check` (público)
  - 5.3.1 `routes/public.js` con `POST /api/check` y `GET /api/health`.
  - 5.3.2 Body validado: `{appId, deviceId, currentVersion}`.
  - 5.3.3 Respuesta: snapshot de `app_config`.
  - 5.3.4 Loguea en `check_log` con IP.
  - 5.3.5 Rate limit suave (10 req / minuto / IP) con
          `express-rate-limit` o middleware propio.
  - _Refs: R5.6_

- [ ] 5.4 Auth admin (JWT)
  - 5.4.1 `middleware/auth.js` con `validateJwt`.
  - 5.4.2 Endpoint `POST /api/admin/login` que valida `bcrypt.compare`
          contra `admin_users` y devuelve JWT 24 h.
  - 5.4.3 `JWT_SECRET` en `.env`, generado con
          `node -e "console.log(require('crypto').randomBytes(64).toString('hex'))"`.
  - _Refs: R5.7_

- [ ] 5.5 Endpoints admin de configuración
  - 5.5.1 `GET /api/admin/config` (auth) → devuelve fila singleton.
  - 5.5.2 `PUT /api/admin/config` (auth) → actualiza tech_code,
          latest_version, min_version, blocked, blocked_reason, apk_url.
  - 5.5.3 Loguea cada cambio en `activity_log`.
  - 5.5.4 `GET /api/admin/log` (auth) → últimas 100 entradas de
          `activity_log`.
  - _Refs: R5.7_

- [ ] 5.6 Subida de APK
  - 5.6.1 `POST /api/admin/upload-apk` con `multer` (memoria → fs).
  - 5.6.2 Acepta solo `.apk` (mime + extensión), límite 100 MB.
  - 5.6.3 Guarda en `/var/www/oirpro/public/apk/<filename>`.
  - 5.6.4 Devuelve URL pública.
  - 5.6.5 Loguea en `activity_log`.
  - _Refs: R5.7_

- [ ] 5.7 UI admin (HTML vanilla)
  - 5.7.1 `public/admin/index.html` con form login, form de
          configuración, file picker para APK, lista de log.
  - 5.7.2 `public/admin/style.css` (paleta azul marino consistente con
          la app).
  - 5.7.3 `public/admin/app.js` vanilla con fetch + JWT en
          localStorage. Sin frameworks.
  - 5.7.4 Validar manualmente en el navegador con el server local.
  - _Refs: R5.8_

- [ ] 5.8 Despliegue en el VPS
  - 5.8.1 SCP de `oirpro-server/` (sin `node_modules`) a
          `/var/www/oirpro/` del VPS.
  - 5.8.2 SSH al VPS, `cd /var/www/oirpro`, `npm ci --omit=dev`.
  - 5.8.3 Crear `.env` real con valores de DB, JWT_SECRET, ADMIN_PASSWORD.
  - 5.8.4 Correr `node db/migrate.js` para crear DB y seed.
  - 5.8.5 Agregar bloque a `ecosystem.config.js`:
    ```
    {
      name: 'oirpro-server',
      script: 'server.js',
      cwd: '/var/www/oirpro',
      instances: 1,
      autorestart: true,
      watch: false,
      max_memory_restart: '512M',
      env: { NODE_ENV: 'production', PORT: 8060 }
    }
    ```
  - 5.8.6 `pm2 start oirpro-server`, `pm2 save`.
  - 5.8.7 Abrir `8060/tcp` en firewall.
  - 5.8.8 Smoke test: `curl http://149.50.137.2:8060/api/health`.
  - 5.8.9 Login admin desde navegador, cambiar tech_code de prueba.
  - _Refs: R5.1, R5.2, R5.5, R5.9_

### Fase 6 — Cliente remoto en la app Flutter

- [ ] 6.1 RemoteConfigService
  - 6.1.1 Crear `lib/data/services/remote_config_service.dart`
          con la firma del `design.md`.
  - 6.1.2 Hive box `oirpro_remote_cache`.
  - 6.1.3 Defaults seguros embebidos.
  - 6.1.4 `deviceId`: usar `package:device_info_plus` para obtener un
          ID estable del dispositivo (Android ID).
  - _Refs: R6.1, R6.2, R6.4, R6.6_

- [ ] 6.2 Pantallas reactivas
  - 6.2.1 `lib/presentation/screens/blocked_screen.dart` con un
          `Scaffold` minimalista. Sin botón "Volver". Solo muestra el
          mensaje de `blockedReason` y un botón "Cerrar app".
  - 6.2.2 `lib/presentation/widgets/update_available_dialog.dart`:
          diálogo con botón "Actualizar" (abre `apkUrl` en navegador
          via `url_launcher`) y "Más tarde".
  - 6.2.3 Si `minVersion > currentVersion`, el diálogo no tiene "Más
          tarde" (modal bloqueante).
  - _Refs: R6.3, R6.5_

- [ ] 6.3 Integración en main.dart
  - 6.3.1 Después de la biometría, montar el provider de
          `RemoteConfigService`.
  - 6.3.2 Llamar `fetch()` en background al arrancar.
  - 6.3.3 Listener que reacciona al `RemoteConfig` resultado y muestra
          la UI correspondiente (blocked, update, ok).
  - 6.3.4 Servicio Técnico → screen de seguridad: usar el `techCode`
          del `RemoteConfig` para validar la entrada.
  - 6.3.5 Commit + push.
  - _Refs: R6.3, R6.5_

### Fase 7 — Validación final + release

- [ ] 7. Smoke test integral + release v1.0.0 de Oír Pro Técnico
  - 7.1 Build con todas las fases aplicadas.
  - 7.2 Instalar en celular limpio.
  - 7.3 Validar:
        - Launcher dice "Oír Pro".
        - APK firmada con keystore release (`apksigner verify`).
        - Pide biometría / PIN al abrir.
        - Pega al server (logcat: `RemoteConfig`).
        - DSP funciona (BLE, audio, presets).
        - Admin web responde, cambio de tech_code surte efecto al
          reabrir la app.
        - Bloqueo remoto funciona.
        - Actualización: subir APK con `latestVersion=1.0.1`,
          reabrir 1.0.0, ver el diálogo de update.
  - 7.4 Crear release v1.0.0 en GitHub Actions.
  - 7.5 Subir esa misma APK al backend admin como `latest_version=1.0.0`.

## Notes

- **Modo paciente** vive en spec separado
  `hearing_aid_app/.kiro/specs/oir-pro-patient-mode/` que arranca cuando
  este cierre. El cliente paciente reusará `RemoteConfigService` con
  `appId="oirpro-patient"`.
- **Push directo a `memomedix3-commits/Audifono`** (la cuenta vieja
  `henrysalinas1985-source` tiene Actions agotadas). Comandos en bat
  con token de `TOKEN PUSH.txt`.
- **Backend no va a GitHub.** Se mueve por SCP al VPS. Si en algún
  momento querés versionarlo, abrís un repo aparte tipo
  `memomedix3-commits/oirpro-server`.
- **Ofuscación nativa C++** queda fuera de alcance — el `-O2` y el
  `-fvisibility=hidden` de NDK ya hacen el trabajo razonable. El DNN
  denoiser y el VAD están suficientemente protegidos para esta etapa.

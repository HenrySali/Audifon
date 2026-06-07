# Requirements Document

> Spec — Oír Pro: rebrand, endurecimiento y configuración remota.
>
> Estado: **PENDIENTE** — diseño consensuado, sin implementación.

## Introduction

Este spec finaliza el ciclo de cambios técnicos y de marca acumulados desde
las últimas sesiones, dejando la app **Oír Pro** lista para distribución
controlada por el técnico audiólogo. Cubre cinco fases ordenadas:

1. **Rebrand** — cambio de marca a "Oír Pro" en label, archivo APK y release.
2. **Endurecimiento** — minify R8 + ofuscación Dart para reducir copia casual.
3. **Privacidad** — desbloqueo biométrico al abrir la app.
4. **Identidad** — keystore propia para firmar releases (no la debug key).
5. **Backend remoto** — servicio Node.js independiente en
   `149.50.137.2:8060` con DB MySQL `oirpro` que permite:
   a) cambiar el código del Modo Servicio Técnico sin recompilar,
   b) bloquear la app remotamente (kill switch),
   c) notificar al cliente que hay APK nueva disponible y servirla.

La app sigue 100% offline para el DSP y la operación clínica. Solo pega al
backend al abrir, una vez por sesión, con timeout corto y cache de 7 días.

El **modo paciente** (APK reducida con presets fijos importados desde JSON
firmado por el técnico) queda fuera de alcance de este spec — va en un spec
separado posterior, en `hearing_aid_app/.kiro/specs/oir-pro-patient-mode/`.

## Glossary

- **Oír Pro** — nombre comercial nuevo de la app (antes "PSK Hearing Aid").
- **APK Técnico** — la APK actual con todas las funciones desbloqueadas.
- **Modo Servicio Técnico** — pantalla / sección de la app que destraba
  funcionalidades avanzadas con un código.
- **Tech code** — string corto (4 a 12 caracteres) que destraba el Modo
  Servicio Técnico. Hoy hardcoded; con este spec se mueve al backend.
- **Backend Oír Pro** — servicio Node.js nuevo, independiente de SmartTemp,
  hosteado en `/var/www/oirpro/` del servidor remoto.
- **Server check** — POST único que la app hace al backend al abrirse para
  obtener: tech_code, latest_version, blocked, blocked_reason, apk_url.
- **Kill switch** — flag `blocked=true` en el backend que pone la app en
  pantalla "Servicio suspendido" (sin borrar datos del paciente).
- **Keystore** — archivo `.jks` con la clave criptográfica que firma la APK.
- **R8 / minify** — etapa de Gradle que renombra clases Java/Kotlin a `a, b, c`
  para dificultar reverse engineering.
- **Ofuscación Dart** — flag `--obfuscate` de Flutter que renombra símbolos
  Dart en la AOT compilation.
- **OTA** — Over The Air updates. En este spec significa "notificar al
  usuario que hay APK nueva + servirla desde el backend".

## Requirements

### R1 — Rebrand a "Oír Pro" (Fase 1, mandatorio)

- R1.1 `android:label` en `AndroidManifest.xml` cambia de
  `"PSK Hearing Aid"` a `"Oír Pro"`. Soporta tilde sin problemas.
- R1.2 El archivo APK que sube GitHub Actions a Releases se llama
  `oir-pro.apk` (no `app-release.apk`).
- R1.3 El título del release en GitHub se llama `Oír Pro vN`.
- R1.4 El cuerpo del release se actualiza para no decir "PSK Hearing Aid".
- R1.5 No se cambia `applicationId` de Android (`com.psk.hearing_aid_app`)
  para no romper la firma existente ni perder updates de los celulares
  que ya tienen la versión vieja instalada. Solo cambia el label visible.

### R2 — Endurecimiento (Fase 2, mandatorio)

- R2.1 `minifyEnabled = true` y `shrinkResources = true` en `release` de
  `android/app/build.gradle`.
- R2.2 `proguard-rules.pro` se extiende con reglas para preservar:
  símbolos JNI nativos, callbacks de Oboe, model loaders ONNX, plugins
  Flutter (Bluetooth, audio, permissions). Un solo símbolo mal preservado
  rompe el DSP en runtime.
- R2.3 El comando del workflow agrega `--obfuscate
  --split-debug-info=build/debug-info` al `flutter build apk`.
- R2.4 El `build/debug-info/` queda como artifact del workflow para que
  vos puedas leer crash reports después.
- R2.5 El tamaño de la APK no debe crecer respecto a la versión sin
  endurecimiento (debería bajar gracias a R8 + shrink).

### R3 — Biometría al abrir (Fase 3, mandatorio)

- R3.1 La app pide huella dactilar / face unlock antes de mostrar la UI
  principal en cada arranque "fresco" (no al volver de background corto).
- R3.2 Se usa `package:local_auth` con biometric strong (Class 3) preferida
  y fallback a biometric weak (Class 2). Sin huella en el dispositivo, la
  app cae a un PIN local de 4-6 dígitos seteado en el primer arranque.
- R3.3 Si el usuario falla 5 veces, app se cierra. Sin lockout permanente.
- R3.4 Setting "Pedir biometría al abrir" en Servicio Técnico para que el
  técnico la desactive durante demos en una venta. Default ON.
- R3.5 Splash screen mientras espera la biometría — sin frame de UI a la
  vista detrás.

### R4 — Keystore propia (Fase 4, mandatorio)

- R4.1 Vos generás la keystore localmente con `keytool` (no se commitea).
- R4.2 El archivo `.jks` y sus contraseñas se guardan en GitHub Secrets:
  `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`.
- R4.3 El workflow `build-apk.yml` decodifica el secret a un `.jks` temporal
  durante el build y firma la APK con esa keystore.
- R4.4 Existe `key.properties.example` documentado en el repo.
- R4.5 `key.properties` real está en `.gitignore`.
- R4.6 Si el secret no está configurado, el workflow falla rápido con
  mensaje claro (no firma con debug key silenciosamente).

### R5 — Backend remoto (Fase 5, mandatorio)

- R5.1 Servicio Node.js independiente en `/var/www/oirpro/` del servidor
  `149.50.137.2`. **Sin dependencia de SmartTemp.** Si SmartTemp se cae, Oír
  Pro sigue. Si Oír Pro se cae, SmartTemp sigue.
- R5.2 Puerto interno **8060** (libre, distinto de SmartTemp `8055`).
- R5.3 DB MySQL nueva llamada `oirpro` en la misma instancia que SmartTemp.
  Mismo usuario / contraseña reutilizables. Si en el futuro se migra a otro
  VPS, alcanza con copiar `/var/www/oirpro/` y la DB `oirpro`.
- R5.4 Stack: **Node 20 + Express + mysql2 + dotenv + bcrypt + jsonwebtoken**.
  Sin frameworks pesados. Una sola dependencia ORM (`mysql2/promise` plain).
- R5.5 PM2 segunda app llamada `oirpro-server` en `ecosystem.config.js`.
- R5.6 Endpoints públicos:
  - `POST /api/check` — recibe `{appId, deviceId, currentVersion}`,
    devuelve `{techCode, latestVersion, minVersion, blocked, blockedReason,
    apkUrl}`.
  - `GET /api/health` — devuelve `{status: "ok", uptime, dbOk}`.
- R5.7 Endpoints admin (autenticados):
  - `POST /api/admin/login` — `{username, password}` → JWT 24h.
  - `GET /api/admin/config` — devuelve la fila singleton actual.
  - `PUT /api/admin/config` — actualiza tech_code / latest_version /
    blocked / blocked_reason / apk_url.
  - `POST /api/admin/upload-apk` — multipart upload, guarda APK en
    `/var/www/oirpro/public/apk/<filename>` y devuelve la URL pública.
  - `GET /api/admin/log` — últimas 100 entradas de `oirpro.activity_log`.
- R5.8 UI admin servida estática desde `/var/www/oirpro/public/admin/`:
  página HTML simple con login, formulario de configuración y subida
  de APK. Sin frameworks JS pesados (vanilla + fetch).
- R5.9 Acceso público inicial **directo por puerto** (`https://149.50.137.2:8060`).
  Reverse proxy nginx queda fuera de alcance — se puede agregar después.
- R5.10 **TLS:** se usa el mismo certificado que SmartTemp si es posible.
  Si no, HTTP plano en LAN y la app acepta connection sin SSL — solo durante
  bootstrap. **Reforzable después**, no bloquea el spec.

### R6 — Cliente remoto en la app (Fase 5b, mandatorio)

- R6.1 Servicio Dart `RemoteConfigService` en
  `lib/data/services/remote_config_service.dart`.
- R6.2 Al iniciar la app (después de la biometría), un `POST /api/check` con
  timeout 3 s.
- R6.3 Si el server responde:
  - Cachear el JSON completo en Hive box `oirpro_remote_cache` con
    timestamp.
  - Si `blocked == true`, mostrar pantalla "Servicio suspendido"
    (no destructiva: no borra audiograma, settings, presets) con el texto
    de `blockedReason`. Solo se sale apagando la app.
  - Si `latestVersion > currentVersion`, mostrar diálogo "Actualización
    disponible" con botón "Descargar" que abre `apkUrl` en navegador.
  - Si `minVersion > currentVersion`, el diálogo es **modal bloqueante**
    (no se puede cerrar sin actualizar).
  - Guardar el `techCode` en cache para usar dentro de la app.
- R6.4 Si el server NO responde:
  - Usar el último JSON del cache si tiene < 7 días.
  - Si el cache está expirado o vacío, usar defaults seguros embebidos en
    la APK: `techCode = '<placeholder>'`, `blocked = false`, no version
    notification.
  - **Nunca bloquear la app por falta de internet** — un técnico puede
    estar atendiendo en una zona sin cobertura.
- R6.5 El check es **asíncrono y no bloquea la UI** después del primer
  arranque. La app abre, muestra splash, pide biometría, y a la par hace el
  check en background. La pantalla "blocked" o "update" aparece cuando
  llega la respuesta.
- R6.6 Toda la comunicación es JSON. Errores HTTP se loguean a logcat con
  tag `RemoteConfig` y NO se muestran al usuario en producción.

### R7 — Tarjetas Plano/Silencio (Fase 0, ya hecho)

- R7.1 ✅ Cards rediseñadas con `_DarkInfoChip` cyan translúcido.
- R7.2 ✅ En Modo Amplificador (no diagnóstico), las cards no se muestran.
- R7.3 Solo falta el push del commit aislado (parte de Fase 1 de este spec).

### R8 — No bloqueantes / interacciones

- R8.1 No tocar el DSP nativo (ya cerrado en spec
  `dnn-voice-level-recovery`).
- R8.2 No tocar el flujo de calibración (cerrado en
  `native-calibration-handlers`).
- R8.3 No tocar la lógica de prescripción NL3 ni audiograma.
- R8.4 La APK del técnico sigue siendo distribuida vía Releases de GitHub
  (workflow existente). Adicionalmente se sube manualmente al backend para
  que el cliente pueda descargarla desde ahí.
- R8.5 Spec separado `oir-pro-patient-mode` arrancará después de cerrar
  este. El cliente paciente reusará `RemoteConfigService` con un
  `appId="oirpro-patient"` distinto al del técnico.

## Métricas de éxito

| Métrica | Estado actual | Objetivo |
|---|---|---|
| Nombre visible en launcher | "PSK Hearing Aid" | "Oír Pro" |
| Tamaño APK release | ~30-35 MB | igual o menor (R8 reduce) |
| Tiempo apertura app | inmediato | inmediato + biometría 1-2 s |
| Reverse engineering bytecode Java | trivial (JADX legible) | difícil (R8 ofuscado) |
| Reverse engineering Dart | parcial (reFlutter parsea) | difícil (símbolos obfuscados) |
| Cambiar tech code | recompilar APK | UI admin web, 2 clicks |
| Bloqueo remoto | imposible | flag en server, efecto en próximo abrir |
| Notificar update | manual | automático al abrir |

## Fuera de alcance

- Modo paciente (spec separado `oir-pro-patient-mode/`).
- Reverse proxy nginx para Oír Pro (queda como mejora futura).
- HTTPS con cert válido para el backend (puede usar self-signed o el de
  SmartTemp; se endurece después).
- Multi-tenant en el backend (un solo singleton de configuración por ahora).
- Multi-usuario admin (un solo `admin` con password única en `.env` del
  servidor; multi-usuario va con SmartTemp users si en algún momento se
  consolida la auth).
- Ofuscación nativa C++ (R8 cubre Java/Kotlin; Dart cubre Flutter; el
  C++ ya está con `-O2` y símbolos no exportados, alcanza por ahora).

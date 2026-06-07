# Implementation Plan: Oir Pro Paciente — APK separada con bundle JSON

## Overview

5 fases, ordenadas para que cada commit sea estable. Fase 1 y 2 tocan
el backend y la APK técnico. Fase 3 a 5 arman la APK paciente.

## Task Dependency Graph

```json
{
  "waves": [
    { "wave": 1, "tasks": ["1"] },
    { "wave": 2, "tasks": ["2.1", "2.2", "2.3"] },
    { "wave": 3, "tasks": ["3.1", "3.2", "3.3"] },
    { "wave": 4, "tasks": ["4.1", "4.2", "4.3", "4.4", "4.5", "4.6", "4.7"] },
    { "wave": 5, "tasks": ["5.1", "5.2", "5.3"] }
  ]
}
```

Notas: Fase 1 (HMAC secret) es prerequisito de todo. Fase 2 (export bundle
desde técnico) puede correr en paralelo con Fase 3 (split backend), pero
sin HMAC nada funciona.

## Tasks

### Fase 1 — Generar y compartir HMAC secret

- [ ] 1. Generar HMAC secret y configurar inyección via GitHub Secrets
  - 1.1 Generar string random de 32 bytes hex con
        `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`.
  - 1.2 Subirlo como GitHub Secret `HMAC_SECRET` en
        `memomedix3-commits/Audifon`. Repo nuevo del paciente reusará el
        mismo valor cuando se cree.
  - 1.3 Modificar workflow `build-apk.yml` del técnico para pasar
        `--dart-define=HMAC_SECRET=${{ secrets.HMAC_SECRET }}` al
        `flutter build apk`.
  - 1.4 Agregar `tools/generate_hmac.dart` (helper local) que muestre el
        secret actual leyéndolo del `.env` de dev (gitignored).
  - _Refs: R3.2, R3.3, R8.2_

### Fase 2 — Exportar bundle desde APK técnico

- [ ] 2.1 Crear `BundleExporter` en hearing_aid_app
  - 2.1.1 Archivo `lib/bundle_export/bundle_exporter.dart`.
  - 2.1.2 API: `exportBundle({audiogram, presets, wdrc, mpo, mhlEnabled,
          defaultPresetName, patientName, notes})`.
  - 2.1.3 Helpers:
          `_canonicalJson(body)` — JSON con claves ordenadas alfabéticamente.
          `_hmacSha256(text, secret)` — usando `package:crypto`.
  - 2.1.4 Genera `oirpro_<nombre>_<YYYYMMDD>.oirpro.json` en `Downloads/`.
  - 2.1.5 Dispara share sheet con `package:share_plus`.
  - _Refs: R3.1, R3.2, R4.1, R4.3, R4.4, R4.5_

- [ ] 2.2 UI Servicio Técnico — pantalla "Exportar paciente"
  - 2.2.1 Archivo `lib/presentation/screens/bundle_export_screen.dart`.
  - 2.2.2 Form: `TextField` patientName + notes + dropdown defaultPreset
          + botón "Generar y compartir".
  - 2.2.3 Llama a `BundleExporter.exportBundle(...)` con los valores.
  - 2.2.4 Muestra `SnackBar("Bundle generado")` y abre share sheet.
  - _Refs: R4.2_

- [ ] 2.3 Agregar tarjeta en TechnicalServiceScreen
  - 2.3.1 En `lib/presentation/screens/technical_service_screen.dart`,
          agregar `_ServiceCard` "Exportar configuración del paciente"
          que navega a `BundleExportScreen`.
  - 2.3.2 Icono: `Icons.send_to_mobile`.
  - 2.3.3 Color: `Colors.greenAccent`.
  - _Refs: R4.1_

### Fase 3 — Backend split por appId

- [ ] 3.1 Migración SQL split app_config
  - 3.1.1 Crear `oirpro-server/db/migrations/002_split_appid.sql`:
          `ALTER TABLE app_config DROP PRIMARY KEY;`
          `ALTER TABLE app_config DROP COLUMN id;`
          `ALTER TABLE app_config ADD COLUMN app_id VARCHAR(64) NOT NULL FIRST;`
          `ALTER TABLE app_config ADD PRIMARY KEY (app_id);`
          `UPDATE app_config SET app_id = 'oirpro-tech' WHERE app_id IS NULL OR app_id = '';`
          `INSERT IGNORE INTO app_config (app_id, tech_code, latest_version, min_version) VALUES ('oirpro-patient', '', '1.0.0', '1.0.0');`
  - 3.1.2 Actualizar `db/migrate.js` para correr migrations en orden.
  - _Refs: R7.1, R7.2_

- [ ] 3.2 Actualizar endpoints
  - 3.2.1 `routes/public.js`: `/api/check` filtra por `appId` del body.
          Si no encuentra fila → devolver defaults (`tech_code=''`,
          `latestVersion='1.0.0'`, `blocked=false`).
  - 3.2.2 `routes/admin.js`: `GET/PUT /admin/config?appId=...`. Default
          `oirpro-tech` si no viene query.
  - _Refs: R7.3_

- [ ] 3.3 Admin web con tabs Técnico/Paciente
  - 3.3.1 `public/admin/index.html`: dos botones tab arriba que
          determinan el `appId` activo.
  - 3.3.2 `public/admin/app.js`: cambiar todas las llamadas a `/config`
          para incluir `?appId=...` según tab activo.
  - 3.3.3 Estilo: tab activo en cyan, inactivo en blanco/gris. Persiste
          el tab seleccionado en `localStorage`.
  - _Refs: R7.4_

### Fase 4 — Crear APK Paciente

- [ ] 4.1 Crear proyecto Flutter nuevo
  - 4.1.1 `cd c:\Users\Elsa y Henry\Pictures\Amplificador\PACIENTE`
          (crear si no existe).
  - 4.1.2 `flutter create oir_pro_patient_app --org com.psk --platforms android`.
  - 4.1.3 Cambiar `applicationId = "com.psk.oir_pro_patient"` en
          `android/app/build.gradle`.
  - 4.1.4 `pubspec.yaml`: dependencias mínimas — `flutter_bloc`, `hive`,
          `hive_flutter`, `crypto`, `http`, `share_plus`, `file_picker`,
          `url_launcher`, `local_auth`, `permission_handler`,
          `wakelock_plus`, `just_audio`.
  - _Refs: R1.1, R1.3, R1.6_

- [ ] 4.2 Copiar `.so` precompilados del técnico
  - 4.2.1 Antes: hacer build release del técnico para tener los `.so`
          en `hearing_aid_app/build/app/intermediates/...`.
  - 4.2.2 Crear `oir_pro_patient_app/android/app/src/main/jniLibs/arm64-v8a/`.
  - 4.2.3 Copiar: `libnative-lib.so`, `libonnxruntime.so`, `liboboe.so`.
  - 4.2.4 Verificar que arrancan: `MethodChannel('com.psk.hearing_aid/audio')`
          responde a `start()`.
  - _Refs: R5.1, R5.2, R5.3, R5.4_

- [ ] 4.3 Bridge MethodChannel mínimo
  - 4.3.1 `lib/core/audio_bridge.dart`: copia recortada del técnico.
          Solo expone: `start`, `stop`, `setVolume`, `setEqGains`,
          `setNrLevel`, `setMpoThresholdDbSpl`, `setDnnEnabled`,
          `setDnnIntensity`. NO calibración, NO audiometría.
  - 4.3.2 `MainActivity.kt` minimal: registra solo el channel de audio.
  - _Refs: R2.5, R5.4_

- [ ] 4.4 Bundle importer
  - 4.4.1 `lib/bundle/bundle_data.dart`: modelos `FittingBundle`,
          `Audiogram`, `EqPreset`, `WdrcParams`.
  - 4.4.2 `lib/bundle/bundle_importer.dart`:
          - `importFromFile(File f)` — lee, parsea, valida HMAC.
          - `_canonicalJson` consistente con el técnico (claves ordenadas).
          - `_constantTimeEquals` para comparar hashes.
          - Persistir bundle exitoso en Hive `patient_bundle.last`.
  - 4.4.3 `lib/bundle/pending_setup_screen.dart`: pantalla "Pendiente
          de configuración inicial" + botón "Cargar archivo".
  - _Refs: R3.4, R3.5, R3.6, R3.7_

- [ ] 4.5 UI principal recortada
  - 4.5.1 `home_screen.dart` — solo: chip "Conexión", `presets_panel`,
          `smart_toggle`, `auto_tnr_toggle`, botón a `advanced_config`,
          botón a `dsp_test`, botón importar bundle.
  - 4.5.2 `presets_panel.dart` — lista los presets del bundle, click
          aplica al DSP. NO permite editar.
  - 4.5.3 `smart_toggle.dart` — toggle clasificador automático.
  - 4.5.4 `auto_tnr_toggle.dart` — toggle AutoTNR (default ON).
  - 4.5.5 `advanced_config_screen.dart` — 4 sliders: volumen master,
          MPO threshold, intensidad DNN, "comodidad" WDRC.
  - 4.5.6 `dsp_test_screen.dart` — reproduce tonos puros (1 kHz, 4 kHz)
          a niveles fijos. Sin métricas.
  - 4.5.7 `mhl_toggle.dart` — visible solo si `bundle.mhl.enabled`.
  - _Refs: R2.1, R2.2, R2.3, R2.4, R2.5, R2.6_

- [ ] 4.6 Cliente RemoteConfigService paciente
  - 4.6.1 Copy de `remote_config_service.dart` del técnico.
  - 4.6.2 Cambiar `appId = 'oirpro-patient'` por default.
  - 4.6.3 Mismo `RemoteConfigGate` y `BlockedScreen`.
  - 4.6.4 Update dialog apunta a `apkUrl` paciente.
  - _Refs: R6.1, R6.3, R6.4_

- [ ] 4.7 Workflow GitHub Actions paciente
  - 4.7.1 `oir_pro_patient_app/.github/workflows/build-patient-apk.yml`.
  - 4.7.2 Espejo de `build-apk.yml` del técnico.
  - 4.7.3 Output: `oir-pro-paciente.apk` en releases.
  - 4.7.4 Misma keystore (mismos secrets `KEYSTORE_*`).
  - 4.7.5 Mismo `HMAC_SECRET` en secrets.
  - _Refs: R8.1, R8.2, R8.3_

### Fase 5 — Validación end-to-end

- [ ] 5.1 Smoke test técnico → paciente
  - 5.1.1 Build técnico, instalar, ir a Servicio Técnico.
  - 5.1.2 Exportar bundle de prueba.
  - 5.1.3 Build paciente, instalar.
  - 5.1.4 Importar el bundle.
  - 5.1.5 Validar: presets aparecen, audio sale, DSP responde a sliders.

- [ ] 5.2 Test de seguridad
  - 5.2.1 Editar el JSON con Notepad → re-importar → tiene que rechazar.
  - 5.2.2 `apksigner verify` ambas APKs → mismo certificado, distinto
          applicationId.
  - 5.2.3 `aapt dump strings` de la APK paciente buscando strings del
          técnico (`CalibrationStep`, `AudiometryScreen`) — no debe
          encontrar.

- [ ] 5.3 Smoke test backend
  - 5.3.1 Admin web → tab Paciente → cambiar `tech_code`.
  - 5.3.2 Abrir APK paciente → verificar logcat: `appId=oirpro-patient`
          en el body del POST.
  - 5.3.3 Admin web → tab Paciente → `blocked=true` → reabrir paciente
          → muestra BlockedScreen.

## Notes

- **Fase 1 (HMAC secret) es bloqueante**. Sin él, ni técnico ni paciente
  pueden firmar/validar bundles.
- **Repo del paciente**: si querés un repo Git aparte, lo creamos como
  `memomedix3-commits/Audifon-paciente`. Si no, queda local en
  `PACIENTE/oir_pro_patient_app/` y vos decidís cuándo subirlo.
- **`.so` precompilados**: la primera vez requiere build release del
  técnico. Después se actualizan solo cuando el DSP nativo cambia.
- **Modo paciente solo Android**. iOS queda fuera de alcance.

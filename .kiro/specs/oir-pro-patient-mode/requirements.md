# Requirements Document

> Spec — Oír Pro Paciente: APK independiente con configuración importada vía
> JSON firmado por el técnico.
>
> Estado: **PENDIENTE** — diseño consensuado, sin implementación.

## Introduction

Oír Pro tiene hoy una sola APK ("Oír Pro Técnico") con todas las funciones
desbloqueadas. Este spec arma la **APK paciente**: una versión recortada
para usuarios finales que solo expone funciones de uso diario. La
configuración clínica (audiograma, presets, parámetros DSP) la prepara el
técnico desde su APK y se la pasa al paciente como un **archivo JSON
firmado** por WhatsApp / email / Bluetooth.

La separación es física, no por flag: la APK paciente es un proyecto
Flutter aparte que **no contiene** el código de servicio técnico. Esto
protege la lógica de calibración, audiometría y herramientas de servicio
contra reverse engineering desde una APK paciente filtrada.

## Glossary

- **APK Técnico** — la app actual `hearing_aid_app/` con todas las
  funciones (calibración, audiometría, servicio técnico, etc.).
- **APK Paciente** — proyecto nuevo `oir_pro_patient_app/`, distribución
  separada, package name distinto. Solo funciones de uso diario.
- **Carpeta del proyecto paciente** — `c:\Users\Elsa y Henry\Pictures\Amplificador\PACIENTE\`
  según pediste en una sesión previa.
- **Bundle de fitting** — JSON firmado que el técnico exporta y el
  paciente importa. Contiene audiograma, presets, params DSP.
- **HMAC** — firma criptográfica del bundle. Sin clave secreta no se puede
  generar un JSON válido.
- **Modo Smart** — clasificador automático de escena (silencio / voz /
  ruido / música) que selecciona preset.
- **AutoTNR** — Targeted Noise Reduction automática.
- **DSP Test** — pantalla que reproduce tonos para que el paciente valide
  audio.
- **MHL** — Minimum Hearing Loss, modo de prescripción para pérdida muy
  leve.
- **Configuración avanzada** — pantalla con sliders (volumen, MPO,
  intensidad DNN, params WDRC). EQ por banda **NO** entra (los presets
  cubren ese caso).

## Requirements

### R1 — Proyecto paciente físicamente separado

- R1.1 Crear nuevo proyecto Flutter en
  `c:\Users\Elsa y Henry\Pictures\Amplificador\PACIENTE\oir_pro_patient_app\`.
  No comparte sources con `hearing_aid_app/`.
- R1.2 El paciente reusa los **módulos nativos C++ ya compilados** del
  técnico (DSP, DNN, scene engine, BLE). Los `.so` van como `jniLibs`
  pre-buildeados.
- R1.3 Package name distinto: `com.psk.oir_pro_patient`.
  `applicationId` distinto al técnico, así pueden coexistir en el mismo
  celular.
- R1.4 Label visible: `"Oír Pro"` (mismo nombre comercial; el ícono y la
  funcionalidad recortada son la diferencia).
- R1.5 Misma keystore que el técnico — firmado con `oirpro-release.jks`.
- R1.6 Misma estructura de Hive boxes que el técnico para los datos que
  comparten (audiograma, presets), distinta para datos exclusivos del
  paciente (config importada, historial de uso).
- R1.7 NO se copia ni reusa código fuente Dart del técnico relacionado
  con: calibración, audiometría, servicio técnico, debug tools, scripts
  de validación. Solo se reusan widgets neutros (chips, sliders, theme).

### R2 — Funcionalidades del paciente

La APK paciente expone exclusivamente:

- R2.1 **Pantalla principal con presets**: Smart NL2, Smart NL3, y los
  custom que el técnico haya incluido en el bundle.
- R2.2 **Modo Smart**: clasificador automático (sin opción "silencio" —
  sale del paciente, queda en técnico).
- R2.3 **AutoTNR ON**: toggle simple, default ON. El paciente puede
  apagarlo y prenderlo.
- R2.4 **DSP Test**: pantalla con tonos puros para validar audio. Sin
  exportar resultados, sin métricas — solo escuchar.
- R2.5 **Configuración avanzada**: 4 sliders.
  - Volumen master.
  - Threshold MPO.
  - Intensidad DNN.
  - Params WDRC compactos (un solo slider de "comodidad").
  - **EQ por banda NO** (los presets cubren EQ).
- R2.6 **Modo MHL**: toggle visible si el bundle del paciente lo
  habilita. Si el técnico no lo activó, el toggle no aparece.
- R2.7 **Importar bundle**: opción menú "Cargar configuración" que abre
  un file picker.
- R2.8 NO tiene: servicio técnico, calibración, audiometría,
  configuración BLE, simulador, historial detallado, exportar nada.

### R3 — Bundle de fitting (JSON firmado)

- R3.1 El técnico exporta desde su APK actual un archivo `.oirpro.json`
  con todo lo necesario para el paciente:
  - Audiograma medido (12 bandas, izq + der).
  - Presets EQ (incluye custom y los Smart NL2/NL3 calculados).
  - Params WDRC defaults para ese audiograma.
  - Threshold MPO calculado.
  - Modo MHL: enabled/disabled.
  - Default preset al iniciar.
  - Metadata: nombre del paciente (opcional), fecha, técnico, versión schema.
- R3.2 El JSON tiene una sección `signature` con HMAC-SHA256 calculado
  sobre el JSON entero menos esa sección. Clave secreta hardcoded en
  ambos códigos (técnico y paciente).
- R3.3 La clave HMAC es **idéntica** en técnico y paciente. Cambiar la
  clave invalida todos los bundles previos. Versionar: si cambia, el
  campo `keyVersion` del JSON aumenta.
- R3.4 La APK paciente al importar:
  1. Lee el archivo seleccionado.
  2. Verifica firma HMAC. Si falla → rechaza con mensaje "Archivo
     inválido o modificado".
  3. Verifica `schemaVersion`. Si no soporta → "Configuración
     incompatible, contactá al técnico".
  4. Aplica al sistema (Hive boxes + DSP).
  5. Confirma con SnackBar "Configuración aplicada".
- R3.5 El paciente puede importar un bundle nuevo encima de uno previo
  (re-fitting). El nuevo reemplaza al anterior.
- R3.6 El audiograma se guarda **internamente solamente**. No hay
  pantalla que muestre el gráfico al paciente.
- R3.7 Si la APK paciente arranca SIN bundle nunca importado, muestra
  pantalla "Pendiente de configuración inicial" con instrucciones para
  pedir el archivo al técnico. No deja entrar a la pantalla principal.

### R4 — Exportar bundle desde la APK técnico

- R4.1 Agregar a la APK técnico (`hearing_aid_app/`), en pantalla
  Servicio Técnico, un botón "Exportar para paciente".
- R4.2 El botón abre un diálogo: nombre del paciente (opcional), notas
  (opcional), preset default.
- R4.3 Genera el `.oirpro.json` con todo lo del audiograma + presets +
  WDRC + MPO + MHL + signature HMAC.
- R4.4 Lo guarda en `Downloads/` o lo abre en share sheet de Android
  (WhatsApp, email, Bluetooth, Drive, etc.).
- R4.5 Nombre del archivo: `oirpro_<nombre>_<YYYYMMDD>.oirpro.json`.

### R5 — Reuso de DSP nativo

- R5.1 La APK paciente reusa los `.so` ya compilados del técnico:
  - `libnative-lib.so` (audio_engine, dsp_pipeline, DNN, etc.)
  - `libonnxruntime.so`
  - `liboboe.so`
- R5.2 Los `.so` se copian de
  `hearing_aid_app/build/app/intermediates/cmake/release/obj/arm64-v8a/`
  al proyecto paciente como `jniLibs`.
- R5.3 La APK paciente NO incluye código C++ ni `CMakeLists.txt` —
  los `.so` ya vienen compilados. Esto evita publicar el código nativo
  del DSP en el repo paciente.
- R5.4 El paciente expone los mismos MethodChannels que el técnico para
  poder llamar al DSP. Solo cambia la UI Dart.

### R6 — Cliente del backend remoto

- R6.1 El paciente reusa el `RemoteConfigService` ya armado, con
  `appId="oirpro-patient"`.
- R6.2 El backend ya soporta filtrar por `appId` (en `check_log` queda
  registrado). Si en el futuro quieren políticas distintas para paciente
  vs técnico, agregamos endpoint nuevo.
- R6.3 Kill switch: igual que el técnico — si `blocked=true`, paciente
  ve pantalla "Servicio suspendido" no destructiva.
- R6.4 Update: igual que técnico — diálogo "Actualización disponible"
  con link al APK del paciente (otro `apkUrl` distinto al del técnico).

### R7 — Backend: split de configuración técnico vs paciente

- R7.1 Cambiar `app_config` del backend de **singleton** a una tabla con
  fila por `appId` (`oirpro-tech`, `oirpro-patient`).
- R7.2 Migration SQL que agrega la fila paciente con defaults seguros.
- R7.3 Endpoint `POST /api/check` recibe `appId` (ya lo hace) y devuelve
  la fila correspondiente.
- R7.4 Admin web actualizada: tabs o selector "Técnico / Paciente" para
  editar las dos configuraciones por separado.

### R8 — Identidad y distribución

- R8.1 Nuevo workflow de GitHub Actions `build-patient-apk.yml` en el repo
  del paciente (cuando se cree). Espejo del técnico pero apuntando al
  proyecto paciente.
- R8.2 Mismas keystore secrets reutilizados. Misma firma — pero distinto
  package name, así Android los trata como apps distintas.
- R8.3 La APK paciente se llama `oir-pro-paciente.apk` en el release.

### R9 — No bloqueantes / fuera de alcance

- R9.1 No tocar el DSP nativo.
- R9.2 No cambiar el formato del audiograma persistido en Hive.
- R9.3 No agregar funciones nuevas al técnico salvo el botón de exportar
  bundle (R4).
- R9.4 No traducciones — todo en español rioplatense.

## Métricas de éxito

| Métrica | Estado actual | Objetivo |
|---|---|---|
| Repo paciente independiente | No existe | Existe en `PACIENTE/oir_pro_patient_app/` |
| Plagiar paciente revela código técnico | Sí (mismo proyecto) | No (proyectos separados) |
| Fitting remoto sin tocar el celu del paciente | No | Sí, archivo `.oirpro.json` por WhatsApp |
| Bundle modificado a mano funciona | — | NO (HMAC lo rechaza) |
| Tamaño APK paciente | — | < 25 MB (sin código técnico, sin tools) |
| Coexistir técnico+paciente en mismo celu | — | Sí (package names distintos) |

## Fuera de alcance

- Modo paciente con login (multi-paciente en un celu).
- Sincronizar fitting automático vía server (hoy es manual con archivo).
- Web de paciente / portal — solo APK Android.
- Exportar progreso del paciente al técnico (será un spec posterior si
  hace falta).
- Versión iOS (Android primero, iOS después si hay demanda).

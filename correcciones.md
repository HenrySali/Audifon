# PSK Hearing Aid — Registro de Correcciones y Trazabilidad

> Este documento registra cada corrección/feature aplicada, su estado de verificación,
> y sirve como base para construir el `skill.md` definitivo una vez todo esté funcional.

## Estados posibles

| Estado | Significado |
|--------|-------------|
| ✅ EFECTIVA | Verificada en dispositivo real, funciona correctamente |
| ❌ NO EFECTIVA | No resolvió el problema o introdujo otro |
| ⚠️ PARCIAL | Funciona en algunos casos pero no en todos |
| 🔄 PENDIENTE | Aplicada pero no verificada aún en dispositivo |
| 🔁 REVERTIDA | Se deshizo porque causó regresión |

---

## 2026-05-27

### #1 — Fix: Micrófono no captura audio (entrada 0 dB SPL)

| Campo | Valor |
|-------|-------|
| **Estado** | 🔄 PENDIENTE |
| **Commit** | `a685b95` |
| **Problema** | `onBothStreamsReady` recibía datos vacíos del input stream |
| **Causa raíz** | Se había removido `setDataCallback(this)` del output builder. FullDuplexStream necesita ser el callback del output stream. Además, input en modo Exclusive era denegado silenciosamente |
| **Fix** | Restaurado `setDataCallback(this)`, input a `SharingMode::Shared`, agregado `setFormatConversionAllowed(true)`, diagnóstico de `maxSample` |
| **Archivos** | `audio_engine.cpp` |
| **Verificación** | Revisar logcat filtro "OboeEngine" → si `maxSample > 0` funciona |

---

### #2 — Fix: Build falla con `setSharedInputStream` undeclared

| Campo | Valor |
|-------|-------|
| **Estado** | ✅ EFECTIVA |
| **Commit** | `e8391eb` |
| **Problema** | Oboe 1.9.0 no tiene `setSharedInputStream`/`setSharedOutputStream` |
| **Causa raíz** | Esos métodos son de versiones más nuevas de Oboe |
| **Fix** | Cambiado a `setInputStream(ptr.get())` / `setOutputStream(ptr.get())` |
| **Archivos** | `audio_engine.cpp` |
| **Verificación** | Build CI pasó correctamente |

---

### #3 — Fix: Audio se detiene al cambiar de app

| Campo | Valor |
|-------|-------|
| **Estado** | 🔄 PENDIENTE |
| **Commit** | `96adfa6` |
| **Problema** | Al minimizar la app, Android mata el proceso de audio |
| **Causa raíz** | `AudioForegroundService` existía pero nunca se iniciaba |
| **Fix** | `handleStartAudio()` ahora llama `startForegroundService()`. `handleStopAudio()` envía `ACTION_STOP` |
| **Archivos** | `AudioMethodChannel.kt` |
| **Verificación** | Activar amplificación → minimizar app → verificar que sigue sonando y hay notificación persistente |

---

### #4 — Fix: Audio no sale por parlante del auricular BT

| Campo | Valor |
|-------|-------|
| **Estado** | 🔄 PENDIENTE |
| **Commit** | `1523ee3` |
| **Problema** | Después de agregar foreground service, audio dejó de salir por auricular BT |
| **Causa raíz** | El servicio usaba `MODE_IN_COMMUNICATION` + `USAGE_VOICE_COMMUNICATION` que forzaba cambio de A2DP a SCO |
| **Fix** | Removido `requestAudioFocus()`, `MODE_IN_COMMUNICATION`, y `startAudioEngine()` del servicio. Solo mantiene notificación. Oboe usa `Usage::Media` → A2DP |
| **Archivos** | `AudioForegroundService.kt` |
| **Verificación** | Activar → verificar que suena en parlante del auricular BT (no en parlante del celular) |

---

### #5 — Mejora: Presets de EQ con ganancias reducidas

| Campo | Valor |
|-------|-------|
| **Estado** | ⚠️ PARCIAL |
| **Commit** | `ab6943e` |
| **Problema** | Presets Moderate/Severe/Profound causaban distorsión |
| **Fix** | Ganancias reducidas: Moderate máx 14dB, Severe máx 20dB, Profound máx 24dB |
| **Archivos** | `eq_preset.dart` |
| **Verificación usuario** | "Normal y Mild suenan bien" — Moderate+ no verificados aún |

---

### #6 — Feature: Persistencia del preset EQ y NR en Hive

| Campo | Valor |
|-------|-------|
| **Estado** | 🔄 PENDIENTE |
| **Commit** | `ab6943e` |
| **Problema** | Al cerrar la app se perdía el preset seleccionado |
| **Fix** | Nuevos métodos en `SettingsRepository`: `getLastEqPreset()`/`setLastEqPreset()`, `getLastNrLevel()`/`setLastNrLevel()`. Auto-guarda al cambiar |
| **Archivos** | `settings_repository.dart`, `settings_repository_impl.dart`, `amplification_bloc.dart`, `amplification_event.dart` |
| **Verificación** | Seleccionar preset → cerrar app → reabrir → verificar que mantiene el preset |
| **Nota** | Falta conectar `getLastEqPreset()` en `_onStartAmplification` para cargar al iniciar |

---

### #7 — Feature: Indicador de preset EQ en pantalla principal

| Campo | Valor |
|-------|-------|
| **Estado** | 🔄 PENDIENTE |
| **Commit** | `ab6943e` |
| **Fix** | Widget `_EqPresetIndicator` muestra "EQ: Normal | NR: Off" en pantalla principal |
| **Archivos** | `main_screen.dart`, `amplification_state.dart` |
| **Verificación** | Verificar que aparece el indicador cuando la amplificación está activa |

---

### #8 — Feature: Detección de dispositivos de audio

| Campo | Valor |
|-------|-------|
| **Estado** | ⚠️ PARCIAL |
| **Commit** | `494a2e1` |
| **Fix** | Handler `getDeviceInfo` usa `AudioManager.getDevices()` para nombres de mic y auricular BT |
| **Archivos** | `audio_engine.h/cpp`, `native_bridge.cpp`, `NativeAudioBridge.kt`, `AudioMethodChannel.kt`, `audio_bridge.dart/impl`, `simulator_screen.dart` |
| **Verificación usuario** | Se ve en Configuración Avanzada: "mic: (nombre)" y "salida: (nombre BT)" |
| **Nota** | Funciona pero los nombres pueden ser genéricos en algunos dispositivos |

---

### #9 — Feature: Pantalla de Configuración Avanzada (12 bandas + presets)

| Campo | Valor |
|-------|-------|
| **Estado** | ✅ EFECTIVA |
| **Commit** | `494a2e1` |
| **Fix** | Reescrita `SimulatorScreen` con: selector presets, 12 sliders, espectro, dispositivos, NR |
| **Archivos** | `simulator_screen.dart`, `eq_preset.dart` |
| **Verificación usuario** | Confirmado que se ve y los presets Normal/Mild funcionan |

---

### #10 — Feature: Script de test de frecuencias

| Campo | Valor |
|-------|-------|
| **Estado** | 🔄 PENDIENTE |
| **Commit** | `ab6943e` |
| **Fix** | `test_frequencies.html` genera tonos puros a 12 frecuencias y diferentes intensidades |
| **Archivos** | `test_frequencies.html` |
| **Verificación** | Abrir en Chrome del celular con auricular BT y app PSK activa |

---

### #11 — Fix: Sample rate unificado a 48000 Hz

| Campo | Valor |
|-------|-------|
| **Estado** | ✅ EFECTIVA |
| **Commit** | `494a2e1` |
| **Fix** | Unificado a 48000 Hz en todas las capas (Dart, Kotlin, C++) |
| **Archivos** | `audio_config.dart`, `NativeAudioBridge.kt`, `AudioMethodChannel.kt`, `AudioForegroundService.kt` |
| **Verificación** | Build compila sin warnings de sample rate mismatch |

---

## Pendientes para próxima sesión

| # | Tarea | Prioridad |
|---|-------|-----------|
| 1 | Verificar fix #1 (micrófono) con logcat en dispositivo real | ALTA |
| 2 | Verificar fix #3 (background) — ¿suena al minimizar? | ALTA |
| 3 | Verificar fix #4 (A2DP) — ¿volvió a sonar en auricular? | ALTA |
| 4 | Conectar `getLastEqPreset()` al inicio de amplificación | MEDIA |
| 5 | Resaltar visualmente el chip de NR activo | BAJA |
| 6 | Probar script de frecuencias con auricular BT | BAJA |

---

## Objetivo: skill.md

Una vez que todas las correcciones estén en estado ✅ EFECTIVA, se generará `skill.md` con:
- Arquitectura final validada del pipeline Oboe + DSP
- Patrones correctos de uso de FullDuplexStream
- Ruteo de audio A2DP vs SCO (lecciones aprendidas)
- Foreground service sin interferir con audio routing
- Presets NAL-NL2 calibrados para dispositivos móviles
- Persistencia de configuración con Hive
- Checklist de verificación para futuras modificaciones

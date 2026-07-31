# Registro de Sesiones

## Sesión 1 — 1 julio 2026

### Problema detectado
- El paciente reporta "radio mal sintonizado" con DNN al 100% en el supermercado
- Diagnóstico: el clasificador de entorno dice QUIET cuando debería decir SPEECH_IN_NOISE
- Causa raíz: el `splOffset` del micrófono está en 120 pero el Moto G32 necesita ~140
- Con offset incorrecto, el nivel reportado es 44 dB SPL cuando la realidad es ~65 dB SPL
- Al clasificar como QUIET, el VAD no se activa → el DNN no baja su agresividad → mata los agudos

### Solución implementada
- Slider SPL Offset en Servicio Técnico para ajustar manualmente (rango 90-160)
- Se persiste en Hive y se aplica automáticamente al boot

### Otras mejoras de esta sesión
- App usuario: desbloqueo de modo técnico con clave `741852` (iconos ocultos hasta ingresar la clave)
- Ambas apps: conexión del Aprendizaje Adaptativo al VPS real (149.50.137.2:8080)
- Ambas apps: toggle "Hermes aplica automáticamente" (ON = aplica solo, OFF = solo sugiere)
- VPS: instalado paquete `openai` en hermes-learning, configurada API key, aiEnabled=true

### Estado del VPS (hermes-learning)
- Corre en pm2 como `hermes-learning` en puerto 8080
- Endpoints: POST /api/adaptive-learning/analyze, POST /api/adaptive-learning/feedback, GET /health
- aiEnabled: true (OpenAI configurado)

### Pendiente para próxima sesión
- Probar el slider SPL Offset en el supermercado (poner en ~140 y verificar que el nivel reportado suba)
- Verificar que el clasificador cambie de QUIET a SPEECH_IN_NOISE con el offset correcto
- Verificar que Hermes responde con sugerencias desde la app
- Si el offset 140 no alcanza, probar 145-150
- Si todo funciona: mergear o confirmar conformidad
- Evaluar si crear un script de sincronización entre repos (técnico → usuario automático)
- Crear CHANGELOG.md formal para trazabilidad de versiones

### Repos y ramas
- `HenrySali/Audifon` (técnico) — main actualizado
- `HenrySali/Audifon-usuario` (usuario) — main actualizado
- `HenrySali/OirPro` (backend) — sin cambios en esta sesión

### Celular de prueba
- Motorola Moto G32, Android 13
- splOffset sugerido: ~140 (verificar en campo)


---

## Sesión 1 (continuación) — Hermes Colectivo

### Lo que se implementó

**Servidor Hermes v2 (archivo listo para subir al VPS):**
- Persistencia en disco de observaciones por dispositivo (`data/<deviceId>/observations.json`)
- Pool colectivo con todas las observaciones de todos los usuarios (`data/_collective/observations.json`)
- Endpoint GET `/api/adaptive-learning/history/:deviceId` — historial por dispositivo
- Endpoint GET `/api/adaptive-learning/collective-insights` — patrones cruzados entre usuarios
- Endpoint POST `/api/adaptive-learning/sync` — recuperación tras reinstalación
- El archivo está en `hermes-server-upgrade/server-patch.js` del repo Audifon

**App técnico:**
- Cada request a Hermes ahora envía `deviceId` (hex 16 chars, generado y persistido en Hive)
- Al abrir la app, sincroniza historial desde el VPS (recupera observaciones previas)
- Botón de historial (ícono reloj) que abre un modal con todos los ajustes aplicados
- Toggle "Hermes aplica automáticamente" persiste entre sesiones

### Para desplegar en el VPS

```bash
# Desde tu PC (copiar el server nuevo):
scp hermes-server-upgrade/server-patch.js root@149.50.137.2:"/var/www/OirPro K/adaptive-learning/server.js"

# En el VPS via SSH:
ssh root@149.50.137.2
mkdir -p "/var/www/OirPro K/adaptive-learning/data/_collective"
pm2 restart hermes-learning
curl http://localhost:8080/health
# Debe decir version: "2.0.0"
```

### Pendiente para próxima sesión
- Subir el server-patch.js al VPS y reiniciar Hermes
- Verificar que /health dice version 2.0.0
- Probar analyze con deviceId y verificar que persiste en data/
- Probar sync desde la app tras limpiar datos locales
- Duplicar cambios a la app de usuario (Audifon-usuario)
- Probar el slider SPL Offset en el supermercado (Moto G32, valor ~140)
- Evaluar script de sincronización automática entre repos



---

## Sesión 2 — 3 julio 2026

### Lo que se implementó

**Sistema de recomendaciones contextuales de audio (20 detecciones):**

Widget `AudioRecommendationWidget` en la pantalla principal que monitorea condiciones de audio en tiempo real y muestra banners con sugerencias accionables:

| # | Detección | Patrón | Acción |
|---|-----------|--------|--------|
| 1 | Eco/feedback | Nivel alto + agudos altos sin voz (8s) | Reducir agudos -5 dB |
| 2 | Voz baja | SPEECH + nivel <45 dB (10s) | Subir volumen +3 dB |
| 3 | Saturación EQ | 3+ bandas cerca del MPO | Reducir todo -3 dB |
| 4 | Nivel muy bajo | <25 dB por 20s | Informativo (mic check) |
| 5 | Clipping | >90 dB sostenido 6s | Reducir volumen -5 dB |
| 6 | MPO limitando | Output pegado al techo 8s | Reducir ganancias |
| 7 | DNN matando voz | SPEECH + NR≥3 + nivel >55 (10s) | Bajar NR |
| 8 | Roce de ropa/chasquido | Spikes >15 dB repetidos sin voz (6s) | Activar TNR |
| 9 | Ganancia asimétrica | >15 dB diferencia graves/agudos | Informativo |
| 10 | Música | Espectro amplio + sin voz (16s) | Activar Modo Música |
| 11 | Viento | Energía en graves + NOISE (8s) | Cortar graves -8 dB |
| 12 | Fatiga auditiva | Sesión >2 horas | Informativo (descanso) |
| 13 | Volumen al máximo | +10 dB por 10s | Informativo (recalibrar) |
| 14 | NR insuficiente | NOISE + NR≤1 (10s) | Subir NR |
| 15 | Perfil estático | >15 min sin cambiar | Activar Smart |
| 16 | Exposición alta | LEQ sesión >80 dB | Reducir volumen |
| 17-20 | Ambiente (conversación/ruido/silencio) | Clasificador estable 6s | Cambiar perfil |

**Integración con Hermes:**
- Cada detección se envía automáticamente como observación a Hermes (`[Auto] ...`)
- El texto incluye telemetría (nivel, gains, perfil, NR) para que la IA genere ajustes precisos
- Si `autoApply=true` → Hermes aplica solo
- Si `autoApply=false` → aparece como sugerencia en la ventana de Hermes
- Cooldown de 60s por tipo para no spamear el VPS (independiente del cooldown visual de 30s)

### Archivos modificados
- `lib/presentation/widgets/audio_recommendation_widget.dart` — widget nuevo (completo)
- `lib/presentation/screens/main_screen.dart` — import + integración en `_ActiveView`

### Commits
- `ab5b34b` — feat: add contextual audio recommendation popups
- `290982b` — fix: add missing MethodChannel import
- `70e2fff` — feat: connect audio detections to Hermes adaptive learning
- `904a104` — feat: expand recommendations to 20 detection types

### Pendiente para próxima sesión
- Probar las 20 detecciones en campo (Moto G32)
- Verificar que el roce de ropa se detecta correctamente (bolsillo, mesa)
- Confirmar que Hermes recibe las observaciones [Auto] y genera sugerencias coherentes
- Duplicar el widget a la app de usuario (`Audifon-usuario`) si funciona bien
- Subir el server-patch.js al VPS (pendiente de sesión anterior)
- Probar slider SPL Offset en supermercado (pendiente de sesión anterior)
- Evaluar si bajar los tiempos de detección para testing (ej: 4s en vez de 10s para voz baja)



---

## Sesión 2 (continuación) — 3 julio 2026

### Mejoras adicionales implementadas

**Opción C — Hermes modo automático (LED verde + acordeón):**
- `autoApply=true`: widget aplica ajuste LOCAL inmediato (no espera al VPS)
- LED verde pulsante confirma el ajuste (4 segundos, sin banner)
- Hermes recibe la observación con prefijo `[Auto-Applied]` → solo registra, no reaplica
- Ventana de Hermes: lista principal solo muestra observaciones manuales
- Botón verde "N ajustes automáticos" abre bottom sheet acordeón con los eventos auto
- Cada tile expandible muestra: evento + solución + botones 👍/👎
- Solo 👍 envía feedback positivo al servidor (Hermes aprende)

**5 Reglas clínicas (basadas en NAL-NL2, Phonak, Oticon, Starkey, U. of Illinois):**
1. Speech Guard: nunca bajar volumen/ganancia si hay voz detectada
2. Floor absoluto: volumen nunca baja de 0 dB
3. Banda de habla protegida: bandas 4-7 (1-3 kHz) intocables con SPEECH
4. Tope acumulado: máx -5 dB de reducción total por sesión
5. Reducción selectiva: solo fuera de banda de habla cuando hay voz

**Audio routing (3 features):**
- Bloqueo sin auricular: NO se puede activar amplificación solo con speaker del celular
- Selector de micrófono: ícono 🎙️ en StatusBar → bottom sheet con lista de mics (Builtin/BT/USB)
- Accesible en modo usuario Y técnico (no requiere Servicio Técnico)
- Persistido en Hive, se aplica al boot y en caliente
- Nativo: Oboe usa `preferredInputDeviceId_` al abrir input stream
- BT paralelo (mic+speaker): ya funcionaba vía Modo Conversación (SCO)

### Estado de OpenAI / costos
- Gasto julio 2026: $0.05 / $5.00 (1% del budget)
- Saldo acreedor: $4.30
- 102.179 fichas (tokens) consumidas en 24h
- 7 respuestas generadas

### Commits de esta continuación
- `ee9e6e4` — fix: auto-apply recommendations immediately when Hermes is in auto mode
- `3b5d97f` — feat: option C - instant local fix + Hermes registers only + green LED + accordion
- `f33a1ec` — fix: volume floor at -5 dB + robust auto-event filter
- `76bfed1` — feat: implement 5 clinical rules for audio adjustments
- `881fe24` — feat: audio routing - headset gate + mic selector + native support
- `c6ea2ba` — feat: mic selector in StatusBar (accessible in user + tech mode)

### PLAN: Optimización de costos OpenAI (próxima sesión)

**Problema:** Cada detección automática = 1 llamada a OpenAI = tokens. Con 20 detecciones disparándose cada 60s de cooldown, puede haber docenas de llamadas/hora.

**Solución propuesta — Batch + Cache:**
- Acumular observaciones localmente durante 12 horas (no enviar a OpenAI en tiempo real)
- Cada 12h (o al conectar WiFi): enviar batch consolidado a OpenAI con todas las observaciones juntas
- OpenAI responde UNA vez con análisis del patrón del período completo
- Esa respuesta queda cacheada en disco como "regla aprendida"
- Las detecciones futuras se resuelven con el cache local (sin llamar a OpenAI)
- Solo se consulta de nuevo cuando aparece un patrón nuevo no cacheado

**Resultado esperado:** 1-2 llamadas a OpenAI por día en vez de 50+

**Implementación requiere:**
- Timer de 12h en el servidor (o cron job) que procese la cola
- Endpoint `/api/adaptive-learning/batch-analyze` que tome N observaciones juntas
- Cache de respuestas indexado por (escena + condición + telemetría similar)
- Lógica de "cache hit" en la app: antes de enviar al VPS, verificar si hay regla cacheada
- Fallback a reglas keyword locales cuando no hay cache ni internet

### Pendiente para próxima sesión
- Implementar el sistema batch + cache de OpenAI
- Probar las 20 detecciones en campo (Moto G32)
- Verificar bloqueo sin auricular
- Probar selector de micrófono con auricular BT
- Subir server-patch.js al VPS
- Duplicar cambios a app usuario (Audifon-usuario)


---

## Sesión 5 — 8 julio 2026

### Objetivo
Modularizar la pantalla de diagnóstico unificado, corregir bugs del pipeline WAV, y crear sistema de reporte inteligente para el Analizador.

### 1. Modularización de unified_diagnostics_screen.dart

**Antes:** 1 archivo monolítico de 1432 líneas.
**Después:** 20 archivos con responsabilidades claras.

```
lib/presentation/screens/unified_diagnostics/
├── models/
│   ├── diag_test_id.dart        (IDs + nombres de los 13 tests)
│   ├── test_result.dart         (TestResult + TestStatus enum)
│   └── diagnostic_report.dart   (DiagnosticReport + DiagnosticFinding)
├── runners/
│   ├── test_runner_base.dart    (helpers compartidos: WAV, stats)
│   ├── smart_scene_runner.dart
│   ├── dsp_recording_runner.dart
│   ├── session_log_runner.dart
│   ├── spectrum_runner.dart
│   ├── enhancement_runner.dart
│   ├── latency_runner.dart
│   ├── dnn_runner.dart
│   ├── wdrc_runner.dart
│   ├── mpo_runner.dart
│   ├── protection_runner.dart
│   ├── routing_runner.dart
│   ├── health_runner.dart
│   └── ab_comparative_runner.dart
├── report/
│   └── diagnostic_report_generator.dart
├── widgets/
│   ├── control_bar.dart
│   └── test_card.dart
├── theme/
│   └── diagnostics_colors.dart
└── unified_diagnostics_screen.dart (orquestador ~200 líneas)
```

### 2. Bugs corregidos en el pipeline WAV

| Bug | Causa | Fix |
|-----|-------|-----|
| Self-recording tests (DSP, A/B) no enviaban WAVs al Analizador | `addWav()` solo se llamaba para tests normales | Extraer `wavFullPath`/`wavFullPaths` del resultado |
| Path incorrecto (Dart vs Kotlin) | `getExternalStorageDirectory()` ≠ `getExternalFilesDir(null)` | Kotlin devuelve fullPath real como String |
| WAVs de tests normales se borraban | `stop()` borra archivos <15s | Todos usan `stopDiagnosticRecordingKeep` |
| A/B Comparative "Stop code -1" | `stop()` borra WAVs de 5s (intencionales) | Nuevo método `stopAndKeep()` en C++ |

### 3. Reporte unificado de diagnóstico

**DiagnosticReportGenerator** analiza los 13 tests y genera:
- **Sección usuario**: lenguaje simple con ✅/⚠️/❌ + recomendaciones
- **Sección técnica**: JSON completo con todos los datos (para soporte/dev)

Se visualiza en la ventana del Analizador con:
- Header con estado global (OK/warnings/issues)
- Lista de hallazgos con severity + recomendaciones
- Toggle expandible con JSON técnico copiable
- Lista de WAVs con indicador de existencia del archivo

### 4. Correcciones basadas en normas IEC/ANSI

| # | Problema | Norma/Referencia | Fix |
|---|----------|------------------|-----|
| 1 | WDRC `distribuciónRegiones` vacío | IEC 60118-2:2004 | Kotlin devuelve String, runner ahora parsea ambos tipos |
| 2 | MPO falso positivo "distorsionado" con clips=0 | Giannoulis/Massberg/Reiss (2012) JAES 60(6):399-408 | Diferencia envolvente activa (warning) vs clips reales (critical) |
| 3 | Enhancement "Bypass" confuso con DNN activa | IEC 60118-2 (AGC etapas independientes) | Clarifica: modo = beamformer, DNN es independiente |
| 4 | A/B borra WAVs parciales | IEC 60118-0:2022 (no prescribe duración mínima) | `stopAndKeep()`: finaliza header WAV sin borrar |

### Commits de esta sesión

| Commit | Mensaje |
|--------|---------|
| `3f3565f` | refactor: modularizar unified_diagnostics_screen en 20 archivos |
| `9f8bbdb` | fix(diagnostics): WAV pipeline + reporte unificado en Analizador |
| `b46cb56` | fix(diagnostics): 4 correcciones basadas en normas IEC/ANSI y literatura |
| `427f097` | fix(build): remove extraneous closing brace in audio_engine.cpp:1146 |
| `409591b` | fix(diagnostics): stopTestWav usa stopKeep para conservar WAVs de tests normales |

### Resultado final del diagnóstico (test en Moto G32)

- 14 WAVs generados y conservados correctamente
- A/B Comparative: 3/3 modos grabados exitosamente
- WDRC: "Compresión: 96%, Lineal: 4%" (antes vacío)
- MPO: "Protección OK (activo 0%)" o "Protegiendo correctamente (sin distorsión)"
- Enhancement: "IA activa (100%), beamformer desactivado"
- Sistema estable, 0 underruns en latencia, timestamps 100% sanos

### Pendiente para próxima sesión
- **Diagnóstico en ambiente ruidoso**: grabación WAV + validar coherencia del pipeline con SNR bajo
- Verificar que el clasificador de ambiente cambie correctamente con ruido real
- Validar que DNN/WDRC/MPO se comporten coherentemente en ruido
- Evaluar si el underrun reportado en health (1 en 5s durante diagnóstico) es un falso positivo del test mismo
- Considerar bajar threshold de underruns critical de 1 a 3+ para evitar falsos positivos durante diagnóstico


---

## Sesión 6 — 9 julio 2026

### Objetivo
Eliminar el artefacto de "soplido/eco de caracol" que deja la DNN (GTCRN) al limpiar ruido, especialmente en ambientes de calle/subte. También corregir chasquidos por oscilación de escena y mejorar el MVDR.

### 1. Diagnóstico del soplido (validado en Octave + WAVs reales del dispositivo)

**Problema:** con la DNN activa en ambientes ruidosos (calle, subte), se escucha un "soplido" constante de fondo que suena como viento o resonancia de caracol. El bypass no lo tiene. La DNN (GTCRN) deja residuo tonal por usar máscara de magnitud sin tratamiento de fase.

**Análisis realizado:**
- Extracción de 14 WAVs de diagnóstico del Moto G32 via adb
- Simulación en Octave (`simular_eco.m`): confirmó que la interacción DNN + WDRC modula el residuo DNN con fluctuación de 4.8 dB (audible, umbral 3 dB)
- Comparativa A/B en los WAVs: bypass vs DNN — el soplido solo está con DNN activa
- Medición de nivel MVDR vs bypass (`medir_nivel_mvdr_vs_bypass.m`): confirmó onset preservation al 10.5% con Wiener DD

### 2. Cambio de modelo DNN: GTCRN → DPDFNet4

**Causa raíz:** GTCRN aplica máscara de magnitud pura (no toca fase) → deja "huecos" espectrales → musical noise / soplido residual.

**Solución:** DPDFNet4 (repo: `github.com/ceva-ip/DPDFNet`, paper arXiv:2512.16420):
- Usa **Deep Filtering** (predice filtros FIR por banda, no máscaras) → reconstruye sin huecos espectrales → sin soplido
- 16 kHz nativo, causal, streaming
- ONNX ya exportado (11.6 MB)
- Win=320, hop=160, freq_bins=161, state=52592 floats
- PESQ ~3.1 vs ~2.87 del GTCRN
- MIT license

**Validación offline:**
- Descargado el modelo de Hugging Face (`Ceva-IP/DPDFNet`)
- Probado con Python (`inferir_simple.py`) sobre los WAVs reales del diagnóstico:
  - `diag_test_20260708_213700.wav` (solo ruido de calle) → salió **limpio sin soplido**
  - `ab_bypass_20260708_213805.wav` (con voces) → limpió sin perder voces (volumen más bajo, normal — la cadena posterior amplifica)

**Integración:**
- El `dnn_denoiser.cpp` de build-84 **ya estaba adaptado** a DPDFNet4 (win=320, hop=160, DFT directa N=320, state [52592])
- Solo se reemplazó el archivo asset `dnn_denoiser/gtcrn.onnx` por `dpdfnet4.onnx` (renombrado a `gtcrn.onnx` para mantener compatibilidad de path)
- APK compilado desde Pro4 (build-84 + modelo nuevo)

### 3. Histéresis de cambio de escena (anti-chasquido)

**Problema:** en el subte, el clasificador oscila rápido entre escenas (VOICE_IN_NOISE ↔ NOISE) → los targets del WDRC cambian cada ~5 ms → la rampa no converge → chasquido "emisora mal sintonizada".

**Solución:** agregado **dwell time de 2 segundos** (`kSceneDwellBlocks = 375`) en `dsp_pipeline.cpp`:
- La nueva escena debe sostenerse 2 s consecutivos antes de aplicarse
- Si oscila antes del dwell, se ignora (se mantiene la escena anterior)
- Basado en Phonak AutoSense (~3-5 s) y Oticon (PMC4111442)
- Variables nuevas en `dsp_pipeline.h`: `currentAppliedScene_`, `pendingScene_`, `pendingSceneCounter_`

### 4. Mejoras MVDR (de sesiones previas, validadas en Octave)

- **SGJMAP** reemplazó al Wiener DD como post-filtro (preserva 3× más onsets: 30.9% vs 10.5%)
- **Steering endfire 90°** (vs broadside 0° que daba solo 3.78 dB)
- **Loading adaptativo** (trace(Rnn)/2, WNG max 1.98 → 0.67)
- **Noise-only interno** (sin dependencia del VAD pegado, updates-durante-voz 58 → 0)
- **Dereverb suavizado** (over 1.1, floor 0.40, gainSmooth 0.60)
- **MPO soft-knee 12 dB** (vs 6 dB que no capturaba el exceso de 7 dB)

### 5. OpenMHA instalado

- Descargado OpenMHA v4.18.1 para Windows x64 en `Repo Oir Pro4\openmha-4.18.1-windows-x64\`
- Configuración `.cfg` creada para simular el pipeline Oir Pro (EQ + WDRC + MPO)
- Pendiente: usar para validación offline de los WAVs del dispositivo

### Archivos modificados/creados en Pro4

| Archivo | Cambio |
|---------|--------|
| `android/app/src/main/assets/dnn_denoiser/gtcrn.onnx` | Reemplazado por DPDFNet4 (11.6 MB) |
| `android/app/src/main/cpp/dsp_pipeline.cpp` | Histéresis de escena (dwell 2 s) |
| `android/app/src/main/cpp/dsp_pipeline.h` | Variables de histéresis + constante `kSceneDwellBlocks` |
| `build_apk_mvdr_fix.bat` | Corregido path a Pro4 |
| `install_apk_mvdr_fix.bat` | Corregido path a Pro4 |

### Herramientas de análisis creadas (Octave, en Repo Oir Pro2\Octave Kiro IDE\ANALISIS_MVDR\)

- `simular_eco.m` + `correr_eco.bat` — diagnóstico del eco/soplido (H1/H2/H3)
- `medir_nivel_mvdr_vs_bypass.m` + `correr_medicion_nivel.bat` — onset preservation
- `mvdr_run_sgjmap.m` + `medir_sgjmap.m` + `correr_sgjmap.bat` — validación SGJMAP
- `analisis_mvdr.m` / `analisis_mvdr_fix.m` — simulación completa MVDR pre/post fixes

### Herramienta de prueba DPDFNet (Python, en Repo Oir Pro4\DPDFNet\)

- `inferir_simple.py` — procesa WAV con DPDFNet4 ONNX (streaming frame-by-frame)
- `procesar_bypass.bat` — extrae canal izquierdo y procesa
- `correr_inferencia.bat` — wrapper rápido

### Estado pendiente

- **Probar DPDFNet4 en el dispositivo** (APK compilado, falta instalar y escuchar)
- Verificar que el modelo carga bien en Android (compatibilidad ONNX input shapes)
- Si funciona: pushear a `main` el modelo nuevo + histéresis
- Evaluar si `intensity` DNN necesita ajuste con el nuevo modelo
- Prueba en subte para verificar que la histéresis eliminó los chasquidos

### Repos y rutas

- Pro4: `C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro4\Audifon` (build-84 + cambios)
- DPDFNet: `C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro4\DPDFNet` (repo clonado)
- OpenMHA: `C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro4\openmha-4.18.1-windows-x64\`
- WAVs diagnóstico: `C:\Users\Elsa y Henry\Desktop\Amplificador\wavs_diagnostico\`
- Octave análisis: `C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro2\Octave Kiro IDE\ANALISIS_MVDR\`


---

## Sesión 6 (continuación) — Modelo Auditivo (AuditoryModel)

### Investigación científica (MCP Brave)

#### Etapa 1 — Resonancia del canal auditivo (2700 Hz, +12 dB)
- **Hearing Review** (The Acoustics of Hearing Aids): "the first mode of a standing wave... is associated with the **2700 Hz real-ear unaided response (REUR)**"
- **PMC4432547**: "average resonance frequency of **2700 Hz with amplitude of 16.8 dB**" (compilación de estudios sobre resonancia del oído externo)
- Implementación: filtro peaking EQ a 2700 Hz, +12 dB (conservador vs los 16.8 medidos), Q=1.5

#### Etapa 2 — Transferencia del oído medio (400-4000 Hz, +3 dB)
- El oído medio (tímpano + cadena osicular) actúa como un bandpass mecánico con pico ~1-3 kHz
- La ganancia del oído medio es ~20-25 dB (transformador de impedancia aire→líquido) pero ya está implícita en la calibración SPL; lo que modelamos es el **shape** del filtro (bandpass)
- +3 dB es la atenuación relativa fuera de banda

#### Etapa 3 — Banco de filtros gammatone (membrana basilar)
- **Glasberg & Moore (1990)**: ERB(f) = 24.7 × (4.37 × f/1000 + 1)
- Fuente: PubMed (PMID: 6630731), Wikipedia (Equivalent Rectangular Bandwidth), CCRMA Stanford
- CalcSimpler confirma la fórmula exacta
- Implementación: 12 filtros gammatone 4to orden (cascada de 4 biquads) centrados en las frecuencias del audiograma
- Referencia C++: `github.com/mmmaat/libgammatone` (MIT license)
- **IEEE 2015** (7338847): "realtime and efficient digital implementation of Gammatone filterbank"

#### Etapa 4 — Compresor OHC (células ciliadas externas)
- **Moore (2003)**: Loudness recruitment — las OHC dañadas pierden compresión → reclutamiento
- **ResearchGate** (Digital implementation of linear gammatone filters): "The amplitude of the analysis filter outputs is modified by **outer hair-cell dynamic-range compression** and inner-hair cell firing-rate adaptation"
- Compensación: si HL alto → las OHC no comprimen → aplicamos expansión compensatoria
- Parámetros: knee 30 dB SPL (umbral de OHC normales), attack 5 ms, release 50-200 ms

#### Etapa 5 — Transducción IHC (células ciliadas internas)
- **Zilany, Bruce & Carney (2014)**: "Updated parameters and expanded simulation options for a model of the auditory periphery" (JASA 136(1))
- Universidad de Rochester, Carney Lab: modelo de referencia del nervio auditivo
- IHC: rectificación media onda → LP 1 kHz (adaptación temporal) → compresión logarítmica suave
- Simula la conversión mecánica→eléctrica de la cóclea

#### Etapa 6 — Realce temporal del nervio auditivo
- **Lyon (2024)**: CARFAC v2 (arXiv:2404.17490) — modelo coclear con detección de envolvente y modulación
- El nervio auditivo tiene phase-locking que se degrada con la pérdida auditiva
- Compensación: detectar envolvente (LP 50 Hz), amplificar modulaciones ×1.5
- Mejora inteligibilidad en ruido (las fluctuaciones temporales del habla son más perceptibles)

#### Referencia general
- **Dillon (2012)**: Hearing Aids, Chapter 6 — fundamentos de compresión y modelo auditivo en audífonos

### Plan de implementación

| Componente | Archivo | Acción |
|------------|---------|--------|
| Módulo C++ | `auditory_model.h` | Header-only, 6 etapas, patrón existente |
| Pipeline | `dsp_pipeline.h/cpp` | Insertar después de EQ, antes de WDRC |
| JNI | `native_bridge.cpp` | `nativeSetAuditoryModelEnabled` + `Audiogram` |
| Kotlin | `NativeAudioBridge.kt` + `AudioMethodChannel.kt` | Wiring |
| Dart bridge | `audio_bridge.dart` + `audio_bridge_impl.dart` | Métodos |
| UI | `main_screen.dart` | Card toggle con Icons.hearing |

### Constantes del modelo
```
Ear canal:      2700 Hz, +12 dB, Q=1.5
Middle ear:     BP 400-4000 Hz, +3 dB
Gammatone:      order 4, 12 bandas, ERB = 24.7*(4.37*f/1000+1)
OHC:            knee 30 dB SPL, attack 5ms, release 50-200ms
IHC:            LP cutoff 1000 Hz, half-wave rectification
AN:             modulation gain 1.5, envelope LP 50 Hz
SPL offset:     93 dB (calibración del pipeline)
```

### Estado
- Investigación: ✅ completada
- Implementación: ✅ completada (auditory_model.h + toggle en UI + wiring JNI/Dart)


---

## Sesión 7 — 13 julio 2026

### Objetivo
Estabilización del repositorio, limpieza de deuda técnica, CI profesional, y auditoría completa del sistema.

### 1. Estabilización del repositorio (PR #23 — mergeado)

**Problema:** El repo tenía 8800 archivos en un solo commit, incluyendo 60+ MB de artefactos de build que no deberían estar versionados (.gradle/, .cxx/, .dart_tool/, .o, .dill).

**Solución:**
- `.gitignore` expandido de 1 línea a 80+ (cubre Flutter, Gradle, NDK, IDE, Python, Node)
- 120 archivos eliminados del tracking (`.dart_tool/`, `android/.gradle/`, `android/app/.cxx/`, `.flutter-plugins*`, `test_hive_temp/`)
- `.gitattributes` creado para binarios grandes
- `docs/LARGE_FILES.md` documentando estrategia de manejo de binarios

**Commit:** `ef2c3e3` (merge de PR #23)

### 2. CI Core implementado (PR #23)

**Nuevo workflow `.github/workflows/ci-core.yml`:**
- Se ejecuta en toda PR y push a main
- 3 jobs: análisis estático + 94 unit tests + compilación NDK
- Concurrency groups para cancelar runs obsoletos
- El analyze solo falla por errores reales (no warnings)

### 3. Eliminación de código muerto (PR #26)

**10 imports no usados eliminados:**
- `calibration_report_json.dart`, `spectrum_tab.dart`, `adaptive_learning_screen.dart`, `dsp_config_detail_screen.dart`, `main_screen.dart` (4), `simulator_screen.dart`, `spectrum_analyzer_screen.dart`

**8 campos/variables muertos eliminados:**
- `_lastExportPath`, `_isAlreadyCalibrated`, `_calibrationChecked`, `outputLevel`, `splMedido`, `peak`, `channel` (MethodChannel sin uso), `_unused`

**Anotación inválida corregida:**
- `@visibleForTesting` en clase privada `_ServiceCodeGateState`

### 4. WAV fixtures para DSP Quality CI (PR #26)

**5 pares de WAVs sintéticos generados (16 kHz mono, 3s):**

| Archivo | Ruido | SNR |
|---------|-------|-----|
| `voice_white_5dB` | Blanco gaussiano | 5 dB |
| `voice_white_10dB` | Blanco gaussiano | 10 dB |
| `voice_pink_5dB` | Rosa (1/f) | 5 dB |
| `voice_babble_0dB` | Babble (6 hablantes) | 0 dB |
| `voice_babble_5dB` | Babble (6 hablantes) | 5 dB |

- Ubicación: `test/fixtures/dnn_eval/clean/` y `test/fixtures/dnn_eval/noisy/`
- El workflow `dsp-quality.yml` ahora encuentra los fixtures y corre (antes skipeaba)
- Script reproducible: `scripts/generate_eval_fixtures.py`

### 5. Fix del CI analyze (PR #26)

**Problema:** `flutter analyze --no-fatal-warnings` tiene un bug en Flutter <3.22 que retorna exit code 1 con warnings.

**Solución:** Reemplazado por grep manual que solo busca la palabra "error" en el output. Warnings no bloquean.

### 6. Script de sincronización técnico → usuario (PR #26)

**Archivo:** `scripts/sync_to_usuario.bat`

**Sincroniza:**
- C++ DSP completo (pipeline, DNN, MVDR, beamformer, etc.)
- Modelos DNN (ONNX/PT)
- Librerías nativas (.so)
- Domain layer Dart (entities, prescriber, presets)
- Audio bridge + adaptive learning service
- Scene engine + DNN controller

**NO sincroniza (técnico-only):**
- Pantallas de calibración/audiometría/servicio técnico
- `lib/calibration_spectrum/`, `lib/biological_calibration/`, `lib/mic_calibration/`
- Herramientas de diagnóstico, AI chat, bundle export

**Uso:**
```batch
cd C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro4\Audifon
scripts\sync_to_usuario.bat
```

### 7. Agente `audifon-expert` creado

Agente personalizado en `.kiro/agents/audifon-expert.md` con conocimiento completo del sistema:
- Pipeline DSP (HPF→TNR→NR→Expansor→SCE→EQ→[AuditoryModel|WDRC]→Volume→FBS→OC→MPO)
- Flutter app (BLoC, screens, bridges, domain)
- AI backend (Hermes v2.0.0, 6 módulos)
- CI/CD (8 workflows)
- 94 tests (property-based, unit, integration, regression)
- Constantes clave (DNN win=320/hop=160, ERB 12 bandas, dwell 2s)

### 8. Auditoría completa del sistema — Estado real validado

| Feature | Estado |
|---------|--------|
| Pipeline DSP completo (14 módulos) | ✅ Implementado |
| DPDFNet4 (reemplaza GTCRN) | ✅ Funcionando en Moto G32 |
| Modelo Auditivo (12 bandas ERB) | ✅ Implementado + toggle |
| MVDR Beamformer (SGJMAP) | ✅ Implementado |
| Histéresis de escena (2s dwell) | ✅ Implementado |
| 20 detecciones de audio | ✅ Implementado |
| 5 reglas clínicas | ✅ Implementado |
| Hermes v2.0.0 en VPS | ✅ Corriendo (aiEnabled: true) |
| Audio routing + mic selector | ✅ Implementado |
| Smart Scene | ✅ Implementado |
| Adaptive Feedback Canceller | ✅ Implementado |
| Calibración espectro (ISO 17025) | ✅ Implementado |
| Audiometría biológica (Hughson-Westlake) | ✅ Implementado |
| Diagnóstico unificado (13 tests) | ✅ Modularizado (20 archivos) |
| CI Core (analyze + tests + NDK) | ✅ Funcionando |
| DSP Quality CI (PESQ+STOI) | ✅ Fixtures listos, passthrough mode |

### Commits de esta sesión

| Commit | Mensaje |
|--------|---------|
| `ef2c3e3` | Merge PR #23: repo stabilization |
| `e059338` | chore: remove dead code and unused imports |
| `1bf8e4c` | fix: add WAV fixtures for DSP CI + fix analyze |
| `cd06e3a` | feat: add sync script técnico → usuario |

### PRs

| PR | Estado | Contenido |
|----|--------|-----------|
| [#23](https://github.com/HenrySali/Audifon/pull/23) | ✅ Mergeado | Repo stabilization |
| [#24](https://github.com/HenrySali/Audifon/pull/24) | Superseded by #26 | Analyze warnings (// ignore) |
| [#25](https://github.com/HenrySali/Audifon/pull/25) | ❌ Cerrar | Binarios removidos sin release (falló CI) |
| [#26](https://github.com/HenrySali/Audifon/pull/26) | Pendiente merge | Dead code + WAV fixtures + CI fix + sync script |

### Pendiente para próxima sesión
- Mergear PR #26 y cerrar PR #24 y #25
- Implementar batch + cache de OpenAI (reducir llamadas de 50+/día a 1-2)
- Reemplazar WAVs sintéticos por grabaciones reales del Moto G32 (vía `adb pull`)
- Ejecutar `scripts\sync_to_usuario.bat` para sincronizar app usuario
- Crear el GitHub Release `v1.0-binaries` cuando se quiera sacar binarios del repo
- Evaluar implementación del spec `oir-pro-patient-mode` (bundle JSON firmado por WhatsApp)

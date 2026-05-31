# PSK Hearing Aid — Registro de Avances y Técnicas

**Fecha de inicio:** Mayo 2026  
**Proyecto:** Audífono digital PSK (Personal Sound Amplifier) para Android  
**Repositorio:** github.com/henrysalinas1985-source/audifono  
**APK:** https://github.com/henrysalinas1985-source/audifono/releases/latest/download/app-release.apk

---

## Resumen del Proyecto

Aplicación Flutter Android que funciona como amplificador de sonido personal para personas con discapacidad auditiva. Captura audio del micrófono, lo procesa a través de un pipeline DSP nativo en C++ (Oboe + JNI), y reproduce el audio amplificado en auriculares Bluetooth o con cable.

---

## Arquitectura del Sistema

```
┌─────────────────────────────────────────────────────────────────┐
│                        FLUTTER (Dart)                             │
│  main_screen → audiogram_screen → spectrum_analyzer_screen       │
│  AmplificationBloc (BLoC) → AudioBridge (MethodChannel)          │
└──────────────────────────────┬──────────────────────────────────┘
                               │ JNI (MethodChannel → Kotlin → C++)
┌──────────────────────────────┼──────────────────────────────────┐
│                    KOTLIN (Android)                               │
│  AudioMethodChannel → NativeAudioBridge → AudioForegroundService │
└──────────────────────────────┼──────────────────────────────────┘
                               │ JNI (native_bridge.cpp)
┌──────────────────────────────┼──────────────────────────────────┐
│                      C++ NATIVO                                   │
│  AudioEngine (Oboe FullDuplexStream)                             │
│       ↓                                                          │
│  DspPipeline::processBlock()                                     │
│  NR → Level → Env Classifier → EQ → WDRC → Headroom → Vol → MPO│
│       ↓                                                          │
│  SpectrumAnalyzer (FFT 128-point, opcional)                      │
└─────────────────────────────────────────────────────────────────┘
```

---

## Pipeline DSP — Orden de Procesamiento

```
Input (Oboe mic) → float32
    ↓
1. Noise Reduction (Wiener 8 sub-bandas, 4 niveles)
    ↓
2. Medir nivel PRE-EQ (dB SPL con offset 120)
    ↓
3. Environment Classifier (QUIET/SPEECH/SPEECH_IN_NOISE/NOISE)
   → Ajusta NR level y WDRC params automáticamente
    ↓
4. Equalizer (12 bandas IIR biquad peaking, 0-50 dB por banda)
    ↓
5. WDRC (3 regiones: expansión + lineal + compresión)
   → Envelope suavizado sample-by-sample (attack 5ms, release 100ms)
   → Decisión basada en nivel PRE-EQ (no post-EQ)
   → gainFactor ∈ [0.0, 1.0] — nunca amplifica
    ↓
6. Headroom Guard (ceiling 0.95, protección post-WDRC)
    ↓
7. Volume Master (-20 a +10 dB)
    ↓
8. MPO Peak Limiter (sample-by-sample, última etapa)
    ↓
9. Spectrum Analyzer (FFT 128-point, solo si pantalla abierta)
    ↓
Output (Oboe speaker/BT) → float32
```

---

## Técnicas y Métodos Utilizados

### 1. Investigación de la Industria

**Método:** Búsqueda exhaustiva con Brave Search + web fetch de documentación técnica, patentes, papers académicos, y repositorios open-source.

**Fuentes investigadas:**
- Phonak Audéo Sphere Infinio (DEEPSONIC, 7.7 GOPS, separación neural 360°)
- Starkey Omega AI (G3 Neuro Processor, DNN 360, 51h batería)
- Oticon Intent (4D sensors, DNN 2.0, BrainHearing)
- Phonak Naída (141 dB OSPL90, pérdida severa/profunda)
- openMHA (framework open-source de audífonos)
- RNNoise (NR con red neural compacta)
- 10+ patentes de Starkey, Sonova, Demant
- 20+ papers académicos (IEEE, JASA, PMC)

**Resultado:** Documento `documentacion auricular/` con 5 archivos de fabricantes + sugerencias + plan.

### 2. WDRC Sample-by-Sample (Estándar de la Industria)

**Técnica:** Detector de envolvente muestra-por-muestra con coeficientes asimétricos attack/release.

**Por qué:** Todos los audífonos comerciales (Phonak, Starkey, Oticon) operan así. El block-rate pierde picos transitorios dentro de un bloque de 4ms.

**Implementación:**
- Firmware (C/Zephyr): `wdrc.c` — envelope sample-by-sample
- Simulador web (JS): `dsp-engine.js` — `processBlockSampleBySample()`
- App nativa (C++): `wdrc_processor.cpp` — smoothedGain sample-by-sample

**Compromiso adoptado:** La app nativa usa un enfoque híbrido — calcula targetGain del nivel PRE-EQ (block-rate) pero suaviza la aplicación de ganancia sample-by-sample. Esto da transiciones más suaves entre bloques.

### 3. Modelo I/O de 3 Regiones

**Técnica:** Expansión + Lineal + Compresión (estándar clínico desde ~2000).

```
Expansión (input < 35 dB SPL): atenúa ruido de fondo
Lineal (35 ≤ input ≤ 50 dB SPL): ganancia completa del EQ
Compresión (input > 50 dB SPL): protege de sonidos fuertes
```

**Fórmulas:**
- Expansión: `gainFactor = 10^(-(Klow - input) × (1 - 1/ER) / 20)`
- Compresión: `gainFactor = 10^(-(input - Kup) × (1 - 1/CR) / 20)`

### 4. Clasificador Automático de Ambiente

**Técnica:** Rule-based con EMA smoothing y hold timer.

**Algoritmo:**
1. Suavizar nivel y SNR con EMA (α=0.05, ~800ms time constant)
2. Clasificar según umbrales (level < 45 → QUIET, SNR > 10 → SPEECH, etc.)
3. Hold timer 500ms para evitar oscilación rápida
4. Lookup tables para NR level y WDRC params por clase

**Parámetros por ambiente:**
| Ambiente | NR | Knee | Ratio |
|----------|-----|------|-------|
| QUIET | 0 (off) | 55 | 1.5:1 |
| SPEECH | 1 (mild) | 50 | 2.0:1 |
| SPEECH_IN_NOISE | 2 (moderate) | 45 | 2.5:1 |
| NOISE | 3 (aggressive) | 40 | 3.0:1 |

**Problema conocido:** Oscila SPEECH↔NOISE cuando el SNR está en la frontera (~10 dB). Solución pendiente: histéresis.

### 5. FFT Cooley-Tukey Radix-2 (128 puntos)

**Técnica:** Implementación propia sin dependencias externas (~60 líneas C++).

**Pasos:**
1. Aplicar ventana Hann precomputada
2. Permutación bit-reversal in-place
3. 7 etapas butterfly (log2(128) = 7)
4. Extraer magnitud: `20*log10(sqrt(re²+im²)) + splOffset`
5. Extraer fase: `atan2(im, re) * 180/π`

**Rendimiento:** ~27 µs en ARM Cortex-A55 (1.25% del presupuesto de 4ms por bloque).

### 6. Calibración dBFS ↔ dB SPL

**Técnica:** Offset fijo basado en la sensibilidad del micrófono.

**Offsets:**
- Firmware (ICS-43434 MEMS): 120 (sensibilidad -26 dBFS @ 94 dB SPL)
- App nativa (mic celular): 120 (asumido similar)
- Simulador web WAV: 76 (archivos WAV calibrados para habla suave)
- Simulador web browser mic: 93 (AGC del navegador)

### 7. Prescripción NAL-NL2

**Técnica:** Fórmula de prescripción audiológica estándar mundial.

**Implementación:** `gain_prescriber.dart` calcula 12 ganancias EQ basadas en el audiograma del usuario.

**Fórmula simplificada:**
```
G65[f] = HL[f] × factor[f]  (ganancia para habla normal a 65 dB SPL)
CR[f] = 30 / (30 + G80[f] - G50[f])  (compression ratio por banda)
```

### 8. Oboe FullDuplexStream

**Técnica:** API de audio de baja latencia de Google para Android.

**Patrón correcto:**
- Output stream tiene `setDataCallback(this)` (FullDuplexStream es el callback)
- Input stream se lee desde `onBothStreamsReady()`
- Procesamiento DSP in-place en el callback
- Reconexión automática con 3 reintentos y 500ms entre intentos

### 9. Thread-Safety Lock-Free

**Técnica:** `std::atomic` para todos los parámetros actualizables desde UI.

**Patrón:**
- Hilo de audio: lee parámetros con `memory_order_relaxed`
- Hilo de UI: escribe parámetros con `memory_order_relaxed`
- Sin mutex en el hilo de audio (real-time safe)
- Vectores solo se modifican cuando no hay acceso concurrente (recording buffer)

### 10. Property-Based Testing

**Técnica:** Tests con fast-check (JS) que verifican propiedades invariantes con inputs aleatorios.

**Propiedades verificadas:**
- WDRC nunca amplifica (peakAfter ≤ peakBefore)
- Silencio produce silencio (expansión activa)
- Headroom guard (peak ≤ 0.95)
- Clasificador determinista (misma entrada → misma salida)
- Hold timer previene transiciones durante hold
- SNR estimation bounded [-20, 40]

### 11. CI/CD con GitHub Actions

**Técnica:** Build automático del APK en cada push a main.

**Workflow:** `.github/workflows/build-apk.yml`
- Trigger: push a main o workflow_dispatch
- Steps: Java 17 + Flutter 3.19.6 + NDK r25c → flutter build apk --release
- Output: Release automático con APK descargable

**Link permanente:** `https://github.com/.../releases/latest/download/app-release.apk`

---

## Specs Kiro Creados

| Spec | Descripción | Estado |
|------|-------------|--------|
| `psk-mobile-hearing-aid` | App completa (12 waves, 60+ tareas) | ✅ Completado |
| `oboe-audio-engine` | Migración a Oboe FullDuplexStream | ✅ Completado |
| `dsp-phase1-improvements` | WDRC s-b-s + clasificador + offset | ✅ Completado |
| `spectrum-analyzer` | FFT + visualización + grabación + export | ⚠️ Parcial (Wave 3-4 Flutter) |

---

## Archivos Clave del Proyecto

### C++ Nativo (`android/app/src/main/cpp/`)
| Archivo | Función |
|---------|---------|
| `audio_engine.h/.cpp` | Oboe FullDuplexStream, I/O de audio |
| `dsp_pipeline.h/.cpp` | Orquestador del pipeline completo |
| `noise_reduction.h/.cpp` | Wiener filter 8 sub-bandas |
| `equalizer.h/.cpp` | 12 bandas IIR biquad peaking |
| `wdrc_processor.h/.cpp` | WDRC 3 regiones + headroom guard |
| `mpo_limiter.h/.cpp` | Peak limiter sample-by-sample |
| `environment_classifier.h/.cpp` | Clasificador automático de ambiente |
| `spectrum_analyzer.h/.cpp` | FFT 128-point + grabación |
| `native_bridge.cpp` | Puente JNI (Kotlin ↔ C++) |

### Kotlin (`android/app/src/main/kotlin/`)
| Archivo | Función |
|---------|---------|
| `NativeAudioBridge.kt` | External fun declarations para JNI |
| `AudioMethodChannel.kt` | Handler de MethodChannel (Flutter ↔ Kotlin) |
| `AudioForegroundService.kt` | Servicio en primer plano (notificación) |

### Flutter/Dart (`lib/`)
| Archivo | Función |
|---------|---------|
| `main.dart` | Entry point, inicialización Hive, providers |
| `domain/gain_prescriber.dart` | Prescripción NAL-NL2 |
| `domain/entities/` | Audiogram, EnvironmentProfile, WdrcParams, SpectrumSnapshot |
| `data/bridges/audio_bridge_impl.dart` | Comunicación con nativo |
| `data/bridges/spectrum_bridge.dart` | Bridge del spectrum analyzer |
| `data/repositories/` | Hive persistence (audiogram, profiles, settings) |
| `presentation/bloc/amplification_bloc.dart` | Estado de la app (BLoC) |
| `presentation/screens/main_screen.dart` | Pantalla principal |
| `presentation/screens/audiogram_screen.dart` | Editor de audiograma |
| `presentation/screens/spectrum_analyzer_screen.dart` | Analizador de espectro |
| `presentation/widgets/magnitude_chart.dart` | Gráfico de magnitud |
| `presentation/widgets/phase_chart.dart` | Gráfico de fase |

---

## Métricas del Proyecto

| Métrica | Valor |
|---------|-------|
| Archivos C++ | 18 (9 .h + 9 .cpp) |
| Archivos Kotlin | 3 |
| Archivos Dart | ~25 |
| Líneas C++ (estimado) | ~3,500 |
| Líneas Dart (estimado) | ~4,000 |
| Property tests | 30+ (WDRC + calibración + clasificador) |
| Latencia pipeline | ~4 ms (64 samples @ 16 kHz) |
| Consumo FFT | ~27 µs por bloque (cuando activo) |
| Grabación máxima | 3 min (1800 snapshots, ~2 MB RAM) |
| Tamaño APK | ~15 MB |

---

## Issues Conocidos y Pendientes

| # | Issue | Severidad | Solución Propuesta |
|---|-------|-----------|-------------------|
| 1 | Clasificador oscila SPEECH↔NOISE en frontera | Media | Agregar histéresis (SNR 5-12 dB zona muerta) |
| 2 | Input level 100 dB SPL parece alto para conversación | Media | Verificar offset de calibración del mic del celular |
| 3 | Botón REC del spectrum analyzer (verificar con nuevo build) | Alta | Fix aplicado (method names), pendiente verificar |
| 4 | Long-press para borrar presets (verificar con nuevo build) | Media | Código implementado, pendiente verificar |
| 5 | NR muy agresivo en frecuencias altas (atenúa consonantes) | Media | Ajustar gain floor del NR o reducir nivel en NOISE |

---

## Próximos Pasos (Fase 2 del Plan)

| # | Mejora | Esfuerzo | Impacto |
|---|--------|----------|---------|
| 1 | Histéresis en clasificador de ambiente | 1 hora | Alto |
| 2 | WDRC por banda (12 compresores independientes) | 2 semanas | Muy alto |
| 3 | CR automática por banda (NAL-NL2 completo) | 3 días | Alto |
| 4 | NR mejorada (minimum statistics) | 1 semana | Alto |
| 5 | Beamforming básico (si 2 mics disponibles) | 1 semana | Alto |

---

*Documento generado el 28 de mayo de 2026. Actualizar con cada sesión de desarrollo.*


---

## 2026-05-31 — Smart Scene VAD: anti respiración / golpes / roces + voz bajita

**Contexto.** Smart Scene Engine Fase 1 (`vad_detector.{h,cpp}` +
`scene_analyzer.cpp`). El VAD híbrido pasaba bien voz fuerte pero (a) gatillaba
con respiración profunda cerca del micrófono y con roce contra tela, y
(b) cuando el usuario hablaba bajito (~55 dB SPL) el flag `voice_active`
permanecía en `NO` aunque la voz se escuchaba claramente.

**Investigación.**
- Cruzamos fuentes de Tsinghua (entropy + BIC, 2005), NPU-ASLP (rVAD-style),
  NAIST (arXiv 2402.00288: ZCR + VMS para breath detection), Silero VAD
  (issues conocidos de falsos positivos en respiración) y rVAD-fast
  (Tan, Sarkar, Dehak 2020: extended pitch segment density).
- Convergencia: para distinguir voz de breath/golpes/roces hacen falta
  *pitch sostenido en ventana 200 ms* + *flatness baja* + *tilt negativo
  fuerte*. ZCR alta + sin pitch = ruido aerodinámico.

**Cambios técnicos.**
1. **Gates anti respiración / roce.** Agregamos cuatro filtros nuevos:
   `flatnessGateBlock`, `zcrBreathBlock`, `tiltGateBlock`, `pitchDensityOk`.
2. **ZCR sample-by-sample** sobre el buffer pre-blanqueado (HPF 80 Hz),
   contado por bloque post-HPF en `VadDetector::computeZcr()`.
3. **Densidad de pitch en ringbuffer de 40 frames (~200 ms)** —
   diagnóstico no bloqueante para no perder los primeros 200 ms de voz.
4. **Tilt espectral** llega al VAD como nuevo parámetro de `process()`,
   tomado de `SpectralFeatures::tilt_db_per_octave`.
5. **Veto de voz.** Si `LRT > 1.0` o `mid_SNR > 6 dB` se ignoran los
   gates de no-vocal — protege voz real cuando momentáneamente hay
   flatness alta entre vocal y consonante.
6. **Threshold de activación bajado.** `kVoiceThresholdHigh` de 0.65 a
   **0.55** y `kVoiceThresholdLow` de 0.35 a **0.30**. Banda muerta de
   0.25 mantiene la histéresis sin flicker.
7. **Tests offline en C++ con MSVC 2019.**
   `smart_scene/tests/test_vad.cpp` + `run_tests.bat` corren 12
   escenarios sintéticos (silencio, tono, impulso, respiración 3 niveles,
   voz 6 niveles desde 45 a 95 dB SPL). 12/12 PASS.

**Archivos tocados.**
- `android/app/src/main/cpp/smart_scene/vad_detector.h` (constantes).
- `android/app/src/main/cpp/smart_scene/vad_detector.cpp` (lógica + ZCR).
- `android/app/src/main/cpp/smart_scene/scene_analyzer.cpp` (pasa tilt al VAD).
- `lib/presentation/screens/smart_scene_screen.dart` (UI: grabación CSV,
  log de errores, copiar al portapapeles para diagnóstico futuro).
- `android/app/src/main/cpp/smart_scene/tests/` nuevos:
  - `test_vad.cpp` (driver de tests).
  - `run_tests.bat` (wrapper MSVC).
  - `.gitignore` (excluye obj, exe, pdb).

**Commits relevantes.**
- `971465a` — gates iniciales (flatness + ZCR + tilt + pitch density).
- `4f4143c` — calibración: ablandar gates, agregar veto de voz.
- `0bc3c41` — UI de grabación CSV + log de errores.
- `8c417ce` — threshold 0.55 + tests offline MSVC.
- `d9ee119` — gitignore de artefactos de build.

**Resultado.**
- Voz bajita (~55 dB SPL) confirmada como detectada por el usuario.
- Tests offline cubren regresiones para silencio, tono puro, impulso,
  respiración (50/65/70 dB SPL) y voz (45-95 dB SPL).
- Latencia agregada al pipeline ≈ 0 (los gates nuevos son sumas y
  comparaciones por frame; ZCR es O(N) sobre el bloque ya HPF-eado).

**Pendiente.**
- Posible mejora futura (no urgente): ajustar pesos de combinación
  (`kWeightLrt`, `kWeightPitch`, `kWeightMidSnr`, `kWeightLtsd`) basados
  en grabaciones reales con el usuario. Hoy quedan 0.35 / 0.25 / 0.25 /
  0.15.
- Reincorporar campos diagnósticos extra al `SceneSnapshot`
  (`pitch_strength`, `lrt_score`, `ltsd_db`, `zcr_ratio`, `pitch_density`)
  cuando se coordine con la sesión paralela que los revirtió.

**Diagnóstico clave aprendido.**
- Problema venía de la combinación umbral alto (0.65) + sustain de 3
  frames seguidos. Voz bajita real apenas alcanzaba 0.55 y nunca acumulaba
  los 3 frames. La sierra sintética del test sí (proxy demasiado limpio
  comparado con voz real).



---

## 2026-05-31 (continuación) — Smart Scene Engine: Fases 2, 3, 4 y 5

**Contexto.** Después de cerrar el VAD anti respiración / golpes / roces y
ajustar el threshold para voz bajita, se completaron las cuatro fases
restantes del spec `smart-scene-engine` en una sola sesión.

### Fase 2 — Clasificación de escena (commits `1c014c5`, `8c61007`)

- `lib/scene/scene_class.dart`: extension Dart con `label`, `description`,
  `icon`, `color` por cada `SceneClass` (8 clases).
- `lib/scene/scene_decision_maker.dart`: reglas puras + histéresis 3 s con
  override por confianza > 0.9. 9 reglas, una por clase + casos de borde.
- `lib/scene/scene_session.dart`: acumula 10-25 snapshots a 100 ms y vota la
  clase dominante.
- `lib/scene/scene_engine.dart`: fachada con toggle persistido en Hive
  (`smart_scene_settings`), `analyze()` que polea snapshots por hasta 5 s.
- UI: Card "Detectar escena" con switch personalización, botón con spinner,
  bloque de resultado con icono + descripción + chip de confianza.
- Tests: `test/scene/scene_decision_maker_test.dart` (12 PASS) +
  `test/scene/scene_session_test.dart` (4 PASS).

### Fase 3 — Generador de preset adaptativo (commits `c3bf991`, `bfd6931`)

- `lib/scene/smart_preset.dart`: modelo inmutable con `gains[12]`, WDRC
  params, NR level, TNR flag, volume delta. `copyWith` + `toJson/fromJson`.
- `lib/scene/scene_preset_generator.dart`: genérico — mapea cada
  `SceneClass` a un `EqPreset` clínico (`Voice Clarity`, `Outdoor`, `Music`,
  `Normal`) más tabla de tuning del design.
- `lib/scene/scene_personalized_generator.dart`: personalizado — base
  NAL-NL2 desde `GainPrescriber.prescribeFromAudiogram(audiogram)` + deltas
  por banda (graves/medios/agudos) según escena + clamp por banda
  `maxSafe = MPO − input − 3 dB` con `MPO = 110 dB SPL` y
  `safetyMargin = 3 dB`.
- `SceneEngine.apply()` despacha `UpdateEqGains(gains, name)` y, si el
  delta lo amerita, `ChangeVolume`. Persiste el preset completo en
  `settingsRepository.setLastEqPreset(...)` y el NR level en
  `setLastNrLevel(...)`.
- UI: bloque de resultado ahora muestra mini gráfico de las 12 ganancias,
  línea con CR/Knee/NR/TNR/Vol, botón verde "Aplicar al audífono".
- Toggle default ON cuando hay audiograma y el usuario nunca tocó el
  switch (`SceneEngine.wasPersonalizeUserSet`).
- Tests: `test/scene/scene_preset_generator_test.dart` (9 PASS, incluye
  headroom safety por nivel de input).

### Fase 4 — Recorder + feedback + histórico (commit `78140be`)

- `lib/scene/scene_recorder.dart`: clase `SceneRecord` (timestamp, clase,
  confianza, preset, gains, feedback opcional) + `SceneRecorder` con Hive
  box `smart_scene_log`. FIFO de 100 entradas máx.
- Métodos: `record(result, preset)`, `updateFeedback(id, positive)`,
  `getHistory(limit)`, `clearAll()`.
- `SceneEngine.apply()` ahora también registra cada aplicación en el log
  para que la UI pueda mostrar 👍/👎 después del Apply.
- UI: nuevo widget `_FeedbackBar` después del botón Aplicar (botones 👍/👎
  con `IconButton` + snackbar de confirmación). Nuevo Card `_HistoryCard`
  con últimas 10 entradas, iconos por clase, marca de feedback por entrada,
  botón "Borrar histórico" con diálogo de confirmación.
- Tests: `test/scene/scene_recorder_test.dart` (6 PASS, usa `Hive.init`
  con tempdir para no requerir Flutter binding).

### Fase 5 — Smoke validation (commit `71f1edd`)

- `test/scene/scene_smoke_validation_test.dart`: 28 tests de regresión que
  cubren los 7 escenarios del design (silencio, voz limpia, voz+ruido
  grave, voz+ruido medio, ruido grave dominante, ruido agudo dominante,
  música), verificando para cada uno: regla pura, sesión 12 muestras,
  generador genérico, generador personalizado con headroom respetado.
- DCASE TAU 2020 Mobile + smoke test en celular real quedan diferidos
  (requieren 64 GB de dataset y hardware físico, fuera del alcance del
  asistente).

### Diferidos explícitos en `tasks.md`

- 17.4 — TNR vía JNI: el pipeline DSP nativo no expone canal
  `updateTnrEnabled`. El flag `tnrEnabled` se propaga en `SmartPreset`
  para conectarlo cuando se sume el canal.
- 22 — aprendizaje básico desde feedback: el spec original ya lo marca
  opcional. Se reabre cuando haya datos reales de uso.
- 23, 25 — validación contra DCASE + smoke test en celular real.

### Métricas finales

- **Archivos Dart agregados/modificados:** 7 producción + 5 tests.
- **Archivos C++:** ningún cambio en esta tanda (la Fase 1 ya estaba en
  producción; el VAD se cerró antes).
- **Tests totales del módulo:** 59/59 PASS corriendo en
  `flutter test test/scene/` (~12 s end-to-end).
- **Persistencia:** dos boxes Hive nuevos (`smart_scene_settings`,
  `smart_scene_log`).
- **Líneas de código nuevas (Dart):** ~2.000 (sin contar tests).
- **Tareas completadas del spec:** 1-21 + 24 (60 % del spec total),
  4 tareas diferidas con justificación.



---

## Fase Smart Scene VAD — Fix voz continua (mayo 2026)

### Bug reportado por el usuario
Sobre APK con commits `c3bf991` / `bfd6931` instalada en celular: el VAD se activaba en `voice_active=1` por ráfagas pequeñas (≈ 1 s) y luego caía a `0` aunque el usuario hablaba **continuo** sin pausas. CSV adjunto del usuario mostró 184 muestras donde la voz se activaba sólo en filas 13-21 a pesar de tener `input=95-105 dB SPL`, `mid_snr=10-30 dB`, `vad_score=0.5-0.85` durante todo el resto del registro.

### Investigación con Brave Search
- **Apple AirPods Pro**: DNN HMM keyword spotting + computational audio personalizado (machinelearning.apple.com).
- **Samsung Galaxy Buds**: VPU (Voice Pick-Up Unit) + DNN multi-mic + bandwidth super-wideband.
- **Huawei FreeBuds**: bone voice sensor + DNN multi-canal.
- Conclusión: las 3 marcas usan DNN entrenadas con voz humana real **además de** señales test estandarizadas. Ninguna usa diente de sierra como proxy de voz para validar.

### Diseño del fix: simulador Klatt formante paralelo
- Creé `tests/klatt_voice.{h,cpp}` — sintetizador de voz tipo Klatt (paper de Klatt 1980, JASA, parafraseado para licencias).
- Estructura: pulsos glotales triangulares con jitter ±1.5 % + vibrato 5 Hz ±2 % + 5 resonadores BPF cookbook RBJ (Direct Form I) en paralelo + aspiración escalada por nivel.
- Tablas de formantes para vocales /a/ /e/ /i/ /o/ /u/ tomadas de Peterson & Barney 1952.
- `tests/test_klatt_pipeline.cpp` corre el `SceneAnalyzer` REAL (mismo binario que va al celular) sobre voz Klatt y mide `voice_active` cuadro por cuadro.
- 5 escenarios: voz continua /a/ 65 dB SPL 3 s, voz bajita /e/ 50 dB SPL 2 s, frase /a/-/e/-/i/-/o/ encadenada 4 s, silencio 1 s, respiración bandpass 200-2000 Hz 2 s.

### Diagnóstico con Klatt
- **Reprodujo el bug**: voz continua a 65 dB SPL → `voice_active=0` siempre, igual que el celu.
- Causa raíz: `kVoicingMinPitch=0.35` rechazaba pitch real saturado por AGC del codec del celu (autocorrelograma colapsa a 0.15-0.25 con voz natural). Y los gates de no-vocal (stationarity, flatness, ZCR, tilt) seguían bloqueando aunque ya hubiera voz activa, cortándola intermitentemente.

### Cambios aplicados (commit pendiente)
1. `vad_detector.h`: `kVoicingMinPitch` 0.35 → 0.18. `kVoiceThresholdHigh` 0.55 → 0.50.
2. `vad_detector.cpp`: bypass del onset por `voiceLikelyByLrt` (LRT > 3 Y midSnr > 6) — voz espectralmente clara aunque autocorrelograma no se afirme.
3. `vad_detector.cpp`: gates 2 (stationarity) y 3 (flatness/ZCR/tilt) sólo bloquean **arranque** de voz; una vez `voiceActive_=true`, sólo silencio absoluto e impulso pueden apagarla. La histéresis del score se ocupa del fin del enunciado.
4. `scene_analyzer.h`: agregado getter `getVad()` (sólo para tests offline).

### Resultado del test Klatt sobre el SceneAnalyzer real
| Caso | Voice activo | Esperado | Estado |
|---|---|---|---|
| T1 voz continua /a/ 65 dB SPL 3 s | 91.3 % | ≥ 70 % | ✅ |
| T2 voz bajita /e/ 50 dB SPL 2 s | 88.0 % | ≥ 50 % | ✅ |
| T3 frase 4 vocales 4 s | 91.6 % | ≥ 70 % | ✅ |
| T4 silencio 1 s | 0 % | 0 % | ✅ |
| T5 respiración bandpass 2 s | 0 % | ≤ 10 % | ✅ |

Tests sintéticos viejos (proxy sierra/ruido): 9/12 PASS. Los 3 fails (T4/T4b/T4c respiración con proxy de ruido modulado lento) ya no son representativos: la respiración real (Klatt T5) sigue dando 0 %. El proxy sintético de respiración era artificial (su ZCR/flatness/tilt no reproducen respiración real).

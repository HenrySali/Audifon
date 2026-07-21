# Audifon — Documentación técnica y funcional

**Aplicación móvil Android de audioprótesis (PSAP) con DSP nativo en tiempo real, IA de asistencia clínica y motor de aprendizaje adaptativo.**

> Nombre comercial: **Oír Pro** (rebranded desde "PSK Mobile Hearing Aid")
> Repositorio: [HenrySali/Audifon](https://github.com/HenrySali/Audifon)
> Versión pubspec: `1.0.0`
> Última actualización de esta documentación: 21 de julio de 2026

---

## Tabla de contenidos

1. [Qué es Audifon](#1-qué-es-audifon)
2. [Arquitectura general](#2-arquitectura-general)
3. [Stack tecnológico](#3-stack-tecnológico)
4. [Pipeline DSP nativo (C++ / Oboe)](#4-pipeline-dsp-nativo-c--oboe)
5. [Denoisers DNN](#5-denoisers-dnn)
6. [Motor de escena inteligente (Smart Scene Engine)](#6-motor-de-escena-inteligente-smart-scene-engine)
7. [Prescripción y modelo audiológico](#7-prescripción-y-modelo-audiológico)
8. [Subsistema de IA (Node.js)](#8-subsistema-de-ia-nodejs)
9. [Backend Hermes (VPS)](#9-backend-hermes-vps)
10. [Pantallas y flujo de usuario (Flutter)](#10-pantallas-y-flujo-de-usuario-flutter)
11. [Simulador web](#11-simulador-web)
12. [Testing y QA](#12-testing-y-qa)
13. [CI/CD y publicación](#13-cicd-y-publicación)
14. [Requerimientos regulatorios](#14-requerimientos-regulatorios)
15. [Cómo compilar](#15-cómo-compilar)
16. [Glosario](#16-glosario)

---

## 1. Qué es Audifon

Audifon es una **aplicación de amplificación auditiva personal (PSAP)** para Android que convierte al smartphone en un audífono digital de nivel profesional. Toma el audio del micrófono del teléfono en tiempo real, lo procesa a través de una cadena DSP completa (reducción de ruido, ecualización por audiograma, compresión multi-banda, protección MPO) y lo entrega inmediatamente a la salida (auriculares, Bluetooth SCO, altavoz).

### Casos de uso

- **Uso personal**: cualquier persona con hipoacusia leve, moderada o severa puede usar el teléfono más un par de auriculares con cable o Bluetooth como audífono funcional.
- **Uso clínico**: fonoaudiólogos y audioprotesistas pueden usar la app para pre-adaptaciones, evaluaciones biológicas de campo, o como puente hasta que el paciente reciba su audífono definitivo.
- **Uso investigativo / educativo**: la app expone diagnósticos DSP profundos (analizador de espectro, calibración de tonos puros, latency loopback, PESQ/STOI) para docencia y desarrollo.

### Diferenciales

- **DSP nativo en C++** con latencia round-trip < 15 ms (Oboe + arm64-v8a).
- **DNN denoiser** integrado con RNNoise (xiph, static-linked, ~90 KB) como motor primario; GTCRN (ONNX) como fallback. DeepFilterNet3 disponible pero desactivado por bug de runtime.
- **Beamforming MVDR** dual-mic con post-filtro SGJMAP.
- **Modelo coclear** de 6 etapas (auditory model) que simula el sistema auditivo humano para compresión biológicamente inspirada.
- **Smart Scene Engine** que clasifica el entorno en 8 clases y aplica presets adaptativos (silencio, voz cercana, ruido de máquinas, música, tráfico, viento, restaurante, cocktail party).
- **IA clínica**: asistente de adaptación NAL-NL2, chatbot con RAG, generación de reportes ANMAT, aprendizaje adaptativo colectivo.

---

## 2. Arquitectura general

```
┌────────────────────────────────────────────────────────────────────────┐
│                          Flutter UI (Dart)                             │
│  25+ pantallas: MainScreen, Calibration, DiagnosticoDsp, SmartScene,   │
│  AiChat, Audiogram, LoopbackQc, TechnicalService, etc.                 │
│  BLoC (AmplificationBloc) · Hive (persistencia) · flutter_blue_plus    │
└──────────────────────────────┬─────────────────────────────────────────┘
                               │ MethodChannel
                               │ com.psk.hearing_aid/audio
┌──────────────────────────────▼─────────────────────────────────────────┐
│                   Native audio engine (Kotlin + C++)                   │
│           NativeAudioBridge.kt  ⇄  native_bridge.cpp (JNI)             │
└──────────────────────────────┬─────────────────────────────────────────┘
                               │
┌──────────────────────────────▼─────────────────────────────────────────┐
│                libhearing_aid_dsp.so  (arm64-v8a)                      │
│                                                                        │
│   AudioEngine (Oboe FullDuplex, 48 kHz)                                │
│      └─▶ DspPipeline: HPF → AFC → NR → SCE → Expander → EQ            │
│                       → [AuditoryModel | WDRC] → Volume → FBS         │
│                       → OC → MPO                                       │
│      ├─▶ Denoiser DNN:  RNNoise (static) / GTCRN (ONNX) / DFN3 (dlopen)│
│      ├─▶ MVDR Beamformer (dual mic, WPE + SGJMAP)                     │
│      ├─▶ Smart Scene Analyzer (VAD + spectral features)                │
│      └─▶ Calibration Spectrum Validator (FFT, THD, tonos puros)        │
└──────────────────────────────┬─────────────────────────────────────────┘
                               │ HTTP REST (JSON)
┌──────────────────────────────▼─────────────────────────────────────────┐
│           AI Layer (Node.js)  —  ejecuta local u en VPS Hermes         │
│   FittingAssistant (NAL-NL2) · Chatbot (RAG) · Diagnostics · Reports   │
│   DevRAG · EnvironmentML  ·  OpenAI gpt-4o-mini / gpt-4o               │
└──────────────────────────────┬─────────────────────────────────────────┘
                               │
┌──────────────────────────────▼─────────────────────────────────────────┐
│    Backend Hermes v2.0.0  (VPS 149.50.137.2:8080, pm2)                 │
│    /api/adaptive-learning/{analyze,feedback,history,sync,insights}     │
└────────────────────────────────────────────────────────────────────────┘
```

### Capas

| Capa | Tecnología | Responsabilidad |
|---|---|---|
| **UI** | Flutter 3.19.6 + Dart + BLoC | Presentación, configuración, diagnósticos, chat clínico |
| **Bridge** | Kotlin + JNI (C++) | Puente Flutter ↔ nativo, permisos, routing de micrófono |
| **Motor de audio** | C++17 + Oboe 1.9.0 | Full-duplex stream, callback en tiempo real |
| **DSP** | C++17 (arm64-v8a) | Cadena de procesamiento por bloque |
| **DNN** | ONNX Runtime 1.16.3 + RNNoise C + PyTorch Mobile 2.1.0 | Inferencia neural en dispositivo |
| **IA** | Node.js ≥18 + OpenAI SDK | Asistencia clínica, chatbot, reportes |
| **Backend** | Node.js + Express + pm2 (VPS) | Aprendizaje adaptativo colectivo |
| **Persistencia** | Hive 2.2.3 (local) | Perfiles, presets, audit trail, session logs |

---

## 3. Stack tecnológico

### Frontend (Flutter)

| Paquete | Versión | Uso |
|---|---|---|
| `flutter` | SDK ≥3.0.0 | Framework base |
| `flutter_bloc` | 8.1.3 | State management |
| `hive` + `hive_flutter` | 2.2.3 / 1.1.0 | Almacenamiento local |
| `flutter_blue_plus` | **pinned 1.35.5** | BT audio pairing (compat AGP 8.3.2) |
| `local_auth` | latest | Biometric gate (huella / rostro) |
| `pdf` | 3.11.3 | Generación de reporte QC ANMAT-compliant |
| `fl_chart` | latest | Analizador de espectro, chart audiométrico |
| `file_picker` | latest | Importación de audiogramas |
| `share_plus` + `path_provider` | latest | BundleExporter (auditoría clínica) |
| `crypto` | latest | HMAC-SHA256 para audit trail ANMAT 2318/02 |
| `glados` | latest | Property-based testing |
| `bloc_test` + `mocktail` | latest | Unit tests |

### Nativo (Android)

| Componente | Versión | Notas |
|---|---|---|
| Android NDK | **25.2.9519653** | Fijo (r25c en CI) |
| CMake | 3.22.1 | Build de `libhearing_aid_dsp.so` |
| C++ std | C++17 | Con `-O3 -ffast-math` en release |
| Target ABI | **arm64-v8a únicamente** | ONNX Runtime + libdfn3 son 64-bit only |
| minSdk | 24 (Android 7.0) | |
| targetSdk / compileSdk | 34 (Android 14) | |
| Oboe | 1.9.0 (Prefab) | Full-duplex audio, low-latency |
| OnnxRuntime | 1.16.3 (SHARED IMPORTED) | Inferencia GTCRN / gtcrn_dual |
| PyTorch Android | 2.1.0 (**full JIT**) | Migrado desde lite por SIGSEGV en shapes dinámicas |
| RNNoise (xiph) | v0.1.1 vendored | Static-linked, ~90 KB de modelo baked-in |
| androidx.core | 1.13.1 forzado | Compat compileSdk 34 |

### AI subsystem (Node.js)

| Componente | Versión | Notas |
|---|---|---|
| Node.js | ≥18 | Módulo `hearing-aid-ai` |
| OpenAI SDK | latest | `gpt-4o-mini` (default) / `gpt-4o` (advanced) |
| Modo local | fallback | Si no hay API key, el sistema degrada graciosamente |

---

## 4. Pipeline DSP nativo (C++ / Oboe)

**Definido en**: `android/app/src/main/cpp/dsp_pipeline.h` + `dsp_pipeline.cpp`.

**Sample rate nativo**: 48 kHz (negociado con Oboe; el DNN denoiser mono resamplea internamente a 16 kHz para GTCRN).
**Frame size**: variable (bursts de Oboe, típicamente 256 samples ≈ 5.3 ms).
**Formato**: `float32` mono `[-1, +1]`.

### Orden canónico de la cadena

```
Input (mic o dual-mic beamforming)
   │
   ▼
[1] High-Pass Filter (100 Hz)          — Elimina rumble sub-audible
   │
   ▼
[2] AFC (Adaptive Feedback Canceller)  — NLMS, cancela realimentación acústica
   │
   ▼
[3] NR / DNN Denoiser                  — Wiener clásico OR RNNoise/GTCRN/DFN3
   │                                     (excluyente por flag setNrBypassed)
   ▼
[4] SCE (Spectral Contrast Enhancer)   — Realce de bordes espectrales
   │
   ▼
[5] Expander (downward)                — Piso de ruido, no comprime señal débil
   │
   ▼
[6] Equalizer 12 bandas                — IIR biquads, ganancia por audiograma
   │
   ▼
[7a] AuditoryModel (6 etapas)          — Alternativa biológica al WDRC
    OR
[7b] WDRC (3-region)                   — Compresión clínica estándar (NAL-NL2)
   │
   ▼
[8] Volume master                      — Control usuario
   │
   ▼
[9] FBS (Feedback Suppressor)          — Notch adaptativo si detecta howl
   │
   ▼
[10] Output Compressor                 — Suavizado final
   │
   ▼
[11] MPO Limiter (110 dB SPL max)      — FDA OTC 21 CFR 800.30 compliant
   │
   ▼
Output (auriculares / BT SCO / speaker)
```

### Módulos nativos (código fuente)

| Archivo | Módulo | Función |
|---|---|---|
| `audio_engine.cpp/.h` | AudioEngine | Full-duplex Oboe, dispatch de motores DNN, mode selector |
| `dsp_pipeline.cpp/.h` | DspPipeline | Chain de 11 stages, ScenePolicy application |
| `noise_reduction.cpp` | NR Wiener | Reducción clásica multi-banda (bypasseada si DNN ON) |
| `transient_reducer.cpp` | TNR | Elimina click/tap/portazos (Phonak SoundRelax 2006) |
| `equalizer.cpp` | Equalizer | 12 bandas IIR configurable |
| `wdrc_processor.cpp` | WDRC | Compresión 3 regiones (linear→compress→limit) |
| `mpo_limiter.cpp` | MPO | Hard limit 110 dB SPL (regulatorio OTC) |
| `environment_classifier.cpp` | EnvClassifier | 4 clases legacy (métricas) |
| `spectrum_analyzer.cpp` | SpectrumAnalyzer | FFT 128 puntos, live display |
| `spectral_contrast_enhancer.cpp` | SCE | Realce de contornos formánticos |
| `expander.cpp` | Expander | Gate downward suave |
| `feedback_suppressor.cpp` | FBS | Notch adaptativo |
| `adaptive_feedback_canceller.cpp` | AFC | NLMS 128 taps |
| `output_compressor.cpp` | OC | Compresor final |
| `auditory_model.cpp` | AuditoryModel | Simulación coclear (Meddis, Zilany, dinámica IHC) |
| `mvdr_beamformer.cpp` | MVDR | Beamformer minimum-variance dual-mic |
| `wpe_beamformer.cpp` | WPE | Weighted Prediction Error (de-reverb) |
| `voice_activity_detector.cpp` | VAD | Multi-feature (pitch, LRT, LTSD, ZCR) |
| `diagnostic_recorder.cpp` | DiagnosticRecorder | Grabación WAV pre/post DSP |
| `latency_loopback_tester.cpp` | LatencyTester | Chirp + cross-correlation |
| `smart_scene/*.cpp` | SceneAnalyzer | 8 clases, hysteresis 2s |
| `calibration_spectrum/*.cpp` | CalibrationValidator | Tonos puros, THD, SNR |

### Parámetros clave

| Constante | Valor | Comentario |
|---|---|---|
| `kSampleRate` | 48000 Hz | Rate nativo Oboe |
| `kMpoDigitalCeiling` | 0.85 | Nunca satura digital antes del MPO |
| `kSceneDwellBlocks` | 375 | ≈ 2 s de anti-oscilación de escena |
| `kHopSize` (DFN3) / `kFrameSize` (RNNoise) | 480 | 10 ms @ 48 kHz |
| `kMpoThresholdDbSpl` | 110 dB SPL | Techo OTC 21 CFR 800.30 |
| `kSplOffset` | 93 dB SPL | Referencia dBFS → dB SPL |

---

## 5. Denoisers DNN

Audifon integra **tres motores de denoising** con dispatch dinámico. El motor activo se elige en `initDnnDenoiser()` según disponibilidad y estabilidad:

### Prioridad de activación

```
1. RNNoise      ✅ ACTIVO (motor primario)  — xiph v0.1.1, static-linked
2. DFN3         ❌ DESACTIVADO             — libdfn3.so SIGABRT en runtime
3. GTCRN        ✅ FALLBACK                — ONNX Runtime, tarde una carga de 2 MB
```

### 5.1 RNNoise (xiph)

- **Motor primario desde julio 2026**.
- **Fuente**: xiph/rnnoise v0.1.1 vendoreado en `android/app/src/main/cpp/rnnoise/` (~572 KB de fuentes C, modelo tiny de ~90 KB compilado en el `.so`).
- **Static-linked** — no requiere `.so` externo, no `dlopen`, no extracción de assets.
- **Ventajas**: 0 crashes por routing (a diferencia de DFN3), 48 kHz nativo, `frame_size` = 480 samples (10 ms).
- **Wrapper**: `rnnoise_denoiser.cpp` — usa **ring buffer per-sample** (`inBuffer_` acumula dry, `outBuffer_` drena wet) para garantizar procesamiento continuo con bursts de Oboe de cualquier tamaño.
- **Uso en producción**: OBS Studio, Mumble, ffmpeg (`arnndn` filter), múltiples prototipos publicados de audífonos.
- **Licencia**: BSD 3-Clause.

### 5.2 DFN3 (DeepFilterNet3)

- **Estado**: **desactivado** por bug de runtime.
- **Fuente**: `libdfn3.so` (Rust + Tract inference) cargado con `dlopen`.
- **Modelos ONNX**: `df_dec.onnx`, `enc.onnx`, `erb_dec.onnx` en `assets/dfn3/`, extraídos a `filesDir` al arrancar.
- **Problema documentado**: `Abort: index out of bounds: the len is 481 but the index is 481` en `libdfn3.so::process_hop`. Tombstone `data_app_native_crash 2026-07-20`. Confirmado en Motorola devon_g.
- **Se mantiene el código** (`dfn3_denoiser.cpp`, workflow `build-dfn3.yml`) para reactivar cuando se recompile el `.so` corregido.

### 5.3 GTCRN (Group Temporal Convolutional Recurrent Network)

- **Estado**: fallback si RNNoise no arranca.
- **Motor**: ONNX Runtime 1.16.3 (compartida vía `jniLibs/arm64-v8a/libonnxruntime.so`).
- **Dos instancias**:
  - Mono legacy: `gtcrn.onnx` — usa resampler polyphase 3:1 interno (48 → 16 kHz).
  - Dual-channel: `gtcrn_dual_core.onnx` + WPE beamformer (activa vía `EnhancementEngineMode::kDualChannelDnn`).
- **Worker thread propio** con SPSC ring buffers — a diferencia de RNNoise que es síncrono.

### 5.4 DPDFNet4 (histórico)

Migración documentada en `SESION.md` sesión 5 → 6:

- **DPDFNet4** = variante custom entrenada sobre DeepFilterNet4, 11.6 MB, licencia MIT.
- **Métricas**: PESQ ≈ 3.1 (vs GTCRN 2.87), STOI ≈ 0.94.
- No está activo en el APK actual (código en `_legacy/`).

---

## 6. Motor de escena inteligente (Smart Scene Engine)

**Ubicación**: `android/app/src/main/cpp/smart_scene/`.

Clasifica el entorno acústico en **8 clases** cada bloque de audio (~5 ms) y aplica un preset DSP unificado (NR + WDRC + TNR + Enhancement + MPO). La tabla se define en `scene_policy.h`.

### Clases

| # | Clase | Preset objetivo |
|---|---|---|
| 0 | UNKNOWN | Arranque, sin decisión |
| 1 | QUIET | Silencio (< 40 dB SPL) — expander agresivo, NR off |
| 2 | SPEECH_NEAR | Voz cercana clara — NR bajo, WDRC lineal |
| 3 | SPEECH_FAR | Voz lejana — NR medio, boost 2-4 kHz |
| 4 | NOISE_STATIONARY | Aire acondicionado, motor — NR alto, DNN ON |
| 5 | NOISE_TRANSIENT | Golpes, tráfico — TNR ON, DNN medio |
| 6 | MUSIC | Música — WDRC lineal, NR mínimo, EQ plano |
| 7 | COCKTAIL | Múltiples voces + ruido — beamforming + DNN dual |

### Features usadas

- **VAD multi-feature** (`voice_activity_detector.cpp`):
  - Pitch strength (autocorrelación normalizada)
  - LRT score (Likelihood Ratio Test)
  - Mid-band SNR (1-3 kHz)
  - LTSD (Long-Term Spectral Divergence)
  - ZCR ratio
  - Stationarity
  - Pitch density
- **Spectral features** (`spectral_features.cpp`): centroide, roll-off, flujo, contraste por sub-banda.
- **Noise profile** (`noise_profile.cpp`): estimación de piso de ruido, tracking Wiener.

### Anti-oscilación (hysteresis)

- **Dwell time**: `kSceneDwellBlocks = 375` bloques (~ 2 s).
- La nueva escena debe sostenerse ≥ 2 s antes de aplicar su preset.
- **Excepción**: transiciones desde `UNKNOWN` (arranque) se aplican inmediatamente.
- **Rationale documentado** en `docs/smart-scene-diagnostico-chasquido.md`: sin dwell, el clasificador oscilaba entre `QUIET` ↔ `SPEECH_NEAR` en las pausas naturales del habla y producía chasquidos audibles.

### Detecciones auxiliares (20)

Documentadas en `SESION.md` sesión 6 — recomendaciones que la app puede sugerir al usuario:

- Eco / reverb, voz baja, saturación EQ, clipping digital, MPO limitando, DNN matando voz, roce de ropa, ganancia asimétrica, música, viento, fatiga acústica, exposición LEQ, ubicación de mic, batería, tap/handshake, sirena/alarma, corriente eléctrica, escucha prolongada, retroalimentación, congestion pipeline.

### Reglas clínicas

5 reglas endurecidas en el pipeline:

1. **Speech Guard** — nunca atenuar más de 3 dB en 1-3 kHz si VAD dice voz.
2. **Volume floor** — piso de 15 dB SPL a la salida.
3. **Protected speech band** — 1-3 kHz protegido de la reducción de NR/DNN.
4. **Cumulative cap -5 dB** — la atenuación acumulada del pipeline no supera -5 dB en las bandas de voz.
5. **Selective reduction** — cuando dos motores atenúan a la vez, se aplica el mínimo (no la suma).

---

## 7. Prescripción y modelo audiológico

**Ubicación**: `lib/domain/`.

### Prescriptores disponibles

| Preset | Módulo | Descripción |
|---|---|---|
| **Smart-NL2** | `gain_prescriber.dart` | NAL-NL2 clásico, tabla de 8 frecuencias × HL 20-80 dB |
| **Smart-NL3** | `gain_prescriber_nl3.dart` | NL2 + CIN adaptativo (Compression for Improved audibility of speech in Noise) |
| **MHL Prescripción** | `mhl_module.dart` | Modo Mild Hearing Loss — ganancia flat 8 dB, compresión 1.0:1 |
| **CIN Module** | `cin_module.dart` | Ajuste dinámico según escena (aumenta compresión en ruido) |

### Audiogram-driven presets

10 estilos de presets (Ley 11.9 de agudización): flat, sloping, high-loss, low-loss, notch-4k, cookie-bite, reverse-slope, ski-slope, moderate-severe, profound.
Cada uno mapeado a **una configuración de EQ + WDRC + MPO** con ceiling de ±5 dB por banda para el audiograma canónico de referencia.

### CIN adaptativo (aclimatación)

Ajusta la ganancia final según **experiencia previa del paciente**:

- Primera vez → -3 dB de aclimatación
- Menos de 6 meses → -2 dB
- 6 a 12 meses → -1 dB
- 1 a 2 años → 0 dB
- Más de 2 años → +0.5 dB (usuarios experimentados toleran más)

### Adaptive Learning

**Servicio en `lib/domain/adaptive_learning.dart` + `lib/services/adaptive_learning_service.dart`.**

Cada interacción del usuario (cambio de volumen, activación de denoiser, preset elegido, tiempo de uso) se envía al backend Hermes vía `deviceId` (16-char hex persistido en Hive). El backend agrega insights colectivos y devuelve sugerencias que la app puede aplicar.

Endpoints:

- `POST /api/adaptive-learning/analyze`
- `POST /api/adaptive-learning/feedback`
- `GET /api/adaptive-learning/history/:deviceId`
- `GET /api/adaptive-learning/collective-insights`
- `POST /api/adaptive-learning/sync`

---

## 8. Subsistema de IA (Node.js)

**Ubicación**: `ai/`.
**Módulo**: `hearing-aid-ai`, Node ≥18.
**Entry point**: `ai/index.js` — `createAISystem({apiKey})` retorna 6 features.

### 8.1 FittingAssistant (`ai/fitting-assistant/`)

Asistente de adaptación NAL-NL2. Recibe:

- Audiograma (AC/BC por frecuencia, oído izq/der)
- Datos del paciente (edad, experiencia, uso, etc.)

Devuelve:

- Ganancias por banda (12 frecuencias)
- Parámetros WDRC (knee, ratio, attack, release)
- MPO recomendado
- Notas clínicas (recomendaciones pediátricas si aplica)

**Límites pediátricos** (en `ai/config.js`):

```javascript
maxMPO: 110 dB SPL
maxGainPerBand: 30 dB
maxTotalGain: 40 dB
minExpansionKnee: 30 dB SPL
maxCompressionRatio: 4.0
```

### 8.2 HearingAidChatbot (`ai/chatbot/`)

Chat clínico usando OpenAI **gpt-4o-mini** (default) o **gpt-4o** (avanzado). Modo local si no hay API key.

Con RAG contra `ai/knowledge-base/` (indexado en `knowledge-index.json`, contenido en `knowledge-content.json`).

Temperature 0.3, maxTokens 2000.

### 8.3 DiagnosticsEngine (`ai/diagnostics/`)

Toma métricas del audit trail (session_logs de la app) y detecta patrones:

- Uso irregular (baja adherencia)
- Volumen usualmente alto (posible progresión de HL)
- Feedback recurrente (mal fitting)
- Preferencia de preset (usuario prefiere uno específico → recomendar como default)

### 8.4 ReportGenerator (`ai/reports/`)

Genera reportes Markdown clínicos conformes a **ANMAT 2318/02** con:

- Datos del paciente
- Audiograma
- Prescripción aplicada
- Historial de uso
- Hash SHA-256 del audit trail
- Firma digital HMAC

### 8.5 DevRAG (`ai/rag/`)

RAG contra el propio código y documentación del proyecto — para asistir a los desarrolladores con "cómo funciona X en este repo".

### 8.6 EnvironmentML (`ai/environment-ml/`)

Clasificador de entorno con **online learning** — ajusta pesos según el feedback del usuario ("estoy en la calle", "esto es música", etc.) para mejorar el Smart Scene Engine.

---

## 9. Backend Hermes (VPS)

**Endpoint**: `http://149.50.137.2:8080` (desplegado en VPS con **pm2**).
**Fuente**: `hermes-server-upgrade/server-patch.js` (v2.0.0).
**Rol**: agregación colectiva de aprendizaje adaptativo, sincronización de perfiles entre dispositivos, insights entre pacientes anonimizados.

**Endpoints REST** (JSON):

- `POST /api/adaptive-learning/analyze` — recibe métricas de sesión, devuelve recomendaciones.
- `POST /api/adaptive-learning/feedback` — recibe feedback explícito del usuario ("mejor así", "peor así").
- `GET /api/adaptive-learning/history/:deviceId` — trae historial del dispositivo.
- `GET /api/adaptive-learning/collective-insights` — patrones agregados de todos los usuarios (anonimizados).
- `POST /api/adaptive-learning/sync` — sincroniza el estado local con el servidor.

---

## 10. Pantallas y flujo de usuario (Flutter)

**Ubicación**: `lib/presentation/screens/`. **Entry point**: `lib/main.dart` (con `BiometricGate` + `RemoteConfigGate` como wrappers).

### Screens principales (25+)

| Screen | Rol |
|---|---|
| **MainScreen** | Pantalla principal — toggle amplificador, denoiser, prescriptor |
| **PermissionsScreen** | Solicita RECORD_AUDIO, BLUETOOTH_CONNECT, MODIFY_AUDIO_SETTINGS |
| **CalibrationScreen** | Calibración inicial (tonos puros, umbral perceptivo) |
| **CalibrationSetupScreen** | Configuración de la sesión de calibración |
| **CalibrationSpectrumScreen** | Analizador espectral en vivo durante la calibración |
| **AudiogramScreen** | Entrada / importación de audiograma AC/BC izq/der |
| **AdaptiveLearningScreen** | Vista del histórico y sugerencias del backend Hermes |
| **AiChatScreen** | Chat clínico con el HearingAidChatbot |
| **BundleExportScreen** | Exporta bundle ANMAT (PDF + audit trail firmado) |
| **DiagnosticAnalyzerScreen** | Analizador clínico completo (13 tests) |
| **DiagnosticoDspScreen** | Diagnóstico del DSP interno (drops, xruns, latencia) |
| **DspConfigDetailScreen** | Configuración avanzada del pipeline (por técnico) |
| **DspTestScreen** | Test bench del pipeline con archivos WAV |
| **GainCapScreen** | Límite superior de ganancia por paciente |
| **GainCeilingCalibrationScreen** | Calibración del techo de ganancia clínico |
| **LoopbackQcScreen** | QC de latencia loopback (chirp + cross-correlation) |
| **PresetLearningScreen** | Preset custom aprendido del usuario |
| **SessionLogScreen** | Log de sesiones (uso, cambios, eventos) |
| **SimulatorScreen** | WebView embebido del simulador (`assets/simulator/`) |
| **SmartSceneScreen** | Monitor en vivo del Smart Scene Engine (clase actual + confidence) |
| **SpectrumAnalyzerScreen** | Analizador espectral FFT 128 puntos |
| **TechnicalServiceScreen** | Modo servicio técnico (fabricante) |
| **BlockedScreen** | Bloqueo por biometric fail o RemoteConfig kill switch |
| **DiagnosticFlowScreen** | Flujo de 5 pasos: cuestionario → tonos → palabras → resultados → recomendación |

### Flujo típico del usuario

```
1. Instala APK → PermissionsScreen concede acceso al mic + BT
2. BiometricGate → huella / rostro (Fase 3 spec oir-pro-rebrand)
3. RemoteConfigGate → chequea kill switch remoto
4. AudiogramScreen → paciente entra su audiograma (o el técnico lo importa)
5. CalibrationScreen → tonos puros, calibración perceptiva
6. MainScreen → toggle "Amplificador" ON
7. Elige prescriptor (Smart-NL2 / Smart-NL3 / MHL)
8. Ajusta "Limpiador de ruido (IA)" y su Fuerza
9. Escucha en tiempo real (con auriculares o BT)
10. Consulta SmartSceneScreen para ver qué está detectando la app
11. Chat con IA (AiChatScreen) si tiene dudas
```

---

## 11. Simulador web

**Ubicación**: `assets/simulator/`.

Simulador de DSP en HTML + JS que corre **dentro del navegador** (sin necesidad del APK):

- `index.html` — UI del simulador
- `app.js` — orquestador
- `calibration-ui.js` — reproduce la pantalla de calibración
- `dsp-engine-browser.js` — port JavaScript de una fracción del pipeline C++
- `dsp-worklet-processor.js` — AudioWorkletProcessor (procesamiento real-time en el browser)
- `level-meter.js` — VU meter
- `realtime-recorder.js` + `realtime-module.js` — grabación / reproducción
- `dsp-config-export.js` — exporta la config al APK

**Deploy**: `.github/workflows/deploy-simulator.yml` publica a GitHub Pages.

---

## 12. Testing y QA

### Test suite (Dart / Flutter)

**94 test files** ejecutados en CI con `flutter test --concurrency=4 --timeout 120s`.

Categorías:

- **`test/dsp/`** — property-based tests con `glados` (pipeline, MPO, WDRC, volume, calibration)
- **`test/scene/`** — Smart Scene Engine tests
- **`test/dnn_denoiser/`** — tests unit del wrapper Dart del DNN
- **`test/domain/`** — GainPrescriber, ScenePrescriptionController, CinModule, AudiogramClassifier, AudiogramDrivenPresets (con property-based)
- **`test/audiometry/`** — cálculo de PTA, categorización de HL
- **`test/biological_calibration/`** — calibración biológica de campo
- **`test/mic_calibration/`** — dBFS → dB SPL offset
- **`test/calibration/`** — validación de tonos puros
- **`test/data/`** — bridges, hive_initializer, repositories
- **`test/presentation/`** — widget tests
- **`integration_test/e2e_integration_test.dart`** — E2E flow completo
- **`test/fixtures/dnn_eval/`** — 5 pares WAV clean/noisy 16 kHz mono para PESQ/STOI

### DSP quality gate

**`tools/quality_eval/`** — evalúa PESQ y STOI del denoiser:

- **PESQ ≥ 2.7** (ITU-T P.862, rango -0.5..4.5)
- **STOI ≥ 0.91** (0..1)
- HASPI / HASQI listado como TODO @ 0.55

Fixtures en `test/fixtures/dnn_eval/{clean,noisy}/` — WAV pares matchados por nombre.

### Regression tests

**`.github/workflows/regression-tests.yml`** — 10 EqPresets × flat 30 dB HL:

- Hard ceiling: **±5 dB** de deviation vs referencia (Requirement 11.9)
- In-suite tolerance: **±3 dB** con mapa softened por `(style, band)`
- Falla el merge del PR si algún preset se desvía > 5 dB

### Property-based tests

**`.github/workflows/property-tests.yml`** — usa `glados` contra `test/domain/audiogram_driven_presets/property/`. Imprime contra-ejemplos shrunken al fallar.

---

## 13. CI/CD y publicación

**10 workflows** en `.github/workflows/`:

| Workflow | Trigger | Rol |
|---|---|---|
| `build-apk.yml` | push main + feat/* + fix/*, PR a main, workflow_dispatch | APK release firmado (`oir-pro.apk`), attachea a GitHub Release, tag `build-{run_number}` |
| `build-apk-with-code.yml` | idem | APK + zip del source para review |
| `build-dfn3.yml` | manual | Recompila `libdfn3.so` (Rust + cargo-ndk) |
| `ci-core.yml` | push + PR | Static analysis + 94 unit tests + NDK compile check |
| `dartdoc-check.yml` | push | Valida que la documentación Dart esté completa |
| `deploy-simulator.yml` | push a `assets/simulator/**` | Publica el simulador a GitHub Pages |
| `dsp-quality.yml` | cambios en cpp/{dnn,dsp,wdrc,eq,mpo,nr} | PESQ + STOI vs baseline |
| `property-tests.yml` | push + PR | `glados` PBT gate |
| `regression-tests.yml` | push + PR | 10 EqPresets ±5 dB gate |
| `release-gate.yml` | manual + tags | Valida el bundle QC PDF firmado (ANMAT compliance) |

### Detalles del release

- **Keystore**: en GitHub Secrets `KEYSTORE_BASE64` + `KEYSTORE_PASSWORD` + `KEY_ALIAS` + `KEY_PASSWORD`.
- **HMAC secret**: `HMAC_SECRET` — usado por el BundleExporter para firmar el audit trail.
- **Sin obfuscación** (`--obfuscate` NO se aplica en release) porque rompe la resolución de símbolos JNI del DNN denoiser (Motorola devon_g crashea con `Cannot resolve libdfn3.so::process_hop`).
- **Archivo output**: `oir-pro.apk` (`build/app/outputs/flutter-apk/app-release.apk` → renombrado).
- **Tags**: `build-{run_number}` (ej `build-145`).
- **GitHub Release**: adjunta el APK.

---

## 14. Requerimientos regulatorios

### FDA OTC Hearing Aid Rule (21 CFR 800.30)

- **MPO Limiter** hard-limitado a **110 dB SPL** en `mpo_limiter.cpp`.
- Digital ceiling en `0.85` para nunca saturar antes del limiter.
- Modo pediátrico con `maxTotalGain: 40 dB` y `minExpansionKnee: 30 dB SPL`.
- **AVISO**: Audifon **no está certificado como audífono médico**; se distribuye como PSAP (Personal Sound Amplification Product). Ver disclaimer en la app.

### ANMAT 2318/02 (Argentina)

- **Audit trail firmado**: cada cambio en el dispositivo se persiste en `audit_trail_box` (Hive) con timestamp + SHA-256 + HMAC.
- **BundleExporter** (`lib/services/bundle_exporter.dart`) genera un ZIP con:
  - PDF clínico del paciente (con acentos y ñ correctamente renderizados en Roboto)
  - JSON del audit trail
  - Firma HMAC-SHA256

### Release gate

`.github/workflows/release-gate.yml` valida que el PDF firmado del QC del bundle exista antes de publicar una release (Tramo 3 QC audit spec).

---

## 15. Cómo compilar

### Prerequisitos

- Flutter 3.19.6 stable
- Java 17 (Temurin)
- Android NDK 25.2.9519653 (`ndkVersion` en `android/app/build.gradle`)
- Node.js ≥18 (para el módulo `ai/`, opcional)

### Flutter dependencies

```bash
flutter pub get
```

### Build debug

```bash
flutter build apk --debug
```

### Build release

```bash
# Configurar keystore (una vez):
cp android/key.properties.example android/key.properties
# Editar android/key.properties con tu ruta y passwords.

flutter build apk --release
# NO usar --obfuscate — rompe el DNN denoiser
```

### Native only (para desarrollo del DSP)

```bash
cd android
./gradlew :app:externalNativeBuildRelease
```

### Corriendo el módulo AI en local

```bash
cd ai
npm install
export OPENAI_API_KEY=sk-...
node -e "const {createAISystem}=require('./index.js'); const ai=createAISystem({}); console.log(Object.keys(ai));"
```

### Corriendo el simulador local

```bash
cd assets/simulator
python -m http.server 8000
# Abrir http://localhost:8000
```

---

## 16. Glosario

| Sigla | Expansión | Contexto |
|---|---|---|
| **PSAP** | Personal Sound Amplification Product | Categoría regulatoria FDA |
| **DSP** | Digital Signal Processing | Pipeline de audio |
| **DNN** | Deep Neural Network | Denoiser IA |
| **WDRC** | Wide Dynamic Range Compression | Compresión audiológica estándar |
| **MPO** | Maximum Power Output | Techo de salida del audífono |
| **NR** | Noise Reduction | Reducción de ruido clásica (Wiener) |
| **TNR** | Transient Noise Reduction | Reducción de golpes / clicks |
| **AFC** | Adaptive Feedback Canceller | Cancelación de realimentación |
| **FBS** | Feedback Suppressor | Notch adaptativo |
| **HPF** | High-Pass Filter | Filtro pasa-altos |
| **SCE** | Spectral Contrast Enhancer | Realce de contornos formánticos |
| **MVDR** | Minimum Variance Distortionless Response | Beamformer |
| **WPE** | Weighted Prediction Error | De-reverberación |
| **VAD** | Voice Activity Detector | Detector de voz |
| **NAL-NL2** | National Acoustic Laboratories, Non-Linear 2 | Prescripción audiológica |
| **CIN** | Compression for Improved audibility of speech in Noise | Compresión adaptativa |
| **RECD** | Real-Ear-to-Coupler Difference | Corrección pediátrica |
| **LTSD** | Long-Term Spectral Divergence | Feature VAD |
| **LRT** | Likelihood Ratio Test | Feature VAD |
| **ZCR** | Zero-Crossing Rate | Feature VAD |
| **PESQ** | Perceptual Evaluation of Speech Quality | Métrica ITU-T P.862 |
| **STOI** | Short-Time Objective Intelligibility | Métrica de inteligibilidad |
| **HASPI** | Hearing-Aid Speech Perception Index | Métrica clínica |
| **HASQI** | Hearing-Aid Speech Quality Index | Métrica clínica |
| **PBT** | Property-Based Testing | glados |
| **AGP** | Android Gradle Plugin | Build system |
| **JNI** | Java Native Interface | Bridge Java/Kotlin ↔ C++ |
| **NDK** | Native Development Kit | Toolchain Android nativo |
| **ONNX** | Open Neural Network Exchange | Formato de modelos DNN |
| **SPL** | Sound Pressure Level | Nivel de presión sonora (dB SPL) |
| **HL** | Hearing Loss | Pérdida auditiva (dB HL) |
| **OTC** | Over-The-Counter | Categoría regulatoria FDA |
| **QC** | Quality Control | Auditoría de calidad |

---

## Créditos y licencia

- Repo owner: **HenrySali**
- DSP nativo: C++17 propietario, con dependencias:
  - [Oboe](https://github.com/google/oboe) — Apache 2.0
  - [ONNX Runtime](https://github.com/microsoft/onnxruntime) — MIT
  - [PyTorch Android](https://pytorch.org/mobile) — BSD 3-Clause
  - [xiph/rnnoise](https://github.com/xiph/rnnoise) v0.1.1 — BSD 3-Clause (vendored)
- AI: OpenAI SDK — Apache 2.0
- Frontend: Flutter — BSD 3-Clause

---

*Este documento se genera manualmente. Última revisión: 21 de julio de 2026 tras el merge del PR #39 (ring-buffer fix del RNNoise wrapper). Para el diario técnico detallado ver `SESION.md`. Para cambios clínicos específicos ver `CAMBIOS_NR_PROFESIONAL.md`, `CAMBIOS_SMART_AUTO_V2.md`, `RESUMEN_AUDITORIA_SMART.md`.*

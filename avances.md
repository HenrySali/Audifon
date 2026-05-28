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

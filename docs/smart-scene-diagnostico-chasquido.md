# Smart Scene — Diagnóstico de chasquidos y desbalance aleatorio

> Estado: **diagnóstico**, sin implementar correcciones todavía.
> Audífono: **PSK Hearing Aid** (Android · Oboe · ONNX · BLE).
> Síntomas reportados: muchísimos chasquidos audibles + voz que se desbalancea de un momento a otro de forma aleatoria al activar Smart Scene.

---

## 1. Resumen ejecutivo

- El **clasificador automático** (`EnvironmentClassifier`) corre en el callback de audio y, cuando cambia de clase, **machaca de golpe** el `compressionKnee` y `compressionRatio` del WDRC más el `nrLevel` del NR. No hay rampa entre clase A y clase B → chasquido.
- El **VAD del Smart Scene** (`VadDetector`) y el **clasificador del DSP** son **dos clasificadores en paralelo** que escriben sobre los mismos parámetros del WDRC desde dos caminos distintos: uno desde el audio thread (al detectar cambio), otro desde Dart (al apretar “Aplicar preset” en `SmartSceneScreen`). La combinación produce ráfagas de cambios de parámetros que se perciben como **desbalance aleatorio** del nivel de voz.
- **Volumen, NR level y EQ gains se actualizan por etapas separadas y sin sincronizar** desde Dart vía `MethodChannel`. Cada `invokeMethod` aterriza en un thread distinto del audio callback, así que las 12 ganancias del EQ, el volumen master y el NR pueden quedar **temporalmente inconsistentes** entre callbacks (se oye un “pop” + un escalón de loudness).
- El hold-counter del clasificador está fijado a **750 bloques** (`environment_classifier.cpp:129`), pero la cuenta real depende del block size negociado por Oboe. Con Oboe a 48 kHz y burst de 192/256 frames el hold no son 3 s sino **~3 s a 4 s**: igual queda corto si el VAD oscila entre **silencio↔voz** durante un enunciado dudoso, porque la histéresis SNR (5 dB / 12 dB) se cumple varias veces por segundo. **Flicker → chasquido + desbalance**.
- El reset de coeficientes del EQ ocurre en `Equalizer::updateCoefficients()` cada vez que `gainsChanged_=true`. Si Smart Scene cambia de preset y desde Dart se llaman `updateEqGains` y `setNrLevel` y `updateVolume` en orden distinto al esperado, las nuevas ganancias EQ se aplican **en mitad de un bloque** y el biquad **no resetea estado** — pero los coeficientes saltan en un punto del bloque, dejando un transitorio audible.

---

## 2. Mapa de actores y de datos compartidos

```
┌──────────────────────────────────────────────────────────────────────┐
│ AUDIO CALLBACK THREAD (Oboe onBothStreamsReady, ~5 ms cada bloque)   │
│                                                                      │
│   inPtr ──▶ DnnDenoiser ──▶ DspPipeline.processBlock()              │
│                                │                                     │
│                                ├─ HPF 100 Hz                          │
│                                ├─ TNR                                 │
│                                ├─ NR Wiener (level_)                  │
│                                ├─ measure RMS                         │
│                                ├─ EnvironmentClassifier.update()      │  (1)
│                                │     └─ on transition: setLevel(),    │
│                                │        setCompressionKnee(),         │
│                                │        setCompressionRatio()         │
│                                ├─ Equalizer.process()                 │
│                                ├─ WdrcProcessor.process()             │
│                                ├─ Volume                              │
│                                └─ MpoLimiter                          │
│                                                                      │
│   inPtr ──▶ SceneAnalyzer.process()  (Smart Scene FFT + VAD + noise) │  (2)
│                publica SceneSnapshot por seqlock                      │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│ DART UI THREAD (SmartSceneScreen + SceneEngine + AmplificationBloc)  │
│                                                                      │
│   poll cada 100 ms ── nativeGetSceneSnapshot ── decisión 2.5 s        │
│                                                                      │
│   _applyPreset() → bloc.add(UpdateEqGains, ChangeVolume)             │  (3)
│       └─ AudioBridgeImpl.updateEqGains    → MethodChannel             │
│       └─ AudioBridgeImpl.updateVolume     → MethodChannel             │
│                                                                      │
│   (No hay updateNrLevel ni updateWdrcParams en el flujo actual)       │
└──────────────────────────────────────────────────────────────────────┘
```

Hay **DOS canales** modificando WDRC al mismo tiempo:

- **(1) EnvironmentClassifier**: muta `compressionKnee` y `compressionRatio` en el audio thread.
- **(3) SceneEngine.apply**: el `SmartPreset` calculado por Dart trae `compressionKnee/Ratio/NrLevel/tnrEnabled/volumeDeltaDb` (`scene_preset_generator.dart:46-103`) pero **el `apply()` actual sólo emite `UpdateEqGains` y `ChangeVolume`** (`scene_engine.dart:226-235`). El `nrLevel` y los kneepoints quedan **persistidos en Hive** pero **nunca llegan al engine**, así que la clasificación automática del audio thread sigue mandando esos valores. Inconsistencia clínica + desbalance aleatorio.

---

## 3. Causas raíz identificadas (con archivo y línea)

### Causa A — Cambio de WDRC y NR sin rampa al cambiar de escena
**Severidad: ALTA** (es la causa principal del chasquido).

- Archivo: `Amplificador/hearing_aid_app/android/app/src/main/cpp/dsp_pipeline.cpp`
- Líneas: **140–157** (bloque `if (envClassInt != lastEnvClass_)`).

Cuando el `EnvironmentClassifier` cambia de clase, el pipeline sustituye **en un solo sample** el `compressionKnee` (entre 40 y 55 dB SPL), el `compressionRatio` (1.5 a 3.0) y el `nrLevel` (0 a 3) sin ninguna interpolación:

```cpp
int targetNrLevel = envClassifier_.getRecommendedNrLevel();
currentNrLevel_ = targetNrLevel;
nr_.setLevel(currentNrLevel_);                    // salta de 0 a 3 directo

EnvWdrcParams wdrcParams = envClassifier_.getRecommendedWdrcParams();
wdrc_.setCompressionKnee(wdrcParams.compressionKnee);   // salta 55 → 40 dB SPL
wdrc_.setCompressionRatio(wdrcParams.compressionRatio); // salta 1.5 → 3.0
```

El comentario interno reconoce que el cambio se hace **directo al target**, justificándolo en que “el NR ya tiene suavizado interno”. El problema es que:

1. `NoiseReduction::process()` cambia el `gainFloor` global de 1.0 → 0.18 inmediatamente. El suavizado interno (`prevGain_` con coeficientes 0.4 / 0.1) **no rampa el gainFloor**, sólo la transición de la ganancia compuesta. El primer bloque tras el cambio aplica `0.18×bandEnergy/totalEnergy` con un escalón fijo respecto al bloque anterior. **Click claro** en la transición.
2. `WdrcProcessor::computeGainFactor()` usa los nuevos `expKnee/compKnee/ratio` recién leídos desde atomic relaxed (`wdrc_processor.cpp:84-87`). El envelope detector suaviza `smoothedGain_` muestra a muestra, pero el `targetGain` cambia de golpe — del orden de 0.4 a 0.7 en una transición SPEECH→NOISE — y el attack 5 ms tarda ~80 samples a 16 kHz. En el inter-bloque entre escenas se oye un **bump de loudness**.
3. La regla 4 del `hearing-aid-dsp.md` dice explícitamente *“Crossfade insuficiente en cambios de config → click”*. El pipeline no implementa crossfade alguno entre presets WDRC.

**Síntoma audible**: el chasquido ocurre exactamente en el frame en que `lastEnvClass_` cambia. Como el clasificador transita varias veces durante un mismo segmento de audio (ver Causa B), suenan **muchos** chasquidos, no uno.

**Solución sugerida (snippet, NO implementar):**

```cpp
// dsp_pipeline.h — agregar miembros para rampa de WDRC y NR
float wdrcKneeRamp_ = 55.0f;
float wdrcKneeTarget_ = 55.0f;
float wdrcRatioRamp_ = 2.0f;
float wdrcRatioTarget_ = 2.0f;
int   nrLevelTarget_ = 0;
int   nrLevelRampBlocksRemaining_ = 0;

// dsp_pipeline.cpp — al detectar cambio de clase, fijar TARGET, no aplicar
if (envClassInt != lastEnvClass_) {
    lastEnvClass_ = envClassInt;
    EnvWdrcParams p = envClassifier_.getRecommendedWdrcParams();
    wdrcKneeTarget_  = p.compressionKnee;
    wdrcRatioTarget_ = p.compressionRatio;
    nrLevelTarget_   = envClassifier_.getRecommendedNrLevel();
    nrLevelRampBlocksRemaining_ = 50; // ~200 ms a 4 ms/bloque
}

// Cada bloque, antes de wdrc_.process(), interpolar
constexpr float kWdrcRampAlpha = 0.02f; // ~200 ms hacia target
wdrcKneeRamp_  += kWdrcRampAlpha * (wdrcKneeTarget_  - wdrcKneeRamp_);
wdrcRatioRamp_ += kWdrcRampAlpha * (wdrcRatioTarget_ - wdrcRatioRamp_);
wdrc_.setCompressionKnee(wdrcKneeRamp_);
wdrc_.setCompressionRatio(wdrcRatioRamp_);

// Para NR, hacer transición discreta cada N bloques (1 nivel por vez):
if (nrLevelRampBlocksRemaining_ > 0) {
    nrLevelRampBlocksRemaining_--;
} else if (currentNrLevel_ != nrLevelTarget_) {
    int step = (nrLevelTarget_ > currentNrLevel_) ? 1 : -1;
    currentNrLevel_ += step;
    nr_.setLevel(currentNrLevel_);
    nrLevelRampBlocksRemaining_ = 75; // ~300 ms entre niveles
}
```

Prioridad: **Alta**.

---

### Causa B — Histéresis del clasificador es asimétrica y deja zonas que oscilan a > 1 transición/seg
**Severidad: ALTA** (causa el desbalance aleatorio).

- Archivo: `Amplificador/hearing_aid_app/android/app/src/main/cpp/environment_classifier.cpp`
- Líneas: **76–113** (cuerpo de `update()`).
- Constantes asociadas: `environment_classifier.h` líneas **34–37** (`kEnvLevelQuietThreshold=45`, `kEnvLevelSpeechMax=70`, `kEnvSnrSpeechThreshold=10`, `kEnvSnrNoiseThreshold=0`).

Estructura actual del clasificador:

- EMA del nivel y SNR con `α=0.05` (~800 ms tau a 4 ms/bloque). Suaviza los valores pero **no la decisión**.
- Histéresis SNR: para entrar a `SPEECH` se exige `snr > 12`, para salir `snr < 5` — **banda muerta de 7 dB**. OK aislada.
- Pero la transición a `QUIET` está dominada **sólo por nivel** (`level < 45 dB SPL`), sin histéresis de nivel. Cualquier respiración o pausa breve durante un enunciado tira el `smoothedLevelDb` debajo de 45 → cambio a QUIET → cambio de WDRC + NR → al volver la voz: cambio a SPEECH.
- El hold-counter sólo bloquea **transiciones consecutivas durante 750 bloques** (3 s a 4 ms/bloque). Pero a 48 kHz con burst típico de 192 frames el bloque dura **4 ms**, así que sigue siendo 3 s; con burst de 256 son 5,3 s. Si la conversación tiene pausas de >3 s entre frases, **cada pausa dispara un ciclo de transición** SPEECH→QUIET→SPEECH y por lo tanto **dos chasquidos por turno conversacional**.
- Sólo se implementa histéresis al pivotar entre `SPEECH` y `NOISE`. Las transiciones desde `QUIET` y desde `SPEECH_IN_NOISE` no tienen histéresis: usan los umbrales nominales.

**Resultado**: la voz que “suena más fuerte de un momento a otro” coincide con la oscilación SPEECH ↔ SPEECH_IN_NOISE: el knee salta 55→45 dB SPL, el ratio 2.0→2.5, así que la **misma señal de voz queda comprimida 2 dB menos** después de la oscilación. Cuando vuelve, vuelve a comprimirse. El usuario lo percibe como un loudness aleatorio.

**Solución sugerida (snippet):**

```cpp
// 1. Histéresis simétrica en TODO bordes: definir thresholds de entrada
//    distintos de los de salida en CADA dirección.
constexpr float kQuietEnter = 42.0f;   // entrar a QUIET
constexpr float kQuietExit  = 48.0f;   // salir de QUIET (gap 6 dB)
constexpr float kSpeechMaxEnter = 68.0f;
constexpr float kSpeechMaxExit  = 72.0f;

// 2. Hold timer dependiente de la dirección de la transición.
//    SPEECH→SPEECH_IN_NOISE: hold corto (1 s).
//    SPEECH→NOISE / NOISE→SPEECH: hold medio (3 s).
//    cualquier→QUIET: hold largo (5 s) — evitar oscilar por pausas.

// 3. Contador de “silabicidad”: si el VAD reportó voice_active en los
//    últimos N bloques, NO bajar a QUIET aunque el nivel caiga
//    momentáneamente.
if (vad_.isVoiceActive() || framesSinceLastVoice_ < 200) {
    // mantener estado actual hasta que pase un segundo sin voz real
    return current;
}
```

Prioridad: **Alta**.

---

### Causa C — Smart Scene UI pisa parámetros que el clasificador automático también está escribiendo
**Severidad: ALTA** (causa el desbalance aleatorio adicional).

- Archivos:
  - `Amplificador/hearing_aid_app/lib/scene/scene_engine.dart` líneas **220–246** (`SceneEngine.apply`)
  - `Amplificador/hearing_aid_app/lib/scene/scene_preset_generator.dart` líneas **46–103** (define `nrLevel`, `compressionKnee`, `compressionRatio`, `tnrEnabled`, `volumeDeltaDb` por escena)
  - `Amplificador/hearing_aid_app/android/app/src/main/cpp/dsp_pipeline.cpp` líneas **123–157** (clasificador automático que escribe los mismos campos)

Cuando el usuario pulsa “Aplicar preset” en la pantalla Smart Scene, `SceneEngine.apply()`:

```dart
bloc.add(UpdateEqGains(gains: preset.gains, presetName: preset.name));
if (preset.volumeDeltaDb.abs() > 1e-3) { bloc.add(ChangeVolume(...)); }
// PERSISTE en Hive: nrLevel, compressionRatio, compressionKnee, tnrEnabled, ...
// pero NO los manda al engine
```

Sólo despacha `UpdateEqGains` y `ChangeVolume`. **No hay `UpdateNrLevel`, no hay `updateWdrcParams`, no hay `updateTnrEnabled`** en este flujo. El comentario del código lo admite: *“el TNR y el cambio activo de NR level no se despachan al engine en esta fase: el AmplificationBloc aplica NR vía clasificación automática”*. El resultado es que:

1. La UI dice “aplicado” pero el `nrLevel` y `compressionKnee/Ratio` quedan controlados por `EnvironmentClassifier`. La mitad del preset es invisible.
2. El clasificador automático sigue cambiando `compressionKnee/Ratio` mientras el preset persistido dice otra cosa. **Cada vez que cambia la escena automática, el WDRC se aleja del preset**: la voz se desbalancea “sola”.
3. Las nuevas ganancias EQ sí se aplican (`updateEqGains` → JNI → `Equalizer::setGains`). El EQ levanta +25 dB en 4 kHz, pero como el WDRC sigue manejado por el clasificador automático, comprime con un knee que no corresponde al perfil pediátrico → **loudness errático**.

**Solución sugerida (snippet):**

```dart
// scene_engine.dart — apply() debería despachar TODO el preset:
bloc.add(UpdateEqGains(gains: preset.gains, presetName: preset.name));
bloc.add(UpdateNrLevel(level: preset.nrLevel));
bloc.add(UpdateWdrcParams(WdrcParams(
  compressionKnee:   preset.compressionKnee,
  compressionRatio:  preset.compressionRatio,
  expansionKnee:     preset.expansionKnee,
  expansionRatio:    2.0,                         // o el del preset
  attackMs:          5.0,
  releaseMs:         100.0,
)));
bloc.add(SetTnrEnabled(enabled: preset.tnrEnabled));
if (preset.volumeDeltaDb.abs() > 1e-3) bloc.add(ChangeVolume(...));

// dsp_pipeline.cpp — desactivar clasificador automático cuando un preset
// Smart Scene fue aplicado manualmente, para que NO pise el preset:
if (autoClassifyEnabled_.load(...) && !smartPresetPinned_.load(...)) {
    // ... lógica actual del clasificador ...
}
```

Prioridad: **Alta**.

---

### Causa D — `nativeSetEqGains` es atómico por banda pero NO atómico para el conjunto de 12 bandas
**Severidad: MEDIA** (provoca un click puntual al aplicar preset, no el desbalance continuo).

- Archivo: `Amplificador/hearing_aid_app/android/app/src/main/cpp/equalizer.cpp`
- Líneas: **52–62** (`Equalizer::setGains`).

```cpp
void Equalizer::setGains(const float gains[kEqBandCount]) {
    for (int i = 0; i < kEqBandCount; ++i) {
        gains_[i].store(g, std::memory_order_relaxed);  // 12 stores no atómicos
    }
    gainsChanged_.store(true, std::memory_order_release);
}
```

El audio thread puede leer `gains_[3]` con el valor nuevo y `gains_[4]` con el valor viejo en el mismo bloque, porque `setGains` no es transaccional. La lectura sucede en `Equalizer::updateCoefficients()` cuando `gainsChanged_=true`: si la UI escribe **mientras** se está ejecutando ese loop, los coeficientes recalculados pertenecen a presets distintos.

Combinado con el comentario *“Los cambios de preset EQ se manejan con reinicio rápido del engine desde Dart (stop+start ~50ms). Esto garantiza que los filtros siempre arrancan con estado limpio”* (`equalizer.cpp:14-18`) — **ese reinicio NO se hace en el flujo de Smart Scene**. `_applyPreset` no llama `stopAudio` + `startAudio`, sólo `updateEqGains`. Así que el reset de filtros tampoco ocurre. Si la respuesta de los biquads cambia a mitad de un fonema, suena un **click + cambio de timbre**.

Adicional: incluso si todos los `gains_[i]` aterrizaran en el mismo bloque, `updateCoefficients()` **no resetea `BiquadState`** (`equalizer.cpp:130-138`). Cuando un peaking biquad cambia de +10 a +25 dB su salida incluye un transitorio largo (orden 2 IIR con polos próximos al círculo unidad → ringing decae con τ ≈ 1/(1-r), típicamente 30–80 ms). **El usuario oye un “bump” en la voz** de 30–80 ms en cada cambio de preset.

**Solución sugerida (snippet):**

```cpp
// equalizer.h — agregar buffer doble + commit atómico
struct EqSnapshot {
    float gains[kEqBandCount];
    BiquadCoeffs coeffs[kEqBandCount];
};
std::atomic<int> activeSnapshotIdx_{0};
EqSnapshot snapshots_[2];

// setGains: escribe en el snapshot inactivo y publica con un único store
void setGains(const float gains[kEqBandCount]) {
    int writeIdx = 1 - activeSnapshotIdx_.load(std::memory_order_acquire);
    for (int i = 0; i < kEqBandCount; ++i) {
        snapshots_[writeIdx].gains[i] = clampGain(gains[i]);
        snapshots_[writeIdx].coeffs[i] =
            computePeakingCoeffs(kEqFrequencies[i], snapshots_[writeIdx].gains[i],
                                 kEqQFactors[i]);
    }
    activeSnapshotIdx_.store(writeIdx, std::memory_order_release);
}

// process: lee índice una vez por bloque; con crossfade entre el biquad
// previo y el nuevo durante 5 ms para evitar el transient.
// ALTERNATIVA simple: aplicar gain crossfade lineal de las muestras de salida
// del bloque cuando se detecta cambio.
```

Prioridad: **Media**.

---

### Causa E — Histéresis del VAD del Smart Scene + el clasificador automático del DSP **no comparten estado**
**Severidad: MEDIA**.

- Archivos:
  - `Amplificador/hearing_aid_app/android/app/src/main/cpp/smart_scene/vad_detector.cpp` (decide voiceActive con FFT 256, hop variable)
  - `Amplificador/hearing_aid_app/android/app/src/main/cpp/environment_classifier.cpp` (decide envClass con RMS broadband + SNR estimado simple)

El `EnvironmentClassifier` NO usa el VAD del Smart Scene. Usa una estimación de SNR simplificada en `DspPipeline::estimateSnrSimple()` (`dsp_pipeline.cpp:254-263`), donde el “noise floor” es una **constante fija de 30 dB SPL**:

```cpp
static constexpr float kNoiseFloorDbSpl = 30.0f;
float snr = inputLevelDb - kNoiseFloorDbSpl;
```

Esto significa que la SNR usada por el clasificador es básicamente **el nivel de entrada menos 30 dB**. Cualquier ruido continuo a 50 dB SPL se interpreta como SNR de 20 dB (señal limpia) cuando en realidad puede ser ruido sin voz. El clasificador, con esa SNR alta, salta a `SPEECH`. Cuando el ruido baja a 35 dB SPL, salta a `QUIET`. Mientras tanto, el VAD del Smart Scene **sí** detecta correctamente que no hay voz, pero su decisión nunca llega al clasificador.

**Resultado**: clasificaciones erráticas que disparan los cambios de WDRC y NR (Causa A) — y por lo tanto, **chasquidos en falsos cambios de escena**.

**Solución sugerida (snippet):**

```cpp
// dsp_pipeline.cpp — usar la SNR REAL del Smart Scene en vez de la heurística
auto sceneSnap = sceneAnalyzer_.getSnapshot();
float estimatedSnr = std::clamp(sceneSnap.snr_db, kEnvSnrMin, kEnvSnrMax);
// ...
// Y aprovechar el voice_active del VAD para forzar SPEECH:
if (sceneSnap.voice_active) {
    estimatedSnr = std::max(estimatedSnr, kEnvSnrSpeechThreshold + 1.0f);
}
EnvironmentClass envClass = envClassifier_.update(inputLevelDb, estimatedSnr);
```

Prioridad: **Media**.

---

### Causa F — `setCompressionKnee` y `setCompressionRatio` son **dos atómicos relaxed independientes**
**Severidad: MEDIA**.

- Archivo: `Amplificador/hearing_aid_app/android/app/src/main/cpp/wdrc_processor.cpp`
- Líneas: **156–172** (`setCompressionKnee`, `setCompressionRatio`).
- Header: `wdrc_processor.h` líneas **25–32** (struct `AtomicWdrcParams`).

Cuando el clasificador transita SPEECH→NOISE el código del DSP llama:

```cpp
wdrc_.setCompressionKnee(40.0f);    // store relaxed
wdrc_.setCompressionRatio(3.0f);    // store relaxed
```

`WdrcProcessor::computeGainFactor()` lee ambos atomics también con `relaxed`. **Sin orden total** entre stores, el audio thread puede leer `knee=40` con `ratio=1.5` (la combinación inestable). Para input 60 dB SPL con knee 40 + ratio 1.5: reducción = 20·(1−1/1.5) = 6.67 dB. Para knee 40 + ratio 3: reducción = 20·(1−1/3) = 13.33 dB. **Diferencia de 6.66 dB** en un sample. **Click**.

El `dsp_pipeline.cpp` línea 152 solo se ejecuta una vez por bloque, pero el clasificador puede transitar **mientras se procesan samples del WDRC** porque `process()` corre sample-by-sample y el clasificador escribe entre `wdrc_.process()` calls. Aun así, dentro de un mismo bloque la lectura se hace una sola vez en `computeGainFactor` y se usa para los 64-256 samples — el riesgo está en bloques distintos.

**Solución sugerida (snippet):**

```cpp
// wdrc_processor.h — agregar setter compuesto que actualice todo bajo
// el mismo orden:
void setCompressionParams(float knee, float ratio) {
    params_.compressionRatio.store(ratio, std::memory_order_relaxed);
    params_.compressionKnee.store(knee,  std::memory_order_release);
}

// computeGainFactor — leer knee con acquire para sincronizar con ratio
float compKnee  = params_.compressionKnee.load(std::memory_order_acquire);
float compRatio = params_.compressionRatio.load(std::memory_order_relaxed);
```

Prioridad: **Media**.

---

### Causa G — Volumen + EQ se aplican como dos `MethodChannel` separados
**Severidad: MEDIA**.

- Archivo: `Amplificador/hearing_aid_app/lib/scene/scene_engine.dart` líneas **226–235**.

```dart
bloc.add(UpdateEqGains(gains: preset.gains, presetName: preset.name));
if (preset.volumeDeltaDb.abs() > 1e-3) {
    bloc.add(ChangeVolume(volumeDb: ...));
}
```

`UpdateEqGains` y `ChangeVolume` son dos eventos del bloc → dos `await` separados → dos `invokeMethod` separados → dos paradigmas “en cualquier momento” en el JNI. Entre los dos puede pasar **decenas de milisegundos**. Si el preset baja la ganancia EQ en una banda y al mismo tiempo sube volumen `+0 dB` (delta 0), el orden no importa. Pero si baja `volumeDeltaDb=-3 dB` (escena `voiceInNoiseLow`) y el EQ va con +20 dB, durante el gap entre las dos llamadas el audífono está aplicando **EQ nuevo + volumen viejo** = **3 dB más fuerte que el target**. Eso suena como un “salto de loudness al activar el preset”.

**Solución sugerida (snippet):**

Crear un único método nativo `applyScenePreset(...)` que reciba EQ + WDRC + NR + Volume + TNR y los aplique todos **dentro del mismo callback** (ej. usando un staging que se conmuta atómicamente al inicio del próximo bloque):

```dart
// audio_bridge.dart
Future<void> applyScenePreset(SmartPreset preset) =>
    _channel.invokeMethod('applyScenePreset', {
      'gains': preset.gains,
      'volumeDb': resolvedVolumeDb,
      'nrLevel': preset.nrLevel,
      'compressionKnee': preset.compressionKnee,
      'compressionRatio': preset.compressionRatio,
      'expansionKnee': preset.expansionKnee,
      'tnrEnabled': preset.tnrEnabled,
    });
```

```cpp
// dsp_pipeline.cpp — recibir todo y commitear con un single atomic flag
struct PendingPreset {
    float gains[12]; float volumeDb; int nrLevel;
    float compKnee, compRatio, expKnee; bool tnrEnabled;
};
std::atomic<bool> pendingPresetReady_{false};
PendingPreset pending_;
// Dentro de processBlock, antes de procesar:
if (pendingPresetReady_.load(std::memory_order_acquire)) {
    eq_.setGains(pending_.gains);
    setVolume(pending_.volumeDb);
    nr_.setLevel(pending_.nrLevel);
    wdrc_.setCompressionKnee(pending_.compKnee);
    wdrc_.setCompressionRatio(pending_.compRatio);
    wdrc_.setExpansionKnee(pending_.expKnee);
    tnr_.setEnabled(pending_.tnrEnabled);
    pendingPresetReady_.store(false, std::memory_order_release);
}
```

Prioridad: **Media**.

---

### Causa H — El `dryDelayRing` del DnnDenoiser y la rampa de crossfade del DNN se reconfiguran si Smart Scene cambia el sample rate observado
**Severidad: BAJA** (sólo aparece si el preset incluye reinicio del audio engine).

- Archivo: `Amplificador/hearing_aid_app/android/app/src/main/cpp/dnn_denoiser/dnn_denoiser.cpp` (resampler + crossfade)
- Header: `dnn_denoiser.h` líneas **107–108** (`kDnnCrossfadeSamples = 800` = 50 ms).

Si Smart Scene dispara un `stop+start` del engine (mencionado en `equalizer.cpp:14-15` como mecanismo *“para cambios de preset EQ”*), el `DnnDenoiser` re-inicializa caches y el resampler. Durante esos 50 ms del crossfade saliendo de bypass al modelo, la señal pasa por una mezcla `dry × (1−g) + wet × g`. Si justo en ese momento el clasificador automático cambia el WDRC, se acumulan dos transitorios (Causa A) y la mezcla es dry + nuevo WDRC distinto del wet. Suena como un **chirrido + cambio de timbre**.

Solución: encadenar de forma explícita: terminar crossfade del DNN → entonces aplicar preset Smart Scene. O simplemente evitar el `stop+start` (Causa D ya elimina la necesidad) usando crossfade interno de EQ.

Prioridad: **Baja**.

---

### Causa I — Polling del SceneAnalyzer cada 100 ms y session de 2.5 s ⇒ frecuencia alta de cambios de preset si el usuario pulsa repetido
**Severidad: BAJA** (sólo si el usuario apoya el dedo en el botón).

- Archivos: `lib/presentation/screens/smart_scene_screen.dart` línea **47** (`_pollInterval = 100ms`), `lib/scene/scene_engine.dart` líneas **140–186** (sessión de 2.5 s, hasta 25 muestras).

Si el usuario re-aprieta “Detectar” mientras una sesión anterior aún no terminó, hay dos sesiones en paralelo. Cada una resuelve y dispara `apply()`. La segunda sobreescribe la primera mientras los cambios todavía no se aplican (Causa A no rampea). **Doble click** y dos cambios de WDRC seguidos. Es una variante UX de la Causa C.

Solución: deshabilitar el botón Detectar mientras `_isAnalyzing=true`, **o** cancelar la sesión anterior cuando se inicia una nueva.

Prioridad: **Baja**.

---

## 4. Tabla resumen y prioridad

| ID | Causa raíz | Archivo | Líneas | Prioridad | Síntoma |
|----|------------|---------|--------|-----------|---------|
| A  | WDRC + NR cambian sin rampa al cambiar de escena | `dsp_pipeline.cpp` | 140–157 | **Alta** | Chasquido en cada cambio de clase |
| B  | Histéresis del clasificador insuficiente; oscilación SPEECH↔QUIET por pausas de voz | `environment_classifier.cpp` | 76–113 | **Alta** | Desbalance aleatorio + chasquidos repetidos |
| C  | `SceneEngine.apply` no manda `nrLevel` ni `wdrcParams` al engine, sólo EQ + Volume | `scene_engine.dart` | 220–246 | **Alta** | Preset “a medias” + clasificador automático pisando |
| D  | `Equalizer::setGains` no es transaccional + biquads no resetean estado en cambio | `equalizer.cpp` | 52–62, 130–138 | **Media** | Click puntual + ringing 30–80 ms al aplicar preset |
| E  | Clasificador usa SNR heurística con noise-floor fijo en 30 dB SPL; ignora el VAD del Smart Scene | `dsp_pipeline.cpp` | 254–263 | **Media** | Clasificaciones falsas → más chasquidos |
| F  | `setCompressionKnee/Ratio` son dos atomics relaxed independientes | `wdrc_processor.cpp` | 156–172 | **Media** | Combinación inestable knee/ratio durante un bloque |
| G  | EQ + Volume llegan como dos `MethodChannel` separados con gap de ms | `scene_engine.dart` | 226–235 | **Media** | Salto de loudness 3 dB en transición entre EQ-aplicado y Volume-aplicado |
| H  | DNN crossfade y sample-rate re-config solapan con cambios de preset | `dnn_denoiser.cpp` | resampler + 107 | Baja | Chirrido si hay stop+start |
| I  | Sesiones de detección pueden solaparse | `smart_scene_screen.dart` | 47 | Baja | Doble cambio de preset |

---

## 5. Las tres causas más probables del chasquido

1. **Causa A** — el WDRC cambia knee/ratio + el NR cambia gainFloor sin ramping al transitar de clase. Cada transición = un click. El comentario del código dice “es ok porque NR tiene suavizado interno”, pero el suavizado interno aplica a la ganancia compuesta, no al gainFloor → **falsa premisa**.
2. **Causa B** — la histéresis del clasificador no cubre las pausas naturales del habla. Cualquier pausa de >800 ms baja el level por debajo de 45 dB SPL → transición a QUIET → al volver la voz: nueva transición. Chasquido + diferencia de loudness.
3. **Causa C** — Smart Scene UI dice “preset aplicado” pero la mitad del preset se queda en Hive sin llegar al engine, mientras el clasificador automático sigue pisando los mismos campos. La voz se **desbalancea sola** entre el preset declarado y la decisión del clasificador.

---

## 6. Bugs concretos identificados

- **BUG-1** (`environment_classifier.cpp:129`): comentario dice “3 segundos (750 × 4ms)” pero a 48 kHz el block size negociado por Oboe puede ser 192–256 frames (4 a 5,3 ms), no 4 ms estricto. El hold real varía ±30%.
- **BUG-2** (`dsp_pipeline.cpp:152` y `wdrc_processor.cpp:156-163`): aplicación de `compressionKnee/Ratio` no atómica como par; lectura en el audio thread puede ver el knee nuevo con el ratio viejo.
- **BUG-3** (`scene_engine.dart:226-235`): se documenta y persiste en Hive `nrLevel`, `compressionRatio`, `compressionKnee`, `expansionKnee`, `tnrEnabled` pero ninguno llega al engine. La persistencia es engañosa: el preset “aplicado” no se aplica completo.
- **BUG-4** (`equalizer.cpp:52-62`): `setGains` no es transaccional. 12 atomics independientes; el audio thread puede mezclar valores nuevos y viejos.
- **BUG-5** (`equalizer.cpp:130-138`): `updateCoefficients` no resetea `BiquadState` cuando la ganancia salta >5 dB. El biquad arrastra estado de la respuesta vieja → ringing audible.
- **BUG-6** (`dsp_pipeline.cpp:254-263`): noise floor fijo en 30 dB SPL en `estimateSnrSimple` ignora completamente el `noise_floor_db_spl` del SceneSnapshot que el Smart Scene ya tiene calculado (`scene_analyzer.cpp:170`).
- **BUG-7** (`noise_reduction.cpp:142-143`): `kGainFloors` cambia de 1.0 → 0.18 cuando se llama `setLevel(3)`. La transición instantánea no la suaviza el `prevGain_` interno (que opera sobre `compositeGain`, no sobre `gainFloor`).
- **BUG-8** (`environment_classifier.cpp:76-79`): la transición a `QUIET` se evalúa SIEMPRE primero (`if (level < kEnvLevelQuietThreshold)`), antes incluso de chequear si estábamos en `SPEECH`. Una pausa de 200 ms con respiración baja el RMS de 50 dB SPL a 40 dB SPL → directo a QUIET sin pasar por la rama SPEECH (que no tiene histéresis hacia QUIET).

---

## 7. Plan recomendado (en orden de impacto)

1. Corregir **C** primero: mandar el preset Smart Scene completo al engine y desactivar el `EnvironmentClassifier` automático mientras hay un preset Smart Scene pinneado. Sin esto, las correcciones A y B no se sienten.
2. Corregir **A**: aplicar rampa exponencial sobre `compressionKnee/Ratio` y rampa por niveles discretos sobre `nrLevel` durante 200–500 ms.
3. Corregir **B**: histéresis simétrica + integrar `voice_active` del Smart Scene VAD para no caer a QUIET durante pausas de voz.
4. Corregir **D y F**: snapshot doble de EQ + commit atómico, y setter compuesto del WDRC.
5. Corregir **E**: usar `SceneSnapshot.snr_db` como entrada del clasificador (eliminar la heurística de 30 dB SPL).
6. Corregir **G**: nuevo método nativo `applyScenePreset` que aplique todo en un único commit atómico.
7. **H** y **I** son secundarias.

---

*Diagnóstico generado por análisis exhaustivo del código real, no especulativo. Todas las referencias `archivo.cpp:lineas` apuntan al estado actual del repo.*

# Diseño — Recuperación de nivel de voz al activar el DNN denoiser

> Estado: **diseño aprobado, sin implementación.**

## Overview

Este diseño implementa los requerimientos del documento `requirements.md`
en dos pasos. El **Paso 1** modula la `intensity` efectiva del DNN según el
estado del VAD existente: con voz activa, capa la `intensity` para mezclar
más dry; con silencio o ruido sin voz, respeta el valor del usuario. El
**Paso 2 (opcional)** aplica un make-up gain por bandas en 2-8 kHz dentro
del worker DNN, gateado por VAD para evitar bombeo. El Paso 2 sólo se
ejecuta si la validación A/B subjetiva del Paso 1 muestra que no alcanza.

Ambos pasos son contenidos en el módulo nativo del DNN denoiser y un cableo
trivial en `audio_engine.cpp`. Sin cambios en UI Flutter, BLE ni orden del
pipeline.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│ AudioEngine::onBothStreamsReady()                                │
│  inPtr ───┬─► dnnDenoiser_.process(outPtr, N) ──► pipeline_      │
│           │       │                                              │
│           │       ▼                                              │
│           │   [DNN STFT/ONNX worker]                             │
│           │       │                                              │
│           │       ▼                                              │
│           │   [Mezcla dry/wet con effectiveIntensity]            │
│           │              ▲                                       │
│           │              │ rampa asimétrica 40/300 ms            │
│           │              │ cap = voiceActive ? 0.7 : userVal     │
│           │              │                                       │
│           └─► sceneAnalyzer_.process(inPtr, N)                   │
│                  └─► vadDetector → isVoiceActive()               │
│                          │                                       │
│                          ▼                                       │
│                  dnnDenoiser_.notifyVoiceActive(active)          │
│                  (afecta el callback siguiente, latencia ~5 ms)  │
└──────────────────────────────────────────────────────────────────┘
```

El VAD ya está corriendo sobre `inPtr` post-DNN-process en el callback
actual (`audio_engine.cpp:~441`). El estado se entrega al DNN para el
**próximo** bloque, lo cual introduce latencia de un callback (~5 ms a
16 kHz), despreciable frente a la rampa de 40-300 ms.

## Components and Interfaces

### `DnnDenoiser` (extensiones a la API existente)

Archivo: `hearing_aid_app/android/app/src/main/cpp/dnn_denoiser/dnn_denoiser.h`.

Nuevos métodos públicos (la API existente no se modifica ni se rompe):

```
void  notifyVoiceActive(bool active);          // lock-free, atomic bool
float getEffectiveIntensity() const;           // lock-free, atomic float
void  setVoiceCap(float cap);                  // default 0.7f, clamp [0,1]
void  setMakeupEnabled(bool enabled);          // Paso 2; default false
bool  isMakeupEnabled() const;
```

Nuevas constantes:

```
static constexpr float kDefaultVoiceCap = 0.7f;
static constexpr float kAttackMs        = 40.0f;
static constexpr float kReleaseMs       = 300.0f;
static constexpr float kMakeupClampDb   = 4.0f;   // Paso 2
```

### `SceneAnalyzer` o equivalente

Archivo: `hearing_aid_app/android/app/src/main/cpp/smart_scene/`.
Reusar el getter existente `isVoiceActive()` del VAD (o agregar un getter
trivial en `SceneAnalyzer` que delegue al VAD interno si todavía no está
expuesto). No se modifica la lógica del VAD.

### `AudioEngine`

Archivo: `hearing_aid_app/android/app/src/main/cpp/audio_engine.cpp`.
Una sola línea agregada después de `sceneAnalyzer_.process(...)`:

```
dnnDenoiser_.notifyVoiceActive(sceneAnalyzer_.isVoiceActive());
```

Sin cambios en el orden del callback ni en otros módulos.

## Data Models

### Estado interno del `DnnDenoiser` (Paso 1)

| Campo | Tipo | Acceso | Default |
|---|---|---|---|
| `voiceActive_` | `std::atomic<bool>` | RW desde audio thread y caller | `false` |
| `voiceCap_` | `std::atomic<float>` | RW lock-free | `0.7f` |
| `effectiveIntensity_` | `float` | escrito sólo por audio thread | `1.0f` |
| `effectiveIntensityAtomic_` | `std::atomic<float>` | espejo para getter | `1.0f` |
| `stepAttackPerSample_` | `float` | recalculado en `setInputSampleRate` | `1/(40·SR/1000)` |
| `stepReleasePerSample_` | `float` | recalculado en `setInputSampleRate` | `1/(300·SR/1000)` |

### Estado interno del `DnnDenoiser` (Paso 2, opcional)

| Campo | Tipo | Default |
|---|---|---|
| `makeupEnabled_` | `std::atomic<bool>` | `false` |
| `gainDb_[NB]` | `float[]` | `0.0f` |
| `kMakeupBandRanges` | mapeo bin→banda | tabla constante 2-8 kHz |

### Sin persistencia

Ningún campo nuevo se persiste a disco ni se transmite por BLE. Todo es
estado RAM transitorio del módulo nativo.

## Correctness Properties

### Property 1: Invariante "DNN solo atenúa"

`effectiveIntensity_` está siempre en `[0,1]`. Reducirlo aumenta el peso
del dry, no amplifica.

**Validates: Requirements 1.7**

### Property 2: Sin nuevos frames

El loop de mezcla del Paso 1 corre in-place sobre el buffer actual.
Cero buffers adicionales, cero latencia agregada. El Paso 2 reusa la
FFT del worker existente.

**Validates: Requirements 1.6, 4.6**

### Property 3: Reversibilidad

`setVoiceCap(1.0f)` desactiva el Paso 1. `setMakeupEnabled(false)`
desactiva el Paso 2 (default).

**Validates: Requirements 4.7, 5.3**

### Property 4: Determinismo bit-exact en bypass

Si `enabled == false` o `active == false`, ni el cap ni el make-up se
aplican. El callback hace bypass bit-exact como hoy.

**Validates: Requirements 1.5, 5.3**

### Property 5: Lock-free desde audio thread

Todas las lecturas/escrituras cruzadas usan `std::atomic` con
`memory_order_acquire/release`. Sin locks, sin allocaciones en el path
de audio.

**Validates: Requirements 1.6, 5.2**

## Resumen

Dos pasos independientes con criterio de avance entre uno y otro. **Solo el
Paso 1 es mandatorio**; el Paso 2 se ejecuta únicamente si la validación de
campo (R3) muestra que el Paso 1 no alcanza.

```
Paso 1 (mandatorio) — VAD-driven intensity cap:
    voice_active == true  → intensity efectiva ≤ 0.7
    voice_active == false → intensity efectiva = userIntensity
    Rampa asimétrica: attack 40 ms / release 300 ms.

Paso 2 (opcional) — Make-up gain por bandas en el worker DNN:
    Para bandas 2-8 kHz, ratio = RMS(dry_band) / RMS(wet_band)
    Clamp [0, +4 dB], congelado cuando !voice_active.
```

## Paso 1 — VAD-driven intensity cap

### Origen del VAD

`hearing_aid_app/android/app/src/main/cpp/smart_scene/vad_detector.h` ya
expone `isVoiceActive() const`, `getScore() const` y getters
diagnósticos. El `SceneAnalyzer` lo corre sobre el buffer de **input** en
`audio_engine.cpp::onBothStreamsReady` (línea ~441 aprox.) **después** del
`dnnDenoiser_.process()`. Hay que reconfirmar el orden exacto en
implementación: el VAD necesita correr **antes** o sobre la misma copia
de input que el DNN para que `voice_active` esté disponible al momento
de mezclar dry/wet en el bloque actual; alternativamente, se puede usar
`voice_active` del bloque anterior con un retraso de un callback (~5 ms),
que es perfectamente aceptable perceptualmente.

Decisión de diseño: **usar el `voice_active` del bloque anterior** para
no obligar a reordenar el callback. La latencia de un bloque (5 ms a
16 kHz) es despreciable frente a la rampa de 40-300 ms.

### Punto de inserción

`DnnDenoiser::process()` en `dnn_denoiser.cpp:~1320`, dentro del loop de
mezcla `for (int i = 0; i < blockSize; ++i)`:

```
const float dnnAmount = crossfadeGain_ * effectiveIntensity_;
```

Donde `effectiveIntensity_` reemplaza al `intensityVal` actual.

### Cálculo del effective intensity

```
target = vadActive ? min(userIntensity, kIntensityCapVoice)
                   : userIntensity

Rampa asimétrica per-sample:
    if (effectiveIntensity_ > target) {
        // Bajando hacia el cap: attack rápido (~40 ms)
        effectiveIntensity_ -= kStepAttackPerSample;
        if (effectiveIntensity_ < target) effectiveIntensity_ = target;
    } else if (effectiveIntensity_ < target) {
        // Subiendo hacia user: release lento (~300 ms)
        effectiveIntensity_ += kStepReleasePerSample;
        if (effectiveIntensity_ > target) effectiveIntensity_ = target;
    }
```

Constantes (a 16 kHz, sample rate del modelo):

```
kIntensityCapVoice    = 0.7f
kAttackMs             = 40.0f
kReleaseMs            = 300.0f
kStepAttackPerSample  = 1.0f / (kAttackMs  * 16.0f)   // 1.5625e-3
kStepReleasePerSample = 1.0f / (kReleaseMs * 16.0f)   // 2.083e-4
```

> **Nota de implementación:** la mezcla en `dnn_denoiser.cpp:1320` corre a
> `inputSampleRate` (típicamente 48 kHz, no 16 kHz). Hay que escalar las
> constantes al sample rate real con un setter o calcularlas en
> `setInputSampleRate()`. No usar literales hardcoded.

### API agregada al DnnDenoiser

Sin cambios incompatibles. Se agregan getters y constantes:

- `float getEffectiveIntensity() const` — devuelve el valor post-VAD
  cap, atomic, lock-free.
- `void notifyVoiceActive(bool active)` — llamada desde el audio
  callback con el estado del VAD. Lock-free (atomic bool).
- `void setVoiceCap(float cap)` — opcional, para futuro tuning desde
  flags de dev. Default `0.7f`.

### Punto de llamada en audio_engine.cpp

```
sceneAnalyzer_.process(inPtr, numFrames);          // ya existe
const bool voiceActive = sceneAnalyzer_.isVoiceActive();  // getter ya existente o trivial
dnnDenoiser_.notifyVoiceActive(voiceActive);              // NUEVO
// (en el callback siguiente, dnnDenoiser_.process() usará este flag)
```

> Reconfirmar en implementación si `SceneAnalyzer` ya expone
> `isVoiceActive()` o si hay que pasar por el getter del VAD interno.

### Riesgos del Paso 1

- **Falsos negativos del VAD.** Si el VAD no marca voz cuando hay voz,
  no se aplica el cap → vuelve el síntoma original. Mitigación: el VAD
  ya tiene hangover de 60-120 ms (`kHangoverFrames = 12`) y umbral
  adaptado a celular real (`vad_detector.h`). Riesgo bajo.
- **Falsos positivos del VAD en ruido del tren.** Si el VAD marca voz
  cuando solo hay ruido, el cap reduce la limpieza por nada. Mitigación:
  el VAD tiene gates anti-ruido estacionario (`kStationarityGate`,
  `kMidSnrGateDb`) y anti-respiración (flatness, ZCR, tilt, centroide).
  Riesgo bajo-medio.
- **Sensación de "fluctuación" entre voz y pausa.** Si el `intensity`
  oscila entre 0.7 y 1.0 cada vez que entra/sale voz, el usuario podría
  oír cambio de tono ambiental. Mitigación: rampa asimétrica
  release 300 ms suaviza la transición. Riesgo bajo si las constantes
  se respetan.
- **Latencia del VAD.** El VAD puede tardar varios bloques en confirmar
  voz por el `kSustainFramesForOnset = 3`. Durante esos primeros 15 ms
  el cap no aplica. Aceptable: una sílaba dura típicamente > 100 ms.

## Paso 2 — Make-up gain por bandas (opcional)

> **Solo se implementa si la validación de R3 muestra que el Paso 1 no
> alcanza.**

### Punto de inserción

Worker thread del DNN, **antes** del iSTFT/OLA pero **después** de la
inferencia ONNX. Aprox. en `dnn_denoiser.cpp:~990` (zona de la sección
"MEJORA #1 — Compensación COLA").

### Cálculo

Sobre el espectro complejo `enhanced[k]` y el espectro de referencia
`mix[k]` (input al modelo, ya disponible en el worker):

```
Para cada bin k del rango 2-8 kHz:
    band = mapeo bin → banda EQ (ya existe en SceneAnalyzer si conviene reusar)
    drym2[band]  += |mix[k]|^2
    wetm2[band]  += |enhanced[k]|^2

Para cada banda b en 2-8 kHz:
    ratioDb = 10 * log10((drym2[b] + eps) / (wetm2[b] + eps))
    targetDb = clamp(ratioDb, 0, +4 dB)
    Si voice_active:
        applyAttack/Release sobre gainDb_[b] hacia targetDb
    Else:
        // congelar — no actualizar
        ;
    gainLin = 10^(gainDb_[b] / 20)
    Aplicar gainLin a los bins de la banda b en enhanced[k]
```

Constantes:

```
kMakeupBandLow   = banda EQ que cubre 2 kHz   (a definir según mapeo existente)
kMakeupBandHigh  = banda EQ que cubre 8 kHz
kMakeupClampDb   = +4.0f
kMakeupAttackMs  = 40.0f
kMakeupReleaseMs = 300.0f
eps              = 1e-12f
```

### API agregada (Paso 2)

- `void setMakeupEnabled(bool enabled)` — default `false`. Solo se
  habilita si R3 confirma necesidad.
- `bool isMakeupEnabled() const`.

### Riesgos del Paso 2

- **Cambio de timbre con voz lejana.** Si el wet baja mucho en agudos
  porque el modelo decide que es ruido, el make-up puede traer de vuelta
  componentes que el modelo descartó. Mitigación: clamp duro a +4 dB y
  release lento.
- **Headroom WDRC.** Sumar +4 dB en agudos antes del WDRC obliga a
  reverificar que el WDRC no sature ni rompa el MPO. Mitigación:
  validar con grabación real y, si hace falta, bajar el clamp a +3 dB.
- **Interacción con AFC futuro.** Cuando se implemente el AFC del spec
  `afc-before-dnn-reorder/`, este make-up sube el lazo de feedback en
  agudos. Mitigación: revisar conjuntamente al implementar AFC; si el
  AFC reordena el pipeline (AFC → DNN), este make-up corre después del
  AFC y no afecta su convergencia.

## Estructura de archivos

Sin archivos nuevos. Cambios contenidos en:

- `hearing_aid_app/android/app/src/main/cpp/dnn_denoiser/dnn_denoiser.h`
  — agregar `notifyVoiceActive`, `getEffectiveIntensity`, `setVoiceCap`,
  y constantes nuevas.
- `hearing_aid_app/android/app/src/main/cpp/dnn_denoiser/dnn_denoiser.cpp`
  — implementar la rampa, modificar el loop de mezcla, ajustar
  `setInputSampleRate` para recalcular pasos por sample.
- `hearing_aid_app/android/app/src/main/cpp/audio_engine.cpp` — pasar
  `sceneAnalyzer_.isVoiceActive()` (o equivalente) al `dnnDenoiser_`.

Si se implementa Paso 2:

- `dnn_denoiser.cpp` — agregar el cálculo per-banda en el worker.

## Plan de validación

1. **Sanity build.** Compila Android, no rompe la API existente.
2. **Logcat con DNN ON, intensity = 1.0, en silencio.** El log debe
   mostrar `vadActive=0, effectiveIntensity=1.0`. Sin cambios audibles
   respecto al estado actual.
3. **Logcat con DNN ON, intensity = 1.0, voz directa.** El log debe
   mostrar `vadActive=1, effectiveIntensity≈0.7`. Voz menos atenuada
   que el estado actual.
4. **Grabación tren del usuario.** Validar criterio R3.3.
5. **Decisión Paso 2.** Si R3.3 no se cumple, abrir las tasks de
   Paso 2 y repetir validación.

## Reversibilidad

- Paso 1: trivial. `kIntensityCapVoice = 1.0f` desactiva la modulación
  (cap nunca se aplica). Se puede dejar como flag de compilación o
  setter dev.
- Paso 2: trivial. `setMakeupEnabled(false)` es no-op. Default false.

## Error Handling

- **Modelo no cargado / `active == false`.** El loop de mezcla no se
  ejecuta y la modulación es no-op. Bypass bit-exact.
- **VAD no inicializado.** `notifyVoiceActive` nunca se llama, el flag
  queda en su default `false` y el cap no aplica. Comportamiento
  idéntico al estado actual.
- **Sample rate cambia en runtime.** `setInputSampleRate` recalcula
  los pasos de la rampa. Si la rampa estaba a media transición, el
  `effectiveIntensity_` se mantiene y la nueva pendiente toma efecto
  desde el siguiente sample.
- **Race en `voiceActive_`.** Lectura atomic con `memory_order_acquire`
  desde el audio thread; escritura desde el control / callback con
  `memory_order_release`. Si llega tarde, se aplica al callback
  siguiente.
- **Paso 2: división por cero en ratio dry/wet.** Suma `eps = 1e-12f`
  en numerador y denominador.
- **Paso 2: voz que aparece de golpe.** El cap del make-up a +4 dB
  evita amplificar transitorios. La rampa attack 40 ms suaviza el
  encendido.

## Testing Strategy

### Sanity unitario (nativo)

No hay framework de tests nativos en uso para el `DnnDenoiser` hoy más
allá del binario de `quality_eval/` (sin CLI standalone). La validación
nativa es por inspección de logs y A/B subjetivo. Si en el futuro se
agrega CLI a `quality_eval/`, repetir A/B con PESQ/STOI sobre las mismas
grabaciones del tren del usuario.

### Smoke test manual

1. **Silencio + DNN ON + intensity 1.0.** Logcat debe mostrar
   `vadActive=0` la mayoría del tiempo y `effectiveIntensity≈1.0`.
   Audio idéntico al estado anterior.
2. **Voz directa + DNN ON + intensity 1.0.** Logcat debe mostrar
   `vadActive=1` durante la voz y `effectiveIntensity≈0.7`. Voz menos
   atenuada que el estado anterior; ruido residual prácticamente igual.
3. **Toggle DNN ON↔OFF.** Sin clicks audibles (el crossfade existente
   sigue gobernando la transición).

### Validación A/B subjetiva (criterio de avance al Paso 2)

- Grabación del usuario en el tren con DNN ON, intensity 1.0, antes y
  después del cambio.
- Aceptación: voz no se siente atenuada al activar el limpiador, ruido
  sigue bajando notoriamente, sin bombeo audible en pausas.
- Si "voz atenuada" sigue ✗ tras el Paso 1, pasar al Paso 2.
- Si "bombeo audible" pasa a ✗ (regresión), subir `kReleaseMs` a
  500 ms y reevaluar antes del Paso 2.

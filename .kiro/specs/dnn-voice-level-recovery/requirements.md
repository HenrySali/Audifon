# Requirements Document

> Spec — Recuperación de nivel de voz al activar el DNN denoiser.
>
> Estado: **PENDIENTE — diseño aprobado, sin implementación.**

## Introduction

Origen: feedback del usuario en ambiente ruidoso (tren). Al activar el toggle
"Limpiador de ruido (IA)" (GTCRN ONNX) la voz se siente atenuada junto con el
ruido. En silencio el problema no aparece porque el modelo no tiene nada que
limpiar.

Este documento define los requerimientos funcionales y no funcionales del
cambio. El objetivo concreto es que al prender el limpiador la voz no pierda
nivel perceptible respecto al estado con limpiador apagado, sin tocar el
invariante "el DNN solo atenúa".

## Glossary

- **DNN denoiser**: módulo nativo basado en GTCRN ONNX que filtra ruido por
  red neuronal. Implementado en
  `hearing_aid_app/android/app/src/main/cpp/dnn_denoiser/`.
- **VAD**: Voice Activity Detector existente en
  `hearing_aid_app/android/app/src/main/cpp/smart_scene/vad_detector.h`.
  Devuelve `voice_active` con histéresis y hangover.
- **`intensity`**: coeficiente `[0,1]` de mezcla dry/wet del DNN. `0` = señal
  original, `1` = señal procesada por el modelo.
- **dry / wet**: señal original (sin DNN) / señal post-modelo.
- **Make-up gain**: ganancia compensatoria post-procesado para recuperar
  energía perdida por el modelo.
- **MPO**: Maximum Power Output, techo final del pipeline.
- **WDRC**: Wide Dynamic Range Compression, etapa de compresión multibanda.
- **AFC**: Adaptive Feedback Cancellation. No existe nativa todavía.

## Contexto del problema

GTCRN entrega su salida con menos energía que la entrada (trade-off conocido
de modelos tipo DNS Challenge sin make-up gain explícito). El wrapper C++
mezcla `dry/wet` con la fórmula:

```
mixed = dry * (1 - dnnAmount) + wet * dnnAmount
        donde dnnAmount = crossfadeGain * intensity
```

Ver `hearing_aid_app/android/app/src/main/cpp/dnn_denoiser/dnn_denoiser.cpp:1330-1340`.

Entre el modelo y la mezcla **no hay compensación de energía**. Las únicas
"compensaciones" presentes son matemáticas:

- Polyphase resampler 48↔16 kHz (`dnn_denoiser.cpp:~286`).
- Compensación COLA del STFT (`dnn_denoiser.cpp:~995-1015`, MEJORA #1 del
  paper de referencia `Amplificador/docs/ruido-profundo.md`).

El diseño actual es **explícito**: "el DNN solo atenúa, la amplificación se
reserva al WDRC". Está documentado en `dnn_denoiser.cpp:1006` y en
`Amplificador/docs/ruido-profundo.md:684`. La atenuación de voz residual
también está catalogada como trade-off conocido (Healy 2017,
`Amplificador/docs/ruido-profundo.md:691-694`: hasta 40 % mejora subjetiva
de SNR pero ~8 % degradación en muestras limpias; con `intensity > 0.9` ya
muerde habla).

## Por qué no hace falta tocar el invariante "DNN solo atenúa"

La sugerencia inicial del usuario fue agregar **make-up gain banda ancha**:
medir RMS dry/wet por bloque, calcular diferencia en dB, aplicar al wet con
suavizado de 200 ms y clamp [0, +6 dB].

Riesgos identificados sobre esa propuesta cruda:

1. **Bombeo en pausas.** En silencio entre palabras, `RMS(dry)/RMS(wet)`
   se dispara porque el wet residual cae cerca de cero. Aunque el clamp
   tope a +6 dB, modular el ruido residual a 200 ms es audible como
   "respiración" del compensador.
2. **Constante mal elegida.** 200 ms cae entre la *syllabic* WDRC
   (60-150 ms) y la *loudness* WDRC (500-3000 ms). Ni preserva sílabas
   ni se mantiene estable.
3. **Banda ancha enmascara el problema real.** GTCRN no atenúa parejo:
   sobre-suprime 2-8 kHz, donde viven fricativas y formantes. Compensar
   con un escalar global recupera nivel grave (vocales, ruido residual)
   sin recuperar inteligibilidad.
4. **Interacción con WDRC y techo MPO.** El make-up entra antes del WDRC,
   que compensa parte de él, y entre los dos se puede comer headroom MPO
   en transitorios.
5. **AFC ausente.** El AFC NLMS nativo no existe todavía
   (ver spec `afc-before-dnn-reorder/`, 0/21 tasks). Cualquier ganancia
   ciega adicional sube el techo de MSG sin red.

Por eso este spec evita el make-up banda ancha y propone primero un
camino más conservador que **mezcla más dry** cuando hay voz activa.

## Requirements

### R1 — Modulación de `intensity` por VAD (Paso 1, mandatorio)

**El sistema modula automáticamente la `intensity` efectiva del DNN según
el estado del VAD existente, sin amplificar ninguna señal nueva.**

- R1.1 Cuando `vad.isVoiceActive() == true`, la `intensity` efectiva se
  capa a un valor `kIntensityCapVoice` (default `0.7f`), independiente del
  valor seteado por el usuario.
- R1.2 Cuando `vad.isVoiceActive() == false`, la `intensity` efectiva
  respeta el valor del usuario completo (hasta `1.0f`).
- R1.3 La transición entre ambos estados es suavizada con una rampa
  asimétrica: attack ~40 ms al entrar voz (bajar intensity rápido hacia
  el cap), release ~300 ms al salir (subir intensity lento hacia el
  valor del usuario). Asimétrico estilo WDRC.
- R1.4 La modulación es **transparente al usuario**: el slider de la UI
  sigue mostrando el valor que el usuario seteó. El cap es interno.
- R1.5 Cuando el DNN está deshabilitado (`enabled == false`) o en
  bypass por error (`active == false`), la modulación es no-op.
- R1.6 La modulación NO introduce ningún frame adicional de latencia.
  Solo escala un coeficiente ya existente en la mezcla
  (`dnn_denoiser.cpp:1336`).
- R1.7 La modulación NO viola el invariante del steering "el DNN solo
  atenúa". `intensity` es siempre ≤ 1.0; reducir `intensity` mezcla
  más dry, no amplifica nada.

### R2 — Telemetría mínima (mandatorio)

- R2.1 Exponer `getEffectiveIntensity()` en la API pública del
  `DnnDenoiser` para que el log de diagnóstico pueda registrar el
  valor efectivo aplicado (distinto del `getIntensity()` actual que
  devuelve el valor del usuario).
- R2.2 Loguear cada ~2 s en logcat: `userIntensity`, `effectiveIntensity`,
  `vadActive`, sin floodear (mismo cadence que el `Input diag` actual
  en `audio_engine.cpp:~410-422`).
- R2.3 No agregar nuevo canal Flutter ↔ nativo todavía. El log basta
  para validación de campo.

### R3 — Validación con grabación real (mandatorio antes de publicar)

- R3.1 El usuario captura una grabación corta (~30 s) en el ambiente
  ruidoso (tren) con el toggle ON e intensity = 1.0. Antes y después
  del cambio.
- R3.2 Comparación A/B subjetiva por el usuario (no se requiere PESQ/STOI
  porque `tools/quality_eval/` no tiene CLI standalone hoy).
- R3.3 Criterio de aceptación: "la voz no se siente atenuada al activar
  el limpiador, el ruido sigue bajando notoriamente, no hay efecto de
  bombeo en pausas".

### R4 — Make-up por bandas (Paso 2, OPCIONAL — solo si R3 falla)

**Si el Paso 1 no recupera nivel suficiente, agregar compensación de
ganancia por bandas dentro del worker DNN, gateada por VAD.**

- R4.1 Se calcula el ratio RMS(dry)/RMS(wet) **por bandas**, NO banda
  ancha. La FFT del worker ya provee el espectro
  (`dnn_denoiser.cpp` STFT 512, ver `kDnnFftSize`).
- R4.2 La compensación se concentra en las bandas 2-8 kHz (donde GTCRN
  sobre-suprime más). Bandas graves quedan sin compensación.
- R4.3 Constantes asimétricas: attack ~40 ms, release ~300 ms.
- R4.4 Clamp inicial conservador a `[0, +4 dB]` por banda (más estricto
  que el +6 dB original). Se puede relajar después con medición.
- R4.5 Gating duro por VAD: con `voice_active == false`, congelar la
  ganancia en su último valor; **no** recalcular sobre ruido residual.
  Evita el bombeo en pausas.
- R4.6 No agrega frames de latencia: la FFT ya está dentro del worker
  y el cálculo es per-banda en cada hop.
- R4.7 Disponible detrás de un flag de compilación o un setter
  `setMakeupEnabled(bool)` que default a `false`. Solo se prende si
  R3 confirma que el Paso 1 no alcanza.

### R5 — No bloqueantes / interacciones

- R5.1 No bloquea ni depende del spec `afc-before-dnn-reorder/`. Puede
  desarrollarse en paralelo.
- R5.2 No toca el NR Wiener clásico (`noise_reduction.cpp`) ni el orden
  del pipeline en `audio_engine.cpp::onBothStreamsReady`.
- R5.3 No altera la API pública existente del DnnDenoiser
  (`hearing_aid_app/android/app/src/main/cpp/dnn_denoiser/dnn_denoiser.h`),
  solo la extiende.
- R5.4 No requiere cambios en la UI Flutter ni en BLE.

## Métricas de éxito

| Métrica | Estado actual | Objetivo |
|---|---|---|
| Sensación de voz atenuada con DNN ON en tren | Sí (reportado) | No |
| Reducción de ruido percibida con DNN ON en tren | Notoria | Notoria (sin regresión) |
| Bombeo audible en pausas | No (porque no hay make-up) | Mantener: no |
| Latencia algorítmica DNN | ~14-18 ms | Igual |
| Headroom MPO bajo transitorio | OK | OK (sin regresión) |
| Riesgo de Larsen sin AFC | Bajo (DNN solo atenúa) | Igual o menor |

## Fuera de alcance

- Implementación del AFC nativo Android (spec separado).
- Sustitución del modelo GTCRN por otro (DTLN, FullSubNet, etc.).
- Reentreno del modelo con dataset propio.
- Métricas objetivas PESQ/STOI hasta que `tools/quality_eval/` tenga CLI.
- Cambio del orden del pipeline (DNN sigue donde está hoy).
- Banda ancha de make-up gain (descartada por riesgo de bombeo y
  por no atacar la sobre-supresión de agudos).

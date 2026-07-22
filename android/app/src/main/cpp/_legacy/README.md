# `_legacy/` — Código DSP Reservado por Referencia Histórica

Este directorio contiene código que **NO se compila** (no aparece en
`CMakeLists.txt`) y que se mantiene únicamente como referencia histórica
del camino de exploración del proyecto.

## Contenido

### `rnnoise_stub/` — RNNoise (Mozilla/Xiph) en su versión "stub"

Conjunto de archivos `.c` / `.h` provenientes del repositorio upstream
[xiph/rnnoise](https://gitlab.xiph.org/xiph/rnnoise) que llegaron al
proyecto en una iteración previa de la investigación de DNN denoising.
Estos archivos por sí solos **no compilan ni denoisean** porque:

- Faltan los pesos de la red neuronal embebidos (no se descargó el
  archivo `rnn_data.c` con los coeficientes).
- La integración con el pipeline DSP nativo nunca se completó.
- El sample rate nativo de RNNoise (48 kHz) no coincide con el del
  pipeline (16 kHz para GTCRN, sin resampler embebido).

### `rnnoise_nr.cpp` / `rnnoise_nr.h` — Wrapper C++ no funcional

Wrapper tipo "SubVI" estilo LabVIEW pensado para envolver al RNNoise
stub anterior con una interfaz `process(buffer, size)` /
`setLevel(int)` / `reset()`. Como el motor RNNoise nunca pudo
inicializarse, este wrapper **nunca se incluyó en `CMakeLists.txt`**
ni se ejecutó en producción.

## ¿Por qué se conserva?

1. **Documentar el camino de decisión.** Esta exploración llevó a la
   decisión de reemplazar RNNoise por **GTCRN** (operativo a 16 kHz,
   modelo más liviano, integrado vía OnnxRuntime). Ver
   `cpp/dnn_denoiser/` para la implementación viva.
2. **Permitir reanudar el camino RNNoise** si en el futuro se
   reconsidera (por ejemplo, si GTCRN da problemas en producción).
3. **Trazabilidad para auditorías** (estándares ANSI/IEC y trabajos
   académicos): mostramos qué se evaluó y descartó, no sólo qué se
   adoptó.

## Reglas

- ❌ No agregar estos archivos a `CMakeLists.txt`.
- ❌ No incluir `_legacy/...` desde otros archivos del proyecto.
- ✅ Si reviven, moverlos fuera de `_legacy/` y documentar la decisión
  en `Amplificador/docs/`.

Última revisión: 2025-11 — al activar el wrapper GTCRN
(`cpp/dnn_denoiser/`) como reemplazo del NR Wiener clásico cuando se
habilita el denoiser DNN.

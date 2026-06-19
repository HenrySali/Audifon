# Filtro de Ruido (GTCRN)

Este módulo es el **filtro de ruido** del sistema. Nombre interno: `dnn_denoiser`.

## Qué hace

Atenúa el ruido ambiental (calle, tráfico, viento, multitalker) preservando la voz del interlocutor. Usa una red neuronal profunda (GTCRN — Grouped Temporal Convolutional Recurrent Network) ejecutada vía OnnxRuntime.

## Especificaciones

- **Modelo:** GTCRN (112K parámetros, 0.22 MMAC)
- **Latencia:** < 5 ms
- **Asset:** `dnn_denoiser/gtcrn.onnx` (en `assets/`)
- **Frecuencias atenuadas:** broadband (100–8000 Hz), con mayor eficacia en ruido estacionario (motor, AC) y buena en no-estacionario (bocinas, babble)
- **Preserva inteligibilidad del habla:** sí

## Archivos

| Archivo | Función |
|---|---|
| `dnn_denoiser.h` | Header público — interfaz `DnnDenoiser` (init, process, enable/disable, intensity) |
| `dnn_denoiser.cpp` | Implementación: ring buffers SPSC, worker thread, inferencia ONNX |
| `onnxruntime/` | Headers de OnnxRuntime C API (v1.16.3) |

## Conexión al sistema

Se conecta al pipeline DSP vía `audio_engine.cpp`:
- `AudioEngine::initDnnDenoiser()` — carga el modelo
- `AudioEngine::onBothStreamsReady()` — procesa cada bloque antes del pipeline principal
- Activación/desactivación desde Dart: `setDnnEnabled(bool)` + `setDnnIntensity(float)`

## Nota

No renombrar esta carpeta sin actualizar `CMakeLists.txt`, `audio_engine.h`, `audio_engine.cpp`, el asset path en Kotlin, y los archivos Dart en `lib/dnn_denoiser/`.

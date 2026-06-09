# CMakeLists.txt — Pipeline DSP nativo para PSK Hearing Aid (Oboe)
# Compila el motor de audio C++ que procesa audio en tiempo real vía JNI

cmake_minimum_required(VERSION 3.22.1)
project("hearing_aid_dsp" LANGUAGES CXX)

# Estándar C++17 para features modernos
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Optimizaciones para procesamiento de audio en tiempo real.
# NOTA: NO usamos -fno-exceptions porque OnnxRuntime C++ API requiere try/catch
# para reportar errores de inferencia. El resto del pipeline DSP no lanza
# excepciones, así que el costo es marginal.
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O2 -ffast-math")
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3 -ffast-math -DNDEBUG")

# Find Oboe package (provided via prefab)
find_package(oboe REQUIRED CONFIG)

# ─────────────────────────────────────────────────────────────────────────────
# OnnxRuntime — librería compartida prebuilt en jniLibs/<ABI>/
# ─────────────────────────────────────────────────────────────────────────────
# El .so vive en jniLibs/arm64-v8a/libonnxruntime.so y los headers se
# descargaron a cpp/dnn_denoiser/onnxruntime/ desde el release oficial
# microsoft/onnxruntime (v1.16.3, ver Amplificador/docs/dnn-assets-downloaded.md).
add_library(onnxruntime SHARED IMPORTED)
set_target_properties(onnxruntime PROPERTIES
    IMPORTED_LOCATION
        "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libonnxruntime.so"
)

# Librería compartida del DSP pipeline
add_library(
    hearing_aid_dsp
    SHARED
    # Puente JNI (Kotlin ↔ C++)
    native_bridge.cpp
    # Motor de audio (Oboe FullDuplexStream)
    audio_engine.cpp
    # Pipeline DSP completo
    dsp_pipeline.cpp
    # Módulos individuales del pipeline
    noise_reduction.cpp
    equalizer.cpp
    wdrc_processor.cpp
    mpo_limiter.cpp
    environment_classifier.cpp
    # Analizador de espectro (FFT 128-point Cooley-Tukey)
    spectrum_analyzer.cpp
    # Smart Scene Engine (Fase 1) — análisis espectral + VAD pitch-based
    smart_scene/spectral_features.cpp
    smart_scene/vad_detector.cpp
    smart_scene/noise_profile.cpp
    smart_scene/scene_analyzer.cpp
    # Calibration Spectrum Validator (Fase 1+2) — motor matemático autocontenido
    calibration_spectrum/fft_engine.cpp
    calibration_spectrum/peak_detector.cpp
    calibration_spectrum/thd_calculator.cpp
    calibration_spectrum/tone_analyzer.cpp
    # DNN Denoiser (GTCRN vía OnnxRuntime) — reemplazo del NR Wiener cuando enabled
    dnn_denoiser/dnn_denoiser.cpp
    # Grabador de diagnóstico DSP (captura dual-channel pre/post DSP)
    diagnostic_recorder.cpp
)

# Enlazar con Oboe, librerías del sistema Android, y OnnxRuntime
target_link_libraries(
    hearing_aid_dsp
    android
    log
    oboe::oboe
    onnxruntime
)

# Incluir headers del directorio actual + headers de OnnxRuntime locales
target_include_directories(
    hearing_aid_dsp
    PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/dnn_denoiser
)

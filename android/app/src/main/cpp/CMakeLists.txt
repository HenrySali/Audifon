# CMakeLists.txt — Pipeline DSP nativo para PSK Hearing Aid (Oboe)
# Compila el motor de audio C++ que procesa audio en tiempo real vía JNI

cmake_minimum_required(VERSION 3.22.1)
# LANGUAGES CXX C: se añadió C para compilar los sources vendorizados de
# xiph/rnnoise (denoise.c, rnn.c, kiss_fft.c, pitch.c, celt_lpc.c,
# rnn_data.c, rnn_reader.c). El wrapper C++ (rnnoise_denoiser.cpp) los
# incluye vía extern "C" y CMake se encarga del linkage.
project("hearing_aid_dsp" LANGUAGES CXX C)

# Estándar C++17 para features modernos
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# RNNoise fue escrito para C89/C99. -std=c11 le va bien y no rompe nada.
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

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
    transient_reducer.cpp
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
    # DenoiserSelector — toggle exclusivo entre RNNoise/DFN3/GTCRN con crossfade
    denoiser_selector.cpp
    # DeepFilterNet3 wrapper (dlopen de libdfn3.so en runtime)
    dfn3_denoiser.cpp
    # RNNoise denoiser wrapper + vendored xiph/rnnoise v0.1.1 sources
    #   Statically linked. No dlopen, no asset extraction, no ONNX runtime.
    #   Frame size 480 @ 48 kHz. Model baked into the .so (~90 KB compressed).
    rnnoise_denoiser.cpp
    rnnoise/src/denoise.c
    rnnoise/src/rnn.c
    rnnoise/src/rnn_data.c
    rnnoise/src/rnn_reader.c
    rnnoise/src/pitch.c
    rnnoise/src/kiss_fft.c
    rnnoise/src/celt_lpc.c
    # Diagnostic Recorder (grabación dual-channel pre/post DSP)
    diagnostic_recorder.cpp
    # Latency Loopback Tester (chirp + cross-correlation para medir latencia round-trip)
    latency_loopback_tester.cpp
    # DTLN Denoiser (Dual-signal Transformation LSTM Network) — replaces GTCRN
    #   Two-stage: spectral mask (LSTM) + time-domain refinement (LSTM).
    #   No band-gating artifacts. Models: assets/dtln/model_1.onnx + model_2.onnx.
    #   Frame 512 @ 16 kHz (32 ms). MIT license (breizhn/DTLN).
    dtln_denoiser.cpp
)

# Enlazar con Oboe, librerías del sistema Android y OnnxRuntime
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
    ${CMAKE_CURRENT_SOURCE_DIR}/rnnoise/include
    ${CMAKE_CURRENT_SOURCE_DIR}/rnnoise/src
)

# RNNoise C sources — enable strict math and vendor-specific defines.
#   -DRNNOISE_BUILD  : matches the visibility guard in include/rnnoise.h
#   -Wno-unused-*    : the vendored sources are 3rd-party; don't fail the build
#                      on warnings that don't originate in our code.
set_source_files_properties(
    rnnoise/src/denoise.c
    rnnoise/src/rnn.c
    rnnoise/src/rnn_data.c
    rnnoise/src/rnn_reader.c
    rnnoise/src/pitch.c
    rnnoise/src/kiss_fft.c
    rnnoise/src/celt_lpc.c
    PROPERTIES
    COMPILE_FLAGS
    "-DRNNOISE_BUILD -Wno-unused-function -Wno-unused-variable -Wno-unused-parameter -Wno-sign-compare"
)

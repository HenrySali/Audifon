# CMakeLists.txt — Pipeline DSP nativo para PSK Hearing Aid (Oboe)
# Compila el motor de audio C++ que procesa audio en tiempo real vía JNI

cmake_minimum_required(VERSION 3.22.1)
project("hearing_aid_dsp" LANGUAGES CXX)

# Estándar C++17 para features modernos
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Optimizaciones para procesamiento de audio en tiempo real
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O2 -ffast-math -fno-exceptions")
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3 -ffast-math -DNDEBUG")

# Find Oboe package (provided via prefab)
find_package(oboe REQUIRED CONFIG)

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
)

# Enlazar con Oboe y librerías del sistema Android
target_link_libraries(
    hearing_aid_dsp
    android
    log
    oboe::oboe
)

# Incluir headers del directorio actual
target_include_directories(
    hearing_aid_dsp
    PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

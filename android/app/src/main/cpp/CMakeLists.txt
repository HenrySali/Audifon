# CMakeLists.txt — Pipeline DSP nativo para PSK Hearing Aid (Oboe)
# Compila el motor de audio C++ que procesa audio en tiempo real vía JNI

cmake_minimum_required(VERSION 3.22.1)
project("hearing_aid_dsp" LANGUAGES C CXX)

# Estándar C++17 para features modernos
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# C99 para los fuentes de RNNoise
set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Optimizaciones para procesamiento de audio en tiempo real
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O2 -ffast-math -fno-exceptions")
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3 -ffast-math -DNDEBUG")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -O2 -ffast-math")
set(CMAKE_C_FLAGS_RELEASE "${CMAKE_C_FLAGS_RELEASE} -O3 -ffast-math -DNDEBUG")

# Find Oboe package (provided via prefab)
find_package(oboe REQUIRED CONFIG)

# ─────────────────────────────────────────────────────────────────────────────
# RNNoise — Recurrent Neural Network noise suppression (C library)
# ─────────────────────────────────────────────────────────────────────────────
set(RNNOISE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/rnnoise)

add_library(
    rnnoise
    STATIC
    ${RNNOISE_DIR}/denoise.c
    ${RNNOISE_DIR}/rnn.c
    ${RNNOISE_DIR}/pitch.c
    ${RNNOISE_DIR}/celt_lpc.c
    ${RNNOISE_DIR}/kiss_fft.c
)

target_include_directories(
    rnnoise
    PUBLIC
    ${RNNOISE_DIR}
)

# Suprimir warnings en código C de terceros
target_compile_options(
    rnnoise
    PRIVATE
    -w
)

# ─────────────────────────────────────────────────────────────────────────────
# Librería compartida del DSP pipeline
# ─────────────────────────────────────────────────────────────────────────────
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
    rnnoise_nr.cpp
    equalizer.cpp
    wdrc_processor.cpp
    mpo_limiter.cpp
)

# Enlazar con Oboe, RNNoise y librerías del sistema Android
target_link_libraries(
    hearing_aid_dsp
    android
    log
    oboe::oboe
    rnnoise
)

# Incluir headers del directorio actual y de RNNoise
target_include_directories(
    hearing_aid_dsp
    PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${RNNOISE_DIR}
)

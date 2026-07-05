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

# ─────────────────────────────────────────────────────────────────────────────
# PyTorch Full JIT Runtime (LibTorch) — runtime para modelo GTCRN dual-channel (.ptl)
# ─────────────────────────────────────────────────────────────────────────────
# Las .so se extraen del AAR org.pytorch:pytorch_android:2.1.0 y se
# colocan en jniLibs/arm64-v8a/ (mismo patron que OnnxRuntime).
# Libs requeridas: libpytorch_jni.so, libc10.so, libfbjni.so
#
# Headers del Full JIT Interpreter se colocan en:
#   cpp/dnn_denoiser/pytorch_lite/
# (descargados del release oficial pytorch/pytorch, branch v2.1.0,
#  directorio torch/csrc/api/include/ + JIT headers)
#
# NOTA: migracion de pytorch_android_lite a pytorch_android (full runtime)
# requerida porque el modelo fue trazado con torch.jit.trace(model,
# torch.randn(1,2,48000)) y el lite interpreter crasheaba con SIGSEGV
# al pasar T != 48000. El full JIT interpreter maneja los shapes correctamente.
#
# Nota sobre conflictos: tanto ORT como LibTorch usan internamente XNNPACK
# para cuantizacion; no deberia haber conflicto de simbolos porque cada lib
# empaqueta su propia copia como dependencia interna (linkeo estatico interno).
# Si surgiera conflicto, la solucion es recompilar una de las dos con
# -fvisibility=hidden (ORT ya lo hace por defecto).
# ─────────────────────────────────────────────────────────────────────────────

set(PYTORCH_JNI_SO "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libpytorch_jni.so")

if(EXISTS "${PYTORCH_JNI_SO}")
    message(STATUS "PyTorch Full JIT: encontrado en jniLibs/${ANDROID_ABI}/")
    set(HAVE_PYTORCH ON)

    # Libreria principal del Full JIT Runtime.
    # NOTA: en pytorch_android:2.1.0 la core tensor library (libc10)
    # viene FUSIONADA dentro de libpytorch_jni.so (por eso pesa ~60 MB),
    # NO se distribuye libc10.so por separado. Por eso NO declaramos un
    # target c10 aparte: linkeamos solo pytorch_jni + fbjni.
    add_library(pytorch_jni SHARED IMPORTED)
    set_target_properties(pytorch_jni PROPERTIES
        IMPORTED_LOCATION "${PYTORCH_JNI_SO}"
    )

    # libfbjni — Facebook JNI helpers (dependencia transitiva)
    add_library(fbjni SHARED IMPORTED)
    set_target_properties(fbjni PROPERTIES
        IMPORTED_LOCATION
            "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libfbjni.so"
    )
else()
    message(WARNING "PyTorch Full JIT: .so NO encontradas en jniLibs/${ANDROID_ABI}/. "
        "Ejecutar extract_pytorch_libs.bat para descargarlas del AAR. "
        "El DNN Denoiser dual-channel no compilara hasta resolver esto.")
    set(HAVE_PYTORCH OFF)
endif()

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
    # Diagnostic Recorder (grabación dual-channel pre/post DSP)
    diagnostic_recorder.cpp
    # Latency Loopback Tester (chirp + cross-correlation para medir latencia round-trip)
    latency_loopback_tester.cpp
)

# Enlazar con Oboe, librerías del sistema Android, OnnxRuntime, y PyTorch Full JIT
target_link_libraries(
    hearing_aid_dsp
    android
    log
    oboe::oboe
    onnxruntime
)

# Linkear PyTorch Full JIT solo si las .so estan presentes.
# c10 va fusionado dentro de libpytorch_jni.so (no es un target aparte).
if(HAVE_PYTORCH)
    target_link_libraries(hearing_aid_dsp pytorch_jni fbjni)
    target_compile_definitions(hearing_aid_dsp PRIVATE HAVE_PYTORCH=1)

    # FIX linker lld + libpytorch_jni.so prebuilt:
    # El .so prebuilt de pytorch_android:2.1.0 trae en su tabla de
    # simbolos entradas legacy (__bss_end__, __end__, __bss_start, _edata,
    # _end) marcadas como LOCAL pero ubicadas en la parte GLOBAL de la
    # symtab. El linker lld del NDK 25 las rechaza con:
    #   "ld: error: found local symbol '__bss_end__' in global part of
    #    symbol table in file libpytorch_jni.so"
    # Es un bug conocido del empaquetado de PyTorch Android (pytorch/pytorch
    # #51020, #129633; ndk-samples #769). El diagnostico de lld es
    # degradable: --no-fatal-warnings evita que aborte el link. No afecta el
    # runtime (el dynamic loader usa .dynsym, no la symtab estatica).
    target_link_options(hearing_aid_dsp PRIVATE "-Wl,--no-fatal-warnings")
endif()

# Incluir headers del directorio actual + headers de OnnxRuntime locales
# + headers de PyTorch Full JIT (torch::jit::load API) si disponibles
target_include_directories(
    hearing_aid_dsp
    PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/dnn_denoiser
)

if(HAVE_PYTORCH)
    target_include_directories(
        hearing_aid_dsp
        PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/dnn_denoiser/pytorch_lite
    )
endif()

/// @file rnnoise_nr.cpp
/// @brief Implementación del wrapper C++ para RNNoise noise reduction.
///
/// Estrategia de buffering:
/// - RNNoise requiere frames de exactamente 480 muestras (10ms a 48kHz)
/// - El pipeline DSP entrega bloques de tamaño variable (típicamente 64-256)
/// - Este wrapper acumula muestras en un buffer interno hasta completar 480
/// - Cuando se completa un frame, se procesa con RNNoise y las muestras
///   denoised se almacenan en un buffer de salida
/// - Las muestras de salida se entregan al caller conforme las solicita
///
/// Conversión de escala:
/// - Pipeline DSP usa float [-1.0, +1.0]
/// - RNNoise espera float [-32768.0, +32768.0] (escala int16)
/// - Se multiplica por 32768 antes de RNNoise y se divide después
///
/// Mezcla dry/wet por nivel:
/// - output = dry * (1 - wetMix) + wet * wetMix
/// - Esto permite control gradual de la intensidad del NR

#include "rnnoise_nr.h"

extern "C" {
#include "rnnoise/rnnoise.h"
}

#include <cstring>
#include <cmath>
#include <algorithm>

// ─────────────────────────────────────────────────────────────────────────────
// Constantes
// ─────────────────────────────────────────────────────────────────────────────

/// Escala de conversión: float [-1,1] → float [-32768,32768]
static constexpr float kScaleToRnnoise = 32768.0f;

/// Escala inversa: float [-32768,32768] → float [-1,1]
static constexpr float kScaleFromRnnoise = 1.0f / 32768.0f;

/// Factores de mezcla wet por nivel (0=bypass, 1=suave, 2=medio, 3=agresivo)
static constexpr float kWetMixFactors[4] = {
    0.0f,   // Level 0: bypass completo
    0.3f,   // Level 1: 30% wet — preserva naturalidad
    0.6f,   // Level 2: 60% wet — balance
    1.0f,   // Level 3: 100% wet — máxima reducción
};

// ─────────────────────────────────────────────────────────────────────────────
// Constructor / Destructor
// ─────────────────────────────────────────────────────────────────────────────

RnnoiseNr::RnnoiseNr()
    : state_(nullptr)
    , inputBufferPos_(0)
    , outputBufferPos_(0)
    , outputBufferAvail_(0)
    , firstFrameProcessed_(false) {
    // Crear estado de RNNoise (usa modelo built-in)
    state_ = rnnoise_create(nullptr);

    // Limpiar buffers
    std::memset(inputBuffer_, 0, sizeof(inputBuffer_));
    std::memset(outputBuffer_, 0, sizeof(outputBuffer_));
}

RnnoiseNr::~RnnoiseNr() {
    if (state_) {
        rnnoise_destroy(state_);
        state_ = nullptr;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reset
// ─────────────────────────────────────────────────────────────────────────────

void RnnoiseNr::reset() {
    // Destruir y recrear el estado de RNNoise (reset completo del RNN)
    if (state_) {
        rnnoise_destroy(state_);
    }
    state_ = rnnoise_create(nullptr);

    // Limpiar buffers de acumulación
    std::memset(inputBuffer_, 0, sizeof(inputBuffer_));
    std::memset(outputBuffer_, 0, sizeof(outputBuffer_));
    inputBufferPos_ = 0;
    outputBufferPos_ = 0;
    outputBufferAvail_ = 0;
    firstFrameProcessed_ = false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Procesamiento principal
// ─────────────────────────────────────────────────────────────────────────────

void RnnoiseNr::process(float* buffer, int blockSize) {
    if (buffer == nullptr || blockSize <= 0) {
        return;
    }

    // Si NR está desactivado (nivel 0), pass-through sin modificar
    int currentLevel = level_.load(std::memory_order_relaxed);
    if (currentLevel == 0) {
        return;
    }

    // Verificar que RNNoise está inicializado
    if (state_ == nullptr) {
        return;
    }

    float wetMix = getWetMix();

    int samplesProcessed = 0;

    while (samplesProcessed < blockSize) {
        // --- Fase 1: Entregar muestras ya procesadas del outputBuffer ---
        if (outputBufferAvail_ > 0 && firstFrameProcessed_) {
            int toDeliver = std::min(outputBufferAvail_, blockSize - samplesProcessed);

            for (int i = 0; i < toDeliver; ++i) {
                float dry = buffer[samplesProcessed + i];
                float wet = outputBuffer_[outputBufferPos_ + i];
                // Mezcla dry/wet según nivel
                buffer[samplesProcessed + i] = dry * (1.0f - wetMix) + wet * wetMix;
            }

            outputBufferPos_ += toDeliver;
            outputBufferAvail_ -= toDeliver;
            samplesProcessed += toDeliver;
            continue;
        }

        // --- Fase 2: Acumular muestras en inputBuffer ---
        int toAccumulate = std::min(kRnnoiseFrameSize - inputBufferPos_,
                                    blockSize - samplesProcessed);

        std::memcpy(&inputBuffer_[inputBufferPos_],
                    &buffer[samplesProcessed],
                    static_cast<size_t>(toAccumulate) * sizeof(float));

        inputBufferPos_ += toAccumulate;
        samplesProcessed += toAccumulate;

        // --- Fase 3: Si tenemos un frame completo, procesarlo ---
        if (inputBufferPos_ >= kRnnoiseFrameSize) {
            // Copiar input al output buffer (para mezcla dry/wet)
            std::memcpy(outputBuffer_, inputBuffer_, sizeof(outputBuffer_));

            // Procesar el frame con RNNoise
            processFrame(outputBuffer_);

            // Marcar output disponible
            outputBufferPos_ = 0;
            outputBufferAvail_ = kRnnoiseFrameSize;
            firstFrameProcessed_ = true;

            // Reset input buffer
            inputBufferPos_ = 0;

            // Retroceder samplesProcessed para re-entregar las muestras
            // que acabamos de acumular (ahora están en outputBuffer)
            samplesProcessed -= toAccumulate;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Procesamiento de frame RNNoise
// ─────────────────────────────────────────────────────────────────────────────

void RnnoiseNr::processFrame(float* frame) {
    // Convertir de escala [-1,1] a escala RNNoise [-32768,32768]
    for (int i = 0; i < kRnnoiseFrameSize; ++i) {
        frame[i] *= kScaleToRnnoise;
    }

    // Procesar con RNNoise (in-place)
    rnnoise_process_frame(state_, frame, frame);

    // Convertir de vuelta a escala [-1,1]
    for (int i = 0; i < kRnnoiseFrameSize; ++i) {
        frame[i] *= kScaleFromRnnoise;
        // Asegurar que NR solo atenúa — clamp a [-1,1]
        frame[i] = std::max(-1.0f, std::min(1.0f, frame[i]));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Utilidades
// ─────────────────────────────────────────────────────────────────────────────

float RnnoiseNr::getWetMix() const {
    int level = level_.load(std::memory_order_relaxed);
    level = std::max(0, std::min(3, level));
    return kWetMixFactors[level];
}

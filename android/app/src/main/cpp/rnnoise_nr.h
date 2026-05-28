/// @file rnnoise_nr.h
/// @brief Reducción de ruido basada en RNNoise (red neuronal recurrente).
///
/// Reemplaza la reducción de ruido Wiener con RNNoise de Mozilla/Xiph.
/// Mantiene la misma interfaz pública que NoiseReduction (process, setLevel, reset)
/// para integración transparente en el pipeline DSP.
///
/// Diseño:
/// - RNNoise opera a 48kHz con frames de exactamente 480 muestras (10ms)
/// - El wrapper acumula muestras hasta completar un frame de 480
/// - Convierte float [-1,1] ↔ float [-32768,32768] (escala de RNNoise)
/// - Niveles 0-3 controlan mezcla dry/wet (0=bypass, 1=30%, 2=60%, 3=100%)
/// - Thread-safe: nivel atómico para actualizaciones desde UI
///
/// Restricciones:
/// - NR solo atenúa: la salida nunca excede la entrada en amplitud
/// - Latencia adicional: hasta 10ms (480 muestras a 48kHz) por buffering
/// - El pipeline del sistema ya opera a 48kHz, compatible directamente

#ifndef HEARING_AID_RNNOISE_NR_H
#define HEARING_AID_RNNOISE_NR_H

#include <atomic>
#include <cstdint>

// Forward declaration — evita incluir headers C de RNNoise en código C++
struct DenoiseState;

/// Tamaño de frame requerido por RNNoise (480 muestras = 10ms a 48kHz)
static constexpr int kRnnoiseFrameSize = 480;

/// Reducción de ruido basada en RNNoise (Deep RNN).
///
/// Interfaz compatible con NoiseReduction para reemplazo directo en DspPipeline.
/// Internamente acumula muestras hasta completar frames de 480 para RNNoise.
///
/// Niveles de intensidad (mezcla dry/wet):
/// - 0: Bypass (sin procesamiento)
/// - 1: Suave (30% wet, 70% dry) — preserva más naturalidad
/// - 2: Medio (60% wet, 40% dry) — balance
/// - 3: Agresivo (100% wet) — máxima reducción de ruido
class RnnoiseNr {
public:
    RnnoiseNr();
    ~RnnoiseNr();

    // No copiable ni movible (contiene estado C opaco)
    RnnoiseNr(const RnnoiseNr&) = delete;
    RnnoiseNr& operator=(const RnnoiseNr&) = delete;
    RnnoiseNr(RnnoiseNr&&) = delete;
    RnnoiseNr& operator=(RnnoiseNr&&) = delete;

    /// Procesa un bloque de audio aplicando reducción de ruido in-place.
    /// @param buffer Puntero al buffer de audio float32 [-1.0, +1.0]
    /// @param blockSize Número de muestras en el buffer
    ///
    /// El bloque puede ser de cualquier tamaño. Internamente se acumulan
    /// muestras hasta completar frames de 480 para RNNoise. Las muestras
    /// procesadas se escriben de vuelta al buffer; las pendientes se
    /// almacenan internamente hasta el próximo llamado.
    void process(float* buffer, int blockSize);

    /// Establece el nivel de reducción de ruido.
    /// @param level 0=off, 1=suave(30%), 2=medio(60%), 3=agresivo(100%)
    void setLevel(int level) {
        level_.store(level, std::memory_order_relaxed);
    }

    /// Obtiene el nivel actual de NR.
    int getLevel() const {
        return level_.load(std::memory_order_relaxed);
    }

    /// Reinicia el estado interno (RNN state, buffers de acumulación).
    void reset();

private:
    /// Procesa un frame completo de 480 muestras a través de RNNoise.
    /// @param frame Buffer de 480 muestras float [-1,1] (modificado in-place)
    void processFrame(float* frame);

    /// Obtiene el factor de mezcla wet para el nivel actual.
    /// @return Factor wet: 0.0 (bypass), 0.3, 0.6, o 1.0
    float getWetMix() const;

    // --- Estado RNNoise ---
    DenoiseState* state_;  ///< Estado opaco de RNNoise (heap-allocated)

    // --- Buffer de acumulación ---
    /// Buffer circular para acumular muestras hasta completar un frame.
    float inputBuffer_[kRnnoiseFrameSize];
    /// Número de muestras actualmente en el buffer de acumulación.
    int inputBufferPos_;

    /// Buffer de salida con muestras procesadas pendientes de entregar.
    float outputBuffer_[kRnnoiseFrameSize];
    /// Posición de lectura en el buffer de salida.
    int outputBufferPos_;
    /// Número de muestras disponibles en el buffer de salida.
    int outputBufferAvail_;

    /// Flag: indica si ya se procesó al menos un frame (para evitar
    /// entregar basura en las primeras muestras).
    bool firstFrameProcessed_;

    // --- Parámetro atómico ---
    std::atomic<int> level_{2};  ///< Nivel NR: 0=off, 1=suave, 2=medio, 3=agresivo
};

#endif // HEARING_AID_RNNOISE_NR_H

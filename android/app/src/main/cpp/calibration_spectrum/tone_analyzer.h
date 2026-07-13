/// @file tone_analyzer.h
/// @brief Orquestador del análisis de tono: integra FFT + peak + THD + SNR.
///
/// Acumula muestras desde el thread de audio, dispara FFT cuando llena la
/// ventana, y publica un `ToneSnapshot` thread-safe para que la UI lo lea.
///
/// API pensada para ser invocada por el wrapper de audio (audio_engine)
/// o, en tests offline, alimentada manualmente con buffers sintéticos.

#ifndef HEARING_AID_CALIBRATION_SPECTRUM_TONE_ANALYZER_H
#define HEARING_AID_CALIBRATION_SPECTRUM_TONE_ANALYZER_H

#include <atomic>
#include <cstdint>
#include <mutex>
#include <vector>

#include "fft_engine.h"
#include "tone_types.h"

namespace cal_spectrum {

/// Configuración del analyzer.
struct ToneAnalyzerConfig {
    float       sample_rate_hz   = 48000.0f;
    int         fft_size         = 4096;
    WindowType  window           = WindowType::Hann;
    int         harmonics_count  = 4;            ///< 4 clínico (H2-H5) o 7 premium (H2-H8).
    float       dbfs_to_dbspl_offset = 76.0f;    ///< 76 para WAV, 120 para MEMS calibrado.
};

/// Analizador de tono autocontenido.
///
/// Modo de uso desde el thread de audio:
/// @code
///   tone_analyzer.configure({...});
///   tone_analyzer.setExpectedFrequency(1000.0f);
///   tone_analyzer.setNoiseFloor(0.001f);   // amplitud lineal
///   tone_analyzer.setActive(true);
///   // En el callback de audio:
///   tone_analyzer.process(input, n_samples);
///   // Desde la UI:
///   ToneSnapshot snap = tone_analyzer.getSnapshot();
/// @endcode
class ToneAnalyzer {
public:
    ToneAnalyzer();
    ~ToneAnalyzer();

    ToneAnalyzer(const ToneAnalyzer&) = delete;
    ToneAnalyzer& operator=(const ToneAnalyzer&) = delete;

    // ─── Configuración ──────────────────────────────────────────────────

    /// Configura sample rate, tamaño de FFT y ventana. Aloca buffers internos.
    /// @return true si la configuración es válida.
    bool configure(const ToneAnalyzerConfig& cfg);

    /// Cambia la frecuencia esperada del tono actual (sin reiniciar buffers).
    void setExpectedFrequency(float expected_hz);

    /// Establece el piso de ruido medido en amplitud lineal (0..1).
    /// Usado para el chequeo de "señal detectada" y el cálculo de SNR.
    void setNoiseFloor(float noise_floor_amplitude_lin, float noise_floor_dbfs);

    /// Activa/desactiva el procesamiento. Cuando está inactivo, process() es no-op.
    void setActive(bool active);

    /// Limpia el buffer de acumulación y el snapshot. Llamar entre tonos.
    void reset();

    // ─── Procesamiento ──────────────────────────────────────────────────

    /// Procesa un bloque de muestras desde el thread de audio.
    /// Acumula hasta llenar fft_size, luego dispara FFT + métricas.
    void process(const float* block, int n_samples);

    /// Procesa un buffer completo de fft_size muestras de una sola vez.
    /// Útil para tests offline (no acumula).
    /// @return true si se actualizó el snapshot.
    bool processFullWindow(const float* buffer, int n_samples);

    // ─── Lectura ────────────────────────────────────────────────────────

    /// Obtiene el último snapshot computado (thread-safe).
    ToneSnapshot getSnapshot() const;

    /// Estado actual.
    bool isActive() const { return active_.load(std::memory_order_relaxed); }
    bool isConfigured() const { return configured_; }
    int  fftSize() const { return cfg_.fft_size; }

private:
    /// Computa FFT + métricas sobre `accum_buffer_` y actualiza `snapshot_`.
    void computeAndPublish();

    ToneAnalyzerConfig cfg_;
    bool               configured_ = false;
    std::atomic<bool>  active_{false};

    FftEngine          fft_;

    // Acumulación de muestras de entrada.
    std::vector<float> accum_buffer_;
    int                accum_pos_ = 0;

    // Frecuencia esperada (atómica para permitir cambios cross-thread).
    std::atomic<float> expected_freq_hz_{0.0f};

    // Piso de ruido.
    std::atomic<float> noise_floor_lin_{0.0f};
    std::atomic<float> noise_floor_dbfs_{-120.0f};

    // Snapshot publicado (protegido por mutex liviano).
    mutable std::mutex snapshot_mtx_;
    ToneSnapshot       snapshot_{};

    // Tiempo de origen para timestamp_us del snapshot.
    uint64_t origin_us_ = 0;
};

}  // namespace cal_spectrum

#endif  // HEARING_AID_CALIBRATION_SPECTRUM_TONE_ANALYZER_H

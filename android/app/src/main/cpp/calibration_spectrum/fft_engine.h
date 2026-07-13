/// @file fft_engine.h
/// @brief FFT propia del módulo Calibration Spectrum Validator.
///
/// Cooley-Tukey radix-2 in-place con tamaño configurable en runtime.
/// Devuelve coeficientes complejos crudos (re/im) sin agrupar en bandas
/// ni convertir a dB. Esto es esencial para Quinn's Second Estimator y
/// para el cálculo de THD por bins individuales.
///
/// NO depende de `spectrum_analyzer.cpp` ni de ningún otro módulo del proyecto.
///
/// Justificación de diseño:
/// - Tamaño configurable (1024 / 4096 / 8192) → resolución suficiente para 250 Hz.
/// - Output complejo (re/im) → habilita Quinn's Second Estimator (Quinn 1994).
/// - Hann y Blackman-Harris precomputadas → cero costo trigonométrico en runtime.

#ifndef HEARING_AID_CALIBRATION_SPECTRUM_FFT_ENGINE_H
#define HEARING_AID_CALIBRATION_SPECTRUM_FFT_ENGINE_H

#include <cstdint>
#include <vector>

#include "tone_types.h"

namespace cal_spectrum {

/// Resultado de un FFT compute().
/// `real` e `imag` apuntan a buffers internos del engine, válidos hasta
/// la próxima llamada a `compute()`. NO liberar.
struct FftResult {
    const float* real;     ///< N coeficientes reales.
    const float* imag;     ///< N coeficientes imaginarios.
    int          n_bins;   ///< Tamaño de la FFT (igual a fft_size).
    bool         valid;    ///< true si el output es matemáticamente válido.
};

/// Motor FFT autocontenido para el validador de calibración.
///
/// Uso típico:
/// @code
///   FftEngine fft;
///   fft.init(4096, WindowType::Hann);     // tamaño + ventana
///   const auto result = fft.compute(buffer, n_samples);
///   // result.real[k], result.imag[k] son los coeficientes del bin k
/// @endcode
class FftEngine {
public:
    FftEngine();
    ~FftEngine();

    // Copia y asignación deshabilitadas: el engine posee buffers internos.
    FftEngine(const FftEngine&) = delete;
    FftEngine& operator=(const FftEngine&) = delete;

    /// Inicializa el engine con tamaño de FFT y tipo de ventana.
    /// @param fft_size Debe ser potencia de 2 entre 256 y 16384.
    /// @param window Hann (default) o BlackmanHarris (low-leakage).
    /// @return true si se inicializó correctamente.
    bool init(int fft_size, WindowType window);

    /// Computa la FFT del buffer de entrada.
    /// Si `n_samples < fft_size`, el resto se rellena con ceros (zero-pad).
    /// Si `n_samples > fft_size`, se usan las primeras `fft_size` muestras.
    /// @param buffer Muestras de entrada.
    /// @param n_samples Número de muestras del buffer.
    /// @return FftResult con coeficientes complejos.
    FftResult compute(const float* buffer, int n_samples);

    /// Tamaño de la FFT configurada (0 si no inicializado).
    int fft_size() const { return fft_size_; }

    /// Tipo de ventana configurado.
    WindowType window_type() const { return window_; }

    /// Equivalent Noise Bandwidth (ENBW) de la ventana actual, en bins.
    /// Útil para calibrar magnitudes en dB FS. Hann ≈ 1.5 bins.
    float enbw_bins() const { return enbw_bins_; }

private:
    /// Precomputa la ventana en `window_buffer_` según `window_type`.
    void buildWindow();

    /// Cooley-Tukey radix-2 in-place sobre `real_` e `imag_`.
    void runFftInPlace();

    int        fft_size_     = 0;
    WindowType window_       = WindowType::Hann;
    float      enbw_bins_    = 1.0f;
    bool       initialized_  = false;

    // Buffers internos (alocados en init, reusados en cada compute).
    std::vector<float> window_buffer_;  ///< Ventana precomputada (fft_size).
    std::vector<float> real_;           ///< Parte real (fft_size).
    std::vector<float> imag_;           ///< Parte imaginaria (fft_size).
};

}  // namespace cal_spectrum

#endif  // HEARING_AID_CALIBRATION_SPECTRUM_FFT_ENGINE_H

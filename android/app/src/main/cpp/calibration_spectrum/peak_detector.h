/// @file peak_detector.h
/// @brief Detección de pico espectral con precisión sub-bin.
///
/// Implementa Quinn's Second Estimator (Quinn 1994) sobre coeficientes
/// complejos crudos (re/im) de la FFT. Si Quinn no converge o produce NaN/Inf,
/// usa interpolación parabólica de tres puntos en log-magnitud (Smith / CCRMA)
/// como fallback robusto.
///
/// Justificación: ventana Hann + zero-pad ≥ 2× requeridos para precisión
/// óptima del Quinn 2nd estimator (Jacobsen & Kootsookos).

#ifndef HEARING_AID_CALIBRATION_SPECTRUM_PEAK_DETECTOR_H
#define HEARING_AID_CALIBRATION_SPECTRUM_PEAK_DETECTOR_H

#include <cmath>
#include <cstdint>

namespace cal_spectrum {

/// Resultado de buscar un pico espectral.
struct PeakResult {
    float peak_freq_hz;          ///< Frecuencia interpolada sub-bin (Hz).
    float peak_magnitude_lin;    ///< Magnitud lineal del pico (sqrt(re²+im²)).
    float peak_magnitude_dbfs;   ///< Magnitud en dB FS = 20·log10(lin / fft_size · 2).
    int   peak_bin_index;        ///< Índice del bin más fuerte (entero).
    bool  detected;              ///< true si se encontró un pico válido sobre el floor.
    bool  used_quinn;            ///< true si Quinn convergió, false si fallback parabólico.
};

/// Detector de picos espectrales con precisión sub-bin.
///
/// Stateless: los métodos son funciones puras sobre arrays.
class PeakDetector {
public:
    /// Busca el pico de mayor magnitud cerca de `expected_hz`.
    ///
    /// @param real Coeficientes reales del FFT (n_bins).
    /// @param imag Coeficientes imaginarios del FFT (n_bins).
    /// @param n_bins Tamaño de la FFT (n_bins/2 corresponde a Nyquist).
    /// @param sample_rate_hz Frecuencia de muestreo.
    /// @param expected_hz Frecuencia esperada del tono (centro de búsqueda).
    /// @param search_window_pct Ventana de búsqueda como fracción ±search_window_pct
    ///        de expected_hz (default 0.20 = ±20%).
    /// @param noise_floor_lin Piso de ruido lineal; si el pico no lo supera por
    ///        20 dB, se considera "no detectado". 0.0 deshabilita el chequeo.
    /// @return PeakResult con frecuencia y magnitud interpoladas.
    static PeakResult findPeak(const float* real,
                               const float* imag,
                               int n_bins,
                               float sample_rate_hz,
                               float expected_hz,
                               float search_window_pct = 0.20f,
                               float noise_floor_lin = 0.0f);

    /// Igual que findPeak pero busca alrededor de un bin específico (sin
    /// recalcular el rango). Usado por THDCalculator para los armónicos.
    ///
    /// @param real Coeficientes reales.
    /// @param imag Coeficientes imaginarios.
    /// @param n_bins Tamaño de la FFT.
    /// @param sample_rate_hz Sample rate.
    /// @param target_bin Bin nominal alrededor del cual buscar.
    /// @param search_radius Bins a cada lado del target (default 2).
    /// @return PeakResult.
    static PeakResult findPeakAroundBin(const float* real,
                                        const float* imag,
                                        int n_bins,
                                        float sample_rate_hz,
                                        int target_bin,
                                        int search_radius = 2);

    /// Quinn's Second Estimator: estima la posición fraccional del pico
    /// sobre tres bins complejos consecutivos (k-1, k, k+1).
    ///
    /// @param re_km1 Re del bin k-1.
    /// @param im_km1 Im del bin k-1.
    /// @param re_k   Re del bin k (máximo).
    /// @param im_k   Im del bin k.
    /// @param re_kp1 Re del bin k+1.
    /// @param im_kp1 Im del bin k+1.
    /// @return Delta fraccional [-0.5, 0.5] respecto del bin k. NaN si falla.
    static float quinnSecondEstimator(float re_km1, float im_km1,
                                      float re_k,   float im_k,
                                      float re_kp1, float im_kp1);

    /// Interpolación parabólica en log-magnitud sobre tres bins (CCRMA).
    /// Más robusta que Quinn cuando hay ruido alto.
    /// @return Delta fraccional [-0.5, 0.5] respecto del bin central.
    static float parabolicInterpolation(float mag_km1, float mag_k, float mag_kp1);
};

/// Conversión utilitaria magnitud lineal → dB FS, normalizando por el tamaño
/// de la FFT (factor 2/N para single-sided spectrum).
inline float magnitudeToDbFs(float magnitude_lin, int fft_size) {
    if (magnitude_lin <= 0.0f || fft_size <= 0) {
        return -200.0f;
    }
    const float normalized = magnitude_lin * 2.0f / static_cast<float>(fft_size);
    return 20.0f * std::log10(normalized + 1e-20f);
}

}  // namespace cal_spectrum

#endif  // HEARING_AID_CALIBRATION_SPECTRUM_PEAK_DETECTOR_H

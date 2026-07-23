/// @file thd_calculator.h
/// @brief Cálculo de Total Harmonic Distortion (THD) según ANSI S3.22 / IEC 60118-7.
///
/// Implementa la fórmula normativa:
///     %THD = sqrt(H2² + H3² + ... + HN²) / |H1| × 100
///
/// Cada armónico HK se localiza en su bin nominal (K × f1) y se refina
/// con sub-bin precision usando PeakDetector::findPeakAroundBin.
///
/// Armónicos fuera de Nyquist (K · f1 > sample_rate/2) se omiten y se
/// registran. NO contaminan el cálculo.

#ifndef HEARING_AID_CALIBRATION_SPECTRUM_THD_CALCULATOR_H
#define HEARING_AID_CALIBRATION_SPECTRUM_THD_CALCULATOR_H

#include <cstdint>

namespace cal_spectrum {

/// Resultado del cálculo de THD.
struct ThdResult {
    float thd_percent;            ///< %THD = sqrt(sum(Hk²))/|H1| × 100. NaN si inválido.
    float harmonics_lin[8];       ///< Magnitudes lineales H2..H9. NaN si fuera de Nyquist.
    int   harmonics_count;        ///< Número de armónicos solicitados (4 o 7).
    int   harmonics_included;     ///< Número de armónicos efectivamente usados.
    uint8_t harmonics_skipped_mask; ///< Bit K-2 = 1 si HK fue omitido.
    bool  valid;                  ///< true si H1 > 0 y al menos un armónico fue válido.
};

/// Calculador de THD por FFT de coeficientes complejos.
///
/// Stateless: el método compute() es una función pura.
class ThdCalculator {
public:
    /// Calcula %THD a partir de los coeficientes complejos del FFT.
    ///
    /// @param real Coeficientes reales del FFT.
    /// @param imag Coeficientes imaginarios del FFT.
    /// @param n_bins Tamaño de la FFT.
    /// @param sample_rate_hz Frecuencia de muestreo.
    /// @param h1_freq_hz Frecuencia detectada del fundamental (peak_freq_hz).
    /// @param h1_magnitude_lin Magnitud lineal del fundamental.
    /// @param harmonics_count 4 (clínico, H2-H5) o 7 (premium, H2-H8).
    ///        Máximo soportado: 8 (H2-H9).
    /// @return ThdResult.
    static ThdResult compute(const float* real,
                             const float* imag,
                             int n_bins,
                             float sample_rate_hz,
                             float h1_freq_hz,
                             float h1_magnitude_lin,
                             int harmonics_count);
};

}  // namespace cal_spectrum

#endif  // HEARING_AID_CALIBRATION_SPECTRUM_THD_CALCULATOR_H

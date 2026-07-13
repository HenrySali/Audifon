/// @file snr_calculator.h
/// @brief Cálculo de SNR contra piso de ruido.
///
/// SNR_dB = 20 · log10(|H1| / noise_floor_amplitude)
///
/// Casos especiales:
/// - noise_floor_amplitude ≤ 0.0 → +Infinity (señal ideal o floor inválido).
/// - peak_magnitude_lin ≤ 0.0 → -Infinity (señal cero).

#ifndef HEARING_AID_CALIBRATION_SPECTRUM_SNR_CALCULATOR_H
#define HEARING_AID_CALIBRATION_SPECTRUM_SNR_CALCULATOR_H

#include <cmath>
#include <limits>

namespace cal_spectrum {

class SnrCalculator {
public:
    /// Calcula SNR en dB.
    /// @param peak_magnitude_lin Magnitud lineal del pico (sqrt(re²+im²) sin normalizar).
    /// @param noise_floor_amplitude_lin Amplitud lineal del piso de ruido.
    /// @return SNR en dB. +Inf si noise_floor ≤ 0; -Inf si peak ≤ 0.
    static float compute(float peak_magnitude_lin, float noise_floor_amplitude_lin) {
        if (!std::isfinite(peak_magnitude_lin) || !std::isfinite(noise_floor_amplitude_lin)) {
            return std::numeric_limits<float>::quiet_NaN();
        }
        if (peak_magnitude_lin <= 0.0f) {
            return -std::numeric_limits<float>::infinity();
        }
        if (noise_floor_amplitude_lin <= 0.0f) {
            return std::numeric_limits<float>::infinity();
        }
        return 20.0f * std::log10(peak_magnitude_lin / noise_floor_amplitude_lin);
    }
};

}  // namespace cal_spectrum

#endif  // HEARING_AID_CALIBRATION_SPECTRUM_SNR_CALCULATOR_H

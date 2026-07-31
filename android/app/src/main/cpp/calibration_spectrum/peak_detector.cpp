/// @file peak_detector.cpp
/// @brief Implementación de PeakDetector (Quinn 2nd + fallback parabólico).

#include "peak_detector.h"

#include <algorithm>
#include <cmath>

namespace cal_spectrum {

namespace {

constexpr float kMagFloor = 1e-20f;

/// Magnitud al cuadrado: re² + im².
inline float magSq(float re, float im) {
    return re * re + im * im;
}

/// Magnitud lineal: sqrt(re² + im²).
inline float magLin(float re, float im) {
    return std::sqrt(magSq(re, im));
}

/// Convierte índice de bin → frecuencia Hz.
inline float binToHz(float bin, float sample_rate, int n_bins) {
    return bin * sample_rate / static_cast<float>(n_bins);
}

/// Convierte Hz → índice de bin.
inline float hzToBin(float hz, float sample_rate, int n_bins) {
    return hz * static_cast<float>(n_bins) / sample_rate;
}

/// Función τ de Quinn (1994), usada por el Second Estimator.
/// Argumento x es positivo (típicamente δ²).
/// τ(x) = (1/4)·log(3x² + 6x + 1) - (√6/24)·log((x - 1 + √(2/3))/(x - 1 - √(2/3)))
float quinnTau(float x) {
    const float sqrt23 = 0.81649658092773f;  // √(2/3)
    const float arg1   = 3.0f * x * x + 6.0f * x + 1.0f;
    if (arg1 <= 0.0f) return 0.0f;

    const float num = (x - 1.0f + sqrt23);
    const float den = (x - 1.0f - sqrt23);
    if (den == 0.0f) return 0.0f;
    const float ratio = num / den;
    if (ratio <= 0.0f) return 0.0f;  // log indefinido → no aplicar corrección

    return 0.25f * std::log(arg1) - (std::sqrt(6.0f) / 24.0f) * std::log(ratio);
}

}  // namespace

// ─────────────────────────────────────────────────────────────────────────────
// findPeak — busca pico en ventana ±search_window_pct alrededor de expected_hz
// ─────────────────────────────────────────────────────────────────────────────

PeakResult PeakDetector::findPeak(const float* real,
                                  const float* imag,
                                  int n_bins,
                                  float sample_rate_hz,
                                  float expected_hz,
                                  float search_window_pct,
                                  float noise_floor_lin) {
    PeakResult res{};
    res.peak_freq_hz = std::numeric_limits<float>::quiet_NaN();
    res.peak_magnitude_lin = 0.0f;
    res.peak_magnitude_dbfs = -200.0f;
    res.peak_bin_index = -1;
    res.detected = false;
    res.used_quinn = false;

    if (real == nullptr || imag == nullptr || n_bins <= 4 ||
        sample_rate_hz <= 0.0f || expected_hz <= 0.0f ||
        search_window_pct < 0.0f) {
        return res;
    }

    // Rango de bins de Nyquist: [1, n_bins/2 - 1] (DC y Nyquist excluidos).
    const int nyquist_bin = n_bins / 2;

    const float center_bin_f = hzToBin(expected_hz, sample_rate_hz, n_bins);
    const float half_window  = search_window_pct * center_bin_f;

    int lo = static_cast<int>(std::floor(center_bin_f - half_window));
    int hi = static_cast<int>(std::ceil(center_bin_f + half_window));

    lo = std::max(lo, 1);
    hi = std::min(hi, nyquist_bin - 1);

    if (hi < lo) {
        return res;
    }

    // Buscar bin de máxima magnitud al cuadrado.
    int best_bin = lo;
    float best_mag2 = magSq(real[lo], imag[lo]);
    for (int k = lo + 1; k <= hi; ++k) {
        const float m2 = magSq(real[k], imag[k]);
        if (m2 > best_mag2) {
            best_mag2 = m2;
            best_bin  = k;
        }
    }

    const float peak_lin = std::sqrt(best_mag2);

    // Chequeo de detección contra el floor (si se especificó).
    // Criterio: pico debe superar floor por al menos 20 dB (factor 10× lineal).
    if (noise_floor_lin > 0.0f) {
        if (peak_lin < noise_floor_lin * 10.0f) {
            res.peak_bin_index = best_bin;
            res.peak_freq_hz = binToHz(static_cast<float>(best_bin), sample_rate_hz, n_bins);
            res.peak_magnitude_lin = peak_lin;
            res.peak_magnitude_dbfs = magnitudeToDbFs(peak_lin, n_bins);
            res.detected = false;
            return res;
        }
    } else {
        if (peak_lin <= kMagFloor) {
            return res;
        }
    }

    // Sub-bin precision.
    float delta = std::numeric_limits<float>::quiet_NaN();
    bool used_quinn = false;

    if (best_bin >= 1 && best_bin <= nyquist_bin - 2) {
        delta = quinnSecondEstimator(
            real[best_bin - 1], imag[best_bin - 1],
            real[best_bin],     imag[best_bin],
            real[best_bin + 1], imag[best_bin + 1]);

        used_quinn = std::isfinite(delta) && std::fabs(delta) <= 0.5f;

        if (!used_quinn) {
            // Fallback a parabólica en log-magnitud.
            const float m_km1 = magLin(real[best_bin - 1], imag[best_bin - 1]);
            const float m_k   = peak_lin;
            const float m_kp1 = magLin(real[best_bin + 1], imag[best_bin + 1]);
            delta = parabolicInterpolation(m_km1, m_k, m_kp1);
            if (!std::isfinite(delta) || std::fabs(delta) > 0.5f) {
                delta = 0.0f;
            }
        }
    } else {
        delta = 0.0f;
    }

    const float peak_bin_f = static_cast<float>(best_bin) + delta;

    res.peak_freq_hz       = binToHz(peak_bin_f, sample_rate_hz, n_bins);
    res.peak_magnitude_lin = peak_lin;
    res.peak_magnitude_dbfs = magnitudeToDbFs(peak_lin, n_bins);
    res.peak_bin_index     = best_bin;
    res.detected           = true;
    res.used_quinn         = used_quinn;

    return res;
}

// ─────────────────────────────────────────────────────────────────────────────
// findPeakAroundBin — variante para armónicos (búsqueda por radio en bins)
// ─────────────────────────────────────────────────────────────────────────────

PeakResult PeakDetector::findPeakAroundBin(const float* real,
                                           const float* imag,
                                           int n_bins,
                                           float sample_rate_hz,
                                           int target_bin,
                                           int search_radius) {
    PeakResult res{};
    res.peak_freq_hz       = std::numeric_limits<float>::quiet_NaN();
    res.peak_magnitude_lin = 0.0f;
    res.peak_magnitude_dbfs = -200.0f;
    res.peak_bin_index     = -1;
    res.detected           = false;
    res.used_quinn         = false;

    if (real == nullptr || imag == nullptr || n_bins <= 4 ||
        sample_rate_hz <= 0.0f || search_radius < 0) {
        return res;
    }
    const int nyquist_bin = n_bins / 2;

    int lo = std::max(1, target_bin - search_radius);
    int hi = std::min(nyquist_bin - 1, target_bin + search_radius);
    if (hi < lo) return res;

    int best_bin = lo;
    float best_mag2 = magSq(real[lo], imag[lo]);
    for (int k = lo + 1; k <= hi; ++k) {
        const float m2 = magSq(real[k], imag[k]);
        if (m2 > best_mag2) {
            best_mag2 = m2;
            best_bin  = k;
        }
    }

    const float peak_lin = std::sqrt(best_mag2);
    if (peak_lin <= kMagFloor) {
        res.peak_bin_index = best_bin;
        res.peak_freq_hz   = binToHz(static_cast<float>(best_bin), sample_rate_hz, n_bins);
        return res;
    }

    float delta = 0.0f;
    bool used_quinn = false;

    if (best_bin >= 1 && best_bin <= nyquist_bin - 2) {
        delta = quinnSecondEstimator(
            real[best_bin - 1], imag[best_bin - 1],
            real[best_bin],     imag[best_bin],
            real[best_bin + 1], imag[best_bin + 1]);

        used_quinn = std::isfinite(delta) && std::fabs(delta) <= 0.5f;

        if (!used_quinn) {
            const float m_km1 = magLin(real[best_bin - 1], imag[best_bin - 1]);
            const float m_kp1 = magLin(real[best_bin + 1], imag[best_bin + 1]);
            delta = parabolicInterpolation(m_km1, peak_lin, m_kp1);
            if (!std::isfinite(delta) || std::fabs(delta) > 0.5f) {
                delta = 0.0f;
            }
        }
    }

    const float peak_bin_f = static_cast<float>(best_bin) + delta;
    res.peak_freq_hz       = binToHz(peak_bin_f, sample_rate_hz, n_bins);
    res.peak_magnitude_lin = peak_lin;
    res.peak_magnitude_dbfs = magnitudeToDbFs(peak_lin, n_bins);
    res.peak_bin_index     = best_bin;
    res.detected           = true;
    res.used_quinn         = used_quinn;
    return res;
}

// ─────────────────────────────────────────────────────────────────────────────
// Quinn's Second Estimator (Quinn 1994)
// ─────────────────────────────────────────────────────────────────────────────

float PeakDetector::quinnSecondEstimator(float re_km1, float im_km1,
                                         float re_k,   float im_k,
                                         float re_kp1, float im_kp1) {
    const float mag2_k = magSq(re_k, im_k);
    if (mag2_k <= kMagFloor) {
        return std::numeric_limits<float>::quiet_NaN();
    }

    // αp = Re(X[k+1] · conj(X[k])) / |X[k]|²
    // αm = Re(X[k-1] · conj(X[k])) / |X[k]|²
    const float ap = (re_kp1 * re_k + im_kp1 * im_k) / mag2_k;
    const float am = (re_km1 * re_k + im_km1 * im_k) / mag2_k;

    // Quinn II: δp = αp / (1 - αp), δm = -αm / (1 - αm)
    if (std::fabs(1.0f - ap) < 1e-9f || std::fabs(1.0f - am) < 1e-9f) {
        return std::numeric_limits<float>::quiet_NaN();
    }
    const float dp =  ap / (1.0f - ap);
    const float dm = -am / (1.0f - am);

    // Estimador final: δ = (dp + dm)/2 + τ(dp²) - τ(dm²)
    const float tau_dp = quinnTau(dp * dp);
    const float tau_dm = quinnTau(dm * dm);

    const float delta = 0.5f * (dp + dm) + tau_dp - tau_dm;

    if (!std::isfinite(delta)) {
        // Fallback al First Estimator si τ degeneró.
        if (dp > 0.0f && dm > 0.0f) return dp;
        return dm;
    }
    return delta;
}

// ─────────────────────────────────────────────────────────────────────────────
// Interpolación parabólica de tres puntos (CCRMA)
// ─────────────────────────────────────────────────────────────────────────────

float PeakDetector::parabolicInterpolation(float mag_km1, float mag_k, float mag_kp1) {
    // Trabajar en log-magnitud para mejor estabilidad.
    if (mag_k <= 0.0f) {
        return std::numeric_limits<float>::quiet_NaN();
    }
    const float a = std::log(std::max(mag_km1, kMagFloor));
    const float b = std::log(mag_k);
    const float c = std::log(std::max(mag_kp1, kMagFloor));

    // δ = 0.5 · (a - c) / (a - 2b + c)
    const float den = a - 2.0f * b + c;
    if (std::fabs(den) < 1e-12f) {
        return 0.0f;
    }
    return 0.5f * (a - c) / den;
}

}  // namespace cal_spectrum

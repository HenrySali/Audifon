/// @file thd_calculator.cpp
/// @brief Implementación de ThdCalculator.

#include "thd_calculator.h"

#include <algorithm>
#include <cmath>
#include <limits>

#include "peak_detector.h"

namespace cal_spectrum {

namespace {

constexpr int   kMaxHarmonics = 8;     // H2..H9
constexpr float kMagFloor     = 1e-20f;

/// Constexpr NaN portátil.
const float kNan = std::numeric_limits<float>::quiet_NaN();

}  // namespace

ThdResult ThdCalculator::compute(const float* real,
                                 const float* imag,
                                 int n_bins,
                                 float sample_rate_hz,
                                 float h1_freq_hz,
                                 float h1_magnitude_lin,
                                 int harmonics_count) {
    ThdResult res{};
    for (int i = 0; i < kMaxHarmonics; ++i) {
        res.harmonics_lin[i] = kNan;
    }
    res.thd_percent          = kNan;
    res.harmonics_count      = harmonics_count;
    res.harmonics_included   = 0;
    res.harmonics_skipped_mask = 0;
    res.valid                = false;

    if (real == nullptr || imag == nullptr || n_bins <= 4 ||
        sample_rate_hz <= 0.0f ||
        !std::isfinite(h1_freq_hz) || h1_freq_hz <= 0.0f ||
        !std::isfinite(h1_magnitude_lin) || h1_magnitude_lin <= kMagFloor ||
        harmonics_count <= 0) {
        return res;
    }

    const int clamped_count = std::min(harmonics_count, kMaxHarmonics);
    const float nyquist     = sample_rate_hz * 0.5f;

    float sum_squares = 0.0f;
    int   included    = 0;

    for (int idx = 0; idx < clamped_count; ++idx) {
        // Armónico K-ésimo: K = idx + 2 (idx=0 → H2)
        const int   K              = idx + 2;
        const float harmonic_freq  = h1_freq_hz * static_cast<float>(K);

        if (harmonic_freq >= nyquist) {
            // Fuera de Nyquist: omitir, marcar bit y dejar NaN.
            res.harmonics_skipped_mask |= static_cast<uint8_t>(1u << idx);
            continue;
        }

        // Bin nominal del armónico.
        const float nominal_bin_f = harmonic_freq * static_cast<float>(n_bins) / sample_rate_hz;
        const int   nominal_bin   = static_cast<int>(std::round(nominal_bin_f));

        const PeakResult pr = PeakDetector::findPeakAroundBin(
            real, imag, n_bins, sample_rate_hz,
            nominal_bin, /*search_radius=*/2);

        if (!pr.detected || !std::isfinite(pr.peak_magnitude_lin)) {
            res.harmonics_skipped_mask |= static_cast<uint8_t>(1u << idx);
            continue;
        }

        res.harmonics_lin[idx] = pr.peak_magnitude_lin;
        sum_squares += pr.peak_magnitude_lin * pr.peak_magnitude_lin;
        ++included;
    }

    res.harmonics_included = included;

    if (included == 0) {
        // Sin armónicos válidos → THD reportable como 0% (no hay distorsión medible).
        res.thd_percent = 0.0f;
        res.valid       = true;
        return res;
    }

    const float thd = std::sqrt(sum_squares) / h1_magnitude_lin * 100.0f;
    if (!std::isfinite(thd)) {
        res.thd_percent = kNan;
        res.valid       = false;
        return res;
    }

    res.thd_percent = thd;
    res.valid       = true;
    return res;
}

}  // namespace cal_spectrum

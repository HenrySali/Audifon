/// @file wpe_beamformer.h
/// @brief WPE (Weighted Prediction Error) Beamformer for 2 microphones (header-only).
///
/// Operates in the frequency domain on complex spectra (post-STFT). Receives
/// two channels of complex spectra X0[kNumBins] and X1[kNumBins] and produces
/// one channel of enhanced spectrum Y[kNumBins].
///
/// Algorithm (2-mic simplified WPE / MVDR-like spatial filter):
///   For each frequency bin k:
///     1. Form observation vector x[k] = [X0[k], X1[k]]^T
///     2. Update spatial covariance matrix Rxx[k] with exponential smoothing:
///        Rxx[k] = alpha * Rxx[k] + (1-alpha) * x[k] * x[k]^H
///     3. When VAD=false (noise-only), also update noise covariance Rnn[k]:
///        Rnn[k] = alpha_n * Rnn[k] + (1-alpha_n) * x[k] * x[k]^H
///     4. Compute MVDR/Wiener weights via 2x2 analytic inversion:
///        w[k] = Rxx^{-1}[k] * d[k] / (d[k]^H * Rxx^{-1}[k] * d[k])
///        where d[k] = reference steering vector [1, 0]^T (first mic as ref)
///     5. Apply: Y[k] = w[k]^H * x[k]
///
/// The steering vector is [1, 0]^T (select first microphone as reference),
/// which makes the beamformer act as a spatial noise suppressor that preserves
/// the signal arriving at mic 0 while canceling spatially diffuse noise.
///
/// Design:
///   - Header-only (like mvdr_beamformer.h) to avoid CMakeLists.txt changes
///   - Operates on pre-computed complex spectra (caller handles STFT/iSTFT)
///   - Uses kNumBins=257 (matching kDnnFftSize=512 in dnn_denoiser)
///   - Exponential smoothing with separate alphas for signal and noise
///   - VAD-driven: noise covariance updated only during noise-only segments
///   - 2x2 complex matrix inversion via analytic closed-form with regularization
///
/// References:
///   - Yoshioka et al., "Generalization of Multi-Channel Linear Prediction
///     Methods for Blind MIMO Impulse Response Shortening" (2012)
///   - Nakatani et al., "Speech Dereverberation Based on Variance-Normalized
///     Delayed Linear Prediction" (2010)
///
/// Usage:
///   WpeBeamformer wpe;
///   wpe.reset();
///   // In the worker loop, after STFT of both channels:
///   wpe.process(X0, X1, Y, vadActive);

#ifndef HEARING_AID_WPE_BEAMFORMER_H
#define HEARING_AID_WPE_BEAMFORMER_H

#include <cmath>
#include <complex>
#include <cstring>
#include <algorithm>

/// WPE-style spatial beamformer for 2 microphones.
/// Operates on frequency-domain complex spectra. Produces a single-channel
/// enhanced spectrum suitable for feeding into the GTCRN neural denoiser.
class WpeBeamformer {
public:
    /// Number of frequency bins (kDnnFftSize/2 + 1 = 257).
    static constexpr int kNumBins = 257;

    /// Exponential smoothing factor for the signal covariance matrix Rxx.
    /// Higher values = more memory (slower adaptation). 0.95 is a good
    /// tradeoff between tracking speed and estimation stability.
    static constexpr float kAlphaSignal = 0.95f;

    /// Exponential smoothing factor for the noise covariance matrix Rnn.
    /// Slightly higher than signal alpha for more stable noise estimate.
    static constexpr float kAlphaNoise = 0.98f;

    /// Regularization (diagonal loading) for matrix inversion.
    /// Prevents division by near-zero determinants.
    static constexpr float kReg = 1e-6f;

    using Complex = std::complex<float>;

    /// Reset all internal state (covariance matrices, initialization flags).
    /// Call before first use and after any discontinuity (seek, mode change).
    void reset() {
        for (int k = 0; k < kNumBins; ++k) {
            rxx_[k][0][0] = Complex(0.0f, 0.0f);
            rxx_[k][0][1] = Complex(0.0f, 0.0f);
            rxx_[k][1][0] = Complex(0.0f, 0.0f);
            rxx_[k][1][1] = Complex(0.0f, 0.0f);

            rnn_[k][0][0] = Complex(0.0f, 0.0f);
            rnn_[k][0][1] = Complex(0.0f, 0.0f);
            rnn_[k][1][0] = Complex(0.0f, 0.0f);
            rnn_[k][1][1] = Complex(0.0f, 0.0f);
        }
        rxxInitialized_ = false;
        rnnInitialized_ = false;
        frameCount_ = 0;
    }

    /// Process one STFT frame from 2 microphones and produce enhanced output.
    ///
    /// @param X0  Complex spectrum from microphone 0 (kNumBins elements)
    /// @param X1  Complex spectrum from microphone 1 (kNumBins elements)
    /// @param Y   Output: enhanced single-channel complex spectrum (kNumBins elements)
    /// @param vadActive  true if VAD detects speech (do NOT update noise stats)
    void process(const Complex* X0, const Complex* X1,
                 Complex* Y, bool vadActive) {
        // Always update signal covariance (tracks overall signal statistics).
        updateRxx(X0, X1);

        // Update noise covariance only during noise-only segments.
        if (!vadActive) {
            updateRnn(X0, X1);
            rnnInitialized_ = true;
        }

        // Compute output per bin.
        for (int k = 0; k < kNumBins; ++k) {
            if (!rxxInitialized_) {
                // Not enough data yet: simple delay-and-sum (average).
                Y[k] = (X0[k] + X1[k]) * 0.5f;
            } else if (!rnnInitialized_) {
                // Signal stats available but no noise estimate: use reference mic.
                Y[k] = X0[k];
            } else {
                // Full MVDR/Wiener filtering.
                Complex w[2];
                computeWeights(k, w);
                // y[k] = w^H * x = conj(w[0])*X0 + conj(w[1])*X1
                Y[k] = std::conj(w[0]) * X0[k] + std::conj(w[1]) * X1[k];
            }
        }

        ++frameCount_;
    }

private:
    /// Update signal covariance matrix Rxx with exponential smoothing.
    void updateRxx(const Complex* X0, const Complex* X1) {
        const float alpha = rxxInitialized_ ? kAlphaSignal : 0.0f;
        const float oneMinusAlpha = 1.0f - alpha;

        for (int k = 0; k < kNumBins; ++k) {
            Complex x0 = X0[k];
            Complex x1 = X1[k];

            rxx_[k][0][0] = alpha * rxx_[k][0][0] +
                            oneMinusAlpha * (x0 * std::conj(x0));
            rxx_[k][0][1] = alpha * rxx_[k][0][1] +
                            oneMinusAlpha * (x0 * std::conj(x1));
            rxx_[k][1][0] = alpha * rxx_[k][1][0] +
                            oneMinusAlpha * (x1 * std::conj(x0));
            rxx_[k][1][1] = alpha * rxx_[k][1][1] +
                            oneMinusAlpha * (x1 * std::conj(x1));
        }
        rxxInitialized_ = true;
    }

    /// Update noise covariance matrix Rnn with exponential smoothing.
    /// Only called during noise-only segments (vadActive == false).
    void updateRnn(const Complex* X0, const Complex* X1) {
        const float alpha = rnnInitialized_ ? kAlphaNoise : 0.0f;
        const float oneMinusAlpha = 1.0f - alpha;

        for (int k = 0; k < kNumBins; ++k) {
            Complex x0 = X0[k];
            Complex x1 = X1[k];

            rnn_[k][0][0] = alpha * rnn_[k][0][0] +
                            oneMinusAlpha * (x0 * std::conj(x0));
            rnn_[k][0][1] = alpha * rnn_[k][0][1] +
                            oneMinusAlpha * (x0 * std::conj(x1));
            rnn_[k][1][0] = alpha * rnn_[k][1][0] +
                            oneMinusAlpha * (x1 * std::conj(x0));
            rnn_[k][1][1] = alpha * rnn_[k][1][1] +
                            oneMinusAlpha * (x1 * std::conj(x1));
        }
    }

    /// Compute MVDR-like beamforming weights for a given frequency bin.
    ///
    /// Uses the noise covariance matrix Rnn for spatial filtering:
    ///   w = Rnn^{-1} * d / (d^H * Rnn^{-1} * d)
    /// where d = [1, 0]^T (reference mic steering vector).
    ///
    /// With d = [1, 0]^T, this simplifies to:
    ///   Rnn^{-1} * d = first column of Rnn^{-1}
    ///   d^H * Rnn^{-1} * d = (0,0) element of Rnn^{-1}
    ///   w = Rnn^{-1}[:,0] / Rnn^{-1}[0,0]
    void computeWeights(int k, Complex* w) const {
        // Apply diagonal loading before inversion.
        Complex R00 = rnn_[k][0][0] + Complex(kReg, 0.0f);
        Complex R01 = rnn_[k][0][1];
        Complex R10 = rnn_[k][1][0];
        Complex R11 = rnn_[k][1][1] + Complex(kReg, 0.0f);

        // Analytic 2x2 inversion:
        // inv(R) = (1/det) * [R11, -R01; -R10, R00]
        Complex det = R00 * R11 - R01 * R10;

        float detMag = std::abs(det);
        if (detMag < 1e-10f) {
            // Fallback: select reference mic (no spatial filtering).
            w[0] = Complex(1.0f, 0.0f);
            w[1] = Complex(0.0f, 0.0f);
            return;
        }

        Complex invDet = 1.0f / det;

        // First column of Rnn^{-1}: [R11/det, -R10/det]
        Complex Rinv_col0_0 =  R11 * invDet;
        Complex Rinv_col0_1 = -R10 * invDet;

        // Denominator: d^H * Rnn^{-1} * d = Rinv[0][0] = R11/det
        Complex denom = Rinv_col0_0;

        float denomMag = std::abs(denom);
        if (denomMag < 1e-10f) {
            w[0] = Complex(1.0f, 0.0f);
            w[1] = Complex(0.0f, 0.0f);
            return;
        }

        // w = Rinv[:,0] / Rinv[0,0]
        w[0] = Rinv_col0_0 / denom;  // Always = 1.0 (distortionless constraint)
        w[1] = Rinv_col0_1 / denom;
    }

    // --- Internal state ---

    /// Signal spatial covariance matrix per frequency bin [kNumBins][2][2].
    Complex rxx_[kNumBins][2][2] = {};

    /// Noise spatial covariance matrix per frequency bin [kNumBins][2][2].
    Complex rnn_[kNumBins][2][2] = {};

    /// Whether Rxx has been initialized (at least one update).
    bool rxxInitialized_ = false;

    /// Whether Rnn has been initialized (at least one noise-only frame).
    bool rnnInitialized_ = false;

    /// Frame counter (for diagnostics).
    int frameCount_ = 0;
};

#endif // HEARING_AID_WPE_BEAMFORMER_H

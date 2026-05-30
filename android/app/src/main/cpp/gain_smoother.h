/// @file gain_smoother.h
/// @brief Exponential one-pole gain smoother for artifact-free gain transitions.
///
/// Provides smooth, click-free transitions for Volume, NR, and WDRC gain changes.
/// Uses asymmetric attack/release coefficients per ANSI S3.22 timing definitions:
///   coeff = 1 - exp(-2.2 / (timeMs * sampleRate / 1000))
/// The 2.2 factor equals ln(10), giving 90% settling time as defined by ANSI.
///
/// Thread-safe design:
/// - The target value is stored as std::atomic<float>, settable from the UI thread.
/// - The next() method advances the smoother and is called per-sample from the
///   audio thread. No locks are used — fully lock-free operation.
///
/// Typical usage:
/// @code
///   GainSmoother volumeSmoother;
///   volumeSmoother.init(16000, 5.0f, 50.0f);  // 5ms attack, 50ms release
///   volumeSmoother.setTarget(0.5f);            // UI thread sets new volume
///
///   // Audio thread, per-sample:
///   for (int i = 0; i < blockSize; ++i) {
///       buffer[i] *= volumeSmoother.next();
///   }
/// @endcode

#ifndef HEARING_AID_GAIN_SMOOTHER_H
#define HEARING_AID_GAIN_SMOOTHER_H

#include <atomic>
#include <cmath>

/// Exponential one-pole gain smoother with asymmetric attack/release.
///
/// Attack coefficient is used when the target is above the current value
/// (gain increasing), and release coefficient when the target is below
/// (gain decreasing). This matches the behavior of envelope detectors
/// in clinical hearing aids.
///
/// The settling time follows ANSI S3.22 definition: time to reach 90%
/// of a step change, derived from the ln(10) ≈ 2.2 factor.
class GainSmoother {
public:
    /// Constructs a smoother with the given timing parameters.
    /// @param sampleRate  Audio sample rate in Hz (e.g. 16000).
    /// @param attackMs    Attack time in milliseconds (target > current).
    /// @param releaseMs   Release time in milliseconds (target < current).
    GainSmoother(int sampleRate = 16000, float attackMs = 5.0f, float releaseMs = 50.0f) {
        init(sampleRate, attackMs, releaseMs);
    }

    ~GainSmoother() = default;

    /// (Re)initializes the smoother with new parameters.
    /// Resets current value to 1.0 and target to 1.0.
    /// @param sampleRate  Audio sample rate in Hz.
    /// @param attackMs    Attack time in milliseconds.
    /// @param releaseMs   Release time in milliseconds.
    void init(int sampleRate, float attackMs, float releaseMs) {
        sampleRate_ = sampleRate;
        attackCoeff_ = computeCoeff(attackMs, sampleRate);
        releaseCoeff_ = computeCoeff(releaseMs, sampleRate);
        current_ = 1.0f;
        target_.store(1.0f, std::memory_order_relaxed);
    }

    /// Sets the target value for the smoother.
    /// Thread-safe: can be called from the UI thread while audio is processing.
    /// @param target  The new target gain value.
    void setTarget(float target) {
        target_.store(target, std::memory_order_relaxed);
    }

    /// Returns the next smoothed value, advancing the internal state by one sample.
    /// Called per-sample from the audio thread.
    /// @return The current smoothed gain value after one step toward target.
    float next() {
        const float t = target_.load(std::memory_order_relaxed);
        const float coeff = (t > current_) ? attackCoeff_ : releaseCoeff_;
        current_ += coeff * (t - current_);
        return current_;
    }

    /// Returns the current smoothed value without advancing state.
    /// @return The current internal gain value.
    float current() const {
        return current_;
    }

    /// Immediately sets the current value, bypassing smoothing.
    /// Useful for initialization or hard resets.
    /// @param value  The value to set immediately.
    void reset(float value) {
        current_ = value;
        target_.store(value, std::memory_order_relaxed);
    }

    /// Returns true if the smoother has settled (current ≈ target).
    /// Settled means the difference is within 0.001 (≈ -60 dB).
    /// @return true if no further smoothing is needed.
    bool isSettled() const {
        const float t = target_.load(std::memory_order_relaxed);
        return std::fabs(current_ - t) < 0.001f;
    }

private:
    /// Computes the one-pole coefficient for a given time constant.
    /// Formula: coeff = 1 - exp(-2.2 / (timeMs * sampleRate / 1000))
    /// The 2.2 factor is ln(10), giving 90% settling per ANSI S3.22.
    /// @param timeMs     Time constant in milliseconds.
    /// @param sampleRate Sample rate in Hz.
    /// @return The computed coefficient in range (0, 1).
    static float computeCoeff(float timeMs, int sampleRate) {
        const float samples = timeMs * static_cast<float>(sampleRate) / 1000.0f;
        if (samples < 1.0f) {
            return 1.0f;  // Instant — time shorter than one sample
        }
        return 1.0f - std::exp(-2.2f / samples);
    }

    // --- Configuration ---
    int sampleRate_ = 16000;
    float attackCoeff_ = 0.0f;   ///< Coefficient when target > current
    float releaseCoeff_ = 0.0f;  ///< Coefficient when target < current

    // --- State ---
    float current_ = 1.0f;                  ///< Current smoothed value (audio thread only)
    std::atomic<float> target_{1.0f};       ///< Target value (set from UI thread)
};

#endif // HEARING_AID_GAIN_SMOOTHER_H

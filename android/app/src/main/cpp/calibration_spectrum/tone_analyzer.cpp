/// @file tone_analyzer.cpp
/// @brief Implementación de ToneAnalyzer.

#include "tone_analyzer.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

#include "peak_detector.h"
#include "snr_calculator.h"
#include "thd_calculator.h"

namespace cal_spectrum {

namespace {

constexpr int kMaxHarmonicsStored = 8;

uint64_t nowMicros() {
    return std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

}  // namespace

// ─────────────────────────────────────────────────────────────────────────────
// Constructor / Destructor
// ─────────────────────────────────────────────────────────────────────────────

ToneAnalyzer::ToneAnalyzer() {
    std::memset(&snapshot_, 0, sizeof(snapshot_));
    snapshot_.verdict = static_cast<uint8_t>(ToneVerdict::Unknown);
    for (int i = 0; i < kMaxHarmonicsStored; ++i) {
        snapshot_.harmonics_dbfs[i] = std::numeric_limits<float>::quiet_NaN();
    }
}

ToneAnalyzer::~ToneAnalyzer() = default;

// ─────────────────────────────────────────────────────────────────────────────
// Configuración
// ─────────────────────────────────────────────────────────────────────────────

bool ToneAnalyzer::configure(const ToneAnalyzerConfig& cfg) {
    if (cfg.sample_rate_hz <= 0.0f) return false;
    if (cfg.harmonics_count < 1 || cfg.harmonics_count > kMaxHarmonicsStored) return false;

    if (!fft_.init(cfg.fft_size, cfg.window)) {
        return false;
    }

    cfg_ = cfg;
    accum_buffer_.assign(cfg.fft_size, 0.0f);
    accum_pos_  = 0;
    configured_ = true;
    origin_us_  = nowMicros();

    {
        std::lock_guard<std::mutex> lk(snapshot_mtx_);
        std::memset(&snapshot_, 0, sizeof(snapshot_));
        snapshot_.sample_rate_hz = cfg.sample_rate_hz;
        snapshot_.fft_size       = static_cast<uint16_t>(cfg.fft_size);
        snapshot_.window_type    = static_cast<uint8_t>(cfg.window);
        snapshot_.harmonics_count = static_cast<uint8_t>(cfg.harmonics_count);
        snapshot_.verdict        = static_cast<uint8_t>(ToneVerdict::Unknown);
        for (int i = 0; i < kMaxHarmonicsStored; ++i) {
            snapshot_.harmonics_dbfs[i] = std::numeric_limits<float>::quiet_NaN();
        }
    }
    return true;
}

void ToneAnalyzer::setExpectedFrequency(float expected_hz) {
    expected_freq_hz_.store(expected_hz, std::memory_order_relaxed);
}

void ToneAnalyzer::setNoiseFloor(float noise_floor_amplitude_lin, float noise_floor_dbfs) {
    noise_floor_lin_.store(noise_floor_amplitude_lin, std::memory_order_relaxed);
    noise_floor_dbfs_.store(noise_floor_dbfs, std::memory_order_relaxed);
}

void ToneAnalyzer::setActive(bool active) {
    active_.store(active, std::memory_order_relaxed);
    if (!active) {
        accum_pos_ = 0;
    }
}

void ToneAnalyzer::reset() {
    std::fill(accum_buffer_.begin(), accum_buffer_.end(), 0.0f);
    accum_pos_ = 0;

    std::lock_guard<std::mutex> lk(snapshot_mtx_);
    snapshot_.timestamp_us         = 0;
    snapshot_.expected_freq_hz     = expected_freq_hz_.load();
    snapshot_.peak_freq_hz         = std::numeric_limits<float>::quiet_NaN();
    snapshot_.peak_magnitude_dbfs  = -200.0f;
    snapshot_.peak_magnitude_dbspl = -200.0f + cfg_.dbfs_to_dbspl_offset;
    snapshot_.snr_db               = 0.0f;
    snapshot_.thd_percent          = std::numeric_limits<float>::quiet_NaN();
    snapshot_.verdict              = static_cast<uint8_t>(ToneVerdict::Unknown);
    snapshot_.failure_mask         = 0;
    for (int i = 0; i < kMaxHarmonicsStored; ++i) {
        snapshot_.harmonics_dbfs[i] = std::numeric_limits<float>::quiet_NaN();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Procesamiento — acumula y dispara FFT
// ─────────────────────────────────────────────────────────────────────────────

void ToneAnalyzer::process(const float* block, int n_samples) {
    if (!active_.load(std::memory_order_relaxed) || !configured_ ||
        block == nullptr || n_samples <= 0) {
        return;
    }

    int remaining = n_samples;
    int src_pos   = 0;

    while (remaining > 0) {
        const int space = cfg_.fft_size - accum_pos_;
        const int copy  = std::min(space, remaining);

        std::memcpy(&accum_buffer_[accum_pos_], &block[src_pos], copy * sizeof(float));
        accum_pos_  += copy;
        src_pos     += copy;
        remaining   -= copy;

        if (accum_pos_ >= cfg_.fft_size) {
            computeAndPublish();
            // Hop del 50% (overlap clásico para Hann): conservar la mitad final.
            const int half = cfg_.fft_size / 2;
            std::memmove(&accum_buffer_[0],
                         &accum_buffer_[half],
                         half * sizeof(float));
            accum_pos_ = half;
        }
    }
}

bool ToneAnalyzer::processFullWindow(const float* buffer, int n_samples) {
    if (!configured_ || buffer == nullptr || n_samples <= 0) {
        return false;
    }
    const int copy = std::min(n_samples, cfg_.fft_size);
    std::memcpy(accum_buffer_.data(), buffer, copy * sizeof(float));
    if (copy < cfg_.fft_size) {
        std::fill(accum_buffer_.begin() + copy, accum_buffer_.end(), 0.0f);
    }
    accum_pos_ = cfg_.fft_size;
    computeAndPublish();
    accum_pos_ = 0;
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// computeAndPublish — corre FFT, peak, THD, SNR y publica snapshot
// ─────────────────────────────────────────────────────────────────────────────

void ToneAnalyzer::computeAndPublish() {
    const FftResult fft_out = fft_.compute(accum_buffer_.data(), cfg_.fft_size);
    if (!fft_out.valid) return;

    const float expected_hz = expected_freq_hz_.load(std::memory_order_relaxed);
    const float floor_lin   = noise_floor_lin_.load(std::memory_order_relaxed);
    const float floor_dbfs  = noise_floor_dbfs_.load(std::memory_order_relaxed);

    // 1. Detectar pico fundamental.
    PeakResult peak = PeakDetector::findPeak(
        fft_out.real, fft_out.imag, fft_out.n_bins,
        cfg_.sample_rate_hz, expected_hz,
        /*search_window_pct=*/0.20f,
        /*noise_floor_lin=*/floor_lin);

    // 2. Calcular THD usando la frecuencia detectada y su magnitud.
    ThdResult thd{};
    if (peak.detected) {
        thd = ThdCalculator::compute(
            fft_out.real, fft_out.imag, fft_out.n_bins,
            cfg_.sample_rate_hz, peak.peak_freq_hz, peak.peak_magnitude_lin,
            cfg_.harmonics_count);
    }

    // 3. SNR.
    const float snr_db = SnrCalculator::compute(peak.peak_magnitude_lin, floor_lin);

    // 4. Construir snapshot.
    ToneSnapshot snap{};
    snap.timestamp_us         = nowMicros() - origin_us_;
    snap.sample_rate_hz       = cfg_.sample_rate_hz;
    snap.fft_size             = static_cast<uint16_t>(cfg_.fft_size);
    snap.window_type          = static_cast<uint8_t>(cfg_.window);
    snap.expected_freq_hz     = expected_hz;
    snap.peak_freq_hz         = peak.peak_freq_hz;
    snap.peak_magnitude_dbfs  = peak.peak_magnitude_dbfs;
    snap.peak_magnitude_dbspl = peak.peak_magnitude_dbfs + cfg_.dbfs_to_dbspl_offset;
    snap.noise_floor_dbfs     = floor_dbfs;
    snap.snr_db               = snr_db;
    snap.thd_percent          = thd.thd_percent;
    snap.harmonics_count      = static_cast<uint8_t>(cfg_.harmonics_count);

    for (int i = 0; i < kMaxHarmonicsStored; ++i) {
        snap.harmonics_dbfs[i] = std::numeric_limits<float>::quiet_NaN();
    }
    if (thd.valid) {
        for (int i = 0; i < std::min(thd.harmonics_count, kMaxHarmonicsStored); ++i) {
            const float lin = thd.harmonics_lin[i];
            if (std::isfinite(lin) && lin > 0.0f) {
                snap.harmonics_dbfs[i] = magnitudeToDbFs(lin, fft_out.n_bins);
            }
        }
    }

    // Veredicto se evalúa en Dart con AcceptanceCriteria; acá dejamos Unknown.
    snap.verdict      = static_cast<uint8_t>(
        peak.detected ? ToneVerdict::Unknown : ToneVerdict::Fail);
    snap.failure_mask = peak.detected ? 0 : kFailureNoSig;

    // Marcar bits NaN/Inf si las métricas se rompieron.
    if (!std::isfinite(snap.peak_freq_hz) ||
        !std::isfinite(snap.thd_percent) ||
        !std::isfinite(snap.peak_magnitude_dbfs)) {
        snap.failure_mask |= kFailureNanInf;
        snap.verdict       = static_cast<uint8_t>(ToneVerdict::Fail);
    }

    {
        std::lock_guard<std::mutex> lk(snapshot_mtx_);
        snapshot_ = snap;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Lectura
// ─────────────────────────────────────────────────────────────────────────────

ToneSnapshot ToneAnalyzer::getSnapshot() const {
    std::lock_guard<std::mutex> lk(snapshot_mtx_);
    return snapshot_;
}

}  // namespace cal_spectrum

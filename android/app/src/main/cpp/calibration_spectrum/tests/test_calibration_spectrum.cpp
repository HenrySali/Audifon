/// @file test_calibration_spectrum.cpp
/// @brief Tests offline del motor C++ del Calibration Spectrum Validator.
///
/// Compilación standalone (sin Android, sin gtest):
///   g++ -std=c++17 -O2 -I.. \
///       ../fft_engine.cpp ../peak_detector.cpp ../thd_calculator.cpp \
///       ../tone_analyzer.cpp test_calibration_spectrum.cpp \
///       -o test_calibration_spectrum
///   ./test_calibration_spectrum
///
/// Estructura: cada test es una función `bool testXxx()` que retorna true
/// si pasa. main() ejecuta todos y reporta el total. Imprime PASS/FAIL.

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

#include "../fft_engine.h"
#include "../peak_detector.h"
#include "../snr_calculator.h"
#include "../thd_calculator.h"
#include "../tone_analyzer.h"
#include "../tone_types.h"

using namespace cal_spectrum;

// ─────────────────────────────────────────────────────────────────────────────
// Utilidades
// ─────────────────────────────────────────────────────────────────────────────

namespace {

constexpr float kPi = 3.14159265358979323846f;

/// Genera un tono puro: amp · sin(2π·f·t) en `out`.
void generateSine(std::vector<float>& out,
                  float freq_hz,
                  float amplitude,
                  float sample_rate,
                  int n_samples) {
    out.resize(n_samples);
    const float w = 2.0f * kPi * freq_hz / sample_rate;
    for (int i = 0; i < n_samples; ++i) {
        out[i] = amplitude * std::sin(w * static_cast<float>(i));
    }
}

/// Suma armónicos al buffer existente: out[i] += amp_K · sin(2π·K·f·t).
void addHarmonic(std::vector<float>& out,
                 float fundamental_hz,
                 int K,
                 float amplitude,
                 float sample_rate) {
    const float freq = fundamental_hz * static_cast<float>(K);
    const float w    = 2.0f * kPi * freq / sample_rate;
    for (size_t i = 0; i < out.size(); ++i) {
        out[i] += amplitude * std::sin(w * static_cast<float>(i));
    }
}

/// Suma ruido blanco gaussiano al buffer.
void addWhiteNoise(std::vector<float>& out, float rms, uint32_t seed) {
    std::mt19937 rng(seed);
    std::normal_distribution<float> dist(0.0f, rms);
    for (auto& s : out) s += dist(rng);
}

/// Imprime el resultado de un test y devuelve el booleano original.
bool report(const std::string& name, bool ok, const std::string& detail = "") {
    std::printf(ok ? "  [PASS] " : "  [FAIL] ");
    std::printf("%s", name.c_str());
    if (!detail.empty()) std::printf(" — %s", detail.c_str());
    std::printf("\n");
    return ok;
}

bool approxEqual(float a, float b, float tol) {
    return std::fabs(a - b) <= tol;
}

}  // namespace

// ─────────────────────────────────────────────────────────────────────────────
// Tests del FftEngine
// ─────────────────────────────────────────────────────────────────────────────

bool testFftEngineInit() {
    FftEngine fft;
    bool ok_valid   = fft.init(4096, WindowType::Hann);
    bool ok_invalid = !fft.init(1000, WindowType::Hann);   // no es potencia de 2
    bool ok_too_small = !fft.init(64, WindowType::Hann);   // < 256
    return report("FftEngine init valid + reject invalid sizes",
                  ok_valid && ok_invalid && ok_too_small);
}

bool testFftEngineSineDetection() {
    constexpr int   N    = 4096;
    constexpr float SR   = 16000.0f;
    constexpr float Freq = 1000.0f;
    constexpr float Amp  = 0.5f;

    FftEngine fft;
    if (!fft.init(N, WindowType::Hann)) return report("FFT sine detection (init)", false);

    std::vector<float> sig;
    generateSine(sig, Freq, Amp, SR, N);

    const FftResult r = fft.compute(sig.data(), N);
    if (!r.valid) return report("FFT sine detection (compute)", false);

    // Buscar el bin de máxima magnitud entre 1..N/2.
    int   best = 1;
    float best_mag2 = r.real[1] * r.real[1] + r.imag[1] * r.imag[1];
    for (int k = 2; k < N / 2; ++k) {
        const float m2 = r.real[k] * r.real[k] + r.imag[k] * r.imag[k];
        if (m2 > best_mag2) { best_mag2 = m2; best = k; }
    }
    const float bin_width = SR / static_cast<float>(N);
    const float detected_hz = static_cast<float>(best) * bin_width;
    const bool ok = std::fabs(detected_hz - Freq) <= bin_width;
    return report("FFT detects 1000 Hz tone within 1 bin",
                  ok, "detected=" + std::to_string(detected_hz) + " Hz");
}

bool testFftEngineEnbwHann() {
    FftEngine fft;
    fft.init(4096, WindowType::Hann);
    const float enbw = fft.enbw_bins();
    // ENBW teórico de Hann = 1.5 bins.
    return report("Hann ENBW ≈ 1.5", approxEqual(enbw, 1.5f, 0.05f),
                  "enbw=" + std::to_string(enbw));
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests del PeakDetector
// ─────────────────────────────────────────────────────────────────────────────

bool testPeakSubBinAccuracy() {
    constexpr int   N    = 4096;
    constexpr float SR   = 16000.0f;
    constexpr float Freq = 1000.5f;     // entre dos bins
    constexpr float Amp  = 0.5f;

    FftEngine fft;
    fft.init(N, WindowType::Hann);

    std::vector<float> sig;
    generateSine(sig, Freq, Amp, SR, N);
    const FftResult r = fft.compute(sig.data(), N);

    PeakResult peak = PeakDetector::findPeak(
        r.real, r.imag, r.n_bins, SR, /*expected_hz=*/1000.0f, 0.20f, 0.0f);

    const float bin_width = SR / static_cast<float>(N);
    const bool detected = peak.detected;
    const bool accurate = std::fabs(peak.peak_freq_hz - Freq) <= 0.5f * bin_width;

    return report("Peak sub-bin accuracy (1000.5 Hz, FFT 4096)",
                  detected && accurate,
                  "detected=" + std::to_string(peak.peak_freq_hz) +
                  " Hz, error=" + std::to_string(std::fabs(peak.peak_freq_hz - Freq)) +
                  ", quinn=" + (peak.used_quinn ? "yes" : "no"));
}

bool testPeakNoSignal() {
    constexpr int N = 1024;
    std::vector<float> zero(N, 0.0f);
    FftEngine fft;
    fft.init(N, WindowType::Hann);
    const FftResult r = fft.compute(zero.data(), N);
    PeakResult p = PeakDetector::findPeak(
        r.real, r.imag, r.n_bins, 16000.0f, 1000.0f, 0.20f,
        /*noise_floor_lin=*/0.001f);
    return report("Peak detector returns 'not detected' on silence", !p.detected);
}

bool testPeakRandomFrequencies() {
    constexpr int   N         = 4096;
    constexpr float SR        = 16000.0f;
    constexpr int   kRuns     = 100;
    const float bin_width     = SR / static_cast<float>(N);

    FftEngine fft;
    fft.init(N, WindowType::Hann);

    std::mt19937 rng(42);
    std::uniform_real_distribution<float> freq_dist(200.0f, 7900.0f);

    int failures = 0;
    float max_err = 0.0f;
    int outliers_above_half_bin = 0;
    for (int i = 0; i < kRuns; ++i) {
        const float f = freq_dist(rng);
        std::vector<float> sig;
        generateSine(sig, f, 0.5f, SR, N);
        const FftResult r = fft.compute(sig.data(), N);
        PeakResult p = PeakDetector::findPeak(r.real, r.imag, r.n_bins, SR, f, 0.20f, 0.0f);
        if (!p.detected) { ++failures; continue; }
        const float err = std::fabs(p.peak_freq_hz - f);
        if (err > max_err) max_err = err;
        // REQ-10.2 exige ±5% (≈ ±50 Hz a 1 kHz). Acá pedimos ≤ 1 bin (5× más estricto).
        if (err > 1.0f * bin_width) ++failures;
        if (err > 0.5f * bin_width) ++outliers_above_half_bin;
    }
    const bool ok = failures == 0;
    char buf[160];
    std::snprintf(buf, sizeof(buf),
                  "fails=%d/%d (>1 bin), >0.5 bin=%d/%d, max_err=%.3f Hz (bin=%.2f Hz)",
                  failures, kRuns, outliers_above_half_bin, kRuns, max_err, bin_width);
    return report("Peak P2: 100 random tones within 1 bin (5x stricter than ±5% REQ)",
                  ok, buf);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests del ThdCalculator
// ─────────────────────────────────────────────────────────────────────────────

bool testThdSimple() {
    // H1=1.0, H2=0.01 (i.e., -40 dB) → THD esperado = 0.01/1.0 × 100 = 1.0%
    constexpr int   N  = 8192;
    constexpr float SR = 16000.0f;
    constexpr float F  = 1000.0f;

    FftEngine fft;
    fft.init(N, WindowType::Hann);

    std::vector<float> sig;
    generateSine(sig, F, 1.0f, SR, N);
    addHarmonic(sig, F, 2, 0.01f, SR);

    const FftResult r = fft.compute(sig.data(), N);
    PeakResult peak = PeakDetector::findPeak(r.real, r.imag, r.n_bins, SR, F, 0.20f, 0.0f);
    if (!peak.detected) return report("THD basic — H1 detection", false);

    ThdResult thd = ThdCalculator::compute(
        r.real, r.imag, r.n_bins, SR, peak.peak_freq_hz,
        peak.peak_magnitude_lin, /*harmonics_count=*/4);

    const bool ok = thd.valid && approxEqual(thd.thd_percent, 1.0f, 0.15f);
    return report("THD ≈ 1.0% with H2 at -40 dB",
                  ok, "thd=" + std::to_string(thd.thd_percent) + "%");
}

bool testThdHarmonicsAboveNyquist() {
    // Tono a 7000 Hz, sample rate 16 kHz → H2 (14k) válido, H3 (21k) > Nyquist 8 kHz.
    constexpr int   N  = 8192;
    constexpr float SR = 16000.0f;
    constexpr float F  = 7000.0f;

    FftEngine fft;
    fft.init(N, WindowType::Hann);

    std::vector<float> sig;
    generateSine(sig, F, 1.0f, SR, N);
    // H2 está en 14 kHz que es > Nyquist (8 kHz), también se omitirá.

    const FftResult r = fft.compute(sig.data(), N);
    PeakResult peak = PeakDetector::findPeak(r.real, r.imag, r.n_bins, SR, F, 0.20f, 0.0f);
    if (!peak.detected) return report("THD Nyquist (peak)", false);

    ThdResult thd = ThdCalculator::compute(
        r.real, r.imag, r.n_bins, SR, peak.peak_freq_hz,
        peak.peak_magnitude_lin, /*harmonics_count=*/4);

    // Todos los armónicos deberían estar fuera de Nyquist → 0 incluidos.
    const bool ok = thd.valid && thd.harmonics_included == 0 &&
                    thd.harmonics_skipped_mask != 0;
    return report("THD skips harmonics above Nyquist", ok,
                  "included=" + std::to_string(thd.harmonics_included) +
                  ", skipped_mask=" + std::to_string(thd.harmonics_skipped_mask));
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests del SnrCalculator
// ─────────────────────────────────────────────────────────────────────────────

bool testSnrBasic() {
    // peak_lin = 0.1, floor_lin = 0.001 → SNR = 20·log10(100) = 40 dB
    const float snr = SnrCalculator::compute(0.1f, 0.001f);
    return report("SNR 40 dB exact", approxEqual(snr, 40.0f, 0.001f),
                  "snr=" + std::to_string(snr));
}

bool testSnrZeroFloor() {
    const float snr = SnrCalculator::compute(0.5f, 0.0f);
    return report("SNR returns +Inf when floor is zero", std::isinf(snr) && snr > 0.0f);
}

bool testSnrZeroPeak() {
    const float snr = SnrCalculator::compute(0.0f, 0.001f);
    return report("SNR returns -Inf when peak is zero", std::isinf(snr) && snr < 0.0f);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests del ToneAnalyzer (orquestador completo)
// ─────────────────────────────────────────────────────────────────────────────

bool testToneAnalyzerEndToEnd() {
    constexpr int   N  = 4096;
    constexpr float SR = 16000.0f;
    constexpr float F  = 1000.0f;

    ToneAnalyzer ta;
    ToneAnalyzerConfig cfg;
    cfg.sample_rate_hz = SR;
    cfg.fft_size       = N;
    cfg.window         = WindowType::Hann;
    cfg.harmonics_count = 4;
    cfg.dbfs_to_dbspl_offset = 76.0f;

    if (!ta.configure(cfg)) return report("ToneAnalyzer end-to-end (configure)", false);
    ta.setExpectedFrequency(F);
    ta.setNoiseFloor(/*lin=*/0.001f, /*dbfs=*/-60.0f);
    ta.setActive(true);

    std::vector<float> sig;
    generateSine(sig, F, 0.5f, SR, N);
    addHarmonic(sig, F, 2, 0.005f, SR);   // H2 ≈ -40 dB → THD ≈ 1%

    bool published = ta.processFullWindow(sig.data(), N);
    if (!published) return report("ToneAnalyzer end-to-end (process)", false);

    ToneSnapshot snap = ta.getSnapshot();
    const bool freq_ok = approxEqual(snap.peak_freq_hz, F, 1.0f);
    const bool thd_ok  = std::isfinite(snap.thd_percent) &&
                         approxEqual(snap.thd_percent, 1.0f, 0.20f);
    const bool snr_ok  = std::isfinite(snap.snr_db) && snap.snr_db > 30.0f;

    char buf[256];
    std::snprintf(buf, sizeof(buf),
                  "freq=%.2f thd=%.3f%% snr=%.1f dB",
                  snap.peak_freq_hz, snap.thd_percent, snap.snr_db);
    return report("ToneAnalyzer end-to-end (1 kHz, H2=-40dB)",
                  freq_ok && thd_ok && snr_ok, buf);
}

bool testToneAnalyzerSilence() {
    ToneAnalyzer ta;
    ToneAnalyzerConfig cfg;
    cfg.sample_rate_hz = 16000.0f;
    cfg.fft_size       = 1024;
    cfg.window         = WindowType::Hann;
    cfg.harmonics_count = 4;
    ta.configure(cfg);
    ta.setExpectedFrequency(1000.0f);
    ta.setNoiseFloor(/*lin=*/0.001f, /*dbfs=*/-60.0f);
    ta.setActive(true);

    std::vector<float> silence(1024, 0.0f);
    ta.processFullWindow(silence.data(), 1024);

    ToneSnapshot snap = ta.getSnapshot();
    const bool ok = snap.verdict == static_cast<uint8_t>(ToneVerdict::Fail) &&
                    (snap.failure_mask & kFailureNoSig) != 0;
    return report("ToneAnalyzer flags FAIL on silence", ok);
}

// ─────────────────────────────────────────────────────────────────────────────
// Property tests
// ─────────────────────────────────────────────────────────────────────────────

bool testPropertyP1ThdFormula() {
    // Generar arrays aleatorios H1, H2..H5 y verificar que la fórmula coincide
    // con el cálculo manual.
    constexpr int   N  = 8192;
    constexpr float SR = 16000.0f;
    constexpr float F  = 1000.0f;
    constexpr int   kRuns = 50;

    FftEngine fft;
    fft.init(N, WindowType::Hann);

    std::mt19937 rng(7);
    std::uniform_real_distribution<float> dist(0.001f, 0.05f);

    int fails = 0;
    for (int run = 0; run < kRuns; ++run) {
        std::vector<float> sig;
        generateSine(sig, F, 1.0f, SR, N);

        float h_amps[4];
        for (int k = 0; k < 4; ++k) {
            h_amps[k] = dist(rng);
            addHarmonic(sig, F, k + 2, h_amps[k], SR);
        }

        const FftResult r = fft.compute(sig.data(), N);
        PeakResult peak = PeakDetector::findPeak(r.real, r.imag, r.n_bins, SR, F, 0.20f, 0.0f);
        if (!peak.detected) { ++fails; continue; }

        ThdResult thd = ThdCalculator::compute(
            r.real, r.imag, r.n_bins, SR, peak.peak_freq_hz,
            peak.peak_magnitude_lin, 4);

        if (!thd.valid) { ++fails; continue; }

        // Calcular fórmula esperada: sqrt(sum(harmonics_lin²)) / |H1| × 100
        float ss = 0.0f;
        for (int i = 0; i < 4; ++i) {
            const float h = thd.harmonics_lin[i];
            if (std::isfinite(h)) ss += h * h;
        }
        const float expected = std::sqrt(ss) / peak.peak_magnitude_lin * 100.0f;
        if (!approxEqual(thd.thd_percent, expected, 0.001f)) ++fails;
    }
    return report("P1: THD formula matches sqrt(sum(Hk²))/|H1|×100",
                  fails == 0,
                  "fails=" + std::to_string(fails) + "/" + std::to_string(kRuns));
}

// ─────────────────────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────────────────────

int main() {
    std::printf("=== Calibration Spectrum — Motor C++ Tests ===\n");

    int total = 0;
    int passed = 0;

    auto run = [&](bool (*fn)()) {
        ++total;
        if (fn()) ++passed;
    };

    std::printf("\n[FftEngine]\n");
    run(testFftEngineInit);
    run(testFftEngineSineDetection);
    run(testFftEngineEnbwHann);

    std::printf("\n[PeakDetector]\n");
    run(testPeakSubBinAccuracy);
    run(testPeakNoSignal);
    run(testPeakRandomFrequencies);

    std::printf("\n[ThdCalculator]\n");
    run(testThdSimple);
    run(testThdHarmonicsAboveNyquist);

    std::printf("\n[SnrCalculator]\n");
    run(testSnrBasic);
    run(testSnrZeroFloor);
    run(testSnrZeroPeak);

    std::printf("\n[ToneAnalyzer]\n");
    run(testToneAnalyzerEndToEnd);
    run(testToneAnalyzerSilence);

    std::printf("\n[Property tests]\n");
    run(testPropertyP1ThdFormula);

    std::printf("\n=== %d / %d tests passed ===\n", passed, total);
    return (passed == total) ? 0 : 1;
}

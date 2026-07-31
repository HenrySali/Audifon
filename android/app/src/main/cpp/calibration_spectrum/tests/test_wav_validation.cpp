/// @file test_wav_validation.cpp
/// @brief Validación del motor C++ contra archivos WAV pre-renderizados.
///
/// 1. Genera WAV de referencia con tonos puros y mezclas conocidas en `out_wavs/`.
/// 2. Procesa cada WAV a través del ToneAnalyzer.
/// 3. Verifica que las métricas detectadas coincidan con las esperadas dentro
///    de tolerancias clínicas (REQ-4.2, REQ-5.3).
///
/// Compilación standalone (mismo flag que test_calibration_spectrum.cpp):
///   ver run_wav_tests.bat

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "../fft_engine.h"
#include "../peak_detector.h"
#include "../snr_calculator.h"
#include "../thd_calculator.h"
#include "../tone_analyzer.h"
#include "../tone_types.h"
#include "wav_io.h"

using namespace cal_spectrum;
using namespace cal_spectrum_test;

namespace {

constexpr float kPi = 3.14159265358979323846f;
constexpr float kSampleRate = 48000.0f;
constexpr int   kFftSize = 8192;
constexpr int   kDurationSec = 2;

struct ReferenceWav {
    std::string filename;
    float       fundamental_hz;
    float       fundamental_amp;     // amplitud del fundamental [0,1]
    float       h2_amp;              // amplitud del H2 [0,1]; 0 = sin H2
    float       expected_thd_pct;    // calculado: (h2_amp / fund_amp) × 100
    bool        expect_pass;
};

void generateReferenceWavs(const std::string& outDir, std::vector<ReferenceWav>& refs) {
    refs.clear();

    auto pushRef = [&](const std::string& name, float f, float a, float h2) {
        ReferenceWav r;
        r.filename = name;
        r.fundamental_hz = f;
        r.fundamental_amp = a;
        r.h2_amp = h2;
        r.expected_thd_pct = (h2 / a) * 100.0f;
        r.expect_pass = r.expected_thd_pct < 3.0f;
        refs.push_back(r);
    };

    // Tonos puros estándar audiometría.
    pushRef("tone_250hz_pure.wav",  250.0f,  0.5f, 0.0f);
    pushRef("tone_500hz_pure.wav",  500.0f,  0.5f, 0.0f);
    pushRef("tone_1khz_pure.wav",   1000.0f, 0.5f, 0.0f);
    pushRef("tone_2khz_pure.wav",   2000.0f, 0.5f, 0.0f);
    pushRef("tone_4khz_pure.wav",   4000.0f, 0.5f, 0.0f);

    // Tono con distorsión conocida (H2 a -40 dB → THD ≈ 1%).
    pushRef("tone_1khz_thd1pct.wav", 1000.0f, 1.0f, 0.01f);
    // Tono con distorsión alta (H2 a -20 dB → THD ≈ 10%).
    pushRef("tone_1khz_thd10pct.wav", 1000.0f, 1.0f, 0.1f);

    // Generar y escribir cada WAV.
    const int totalSamples = static_cast<int>(kSampleRate * kDurationSec);
    std::vector<float> buf(totalSamples);

    for (auto& r : refs) {
        const float w1 = 2.0f * kPi * r.fundamental_hz / kSampleRate;
        const float w2 = 2.0f * w1;
        for (int i = 0; i < totalSamples; ++i) {
            buf[i] = r.fundamental_amp * std::sin(w1 * i);
            if (r.h2_amp > 0.0f) buf[i] += r.h2_amp * std::sin(w2 * i);
        }
        const std::string path = outDir + "/" + r.filename;
        if (!writeWavMono16(path, buf.data(), totalSamples, static_cast<int>(kSampleRate))) {
            std::printf("ERROR: no se pudo escribir %s\n", path.c_str());
        }
    }
}

bool processWavThroughAnalyzer(const ReferenceWav& ref, const std::string& path) {
    WavData wav = readWavMono16(path);
    if (!wav.valid) {
        std::printf("  [FAIL] %s — error: %s\n", ref.filename.c_str(), wav.error.c_str());
        return false;
    }

    ToneAnalyzer analyzer;
    ToneAnalyzerConfig cfg;
    cfg.sample_rate_hz = static_cast<float>(wav.sample_rate_hz);
    cfg.fft_size = kFftSize;
    cfg.window = WindowType::Hann;
    cfg.harmonics_count = 4;
    cfg.dbfs_to_dbspl_offset = 76.0f;

    if (!analyzer.configure(cfg)) {
        std::printf("  [FAIL] %s — configure() falló\n", ref.filename.c_str());
        return false;
    }
    analyzer.setExpectedFrequency(ref.fundamental_hz);
    analyzer.setNoiseFloor(/*lin=*/0.0001f, /*dbfs=*/-80.0f);
    analyzer.setActive(true);

    // Tomamos un bloque del medio del WAV (saltamos posibles transitorios de ataque).
    const int offsetSamples = wav.sample_rate_hz / 4;  // 0.25 s adentro
    if (static_cast<int>(wav.samples.size()) < offsetSamples + kFftSize) {
        std::printf("  [FAIL] %s — WAV demasiado corto\n", ref.filename.c_str());
        return false;
    }
    analyzer.processFullWindow(wav.samples.data() + offsetSamples, kFftSize);

    const ToneSnapshot snap = analyzer.getSnapshot();

    // Validaciones.
    const float bin_width = cfg.sample_rate_hz / static_cast<float>(cfg.fft_size);
    const float freq_err = std::fabs(snap.peak_freq_hz - ref.fundamental_hz);
    const bool freq_ok = freq_err <= bin_width;

    bool thd_ok;
    if (ref.h2_amp == 0.0f) {
        // Tono puro: aceptamos < 0.5% (numéricamente cerca de 0).
        thd_ok = std::isfinite(snap.thd_percent) && snap.thd_percent < 0.5f;
    } else {
        const float thd_err = std::fabs(snap.thd_percent - ref.expected_thd_pct);
        // Tolerancia 5% relativa (dimensionado para distorsión real).
        thd_ok = std::isfinite(snap.thd_percent) &&
                 thd_err <= ref.expected_thd_pct * 0.05f;
    }

    const bool snr_ok = std::isfinite(snap.snr_db) && snap.snr_db > 30.0f;

    const bool overall = freq_ok && thd_ok && snr_ok;
    std::printf("  [%s] %-32s freq=%.2f Hz (esp %.0f, err %.2f), thd=%.4f%% (esp %.4f), snr=%.1f dB\n",
                overall ? "PASS" : "FAIL",
                ref.filename.c_str(),
                snap.peak_freq_hz,
                ref.fundamental_hz,
                freq_err,
                snap.thd_percent,
                ref.expected_thd_pct,
                snap.snr_db);
    return overall;
}

}  // namespace

int main(int argc, char** argv) {
    const std::string outDir = (argc > 1) ? argv[1] : "out_wavs";

    std::printf("=== WAV Validation ===\n");
    std::printf("Generando WAVs de referencia en %s/\n", outDir.c_str());

    // Crear dir si no existe (Windows mkdir).
#ifdef _WIN32
    std::string mkdirCmd = "if not exist \"" + outDir + "\" mkdir \"" + outDir + "\"";
    std::system(mkdirCmd.c_str());
#else
    std::system(("mkdir -p " + outDir).c_str());
#endif

    std::vector<ReferenceWav> refs;
    generateReferenceWavs(outDir, refs);
    std::printf("Generados %zu WAV.\n\n", refs.size());

    std::printf("Procesando WAVs a través del ToneAnalyzer:\n");
    int passed = 0;
    for (const auto& r : refs) {
        if (processWavThroughAnalyzer(r, outDir + "/" + r.filename)) ++passed;
    }

    std::printf("\n=== %d / %zu WAVs validados ===\n", passed, refs.size());
    return (passed == static_cast<int>(refs.size())) ? 0 : 1;
}

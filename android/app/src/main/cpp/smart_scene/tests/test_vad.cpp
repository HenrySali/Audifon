/// @file test_vad.cpp
/// @brief Tests offline para el SceneAnalyzer + VadDetector.
///
/// Compila y corre en host (Windows MSVC, Linux gcc, macOS clang).
/// No depende de Android NDK ni de Oboe — sólo de los archivos del
/// directorio padre `smart_scene/`.
///
/// Genera señales sintéticas, las pasa por el pipeline completo y verifica:
///   - Silencio: `voice_active=false`.
///   - Tono puro estacionario: gateado por stationarity.
///   - Pulso de impulso: bloqueado por impulse holdoff.
///   - Ruido modulado tipo breath: bloqueado por flatness/ZCR/tilt.
///   - Diente de sierra 200 Hz con envolvente 4 Hz (proxy de voz):
///     debería activar voz.
///
/// Cómo compilar y correr (desde esta carpeta):
///   cl /std:c++17 /EHsc /O2 /I.. test_vad.cpp ^
///       ..\spectral_features.cpp ..\noise_profile.cpp ^
///       ..\vad_detector.cpp ..\scene_analyzer.cpp /Fe:test_vad.exe
///   .\test_vad.exe

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "../scene_analyzer.h"
#include "../scene_types.h"

namespace {

constexpr int   kSampleRate = 48000;
constexpr int   kBlockSize  = 256;
constexpr float kSplOffset  = 93.0f;  // mismo default del DspPipeline.
constexpr float kPi         = 3.14159265358979323846f;

// Convierte un nivel objetivo en dB SPL al RMS lineal equivalente.
float dbSplToRms(float dbSpl) {
    return std::pow(10.0f, (dbSpl - kSplOffset) / 20.0f);
}

// Genera N segundos de silencio (zeros).
std::vector<float> genSilence(int seconds) {
    return std::vector<float>(seconds * kSampleRate, 0.0f);
}

// Tono puro a frequency Hz, level dB SPL, durante seconds segundos.
std::vector<float> genTone(float freqHz, float dbSpl, int seconds) {
    const int N = seconds * kSampleRate;
    std::vector<float> out(N, 0.0f);
    const float amp = dbSplToRms(dbSpl) * std::sqrt(2.0f); // peak para sine
    const float w = 2.0f * kPi * freqHz / static_cast<float>(kSampleRate);
    for (int i = 0; i < N; ++i) {
        out[i] = amp * std::sin(w * static_cast<float>(i));
    }
    return out;
}

// Pulso de duration ms a level dB SPL, precedido y seguido de silencio.
std::vector<float> genImpulse(float dbSpl, int durationMs, int totalSeconds) {
    std::vector<float> out(totalSeconds * kSampleRate, 0.0f);
    const int start = (totalSeconds * kSampleRate) / 2;
    const int n = (durationMs * kSampleRate) / 1000;
    const float amp = dbSplToRms(dbSpl);
    for (int i = 0; i < n && (start + i) < (int)out.size(); ++i) {
        out[start + i] = amp;
    }
    return out;
}

// Ruido blanco filtrado en banda 200-2000 Hz, modulado a 0.5 Hz (proxy de
// respiración profunda y sostenida).
std::vector<float> genBreathProxy(float dbSpl, int seconds) {
    const int N = seconds * kSampleRate;
    std::vector<float> out(N, 0.0f);

    // Generador LCG simple para reproducibilidad.
    uint32_t seed = 1;
    auto rand01 = [&seed]() {
        seed = seed * 1664525u + 1013904223u;
        return (static_cast<float>(seed >> 8) / 16777216.0f) * 2.0f - 1.0f;
    };

    // Filtro pasabandas barato: HPF + LPF de 1er orden en cascada.
    const float fcLow  = 200.0f;
    const float fcHigh = 2000.0f;
    const float dt     = 1.0f / kSampleRate;
    const float rcLow  = 1.0f / (2.0f * kPi * fcLow);
    const float rcHigh = 1.0f / (2.0f * kPi * fcHigh);
    const float aHpf   = rcLow / (rcLow + dt);
    const float aLpf   = dt    / (rcHigh + dt);

    float xPrev = 0.0f, yHpf = 0.0f, yLpf = 0.0f;
    const float amp = dbSplToRms(dbSpl) * 1.5f; // un poco más de margen.
    const float modW = 2.0f * kPi * 0.5f / static_cast<float>(kSampleRate);

    for (int i = 0; i < N; ++i) {
        const float x = rand01();
        yHpf = aHpf * (yHpf + x - xPrev);
        yLpf = yLpf + aLpf * (yHpf - yLpf);
        xPrev = x;
        const float env = 0.5f * (1.0f + std::sin(modW * static_cast<float>(i)));
        out[i] = amp * yLpf * env;
    }
    return out;
}

// Diente de sierra a freqHz Hz (rico en armónicos, proxy de vocal),
// modulado por una envolvente a envHz Hz, level dB SPL, seconds segundos.
std::vector<float> genVoiceProxy(float freqHz,
                                 float envHz,
                                 float dbSpl,
                                 int seconds) {
    const int N = seconds * kSampleRate;
    std::vector<float> out(N, 0.0f);
    const float amp = dbSplToRms(dbSpl) * std::sqrt(2.0f);
    const float wPhase = 2.0f * kPi * freqHz / static_cast<float>(kSampleRate);
    const float wEnv   = 2.0f * kPi * envHz  / static_cast<float>(kSampleRate);
    float phase = 0.0f;
    for (int i = 0; i < N; ++i) {
        // Diente de sierra en [-1, 1].
        const float saw = (phase / kPi) - 1.0f;
        // Envolvente AM a 4 Hz, sin caer a 0 — entre 0.4 y 1.0.
        const float env = 0.7f + 0.3f * std::sin(wEnv * static_cast<float>(i));
        out[i] = amp * saw * env;
        phase += wPhase;
        if (phase >= 2.0f * kPi) phase -= 2.0f * kPi;
    }
    return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// Driver: corre el pipeline sobre la señal y devuelve un vector de snapshots
// (uno por bloque de FFT, ~10 Hz a kBlockSize=256 con overlap 50%).
// ─────────────────────────────────────────────────────────────────────────────

struct RunResult {
    int totalBlocks;
    int voiceActiveBlocks;
    smart_scene::SceneSnapshot last;
    std::vector<smart_scene::SceneSnapshot> samples;
};

RunResult runPipeline(const std::vector<float>& signal,
                      bool keepAllSamples = false) {
    smart_scene::SceneAnalyzer analyzer;
    analyzer.init(kSampleRate, kSplOffset);

    RunResult result{};
    int voiceCount = 0;
    int blocks     = 0;
    smart_scene::SceneSnapshot prev{};
    std::memset(&prev, 0, sizeof(prev));

    for (size_t i = 0; i + kBlockSize <= signal.size(); i += kBlockSize) {
        analyzer.process(signal.data() + i, kBlockSize);
        const auto snap = analyzer.getSnapshot();
        // Detectar publicación de un nuevo snapshot por timestamp distinto.
        if (snap.timestamp_us != prev.timestamp_us) {
            ++blocks;
            if (snap.voice_active) ++voiceCount;
            if (keepAllSamples) result.samples.push_back(snap);
            prev = snap;
        }
    }

    result.totalBlocks       = blocks;
    result.voiceActiveBlocks = voiceCount;
    result.last              = prev;
    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers de reporte
// ─────────────────────────────────────────────────────────────────────────────

struct TestSpec {
    std::string name;
    std::string description;
    bool        expectVoice;     // true = debería marcar voz casi todo el bloque.
    float       expectMinRatio;  // mínimo aceptable de voiceActiveBlocks/total.
    float       expectMaxRatio;  // máximo aceptable.
};

bool runTest(const TestSpec& spec, const std::vector<float>& signal) {
    const auto r = runPipeline(signal);
    const float ratio = (r.totalBlocks > 0)
        ? static_cast<float>(r.voiceActiveBlocks) /
              static_cast<float>(r.totalBlocks)
        : 0.0f;

    const bool ok = (ratio >= spec.expectMinRatio) &&
                    (ratio <= spec.expectMaxRatio);

    std::printf("\n=== %s ===\n", spec.name.c_str());
    std::printf("    %s\n", spec.description.c_str());
    std::printf("    Bloques procesados : %d\n", r.totalBlocks);
    std::printf("    Voice active       : %d (%.1f%%)\n",
                r.voiceActiveBlocks, ratio * 100.0f);
    std::printf("    Esperado           : entre %.0f%% y %.0f%%\n",
                spec.expectMinRatio * 100.0f, spec.expectMaxRatio * 100.0f);
    std::printf("    Último snapshot:\n");
    std::printf("      input=%.1f dB SPL  noise=%.1f dB  snr=%.1f dB\n",
                r.last.input_db_spl, r.last.noise_floor_db_spl, r.last.snr_db);
    std::printf("      vad_score=%.3f  vad_conf=%.3f  voice_active=%u  hangover=%u\n",
                r.last.vad_score, r.last.vad_confidence,
                r.last.voice_active, r.last.vad_hangover_active);
    std::printf("      flatness=%.3f  tilt=%.2f dB/oct  centroid=%.0f Hz  flux=%.3f\n",
                r.last.spectral_flatness, r.last.spectral_tilt_db,
                r.last.spectral_centroid_hz, r.last.spectral_flux);
    std::printf("      mid_snr_q8=%u (~%.1f dB)  stationarity_q8=%u (~%.2f)\n",
                r.last.vad_mid_snr_q8,
                (r.last.vad_mid_snr_q8 / 255.0f) * 30.0f,
                r.last.vad_stationarity_q8,
                r.last.vad_stationarity_q8 / 255.0f);
    std::printf("    Resultado          : %s\n", ok ? "PASS" : "FAIL");
    return ok;
}

} // namespace

int main() {
    std::printf("========================================\n");
    std::printf("  Smart Scene VAD — tests offline\n");
    std::printf("  Sample rate : %d Hz\n", kSampleRate);
    std::printf("  Block size  : %d samples\n", kBlockSize);
    std::printf("  SPL offset  : %.1f dB\n", kSplOffset);
    std::printf("========================================\n");

    int passed = 0;
    int total  = 0;

    auto runOne = [&](const TestSpec& spec, const std::vector<float>& sig) {
        ++total;
        if (runTest(spec, sig)) ++passed;
    };

    // Test 1 — silencio puro.
    runOne(
        {"T1 silencio",
         "5 s de zeros. Esperado: voice_active=0 siempre.",
         false, 0.0f, 0.02f},
        genSilence(5));

    // Test 2 — tono puro 1 kHz a 65 dB SPL.
    runOne(
        {"T2 tono 1 kHz a 65 dB SPL",
         "Estacionario, sin envolvente. Stationarity gate debería bloquear.",
         false, 0.0f, 0.10f},
        genTone(1000.0f, 65.0f, 5));

    // Test 3 — pulso de 50 ms a 90 dB SPL desde silencio.
    runOne(
        {"T3 pulso impulso 50 ms",
         "Ataque > 12 dB desde silencio. Impulse holdoff debería matar.",
         false, 0.0f, 0.05f},
        genImpulse(90.0f, 50, 5));

    // Test 4 — proxy de respiración: ruido 200-2000 Hz mod 0.5 Hz a 65 dB SPL.
    runOne(
        {"T4 proxy respiración",
         "Ruido pasabandeado modulado a 0.5 Hz, sin pitch. Esperado: bloqueado.",
         false, 0.0f, 0.10f},
        genBreathProxy(65.0f, 5));

    // Test 4b — respiración fuerte 70 dB SPL (cerca del mic).
    runOne(
        {"T4b proxy respiración fuerte 70 dB SPL",
         "Respiración cerca del mic, mismo perfil sin pitch. Bloqueado.",
         false, 0.0f, 0.10f},
        genBreathProxy(70.0f, 5));

    // Test 4c — respiración baja 50 dB SPL (cuarto silencioso).
    runOne(
        {"T4c proxy respiración baja 50 dB SPL",
         "Respiración suave en ambiente quieto. Bloqueado.",
         false, 0.0f, 0.10f},
        genBreathProxy(50.0f, 5));

    // Test 5a — voz bajita 55 dB SPL (caso real del usuario).
    runOne(
        {"T5a voz bajita 55 dB SPL (sierra 200 Hz + env 4 Hz)",
         "Voz suave, conversacional a distancia. DEBE activar voz.",
         true, 0.40f, 1.00f},
        genVoiceProxy(200.0f, 4.0f, 55.0f, 5));

    // Test 5aa — voz muy bajita 45 dB SPL (susurro a corta distancia).
    runOne(
        {"T5aa voz muy bajita 45 dB SPL",
         "Voz casi al límite del gate SPL (30 dB). Debería activar.",
         true, 0.30f, 1.00f},
        genVoiceProxy(200.0f, 4.0f, 45.0f, 5));

    // Test 5b — voz conversacional 65 dB SPL.
    runOne(
        {"T5b voz conversacional 65 dB SPL",
         "Habla normal. Debería activar voz.",
         true, 0.50f, 1.00f},
        genVoiceProxy(200.0f, 4.0f, 65.0f, 5));

    // Test 5 — proxy de voz: diente de sierra 200 Hz + envolvente 4 Hz a 70 dB SPL.
    runOne(
        {"T5 proxy voz (sierra 200 Hz + env 4 Hz)",
         "Pitch claro a 200 Hz, envolvente vocal. Debería activar voz.",
         true, 0.50f, 1.00f},
        genVoiceProxy(200.0f, 4.0f, 70.0f, 5));

    // Test 6 — proxy de voz fuerte: 80 dB SPL.
    runOne(
        {"T6 proxy voz fuerte 80 dB SPL",
         "Mismo proxy, nivel alto. Debería activar con margen.",
         true, 0.60f, 1.00f},
        genVoiceProxy(180.0f, 4.0f, 80.0f, 5));

    // Test 7 — voz fuerte 95 dB SPL (similar al CSV real del usuario).
    runOne(
        {"T7 proxy voz a 95 dB SPL",
         "Reproduce el rango del CSV pegado por el usuario (filas 25-33).",
         true, 0.40f, 1.00f},
        genVoiceProxy(180.0f, 4.0f, 95.0f, 5));

    std::printf("\n========================================\n");
    std::printf("  TOTAL: %d/%d tests pasados\n", passed, total);
    std::printf("========================================\n");
    return (passed == total) ? 0 : 1;
}

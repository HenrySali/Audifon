/// @file test_noise_scale.cpp
/// @brief Test de escala del Estimador_Ruido (R2, spec mvdr-noise-clarity-tuning).
///
/// Valida el fix de escala del piso de ruido y del SNR del SceneAnalyzer:
///   - Property 4 (design): noise_floor_db_spl ∈ [-60, -40] dBFS para mic real.
///   - Property 5 (design): snr_db varía con el contenido y ∈ [-20, 40]; NUNCA
///     queda fijo en 40 (bug original: pegado en el tope).
///
/// Self-contained (host MSVC/gcc/clang), no depende de Android NDK ni Oboe.
///
/// Compilar y correr (desde esta carpeta, con vcvars64 cargado):
///   cl /std:c++17 /EHsc /O2 /nologo /W3 /I.. test_noise_scale.cpp ^
///       ..\spectral_features.cpp ..\noise_profile.cpp ^
///       ..\vad_detector.cpp ..\scene_analyzer.cpp /Fe:test_noise_scale.exe
///   .\test_noise_scale.exe
///
/// NOTA: no ejecutado en el entorno del agente (sin toolchain C++). Validado
/// por get_diagnostics; queda listo para correr en la máquina del dev.

#include <cmath>
#include <cstdio>
#include <vector>

#include "../scene_analyzer.h"
#include "../scene_types.h"
#include "../noise_profile.h"

namespace {

constexpr int   kSampleRate = 48000;
constexpr int   kBlockSize  = 256;
constexpr float kSplOffset  = 93.0f;  // mismo default del DspPipeline.
constexpr float kPi         = 3.14159265358979323846f;

int g_failures = 0;

#define CHECK(cond, msg)                                                    \
    do {                                                                    \
        if (!(cond)) {                                                      \
            std::printf("  [FAIL] %s\n", (msg));                            \
            ++g_failures;                                                   \
        } else {                                                            \
            std::printf("  [ok]   %s\n", (msg));                            \
        }                                                                   \
    } while (0)

float dbSplToRms(float dbSpl) {
    return std::pow(10.0f, (dbSpl - kSplOffset) / 20.0f);
}

// Corre `seconds` de un tono a `freqHz`/`dbSpl` (o silencio si dbSpl<=0) por el
// SceneAnalyzer y devuelve el último snapshot.
smart_scene::SceneSnapshot runTone(smart_scene::SceneAnalyzer& sa,
                                    float freqHz, float dbSpl, int seconds) {
    const int N = seconds * kSampleRate;
    std::vector<float> block(kBlockSize, 0.0f);
    const float amp = (dbSpl > 0.0f) ? dbSplToRms(dbSpl) * std::sqrt(2.0f) : 0.0f;
    const float w = 2.0f * kPi * freqHz / static_cast<float>(kSampleRate);
    int n = 0;
    while (n < N) {
        for (int i = 0; i < kBlockSize; ++i) {
            block[i] = amp * std::sin(w * static_cast<float>(n + i));
        }
        sa.process(block.data(), kBlockSize);
        n += kBlockSize;
    }
    return sa.getSnapshot();
}

// Corre `seconds` de ruido blanco a `dbFs` (RMS) por el SceneAnalyzer y
// devuelve el último snapshot. Representa el ruido propio del mic (silencio
// real) y el ruido de fondo, que los ceros perfectos de runTone no modelan.
smart_scene::SceneSnapshot runNoise(smart_scene::SceneAnalyzer& sa,
                                    float dbFs, int seconds) {
    const int N = seconds * kSampleRate;
    std::vector<float> block(kBlockSize, 0.0f);
    const float rms = std::pow(10.0f, dbFs / 20.0f);
    const float amp = rms * 1.7320508f;   // uniforme [-amp,amp] → RMS=amp/√3
    uint32_t s = 22695477u;                // LCG determinista (reproducible)
    int n = 0;
    while (n < N) {
        for (int i = 0; i < kBlockSize; ++i) {
            s = s * 1664525u + 1013904223u;
            const float u = static_cast<float>(s >> 8) /
                            static_cast<float>(1u << 24);  // [0,1)
            block[i] = amp * (2.0f * u - 1.0f);
        }
        sa.process(block.data(), kBlockSize);
        n += kBlockSize;
    }
    return sa.getSnapshot();
}

// ── Test A: NoiseProfile init/rango (unidad) ──────────────────────────────
void testNoiseProfileInit() {
    std::printf("Test A: NoiseProfile init plausible\n");
    smart_scene::NoiseProfile np;
    // Sin updates, el piso inicial debe ser plausible (~-50), no -90.
    CHECK(np.getNoiseFloorDb() > -60.0f && np.getNoiseFloorDb() < -40.0f,
          "piso inicial en [-60,-40] dBFS (no -90)");

    // Alimentar energías por banda ~-50 dBFS: el piso debe converger cerca.
    float bands[smart_scene::kSceneNumBands];
    for (int b = 0; b < smart_scene::kSceneNumBands; ++b) bands[b] = -50.0f;
    for (int i = 0; i < 100; ++i) np.update(bands);
    CHECK(np.getNoiseFloorDb() > -60.0f && np.getNoiseFloorDb() < -40.0f,
          "piso converge a rango plausible con energia -50 dBFS");
}

// ── Test B: floor + SNR del snapshot (integración SceneAnalyzer) ──────────
void testSnapshotScale() {
    std::printf("Test B: floor y SNR del snapshot corregidos\n");

    smart_scene::SceneAnalyzer saSilence;
    saSilence.init(kSampleRate, kSplOffset);
    auto snapSilence = runTone(saSilence, 0.0f, 0.0f, 2);

    smart_scene::SceneAnalyzer saVoice;
    saVoice.init(kSampleRate, kSplOffset);
    auto snapVoice = runTone(saVoice, 1000.0f, 65.0f, 2);

    // Property 4: piso físicamente plausible.
    CHECK(snapSilence.noise_floor_db_spl >= -60.0f &&
          snapSilence.noise_floor_db_spl <= -40.0f,
          "silencio: noise_floor_db_spl in [-60,-40] dBFS");
    CHECK(snapVoice.noise_floor_db_spl >= -60.0f &&
          snapVoice.noise_floor_db_spl <= -40.0f,
          "voz: noise_floor_db_spl in [-60,-40] dBFS");

    // Property 5: SNR acotado y NO pegado en 40.
    CHECK(snapVoice.snr_db >= -20.0f && snapVoice.snr_db <= 40.0f,
          "voz: snr_db in [-20,40]");
    CHECK(std::fabs(snapVoice.snr_db - 40.0f) > 1e-3f ||
          std::fabs(snapSilence.snr_db - 40.0f) > 1e-3f,
          "snr_db NO queda fijo en el tope 40 en ambos casos");

    // El SNR debe VARIAR con el contenido: tono 65 dB SPL > silencio.
    CHECK(snapVoice.snr_db > snapSilence.snr_db,
          "snr_db(voz 65dB) > snr_db(silencio) — varia con el contenido");

    std::printf("     floor(silencio)=%.2f floor(voz)=%.2f "
                "snr(silencio)=%.2f snr(voz)=%.2f\n",
                snapSilence.noise_floor_db_spl, snapVoice.noise_floor_db_spl,
                snapSilence.snr_db, snapVoice.snr_db);
}

// ── Test C: el piso ya NO queda pegado en -60 y sube con ruido real ───────
// FIX piso pegado en -60 (grabaciones Moto G32). Con la calibración de las
// energías por banda al dominio dBFS del input, el piso de ruido debe:
//   (1) caer dentro del rango físico SIN quedar clavado en el borde -60 cuando
//       hay ruido propio del mic (silencio real, no ceros perfectos);
//   (2) SUBIR cuando aumenta el ruido de fondo (antes quedaba fijo en -60).
void testFloorMovesWithNoise() {
    std::printf("Test C: piso NO pegado en -60 y sube con ruido de fondo\n");

    // "Silencio real": ruido propio del mic ~-50 dBFS (no ceros perfectos).
    smart_scene::SceneAnalyzer saQuiet;
    saQuiet.init(kSampleRate, kSplOffset);
    auto quiet = runNoise(saQuiet, -50.0f, 3);

    // Ruido de fondo audible ~-42 dBFS.
    smart_scene::SceneAnalyzer saNoise;
    saNoise.init(kSampleRate, kSplOffset);
    auto noisy = runNoise(saNoise, -42.0f, 3);

    // (1) Piso dentro de rango y NO pegado al borde -60.
    CHECK(quiet.noise_floor_db_spl >= -60.0f &&
          quiet.noise_floor_db_spl <= -40.0f,
          "silencio real: piso en rango fisico [-60,-40] dBFS");
    CHECK(quiet.noise_floor_db_spl > -59.0f,
          "silencio real: piso NO queda pegado en el borde -60");

    // (2) El piso SUBE con el ruido de fondo (antes: fijo en -60).
    CHECK(noisy.noise_floor_db_spl > quiet.noise_floor_db_spl + 1.0f,
          "el piso sube con ruido de fondo (no queda clavado en -60)");

    std::printf("     floor(quiet -50dBFS)=%.2f floor(noise -42dBFS)=%.2f\n",
                quiet.noise_floor_db_spl, noisy.noise_floor_db_spl);
}

} // namespace

int main() {
    std::printf("=== test_noise_scale (R2 fix de escala) ===\n");
    testNoiseProfileInit();
    testSnapshotScale();
    testFloorMovesWithNoise();
    if (g_failures == 0) {
        std::printf("\nTODOS LOS TESTS PASARON\n");
        return 0;
    }
    std::printf("\n%d TEST(S) FALLARON\n", g_failures);
    return 1;
}

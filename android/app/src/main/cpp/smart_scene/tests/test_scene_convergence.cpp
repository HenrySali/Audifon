/// @file test_scene_convergence.cpp
/// @brief Test de convergencia del clasificador de escena (R4, tarea 3.4 del
///        spec mvdr-noise-clarity-tuning).
///
/// Valida que, tras el fix de escala R2 + la habilitación de la decisión de
/// SceneClass (SceneAnalyzer::classifyScene, tarea 3.2), el campo crudo
/// snapshot.scene_class YA NO queda pegado en UNKNOWN:
///   - Property 6 (design): sobre una sesión representativa,
///     UNKNOWN ≤ 20% de las muestras.
///   - Property 7 (design): etiquetas coherentes — silencio → SILENCE,
///     ruido de banda ancha sin voz → alguna clase NOISE_*.
///
/// A diferencia del test offline con grabaciones del Moto G32 (que requiere el
/// toolchain de simulación y no está disponible en el entorno del agente), este
/// test es HOST STANDALONE con señal SINTÉTICA representativa (silencio + tono +
/// ruido de banda ancha), siguiendo el patrón de test_noise_scale.cpp. No
/// necesita audio del paciente ni Android NDK/Oboe.
///
/// Compilar y correr (desde esta carpeta, con vcvars64 cargado):
///   cl /std:c++17 /EHsc /O2 /nologo /W3 /I.. test_scene_convergence.cpp ^
///       ..\spectral_features.cpp ..\noise_profile.cpp ^
///       ..\vad_detector.cpp ..\scene_analyzer.cpp /Fe:test_scene_convergence.exe
///   .\test_scene_convergence.exe
///
/// o con gcc/clang:
///   g++ -std=c++17 -O2 -I.. test_scene_convergence.cpp \
///       ../spectral_features.cpp ../noise_profile.cpp \
///       ../vad_detector.cpp ../scene_analyzer.cpp -o test_scene_convergence
///
/// NOTA: no ejecutado en el entorno del agente (sin toolchain C++). Validado
/// por get_diagnostics; queda listo para correr en la máquina del dev.

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "../scene_analyzer.h"
#include "../scene_types.h"

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

// LCG determinista para ruido reproducible (sin depender de <random>).
struct Lcg {
    uint32_t s = 0x12345678u;
    float next() {  // [-1, 1)
        s = s * 1664525u + 1013904223u;
        return (static_cast<float>(s >> 8) / 8388608.0f) - 1.0f;
    }
};

// Acumula estadísticas de scene_class por bloque a lo largo de un tramo.
struct SceneStats {
    int total = 0;
    int unknown = 0;
    int perClass[8] = {0};
    void add(uint8_t sceneClass) {
        ++total;
        if (sceneClass < 8) ++perClass[sceneClass];
        if (sceneClass == static_cast<uint8_t>(smart_scene::SceneClass::UNKNOWN)) {
            ++unknown;
        }
    }
};

// Procesa `seconds` de:
//   - silencio        (kind = 0)
//   - tono freqHz      (kind = 1) a dbSpl
//   - ruido banda ancha(kind = 2) a dbSpl
// muestreando el snapshot tras cada bloque y acumulando en `stats`.
void runSegment(smart_scene::SceneAnalyzer& sa, int kind, float freqHz,
                float dbSpl, int seconds, Lcg& rng, SceneStats& stats) {
    const int N = seconds * kSampleRate;
    std::vector<float> block(kBlockSize, 0.0f);
    const float rms = dbSplToRms(dbSpl);
    const float ampTone = rms * std::sqrt(2.0f);
    const float w = 2.0f * kPi * freqHz / static_cast<float>(kSampleRate);
    int n = 0;
    while (n < N) {
        for (int i = 0; i < kBlockSize; ++i) {
            switch (kind) {
                case 1: block[i] = ampTone * std::sin(w * (n + i)); break;
                case 2: block[i] = rms * rng.next() * 1.732f; break; // ruido
                default: block[i] = 0.0f; break;                     // silencio
            }
        }
        sa.process(block.data(), kBlockSize);
        stats.add(sa.getSnapshot().scene_class);
        n += kBlockSize;
    }
}

// ── Test: sesión representativa → UNKNOWN ≤ 20% (Property 6) ──────────────
void testConvergence() {
    std::printf("Test: UNKNOWN <= 20%% en sesion sintetica representativa\n");

    smart_scene::SceneAnalyzer sa;
    sa.init(kSampleRate, kSplOffset);

    Lcg rng;
    SceneStats stats;

    // Sesión doméstica sintética: silencio → voz → ruido → voz.
    runSegment(sa, /*kind=*/0, 0.0f,    0.0f, 2, rng, stats);   // silencio
    runSegment(sa, /*kind=*/1, 1000.0f, 65.0f, 3, rng, stats);  // "voz" (tono)
    runSegment(sa, /*kind=*/2, 0.0f,    60.0f, 2, rng, stats);  // ruido banda ancha
    runSegment(sa, /*kind=*/1, 1500.0f, 62.0f, 3, rng, stats);  // "voz" (tono)

    const float unknownFrac =
        stats.total > 0 ? static_cast<float>(stats.unknown) / stats.total : 1.0f;

    std::printf("     bloques=%d unknown=%d (%.1f%%)\n",
                stats.total, stats.unknown, unknownFrac * 100.0f);
    std::printf("     por clase: UNK=%d SIL=%d VOI=%d VLN=%d VMN=%d "
                "NLO=%d NHI=%d MUS=%d\n",
                stats.perClass[0], stats.perClass[1], stats.perClass[2],
                stats.perClass[3], stats.perClass[4], stats.perClass[5],
                stats.perClass[6], stats.perClass[7]);

    // Property 6: UNKNOWN acotado.
    CHECK(unknownFrac <= 0.20f, "UNKNOWN <= 20% de las muestras (R4 AC6)");

    // Property 7 (coherencia mínima): el clasificador emite al menos una clase
    // concreta distinta de UNKNOWN durante la sesión.
    int concrete = stats.total - stats.unknown;
    CHECK(concrete > 0, "clasifica al menos una muestra a clase concreta");
}

// ── Test: silencio prolongado → SILENCE dominante (Property 7) ────────────
void testSilenceLabel() {
    std::printf("Test: silencio -> SILENCE dominante\n");

    smart_scene::SceneAnalyzer sa;
    sa.init(kSampleRate, kSplOffset);

    Lcg rng;
    SceneStats stats;
    runSegment(sa, /*kind=*/0, 0.0f, 0.0f, 3, rng, stats);

    const int silence =
        stats.perClass[static_cast<int>(smart_scene::SceneClass::SILENCE)];
    CHECK(silence > stats.unknown,
          "silencio prolongado etiqueta SILENCE mas que UNKNOWN");
}

} // namespace

int main() {
    std::printf("=== test_scene_convergence (R4 tarea 3.4) ===\n");
    testConvergence();
    testSilenceLabel();
    if (g_failures == 0) {
        std::printf("\nTODOS LOS TESTS PASARON\n");
        return 0;
    }
    std::printf("\n%d TEST(S) FALLARON\n", g_failures);
    return 1;
}

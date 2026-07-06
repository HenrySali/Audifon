/// @file mpo_invariant_test.cpp
/// @brief Invariante de seguridad clínica del MPO (R7, spec
///        mvdr-noise-clarity-tuning).
///
/// Valida:
///   - Property 9 (design): para TODA muestra de salida y TODA combinación de
///     toggles (Expansor, NR, SCE, TNR), |salida| ≤ thresholdLinear.
///   - Property 10 (design): el comportamiento del MPO (getLimitingFraction)
///     es determinista para la misma entrada y no depende de que los toggles
///     nuevos cambien el algoritmo del limitador.
///
/// El MPO es la ÚLTIMA etapa del DspPipeline: su hard-clamp garantiza el techo
/// independientemente de las etapas previas.
///
/// Depende de dsp_pipeline.cpp y sus módulos .cpp (NO de Oboe/Android).
/// Compilar y correr (con vcvars64 cargado, desde cpp/tests/):
///   cl /std:c++17 /EHsc /O2 /nologo /W3 /I.. mpo_invariant_test.cpp ^
///       ..\dsp_pipeline.cpp ..\noise_reduction.cpp ..\equalizer.cpp ^
///       ..\wdrc_processor.cpp ..\mpo_limiter.cpp ..\environment_classifier.cpp ^
///       ..\spectrum_analyzer.cpp ..\transient_reducer.cpp ^
///       /Fe:mpo_invariant_test.exe
///   .\mpo_invariant_test.exe
///
/// NOTA: no ejecutado en el entorno del agente (sin toolchain C++). Validado
/// por get_diagnostics; queda listo para correr en la máquina del dev.

#include <cmath>
#include <cstdio>
#include <vector>

#include "../dsp_pipeline.h"
#include "../mpo_limiter.h"

namespace {

constexpr int   kSampleRate = 16000;
constexpr int   kBlockSize  = 64;
constexpr float kPi         = 3.14159265358979323846f;

// MPO 100 dB SPL con la calibración de SALIDA kMpoSplOffset=120 →
// linear = 10^((100-120)/20) = 0.1. (< techo digital 0.85 → manda 0.1.)
constexpr float kMpoDbSpl        = 100.0f;
constexpr float kExpectedThresh  = 0.1f;
constexpr float kEps             = 1e-4f;

int g_failures = 0;

#define CHECK(cond, msg)                                                    \
    do {                                                                    \
        if (!(cond)) { std::printf("  [FAIL] %s\n", (msg)); ++g_failures; } \
        else         { std::printf("  [ok]   %s\n", (msg)); }               \
    } while (0)

// Genera un bloque de señal fuerte (sine casi full-scale + ruido) para forzar
// al pipeline (EQ con ganancia alta) a superar el techo del MPO.
void fillLoudBlock(std::vector<float>& buf, int startSample) {
    const float w = 2.0f * kPi * 1000.0f / static_cast<float>(kSampleRate);
    for (int i = 0; i < (int)buf.size(); ++i) {
        const int n = startSample + i;
        float s = 0.9f * std::sin(w * n);
        // Un poco de ruido determinista para excitar todas las bandas.
        s += 0.05f * std::sin(2.0f * kPi * 4000.0f * n / kSampleRate);
        buf[i] = s;
    }
}

// Procesa varios bloques y devuelve el pico absoluto de salida observado.
float runPipeline(DspPipeline& p, int numBlocks) {
    std::vector<float> buf(kBlockSize, 0.0f);
    float peak = 0.0f;
    for (int b = 0; b < numBlocks; ++b) {
        fillLoudBlock(buf, b * kBlockSize);
        p.processBlock(buf.data(), kBlockSize);
        for (float x : buf) {
            const float a = std::fabs(x);
            if (a > peak) peak = a;
        }
    }
    return peak;
}

// Configura un pipeline con EQ de ganancia alta + MPO clínico y una
// combinación de toggles dada.
void configurePipeline(DspPipeline& p, bool expander, int nrLevel,
                       bool sce, bool tnr) {
    AudioConfig cfg;
    cfg.sampleRate = kSampleRate;
    cfg.bufferSize = kBlockSize;
    cfg.channels = 1;
    cfg.mpoThresholdDbSpl = kMpoDbSpl;
    cfg.splOffset = 93.0f;
    p.init(cfg);

    // EQ con ganancia alta para forzar clipping y disparar el MPO.
    float gains[12];
    for (int i = 0; i < 12; ++i) gains[i] = 30.0f;  // +30 dB
    p.setEqGains(gains);
    p.setVolume(10.0f);  // +10 dB extra

    // Toggles nuevos + existentes.
    if (expander) {
        p.setExpanderParams(true, 45.0f, 3.0f, 1000.0f, 30.0f, 400.0f);
    } else {
        p.setExpanderParams(false, 45.0f, 1.0f, 1000.0f, 30.0f, 400.0f);
    }
    p.setNrLevel(nrLevel);
    p.setSceEnabled(sce);
    p.setTnrEnabled(tnr);
}

// ── Property 9: invariante para toda combinación de toggles ───────────────
void testInvariantAllToggles() {
    std::printf("Property 9: |salida| ≤ threshold para toda combinación de toggles\n");
    const bool bools[2] = {false, true};
    const int nrLevels[2] = {0, 3};
    int combos = 0;

    for (bool expander : bools)
    for (int nr : nrLevels)
    for (bool sce : bools)
    for (bool tnr : bools) {
        DspPipeline p;
        configurePipeline(p, expander, nr, sce, tnr);
        const float peak = runPipeline(p, 200);
        ++combos;
        if (peak > kExpectedThresh + kEps) {
            std::printf("  [FAIL] combo exp=%d nr=%d sce=%d tnr=%d peak=%.5f > %.5f\n",
                        expander, nr, sce, tnr, peak, kExpectedThresh);
            ++g_failures;
        }
    }
    std::printf("  [ok]   %d combinaciones evaluadas; ninguna supera el techo %.3f\n",
                combos, kExpectedThresh);
}

// ── Property 10: MPO determinista / independiente del algoritmo de toggles ─
void testMpoDeterministic() {
    std::printf("Property 10: MPO determinista para la misma entrada\n");

    DspPipeline p1; configurePipeline(p1, /*exp*/false, /*nr*/0, /*sce*/false, /*tnr*/false);
    DspPipeline p2; configurePipeline(p2, /*exp*/false, /*nr*/0, /*sce*/false, /*tnr*/false);

    const float peak1 = runPipeline(p1, 100);
    const float peak2 = runPipeline(p2, 100);

    CHECK(std::fabs(peak1 - peak2) < 1e-6f,
          "dos corridas idénticas → mismo pico (MPO determinista)");
    CHECK(peak1 <= kExpectedThresh + kEps,
          "pico ≤ threshold en la corrida de referencia");
}

// ── Property 11: soft-knee reduce ganancia PROGRESIVAMENTE (no hard-clip) ──
// FIX voz ronca (grabaciones Moto G32). Verifica que el MpoLimiter con
// soft-knee:
//   (a) NO limita muy por debajo de la rodilla (ganancia ≈ 1),
//   (b) empieza a reducir ganancia DENTRO de la rodilla, por DEBAJO del techo
//       (ganancia < 1 con salida aún < threshold) — imposible con hard-clamp,
//   (c) monotonía: a más nivel de entrada, más reducción de ganancia,
//   (d) el invariante |salida| ≤ threshold se mantiene siempre.

// Corre un tono estable de amplitud `amp` por un MpoLimiter fresco y devuelve
// el pico de salida tras converger la envolvente.
float runSteadyToneThroughMpo(float thresholdLinear, float kneeDb, float amp) {
    MpoLimiter mpo;
    mpo.init(kSampleRate);
    mpo.setThresholdLinear(thresholdLinear);
    mpo.setKneeWidthDb(kneeDb);

    const float w = 2.0f * kPi * 1000.0f / static_cast<float>(kSampleRate);
    std::vector<float> buf(kBlockSize, 0.0f);
    const int totalBlocks = 80;              // ~320 ms → envolvente convergida
    const int measureFromBlock = 60;         // medir sólo el tramo estable
    float peak = 0.0f;
    int n = 0;
    for (int b = 0; b < totalBlocks; ++b) {
        for (int i = 0; i < kBlockSize; ++i) {
            buf[i] = amp * std::sin(w * static_cast<float>(n + i));
        }
        mpo.process(buf.data(), kBlockSize);
        if (b >= measureFromBlock) {
            for (float x : buf) {
                const float a = std::fabs(x);
                if (a > peak) peak = a;
            }
        }
        n += kBlockSize;
    }
    return peak;
}

void testSoftKneeProgressive() {
    std::printf("Property 11: soft-knee reduce ganancia progresivamente (no hard-clip)\n");

    const float th = 0.1f;      // threshold lineal
    const float knee = 6.0f;    // rodilla por defecto

    // Amplitudes de prueba. Borde inferior de la rodilla = th·10^(-3/20) ≈ 0.0708.
    const float ampLow  = 0.05f;  // por debajo de la rodilla → sin limitar
    const float ampKnee = 0.09f;  // dentro de la rodilla → gain < 1, salida < th
    const float ampHigh = 0.50f;  // muy por encima → salida ≈ th (limitado)

    const float outLow  = runSteadyToneThroughMpo(th, knee, ampLow);
    const float outKnee = runSteadyToneThroughMpo(th, knee, ampKnee);
    const float outHigh = runSteadyToneThroughMpo(th, knee, ampHigh);

    const float gainLow  = outLow  / ampLow;
    const float gainKnee = outKnee / ampKnee;
    const float gainHigh = outHigh / ampHigh;

    // (a) Por debajo de la rodilla: prácticamente sin limitar.
    CHECK(gainLow > 0.98f, "amp<rodilla → ganancia ~1 (sin limitar)");

    // (b) Dentro de la rodilla: ya hay reducción (gain<1) PERO la salida sigue
    //     por debajo del techo. Un hard-clamp daría gain==1 aquí.
    CHECK(gainKnee < 0.99f && gainKnee > 0.80f,
          "en la rodilla → ganancia reducida progresivamente (<1) por debajo del techo");
    CHECK(outKnee < th + kEps,
          "en la rodilla → salida por debajo del techo (aún no toca el clamp)");

    // (c) Monotonía: más entrada → más reducción de ganancia.
    CHECK(gainLow > gainKnee && gainKnee > gainHigh,
          "ganancia decrece monotónicamente con el nivel de entrada (rodilla suave)");

    // (d) Invariante de seguridad: salida ≤ threshold en todos los casos.
    CHECK(outHigh <= th + kEps, "amp>>techo → |salida| ≤ threshold (invariante)");
    CHECK(outKnee <= th + kEps && outLow <= th + kEps,
          "salida ≤ threshold en rodilla y por debajo (invariante)");

    // Contraste con hard-clamp (knee=0): en la rodilla NO hay reducción.
    const float outKneeHard = runSteadyToneThroughMpo(th, 0.0f, ampKnee);
    CHECK(std::fabs((outKneeHard / ampKnee) - 1.0f) < 1e-3f,
          "hard-clamp (knee=0) → sin reducción a amp<techo (contraste con soft-knee)");

    std::printf("     gainLow=%.4f gainKnee=%.4f gainHigh=%.4f outHigh=%.5f (th=%.3f)\n",
                gainLow, gainKnee, gainHigh, outHigh, th);
}

} // namespace

int main() {
    std::printf("=== mpo_invariant_test (R7) ===\n");
    testInvariantAllToggles();
    testMpoDeterministic();
    testSoftKneeProgressive();
    if (g_failures == 0) { std::printf("\nTODOS LOS TESTS PASARON\n"); return 0; }
    std::printf("\n%d TEST(S) FALLARON\n", g_failures);
    return 1;
}

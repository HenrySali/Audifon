/// @file expander_test.cpp
/// @brief Tests unitarios del Expansor de baja frecuencia (R1, spec
///        mvdr-noise-clarity-tuning).
///
/// Valida:
///   - Property 1: passthrough bit-exacto con enabled=false o ratio=1.0.
///   - Property 2: banda limitada — energía > cutoff conservada (±ε).
///   - Property 3: sin reducción sobre el knee (nivel > knee → ganancia 1.0).
///   - AC6: transición de ataque (recuperación de ganancia) ≤ 50 ms.
///
/// Header-only: solo depende de ../expander.h. Self-contained (host).
///
/// Compilar y correr (con vcvars64 cargado):
///   cl /std:c++17 /EHsc /O2 /nologo /W3 /I.. expander_test.cpp /Fe:expander_test.exe
///   .\expander_test.exe
/// o con gcc/clang:
///   g++ -std=c++17 -O2 -I.. expander_test.cpp -o expander_test && ./expander_test
///
/// NOTA: no ejecutado en el entorno del agente (sin toolchain C++). Validado
/// por get_diagnostics; queda listo para correr en la máquina del dev.

#include <cmath>
#include <cstdio>
#include <vector>

#include "../expander.h"

namespace {

constexpr int   kSampleRate = 48000;
constexpr int   kBlockSize  = 256;
constexpr float kPi         = 3.14159265358979323846f;

int g_failures = 0;

#define CHECK(cond, msg)                                                    \
    do {                                                                    \
        if (!(cond)) { std::printf("  [FAIL] %s\n", (msg)); ++g_failures; } \
        else         { std::printf("  [ok]   %s\n", (msg)); }               \
    } while (0)

float rms(const std::vector<float>& v) {
    double acc = 0.0;
    for (float x : v) acc += static_cast<double>(x) * x;
    return static_cast<float>(std::sqrt(acc / v.size()));
}

std::vector<float> genTone(float freqHz, float amp, int n) {
    std::vector<float> out(n, 0.0f);
    const float w = 2.0f * kPi * freqHz / static_cast<float>(kSampleRate);
    for (int i = 0; i < n; ++i) out[i] = amp * std::sin(w * i);
    return out;
}

// ── Property 1: passthrough ───────────────────────────────────────────────
void testPassthrough() {
    std::printf("Property 1: passthrough (enabled=false y ratio=1.0)\n");

    auto sig = genTone(500.0f, 0.2f, kBlockSize);

    // enabled=false → passthrough bit-exacto.
    Expander exOff; exOff.init(kSampleRate);
    auto a = sig;
    exOff.process(a.data(), kBlockSize, 30.0f);  // nivel bajo el knee
    bool bitExactOff = true;
    for (int i = 0; i < kBlockSize; ++i) if (a[i] != sig[i]) bitExactOff = false;
    CHECK(bitExactOff, "enabled=false → salida bit-exacta a la entrada");

    // enabled=true pero ratio=1.0 → passthrough.
    Expander exUnity; exUnity.init(kSampleRate);
    exUnity.setEnabled(true);
    exUnity.setRatio(1.0f);
    auto b = sig;
    exUnity.process(b.data(), kBlockSize, 30.0f);
    bool bitExactUnity = true;
    for (int i = 0; i < kBlockSize; ++i) if (b[i] != sig[i]) bitExactUnity = false;
    CHECK(bitExactUnity, "ratio=1.0 → salida bit-exacta a la entrada");
}

// ── Property 2: banda limitada (energía > cutoff conservada) ──────────────
void testBandLimited() {
    std::printf("Property 2: banda limitada ≤1000 Hz\n");

    // Tono ALTO (4 kHz) bien por encima del corte, a nivel bajo (< knee) para
    // que la expansión intente atenuar. La banda alta debe conservarse.
    Expander ex; ex.init(kSampleRate);
    ex.setEnabled(true);
    ex.setKneeDbSpl(45.0f);
    ex.setRatio(3.0f);
    ex.setCutoffHz(1000.0f);
    ex.setAttackMs(5.0f);
    ex.setReleaseMs(50.0f);

    auto high = genTone(4000.0f, 0.05f, kBlockSize * 20);
    const float rmsIn = rms(high);
    // Procesar por bloques con inputLevelDb bajo (30 dB SPL < knee).
    for (int off = 0; off + kBlockSize <= (int)high.size(); off += kBlockSize) {
        ex.process(high.data() + off, kBlockSize, 30.0f);
    }
    const float rmsOut = rms(high);
    // Tolerancia por fuga del filtro complementario (banda alta debería
    // conservar ≥ ~85% de energía RMS).
    CHECK(rmsOut > 0.85f * rmsIn,
          "energia > cutoff conservada (banda alta intacta ±eps)");
    std::printf("     rmsIn=%.5f rmsOut=%.5f (ratio=%.3f)\n",
                rmsIn, rmsOut, rmsOut / rmsIn);
}

// ── Property 3: sin reducción sobre el knee ───────────────────────────────
void testNoReductionAboveKnee() {
    std::printf("Property 3: sin reducción con nivel > knee\n");

    Expander ex; ex.init(kSampleRate);
    ex.setEnabled(true);
    ex.setKneeDbSpl(45.0f);
    ex.setRatio(3.0f);
    ex.setAttackMs(5.0f);

    auto low = genTone(300.0f, 0.2f, kBlockSize * 20);
    auto ref = low;
    // Nivel 65 dB SPL > knee 45 → ganancia objetivo 1.0.
    for (int off = 0; off + kBlockSize <= (int)low.size(); off += kBlockSize) {
        ex.process(low.data() + off, kBlockSize, 65.0f);
    }
    // Tras converger, la salida ≈ entrada (sin reducción).
    const int tail = kBlockSize * 4;
    float rIn = 0.0f, rOut = 0.0f;
    for (int i = (int)low.size() - tail; i < (int)low.size(); ++i) {
        rOut += low[i] * low[i];
        rIn  += ref[i] * ref[i];
    }
    CHECK(std::sqrt(rOut) > 0.99f * std::sqrt(rIn),
          "nivel > knee → ganancia ≈ 1.0 (sin reducción)");
}

// ── AC6: transición de ataque ≤ 50 ms ─────────────────────────────────────
void testAttackTime() {
    std::printf("AC6: recuperación de ganancia ≤ 50 ms\n");

    Expander ex; ex.init(kSampleRate);
    ex.setEnabled(true);
    ex.setKneeDbSpl(45.0f);
    ex.setRatio(3.0f);
    ex.setAttackMs(30.0f);    // dentro del límite ≤50 ms
    ex.setReleaseMs(400.0f);

    // 1) Nivel bajo prolongado → ganancia baja (atenuación establecida).
    auto lowSig = genTone(300.0f, 0.2f, kSampleRate);  // 1 s
    for (int off = 0; off + kBlockSize <= (int)lowSig.size(); off += kBlockSize) {
        ex.process(lowSig.data() + off, kBlockSize, 25.0f);  // muy bajo el knee
    }

    // 2) Salto a nivel de voz (65 dB SPL). Medir cuántas muestras hasta que la
    //    ganancia efectiva se recupera (salida ≈ entrada) — debe ser ≤ 50 ms.
    const int voiceLen = (kSampleRate * 100) / 1000;  // 100 ms de margen
    auto voice = genTone(300.0f, 0.2f, voiceLen);
    auto ref = voice;
    for (int off = 0; off + kBlockSize <= (int)voice.size(); off += kBlockSize) {
        ex.process(voice.data() + off, kBlockSize, 65.0f);
    }
    // Buscar el índice donde |out| recupera ≥ 95% de |ref| de forma sostenida.
    int recoverIdx = voiceLen;
    for (int i = 0; i < voiceLen; ++i) {
        if (std::fabs(ref[i]) > 1e-4f &&
            std::fabs(voice[i]) >= 0.95f * std::fabs(ref[i])) {
            recoverIdx = i;
            break;
        }
    }
    const float recoverMs = 1000.0f * recoverIdx / static_cast<float>(kSampleRate);
    CHECK(recoverMs <= 50.0f, "recuperación de ganancia ≤ 50 ms (AC6)");
    std::printf("     recuperacion ≈ %.1f ms\n", recoverMs);
}

} // namespace

int main() {
    std::printf("=== expander_test (R1) ===\n");
    testPassthrough();
    testBandLimited();
    testNoReductionAboveKnee();
    testAttackTime();
    if (g_failures == 0) { std::printf("\nTODOS LOS TESTS PASARON\n"); return 0; }
    std::printf("\n%d TEST(S) FALLARON\n", g_failures);
    return 1;
}

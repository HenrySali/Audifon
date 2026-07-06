/// @file dereverb_ab_test.cpp
/// @brief Test A/B del toggle de dereverb del MVDR (R5, spec
///        mvdr-noise-clarity-tuning).
///
/// Valida Property 8 (design): con dereverbEnabled=false la salida del MVDR
/// equivale al beamforming SIN la etapa de dereverb; con enabled=true se
/// atenúa la cola reverberante preservando la voz directa (AC4).
///
/// Header-only: solo depende de ../mvdr_beamformer.h. Self-contained (host).
///
/// Compilar y correr (con vcvars64 cargado):
///   cl /std:c++17 /EHsc /O2 /nologo /W3 /I.. dereverb_ab_test.cpp ^
///       /Fe:dereverb_ab_test.exe
///   .\dereverb_ab_test.exe
///
/// NOTA: no ejecutado en el entorno del agente (sin toolchain C++). Validado
/// por get_diagnostics; queda listo para correr en la máquina del dev.

#include <cmath>
#include <cstdio>
#include <vector>

#include "../mvdr_beamformer.h"

namespace {

constexpr int   kSampleRate = 16000;
constexpr int   kChunk      = MvdrBeamformer::kFftSize;  // 256
constexpr float kPi         = 3.14159265358979323846f;

int g_failures = 0;

#define CHECK(cond, msg)                                                    \
    do {                                                                    \
        if (!(cond)) { std::printf("  [FAIL] %s\n", (msg)); ++g_failures; } \
        else         { std::printf("  [ok]   %s\n", (msg)); }               \
    } while (0)

// Señal estéreo: onset directo (ataque) + cola con decaimiento exponencial
// (proxy de reverberación tardía). Ambos canales idénticos (broadside).
void genReverbLike(std::vector<float>& ch0, std::vector<float>& ch1, int n) {
    ch0.assign(n, 0.0f);
    ch1.assign(n, 0.0f);
    const float w = 2.0f * kPi * 800.0f / static_cast<float>(kSampleRate);
    const int onset = n / 4;
    for (int i = 0; i < n; ++i) {
        float env;
        if (i < onset) {
            env = 0.6f;                     // directo (energía sostenida)
        } else {
            // Cola con decaimiento exponencial (RT ~ n/4 muestras).
            env = 0.6f * std::exp(-3.0f * (i - onset) / static_cast<float>(n - onset));
        }
        const float s = env * std::sin(w * i);
        ch0[i] = s;
        ch1[i] = s;
    }
}

float tailRms(const std::vector<float>& v) {
    // RMS del último 40% (cola reverberante).
    const int start = static_cast<int>(v.size() * 0.6);
    double acc = 0.0; int cnt = 0;
    for (int i = start; i < (int)v.size(); ++i) { acc += (double)v[i]*v[i]; ++cnt; }
    return cnt ? static_cast<float>(std::sqrt(acc / cnt)) : 0.0f;
}

float headRms(const std::vector<float>& v) {
    // RMS del primer 20% (voz directa).
    const int end = static_cast<int>(v.size() * 0.2);
    double acc = 0.0; int cnt = 0;
    for (int i = 0; i < end; ++i) { acc += (double)v[i]*v[i]; ++cnt; }
    return cnt ? static_cast<float>(std::sqrt(acc / cnt)) : 0.0f;
}

void runBeamformer(MvdrBeamformer& bf, const std::vector<float>& ch0,
                   const std::vector<float>& ch1, std::vector<float>& out) {
    out.assign(ch0.size(), 0.0f);
    const int n = (int)ch0.size();
    for (int off = 0; off + kChunk <= n; off += kChunk) {
        // vadActive=false → permite estimar Rnn; el dereverb corre igual.
        bf.process(ch0.data() + off, ch1.data() + off, out.data() + off,
                   kChunk, /*vadActive=*/false);
    }
}

void testDereverbToggle() {
    std::printf("Property 8: toggle del dereverb A/B\n");

    const int n = kChunk * 40;  // suficiente para pasar el warmup (50 frames)
    std::vector<float> ch0, ch1;
    genReverbLike(ch0, ch1, n);

    // A: dereverb ON (default). B: dereverb OFF.
    MvdrBeamformer bfOn;  bfOn.init(kSampleRate);  bfOn.setEnabled(true);
    MvdrBeamformer bfOff; bfOff.init(kSampleRate); bfOff.setEnabled(true);
    bfOff.setDereverbEnabled(false);

    std::vector<float> outOn, outOff;
    runBeamformer(bfOn, ch0, ch1, outOn);
    runBeamformer(bfOff, ch0, ch1, outOff);

    // Sanidad: sin NaN/Inf.
    bool finite = true;
    for (float x : outOn) if (!std::isfinite(x)) finite = false;
    for (float x : outOff) if (!std::isfinite(x)) finite = false;
    CHECK(finite, "salidas ON/OFF finitas (sin NaN/Inf)");

    const float tailOn = tailRms(outOn);
    const float tailOff = tailRms(outOff);
    const float headOn = headRms(outOn);
    const float headOff = headRms(outOff);

    // AC1/AC2: con dereverb ON la cola reverberante se atenúa vs OFF.
    CHECK(tailOn <= tailOff + 1e-6f,
          "cola reverberante ON ≤ OFF (dereverb atenúa la cola)");
    // El toggle debe CAMBIAR algo (si son idénticos, el toggle no está cableado).
    CHECK(std::fabs(tailOn - tailOff) > 1e-5f,
          "toggle OFF ≠ ON en la cola (toggle efectivamente cableado)");

    // AC4: la voz directa (head) se preserva (ON ≈ OFF en el ataque).
    CHECK(headOff > 1e-5f && headOn >= 0.7f * headOff,
          "voz directa preservada con dereverb ON (AC4)");

    std::printf("     head: ON=%.5f OFF=%.5f | tail: ON=%.5f OFF=%.5f\n",
                headOn, headOff, tailOn, tailOff);
}

} // namespace

int main() {
    std::printf("=== dereverb_ab_test (R5) ===\n");
    testDereverbToggle();
    if (g_failures == 0) { std::printf("\nTODOS LOS TESTS PASARON\n"); return 0; }
    std::printf("\n%d TEST(S) FALLARON\n", g_failures);
    return 1;
}

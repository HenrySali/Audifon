/// @file compat_defaults_test.cpp
/// @brief Compatibilidad con modos existentes — toggles NUEVOS en OFF (R6,
///        spec mvdr-noise-clarity-tuning, tarea 6.1).
///
/// Valida (a nivel de MÓDULO, host-standalone):
///   - Property 1  : con Expander enabled=false O ratio=1.0, la salida del
///     módulo es bit-exacta a la entrada (passthrough).
///   - Property 11 : "default seguro" — si el toggle nuevo no se toca (default
///     OFF/ratio 1.0), el pipeline produce EXACTAMENTE la misma salida que un
///     pipeline donde se setea el Expander explícitamente en OFF. Es decir, la
///     introducción del Expander NO altera el comportamiento previo (R6.3/6.5)
///     mientras esté en su default.
///
/// ── Alcance de la verificación (honestidad de la tarea 6.1) ───────────────
/// VERIFICABLE EN HOST (este test):
///   * Equivalencia bit-exacta del Expander en OFF/ratio 1.0 (módulo).
///   * Equivalencia bit-exacta de la cadena DspPipeline con el toggle nuevo en
///     su default vs. seteado explícitamente en OFF (misma entrada → misma
///     salida sample-a-sample), para Bypass y NR/EQ/WDRC/MPO deterministas.
///
/// REQUIERE RE-PROCESO OFFLINE (validación complementaria del dev, NO cubierta
/// aquí — necesita las grabaciones del Moto G32 y el build del .so):
///   * Equivalencia RMS/bit-a-bit con la salida PRE-spec en los tres modos
///     reales del AudioEngine (kBypass / kDualChannelDnn / kMvdrBackup),
///     re-procesando las grabaciones reales. El AudioEngine (Oboe, GTCRN,
///     MVDR) no se instancia en host.
///   * El Estimador_Ruido nuevo (SceneAnalyzer) corre EN PARALELO y sólo
///     publica métricas (SceneSnapshot) — NO está en la cadena de audio, así
///     que su corrección de escala no cambia el audio de salida. Esto se
///     confirma por lectura (ver nota abajo), no por este test.
///   * El dereverb del MVDR queda en su default ON (comportamiento pre-spec):
///     su equivalencia se cubre en dereverb_ab_test.cpp (Property 8), no aquí.
///
/// NOTA (estimador nuevo): el SNR/piso corregidos viven en el path del
/// SceneAnalyzer (smart_scene/scene_analyzer.cpp), que el AudioEngine invoca
/// SÓLO para diagnóstico/UI (SceneSnapshot). No modifica el buffer de audio;
/// por eso, con el Expander en OFF, la cadena de audio equivale a la pre-spec.
///
/// Depende de dsp_pipeline.cpp y sus módulos .cpp (NO de Oboe/Android).
/// Compilar y correr (con vcvars64 cargado, desde cpp/tests/):
///   cl /std:c++17 /EHsc /O2 /nologo /W3 /I.. compat_defaults_test.cpp ^
///       ..\dsp_pipeline.cpp ..\noise_reduction.cpp ..\equalizer.cpp ^
///       ..\wdrc_processor.cpp ..\mpo_limiter.cpp ..\environment_classifier.cpp ^
///       ..\spectrum_analyzer.cpp ..\transient_reducer.cpp ^
///       /Fe:compat_defaults_test.exe
///   .\compat_defaults_test.exe
///
/// NOTA: no ejecutado en el entorno del agente (sin toolchain C++). Validado
/// por get_diagnostics; queda listo para correr en la máquina del dev.

#include <cmath>
#include <cstdio>
#include <vector>

#include "../dsp_pipeline.h"
#include "../expander.h"

namespace {

constexpr int   kSampleRate = 16000;
constexpr int   kBlockSize  = 64;
constexpr float kPi         = 3.14159265358979323846f;

int g_failures = 0;

#define CHECK(cond, msg)                                                    \
    do {                                                                    \
        if (!(cond)) { std::printf("  [FAIL] %s\n", (msg)); ++g_failures; } \
        else         { std::printf("  [ok]   %s\n", (msg)); }               \
    } while (0)

// Señal mixta: voz-proxy (baja) + pausa (silencio) para ejercitar tanto la
// banda del Expander como los niveles bajo/sobre knee.
void fillBlock(std::vector<float>& buf, int startSample) {
    const float wLow  = 2.0f * kPi * 300.0f  / static_cast<float>(kSampleRate);
    const float wHigh = 2.0f * kPi * 3000.0f / static_cast<float>(kSampleRate);
    for (int i = 0; i < (int)buf.size(); ++i) {
        const int n = startSample + i;
        // Ráfagas de "voz" seguidas de pausas (para nivel bajo el knee).
        const bool speech = ((n / 800) % 2) == 0;
        const float amp = speech ? 0.25f : 0.005f;  // pausa ≈ hiss
        buf[i] = amp * (std::sin(wLow * n) + 0.5f * std::sin(wHigh * n));
    }
}

// Configura un DspPipeline con EQ/WDRC/MPO clínicos típicos.
void configureCommon(DspPipeline& p) {
    AudioConfig cfg;
    cfg.sampleRate = kSampleRate;
    cfg.bufferSize = kBlockSize;
    cfg.channels = 1;
    cfg.mpoThresholdDbSpl = 105.0f;
    cfg.splOffset = 93.0f;
    p.init(cfg);

    float gains[12];
    for (int i = 0; i < 12; ++i) gains[i] = 12.0f;  // prescripción moderada
    p.setEqGains(gains);
    p.setVolume(0.0f);
}

// ── Property 1: passthrough del Expander (módulo) ─────────────────────────
void testExpanderPassthrough() {
    std::printf("Property 1: Expander OFF / ratio 1.0 → passthrough bit-exacto\n");

    std::vector<float> sig(kBlockSize);
    fillBlock(sig, 0);

    // enabled=false (default).
    Expander exOff; exOff.init(kSampleRate);
    auto a = sig;
    exOff.process(a.data(), kBlockSize, 30.0f);
    bool okOff = true;
    for (int i = 0; i < kBlockSize; ++i) if (a[i] != sig[i]) okOff = false;
    CHECK(okOff, "enabled=false → bit-exacto");

    // enabled=true + ratio=1.0.
    Expander exUnity; exUnity.init(kSampleRate);
    exUnity.setEnabled(true);
    exUnity.setRatio(1.0f);
    auto b = sig;
    exUnity.process(b.data(), kBlockSize, 30.0f);
    bool okUnity = true;
    for (int i = 0; i < kBlockSize; ++i) if (b[i] != sig[i]) okUnity = false;
    CHECK(okUnity, "enabled=true + ratio=1.0 → bit-exacto");
}

// ── Property 11: pipeline con toggle nuevo en default == OFF explícito ─────
void testPipelineDefaultEqualsExplicitOff() {
    std::printf("Property 11: pipeline default (Expander OFF) == OFF explícito\n");

    DspPipeline pDefault;  configureCommon(pDefault);
    // pDefault: NO se toca el Expander → queda en su default (enabled=false).

    DspPipeline pExplicit; configureCommon(pExplicit);
    // pExplicit: se setea el toggle nuevo explícitamente en OFF/ratio 1.0.
    pExplicit.setExpanderParams(false, 45.0f, 1.0f, 1000.0f, 30.0f, 400.0f);

    bool bitExact = true;
    float maxDiff = 0.0f;
    const int numBlocks = 300;
    std::vector<float> bufA(kBlockSize), bufB(kBlockSize);
    for (int blk = 0; blk < numBlocks; ++blk) {
        fillBlock(bufA, blk * kBlockSize);
        bufB = bufA;
        pDefault.processBlock(bufA.data(), kBlockSize);
        pExplicit.processBlock(bufB.data(), kBlockSize);
        for (int i = 0; i < kBlockSize; ++i) {
            const float d = std::fabs(bufA[i] - bufB[i]);
            if (d > maxDiff) maxDiff = d;
            if (bufA[i] != bufB[i]) bitExact = false;
        }
    }
    CHECK(bitExact, "salida bit-exacta (default == OFF explícito)");
    std::printf("     maxDiff = %.3e sobre %d bloques\n", maxDiff, numBlocks);
}

// ── Property 11 (extra): ratio 1.0 en el pipeline == default OFF ──────────
void testPipelineUnityRatioEqualsDefault() {
    std::printf("Property 11: pipeline con Expander ON+ratio 1.0 == default\n");

    DspPipeline pDefault;  configureCommon(pDefault);

    DspPipeline pUnity;    configureCommon(pUnity);
    // Expander "encendido" pero ratio 1.0 → passthrough (no cambia audio).
    pUnity.setExpanderParams(true, 45.0f, 1.0f, 1000.0f, 30.0f, 400.0f);

    bool bitExact = true;
    const int numBlocks = 200;
    std::vector<float> bufA(kBlockSize), bufB(kBlockSize);
    for (int blk = 0; blk < numBlocks; ++blk) {
        fillBlock(bufA, blk * kBlockSize);
        bufB = bufA;
        pDefault.processBlock(bufA.data(), kBlockSize);
        pUnity.processBlock(bufB.data(), kBlockSize);
        for (int i = 0; i < kBlockSize; ++i) {
            if (bufA[i] != bufB[i]) bitExact = false;
        }
    }
    CHECK(bitExact, "ratio 1.0 en el pipeline no altera la salida (R6.3)");
}

} // namespace

int main() {
    std::printf("=== compat_defaults_test (R6 — toggles nuevos en OFF) ===\n");
    testExpanderPassthrough();
    testPipelineDefaultEqualsExplicitOff();
    testPipelineUnityRatioEqualsDefault();
    if (g_failures == 0) { std::printf("\nTODOS LOS TESTS PASARON\n"); return 0; }
    std::printf("\n%d TEST(S) FALLARON\n", g_failures);
    return 1;
}

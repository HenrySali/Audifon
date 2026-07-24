/// @file test_environment_classifier.cpp
/// @brief Tests offline para EnvironmentClassifier — Fase A (smart-scene).
///
/// Valida la histéresis QUIET con banda muerta de 5 dB y la memoria de
/// voz reciente que bloquea bajadas espurias a QUIET durante una pausa
/// natural del habla.
///
/// Compila en host (MSVC, gcc, clang). Independiente del NDK.
///
/// Cómo compilar (desde esta carpeta) con MSVC:
///   cl /nologo /std:c++17 /EHsc /O2 /I.. test_environment_classifier.cpp ^
///       ..\environment_classifier.cpp /Fe:test_env.exe
///   .\test_env.exe

#include <cstdio>
#include <functional>
#include <string>
#include <vector>

#include "../environment_classifier.h"

namespace {

const char* className(EnvironmentClass c) {
    switch (c) {
        case EnvironmentClass::QUIET:           return "QUIET";
        case EnvironmentClass::SPEECH:          return "SPEECH";
        case EnvironmentClass::SPEECH_IN_NOISE: return "SPEECH_IN_NOISE";
        case EnvironmentClass::NOISE:           return "NOISE";
    }
    return "??";
}

struct Stim {
    float levelDb;
    float snrDb;
    bool  vad;
};

// Corre `n` bloques con el mismo estímulo y devuelve la clase final.
EnvironmentClass runSteady(EnvironmentClassifier& clf,
                           const Stim& stim,
                           int n) {
    EnvironmentClass last = EnvironmentClass::QUIET;
    for (int i = 0; i < n; ++i) {
        last = clf.update(stim.levelDb, stim.snrDb, stim.vad);
    }
    return last;
}

// Cuenta cuántas veces transita la clase a lo largo de una secuencia
// de estímulos (uno por bloque).
int countTransitions(EnvironmentClassifier& clf,
                     const std::vector<Stim>& seq) {
    int trans = 0;
    EnvironmentClass prev = static_cast<EnvironmentClass>(clf.getCurrentClass());
    for (const auto& s : seq) {
        EnvironmentClass cur = clf.update(s.levelDb, s.snrDb, s.vad);
        if (cur != prev) {
            ++trans;
            prev = cur;
        }
    }
    return trans;
}

bool expectClass(const char* tag,
                 EnvironmentClass got,
                 EnvironmentClass want) {
    const bool ok = got == want;
    std::printf("  [%s] got=%-15s want=%-15s %s\n",
                tag, className(got), className(want),
                ok ? "PASS" : "FAIL");
    return ok;
}

bool expectInt(const char* tag, int got, int min, int max) {
    const bool ok = got >= min && got <= max;
    std::printf("  [%s] got=%d expected [%d, %d] %s\n",
                tag, got, min, max, ok ? "PASS" : "FAIL");
    return ok;
}

} // namespace

int main() {
    int passed = 0;
    int total  = 0;

    auto run = [&](const char* name, std::function<bool()> fn) {
        std::printf("\n=== %s ===\n", name);
        const bool ok = fn();
        if (ok) ++passed;
        ++total;
    };

    // T1 — convergencia inicial al silencio absoluto (level=20, snr=0)
    run("T1 silencio absoluto", []() {
        EnvironmentClassifier clf;
        EnvironmentClass last = runSteady(clf, {20.0f, 0.0f, false}, 200);
        return expectClass("final", last, EnvironmentClass::QUIET);
    });

    // T2 — voz limpia 65 dB SPL, SNR 12 dB → SPEECH
    // 1500 bloques = 6 s — supera el hold de 5 s del clasificador para
    // permitir la transición desde NOISE (estado intermedio mientras el
    // EMA de level converge).
    run("T2 voz limpia 65 dB / SNR 12 dB", []() {
        EnvironmentClassifier clf;
        EnvironmentClass last = runSteady(clf, {65.0f, 12.0f, true}, 1500);
        return expectClass("final", last, EnvironmentClass::SPEECH);
    });

    // T3 — ruido fuerte 75 dB SPL, SNR 0 dB → NOISE
    // 1500 bloques para superar el hold y converger.
    run("T3 ruido 75 dB / SNR 0 dB", []() {
        EnvironmentClassifier clf;
        EnvironmentClass last = runSteady(clf, {75.0f, 0.0f, false}, 1500);
        return expectClass("final", last, EnvironmentClass::NOISE);
    });

    // T4 — histéresis QUIET: nivel oscilando entre 45 y 47 dB SPL, sin
    // VAD. ANTES de Fase A: oscilaba QUIET↔SPEECH. AHORA con la banda
    // muerta 44/49, una vez en QUIET solo sale si pasa de 49.
    run("T4 hysteresis QUIET 45..47 dB sin VAD", []() {
        EnvironmentClassifier clf;
        // Primero asentamos en QUIET con level bajo.
        runSteady(clf, {30.0f, 0.0f, false}, 200);
        // Ahora oscilamos 45 ↔ 47 dB durante 2000 bloques (~8 s).
        std::vector<Stim> seq;
        for (int i = 0; i < 2000; ++i) {
            seq.push_back({(i % 2 == 0) ? 45.0f : 47.0f, 5.0f, false});
        }
        const int trans = countTransitions(clf, seq);
        const bool ok = expectInt("transiciones", trans, 0, 0);
        EnvironmentClass last = static_cast<EnvironmentClass>(
            clf.getCurrentClass());
        return ok && expectClass("final", last, EnvironmentClass::QUIET);
    });

    // T5 — memoria de voz: hablamos 5 s (level 65, snr 10, vad true),
    // pausa 0.5 s (level 35, snr 0, vad false), sigue voz 5 s. La
    // memoria de voz debe IMPEDIR que el clasificador pase a QUIET en
    // la pausa corta. ANTES de Fase A: la pausa generaba QUIET → 2
    // transiciones. AHORA: 0 transiciones (queda en SPEECH).
    run("T5 memoria de voz - pausa 0.5 s no debe disparar QUIET", []() {
        EnvironmentClassifier clf;
        // Voz inicial 5 s para llegar a SPEECH y pasar el hold inicial.
        for (int i = 0; i < 1300; ++i) clf.update(65.0f, 10.0f, true);
        EnvironmentClass beforePause = static_cast<EnvironmentClass>(
            clf.getCurrentClass());
        std::printf("  estado pre-pausa: %s\n", className(beforePause));
        bool ok = expectClass("pre-pausa", beforePause,
                              EnvironmentClass::SPEECH);

        // Pausa 0.5 s = 125 bloques (a 4 ms/bloque). Sin VAD, level cae
        // a 35 dB SPL → en TEORÍA podría disparar QUIET sin la memoria.
        int transDuringPause = 0;
        EnvironmentClass prev = beforePause;
        for (int i = 0; i < 125; ++i) {
            EnvironmentClass c = clf.update(35.0f, 0.0f, false);
            if (c != prev) { ++transDuringPause; prev = c; }
        }
        ok = ok && expectInt("transiciones en pausa", transDuringPause, 0, 0);

        // Vuelve la voz por 2 s.
        for (int i = 0; i < 500; ++i) clf.update(65.0f, 10.0f, true);
        EnvironmentClass afterVoice = static_cast<EnvironmentClass>(
            clf.getCurrentClass());
        ok = ok && expectClass("post-voz", afterVoice,
                               EnvironmentClass::SPEECH);
        return ok;
    });

    // T6 — pausa larga (3 s) SIN VAD: la memoria de voz se agota
    // (kVoiceMemoryBlocks=375 ≈ 1.5 s) y el clasificador SÍ debe
    // poder bajar a QUIET. Caso esperado clínicamente.
    run("T6 pausa larga 3 s SIN VAD - SI debe permitir QUIET", []() {
        EnvironmentClassifier clf;
        // Llegar a SPEECH.
        for (int i = 0; i < 1300; ++i) clf.update(65.0f, 10.0f, true);
        // Pausa larga: 3 s @ 4 ms = 750 bloques + más allá del hold (1250).
        for (int i = 0; i < 1500; ++i) clf.update(30.0f, 0.0f, false);
        EnvironmentClass last = static_cast<EnvironmentClass>(
            clf.getCurrentClass());
        return expectClass("final", last, EnvironmentClass::QUIET);
    });

    // T7 — voz muy fuerte 85 dB SPL con VAD activo: NO debe caer en
    // NOISE (gracias al techo elevado a 88 con VAD). Antes (techo
    // fijo 80), level 85 → NOISE.
    run("T7 voz fuerte 85 dB con VAD - debe ser SPEECH", []() {
        EnvironmentClassifier clf;
        EnvironmentClass last = runSteady(clf,
            {85.0f, 12.0f, /*vad=*/true}, 1500);
        return expectClass("final", last, EnvironmentClass::SPEECH);
    });

    std::printf("\n========================================\n");
    std::printf("  TOTAL: %d/%d tests pasados\n", passed, total);
    std::printf("========================================\n");
    return (passed == total) ? 0 : 1;
}

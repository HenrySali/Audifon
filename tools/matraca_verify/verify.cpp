// @file verify.cpp
// @brief Verificacion ejecutable de los fixes anti-matraca (Causa A: gate del
//        GTCRN; Causa B: scale anti-saturacion del EQ).
//
// Usa el DETECTOR REAL (artifact_monitor.h del pipeline, sin copiar) y
// reproduce el mecanismo exacto de cada bug: mide clicks/s ANTES (logica
// vieja) y DESPUES (logica nueva) sobre senal sintetica que dispara el
// artefacto. No es el build de Android; es una prueba aislada y determinista
// del origen del click y de que la rampa per-sample lo elimina.
//
// Compilar y correr:
//   g++ -std=c++17 -O2 -I../../android/app/src/main/cpp verify.cpp -o verify
//   ./verify

#include "artifact_monitor.h"

#include <cmath>
#include <cstdio>
#include <vector>
#include <algorithm>

namespace {

constexpr int   kSr        = 16000;  // GTCRN corre a 16 kHz
constexpr int   kHop       = 160;    // kDnnHopSize
constexpr float kGateOpen  = 0.01f;
constexpr float kGateClose = 0.001f;
constexpr int   kHystFrames = 6;
constexpr float kPi        = 3.14159265358979323846f;

float hopRms(const float* x, int n) {
    double s = 0.0;
    for (int i = 0; i < n; ++i) s += double(x[i]) * x[i];
    return std::sqrt(float(s / n));
}

// ─────────────────────────────────────────────────────────────────────────
// CAUSA A — Noise gate del GTCRN.
// Genera hops alternando voz (tono) y silencio para forzar ciclos de
// apertura/cierre del gate. El artefacto aparece cuando el gate RAMPEA su
// ganancia mientras hay senal presente (arranque de voz tras silencio).
// ─────────────────────────────────────────────────────────────────────────
struct GateResult { ArtifactSnapshot snap; };

// applyRamp=false -> logica VIEJA (gain constante por hop, cierra a 0.0)
// applyRamp=true  -> logica NUEVA (rampa per-sample + piso 0.05)
GateResult runGate(bool applyRamp, double seconds) {
    ArtifactMonitor mon;
    mon.configure(kSr);

    const float kFloor = applyRamp ? 0.05f : 0.0f;
    float gateGain = 1.0f;
    float gateApplied = 1.0f;   // solo usado por la rampa nueva
    int   gateHold = 0;

    const int totalHops = int(seconds * kSr / kHop);
    std::vector<float> hop(kHop);
    long long n = 0;

    for (int h = 0; h < totalHops; ++h) {
        // Patron: 0.40 s de voz + 0.30 s de silencio (ciclo 0.70 s).
        const double tsec = double(h) * kHop / kSr;
        const double phase = std::fmod(tsec, 0.70);
        const bool voiced = phase < 0.40;

        for (int i = 0; i < kHop; ++i) {
            if (voiced) {
                // Tono 220 Hz (F0 masculino) amplitud 0.30 -> rms ~0.21 > open.
                hop[i] = 0.30f * std::sin(2.0f * kPi * 220.0f * float(n) / kSr);
            } else {
                hop[i] = 0.0f;
            }
            ++n;
        }

        // ── Actualizacion del gate (identica al codigo del pipeline) ──
        const float rms = hopRms(hop.data(), kHop);
        if (rms >= kGateOpen) {
            gateHold = 0;
            gateGain = std::min(1.0f, gateGain + 0.33f);
        } else if (rms < kGateClose) {
            gateHold++;
            if (gateHold >= kHystFrames) {
                gateGain = std::max(kFloor, gateGain - 0.25f);
            }
        } else {
            gateHold = 0;
            float knee = std::max(kFloor, (rms - kGateClose) / (kGateOpen - kGateClose));
            const float step = 0.2f;
            if (gateGain < knee) gateGain = std::min(knee, gateGain + step);
            else                 gateGain = std::max(knee, gateGain - step);
        }

        // ── Aplicacion de la ganancia ──
        if (applyRamp) {
            // NUEVA: rampa per-sample gateApplied -> gateGain (continuidad C0).
            const float gS = gateApplied, gE = gateGain;
            if (gS < 0.999f || gE < 0.999f) {
                const float invN = 1.0f / kHop;
                for (int i = 0; i < kHop; ++i) {
                    const float t = float(i + 1) * invN;
                    hop[i] *= gS + (gE - gS) * t;
                }
            }
            gateApplied = gE;
        } else {
            // VIEJA: gain constante en todo el hop (escalon en la frontera).
            if (gateGain < 0.999f) {
                for (int i = 0; i < kHop; ++i) hop[i] *= gateGain;
            }
        }

        mon.feed(hop.data(), kHop);
    }
    return { mon.snapshot() };
}

// ─────────────────────────────────────────────────────────────────────────
// CAUSA B — scale anti-saturacion del EQ.
// El pipeline recomputa 'scale' cada bloque desde el pico del bloque. Con
// una envolvente fluctuante, el factor salta bloque a bloque. La senal
// post-EQ (ya amplificada) se multiplica por ese factor.
// ─────────────────────────────────────────────────────────────────────────
constexpr int   kBlock     = 128;
constexpr float kMaxEqGain = 22.0f;   // prescripcion alta -> scale activo
constexpr float kCeiling   = 0.7f;

float computeEqScale(float peakNow) {
    if (kMaxEqGain <= 6.0f) return 1.0f;
    const float estPeak = peakNow * std::pow(10.0f, kMaxEqGain / 20.0f);
    if (estPeak > kCeiling && peakNow > 1e-6f) {
        float s = kCeiling / estPeak;
        if (s < 0.2f) s = 0.2f;
        return s;
    }
    return 1.0f;
}

GateResult runEqScale(bool applyRamp, double seconds) {
    ArtifactMonitor mon;
    mon.configure(kSr);

    const float eqLin = std::pow(10.0f, kMaxEqGain / 20.0f); // amplificacion EQ
    // Envelope detector del scale (identico al fix: attack 2 ms / release 50 ms).
    float scaleSmoothed = 1.0f;
    const float atkS = 2.0f  * kSr / 1000.0f;
    const float relS = 50.0f * kSr / 1000.0f;
    const float atkC = 1.0f - std::exp(-1.0f / atkS);
    const float relC = 1.0f - std::exp(-1.0f / relS);
    const int totalBlocks = int(seconds * kSr / kBlock);
    std::vector<float> blk(kBlock);
    std::vector<float> pre(kBlock);
    long long n = 0;

    for (int b = 0; b < totalBlocks; ++b) {
        // Senal pre-EQ realista: VOCAL sostenida (tono 300 Hz, amplitud baja
        // 0.05, CONTINUA entre bloques) + PLOSIVA esporadica (transitorio
        // fuerte a mitad de bloque cada 5 bloques). La plosiva eleva el pico
        // SOLO de ese bloque -> el eqScale cae de golpe ese bloque y vuelve al
        // siguiente. La vocal continua recibe scales distintos a cada lado de
        // la frontera -> escalon = click (mecanismo real del bug).
        const bool hasTransient = (b % 5 == 2);
        float peakNow = 0.0f;
        for (int i = 0; i < kBlock; ++i) {
            float s = 0.05f * std::sin(2.0f * kPi * 300.0f * float(n) / kSr); // vocal
            // Transitorio SUAVE (bump raised-cosine, no es click por si mismo)
            // a mitad de bloque: eleva el pico del bloque -> baja el eqScale de
            // ESE bloque, aislando el efecto del escalon de scale en la frontera.
            const int c = kBlock / 2, w = 12;
            if (hasTransient && i >= c - w && i <= c + w) {
                const float u = float(i - (c - w)) / float(2 * w); // 0..1
                const float bump = 0.5f * (1.0f - std::cos(2.0f * kPi * u)); // Hann
                s += 0.15f * bump;
            }
            pre[i] = s;
            peakNow = std::max(peakNow, std::fabs(s));
            ++n;
        }
        const float scale = computeEqScale(peakNow);

        // Senal post-EQ (amplificada) que recibe el scale.
        for (int i = 0; i < kBlock; ++i) blk[i] = pre[i] * eqLin;

        if (applyRamp) {
            // NUEVA: envelope detector per-sample (attack rapido/release lento),
            // continuidad C0 entre bloques y proteccion del transitorio.
            for (int i = 0; i < kBlock; ++i) {
                const float c = (scale < scaleSmoothed) ? atkC : relC;
                scaleSmoothed += c * (scale - scaleSmoothed);
                blk[i] *= scaleSmoothed;
            }
        } else {
            // VIEJA: scale constante por bloque (escalon en la frontera).
            for (int i = 0; i < kBlock; ++i) blk[i] *= scale;
        }

        mon.feed(blk.data(), kBlock);
    }
    return { mon.snapshot() };
}

// ─────────────────────────────────────────────────────────────────────────
// CADENA motor→EQ: demuestra que los clicks del gate (Causa A) se PROPAGAN y
// MULTIPLICAN aguas abajo. Un impulso que entra a un biquad IIR amplificador
// (EQ de prescripcion) genera ringing → varios clicks de salida. Por eso el
// registro mostraba MAS clicks en la SALIDA FINAL que en la salida del motor.
// Arreglar el gate en el ORIGEN reduce tambien los clicks finales.
// ─────────────────────────────────────────────────────────────────────────
struct Biquad {
    float b0, b1, b2, a1, a2;
    float x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    float step(float x) {
        float y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1; x1 = x; y2 = y1; y1 = y;
        return y;
    }
};

Biquad makePeaking(float freq, float gainDb, float q) {
    Biquad c;
    const float A = std::pow(10.0f, gainDb / 40.0f);
    const float w0 = 2.0f * kPi * freq / kSr;
    const float cw = std::cos(w0), sw = std::sin(w0);
    const float alpha = sw / (2.0f * q);
    const float a0 = 1.0f + alpha / A;
    c.b0 = (1.0f + alpha * A) / a0;
    c.b1 = (-2.0f * cw) / a0;
    c.b2 = (1.0f - alpha * A) / a0;
    c.a1 = (-2.0f * cw) / a0;
    c.a2 = (1.0f - alpha / A) / a0;
    return c;
}

ArtifactSnapshot runChain(bool gateRamp, double seconds) {
    ArtifactMonitor mon;
    mon.configure(kSr);

    const float kFloor = gateRamp ? 0.05f : 0.0f;
    float gateGain = 1.0f, gateApplied = 1.0f;
    int gateHold = 0;
    // EQ de prescripcion: +18 dB @ 2 kHz (biquad peaking, resuena con impulsos).
    Biquad eq = makePeaking(2000.0f, 18.0f, 2.0f);

    const int totalHops = int(seconds * kSr / kHop);
    std::vector<float> hop(kHop);
    long long n = 0;

    for (int h = 0; h < totalHops; ++h) {
        const double tsec = double(h) * kHop / kSr;
        const bool voiced = std::fmod(tsec, 0.70) < 0.40;
        for (int i = 0; i < kHop; ++i) {
            hop[i] = voiced ? 0.30f * std::sin(2.0f * kPi * 220.0f * float(n) / kSr) : 0.0f;
            ++n;
        }
        const float rms = hopRms(hop.data(), kHop);
        if (rms >= kGateOpen) { gateHold = 0; gateGain = std::min(1.0f, gateGain + 0.33f); }
        else if (rms < kGateClose) { if (++gateHold >= kHystFrames) gateGain = std::max(kFloor, gateGain - 0.25f); }
        else {
            gateHold = 0;
            float knee = std::max(kFloor, (rms - kGateClose) / (kGateOpen - kGateClose));
            if (gateGain < knee) gateGain = std::min(knee, gateGain + 0.2f);
            else gateGain = std::max(knee, gateGain - 0.2f);
        }
        if (gateRamp) {
            const float gS = gateApplied, gE = gateGain;
            if (gS < 0.999f || gE < 0.999f) {
                const float invN = 1.0f / kHop;
                for (int i = 0; i < kHop; ++i) hop[i] *= gS + (gE - gS) * (float(i + 1) * invN);
            }
            gateApplied = gE;
        } else {
            if (gateGain < 0.999f) for (int i = 0; i < kHop; ++i) hop[i] *= gateGain;
        }
        // Aguas abajo: EQ amplificador (propaga/multiplica impulsos del gate).
        for (int i = 0; i < kHop; ++i) hop[i] = eq.step(hop[i]);
        mon.feed(hop.data(), kHop);
    }
    return mon.snapshot();
}

void report(const char* title, const ArtifactSnapshot& before,
            const ArtifactSnapshot& after) {
    std::printf("\n=== %s ===\n", title);
    std::printf("  %-8s | clicks | clicks/s | maxJump | calidad\n", "version");
    std::printf("  %-8s | %6llu | %8.2f | %7.3f | %5.0f/100\n", "ANTES",
                (unsigned long long)before.clickCount, before.clicksPerSec,
                before.maxAbsJump, before.sessionQuality);
    std::printf("  %-8s | %6llu | %8.2f | %7.3f | %5.0f/100\n", "DESPUES",
                (unsigned long long)after.clickCount, after.clicksPerSec,
                after.maxAbsJump, after.sessionQuality);
    const double red = before.clicksPerSec > 1e-9
        ? 100.0 * (1.0 - after.clicksPerSec / before.clicksPerSec) : 0.0;
    std::printf("  -> reduccion de matraca: %.1f%%\n", red);
}

} // namespace

int main() {
    const double dur = 91.6; // misma duracion que el registro reportado

    std::printf("Verificacion anti-matraca (detector real artifact_monitor.h)\n");
    std::printf("Senal sintetica, %.1f s @ %d Hz\n", dur, kSr);

    auto gaBefore = runGate(false, dur);
    auto gaAfter  = runGate(true,  dur);
    report("CAUSA A - Noise gate GTCRN (per-hop -> per-sample + floor)",
           gaBefore.snap, gaAfter.snap);

    auto ebBefore = runEqScale(false, dur);
    auto ebAfter  = runEqScale(true,  dur);
    report("CAUSA B - EQ anti-saturacion scale (per-block -> per-sample)",
           ebBefore.snap, ebAfter.snap);

    auto chBefore = runChain(false, dur);
    auto chAfter  = runChain(true,  dur);
    report("CADENA motor->EQ (clicks del gate propagados aguas abajo)",
           chBefore, chAfter);

    // Criterio de exito: el fix del gate (Causa A) elimina los clicks del motor
    // Y reduce los clicks propagados aguas abajo (cadena). El fix del EQ no debe
    // empeorar nada (Causa B: no introduce regresion).
    const bool ok =
        gaAfter.snap.clicksPerSec < 0.1 * std::max(0.01, gaBefore.snap.clicksPerSec) &&
        chAfter.clicksPerSec      < 0.5 * std::max(0.01, chBefore.clicksPerSec) &&
        ebAfter.snap.clicksPerSec <= std::max(0.02, ebBefore.snap.clicksPerSec);
    std::printf("\nRESULTADO: %s\n", ok ? "PASS (matraca eliminada)"
                                        : "FAIL (revisar)");
    return ok ? 0 : 1;
}

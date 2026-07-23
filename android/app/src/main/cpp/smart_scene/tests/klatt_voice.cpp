/// @file klatt_voice.cpp
/// @brief Sintetizador de voz tipo formante paralelo (Klatt-simplificado).
///
/// Estructura:
///   excitación glotal (pulsos triangulares + jitter + vibrato)
///       │
///       ├─→ BP F1 ─┐
///       ├─→ BP F2 ─┤
///       ├─→ BP F3 ─┤  ← suma con pesos por formante
///       ├─→ BP F4 ─┤
///       └─→ BP F5 ─┘
///       │
///       + aspiración (ruido) escalada por aspirAmp_
///
/// Cada BP es un biquad cookbook RBJ con Q = fc/bw, ganancia pico
/// unitaria. Los pesos por formante (1.0, 0.6, 0.4, 0.25, 0.15)
/// reproducen el tilt natural de -12 dB/oct de voz humana real.
///
/// Esto NO es Klatt 1980 pleno — es la "versión paralela" descrita
/// en el mismo paper, computacionalmente estable y suficiente para
/// que el VAD vea la estructura espectral correcta de voz.

#include "klatt_voice.h"

#include <algorithm>
#include <cmath>

namespace smart_scene {
namespace klatt {

namespace {
constexpr float kPi    = 3.14159265358979323846f;
constexpr float kTwoPi = 6.28318530717958647692f;

/// Tablas de formantes (Hz) y anchos de banda (Hz) por vocal.
/// Valores parafraseados de Peterson & Barney 1952 (rango adulto medio).
struct VowelFormants {
    float f[5];
    float bw[5];
};

const VowelFormants kVowelTable[5] = {
    // /a/
    { { 730.0f, 1090.0f, 2440.0f, 3400.0f, 4400.0f },
      {  80.0f,  100.0f,  120.0f,  175.0f,  225.0f } },
    // /e/
    { { 530.0f, 1840.0f, 2480.0f, 3400.0f, 4400.0f },
      {  60.0f,  100.0f,  120.0f,  175.0f,  225.0f } },
    // /i/
    { { 270.0f, 2290.0f, 3010.0f, 3700.0f, 4400.0f },
      {  60.0f,   90.0f,  100.0f,  175.0f,  225.0f } },
    // /o/
    { { 570.0f,  840.0f, 2410.0f, 3400.0f, 4400.0f },
      {  60.0f,   80.0f,  120.0f,  175.0f,  225.0f } },
    // /u/
    { { 300.0f,  870.0f, 2240.0f, 3400.0f, 4400.0f },
      {  60.0f,   80.0f,  120.0f,  175.0f,  225.0f } },
};

/// Pesos relativos por formante (tilt natural ≈ -12 dB/oct).
constexpr float kFormantWeight[5] = { 1.0f, 0.60f, 0.40f, 0.25f, 0.15f };

/// dB SPL → amplitud lineal. splOffset = 120 (mismo que SceneAnalyzer
/// en modo realtime). Así: dbSpl=65 → -55 dBFS → amp ≈ 0.00178.
inline float dbSplToAmp(float dbSpl, float splOffset = 120.0f) {
    const float dbFs = dbSpl - splOffset;
    return std::pow(10.0f, dbFs / 20.0f);
}

} // namespace

// ─────────────────────────────────────────────────────────────────────────────

KlattVoice::KlattVoice() = default;

void KlattVoice::init(int sampleRate, Vowel vowel, float f0Hz, float dbSpl) {
    sampleRate_   = static_cast<float>(sampleRate > 0 ? sampleRate : 48000);
    f0_           = f0Hz;
    f0Target_     = f0Hz;
    phase_        = 0.0f;
    vibratoPhase_ = 0.0f;
    jitterRand_   = 0.0f;
    t_            = 0.0f;
    amp_          = dbSplToAmp(dbSpl);
    ampTarget_    = amp_;

    if (dbSpl < 55.0f)      aspirAmp_ = 0.30f;
    else if (dbSpl < 70.0f) aspirAmp_ = 0.15f;
    else                    aspirAmp_ = 0.05f;

    float fInit[5], bwInit[5];
    loadVowelFormants(vowel, fInit, bwInit);
    for (int i = 0; i < 5; ++i) {
        formants_[i].fHz        = fInit[i];
        formants_[i].bwHz       = bwInit[i];
        formants_[i].fHzTarget  = fInit[i];
        formants_[i].bwHzTarget = bwInit[i];
        formants_[i].xz1 = 0.0f;
        formants_[i].xz2 = 0.0f;
        formants_[i].yz1 = 0.0f;
        formants_[i].yz2 = 0.0f;
        recomputeFormantCoeffs(formants_[i]);
    }
}

void KlattVoice::setVowel(Vowel vowel) {
    float fT[5], bwT[5];
    loadVowelFormants(vowel, fT, bwT);
    for (int i = 0; i < 5; ++i) {
        formants_[i].fHzTarget  = fT[i];
        formants_[i].bwHzTarget = bwT[i];
    }
}

void KlattVoice::setF0(float f0Hz)    { f0Target_  = f0Hz; }
void KlattVoice::setLevel(float dbSpl) { ampTarget_ = dbSplToAmp(dbSpl); }

// ─────────────────────────────────────────────────────────────────────────────

void KlattVoice::loadVowelFormants(Vowel v, float fOut[5], float bwOut[5]) {
    const int idx = std::clamp(static_cast<int>(v), 0, 4);
    const VowelFormants& vf = kVowelTable[idx];
    for (int i = 0; i < 5; ++i) {
        fOut[i]  = vf.f[i];
        bwOut[i] = vf.bw[i];
    }
}

void KlattVoice::recomputeFormantCoeffs(Resonator& r) {
    // Biquad bandpass cookbook RBJ (Audio EQ Cookbook):
    //   ω0 = 2π·f/fs
    //   α  = sin(ω0)/(2·Q),   Q = f/bw
    //   b0 =  α / a0
    //   b1 =  0
    //   b2 = -α / a0
    //   a1 = -2·cos(ω0) / a0
    //   a2 = (1-α) / a0
    //   a0 =  1 + α
    // Ganancia pico = 1 (constant peak gain BPF).
    //
    // Almacenamos forma directa I:
    //   y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] - a1·y[n-1] - a2·y[n-2]
    //
    // El struct sólo guarda b0, a1, a2 + estados z1, z2. Para una BPF
    // con b1=0 y b2=-b0, podemos usar la identidad
    //   y[n] = b0·(x[n] - x[n-2]) - a1·y[n-1] - a2·y[n-2]
    // pero necesitamos x[n-2]. Vamos a almacenar también xz1, xz2:
    // amplío el struct usando z1=x[n-1], z2=x[n-2] como historia del
    // input, y mantengo la salida vía dos campos extra en el sample loop.
    // Para no romper el header, dejamos los coeficientes solamente y
    // hacemos la forma directa II transposed dentro del filtro paralelo:
    //
    // Usamos forma directa II transposed (la más estable numéricamente):
    //   y[n]   = b0·x[n] + s1
    //   s1[n+1] = b1·x[n] + s2 - a1·y[n]
    //   s2[n+1] = b2·x[n]      - a2·y[n]
    // Aquí z1 = s1, z2 = s2.
    //
    // Para BPF: b1=0, b2=-b0.
    const float fs = sampleRate_;
    const float Q  = std::max(0.5f, r.fHz / std::max(1.0f, r.bwHz));
    const float w0 = kTwoPi * r.fHz / fs;
    const float cw = std::cos(w0);
    const float sw = std::sin(w0);
    const float alpha = sw / (2.0f * Q);
    const float a0 = 1.0f + alpha;
    r.b0 =  alpha / a0;
    r.a1 = -2.0f * cw / a0;
    r.a2 = (1.0f - alpha) / a0;
}

float KlattVoice::frand() {
    noiseRng_ ^= noiseRng_ << 13;
    noiseRng_ ^= noiseRng_ >> 17;
    noiseRng_ ^= noiseRng_ << 5;
    const uint32_t bits = noiseRng_;
    return (static_cast<float>(bits) / 2147483648.0f) - 1.0f;
}

void KlattVoice::interpolateTowardsTargets() {
    const float aF0   = 0.0005f;
    const float aAmp  = 0.0010f;
    const float aForm = 0.0008f;

    f0_  += (f0Target_  - f0_)  * aF0;
    amp_ += (ampTarget_ - amp_) * aAmp;

    bool needRecompute[5] = {false, false, false, false, false};
    for (int i = 0; i < 5; ++i) {
        const float dF  = (formants_[i].fHzTarget  - formants_[i].fHz)  * aForm;
        const float dBw = (formants_[i].bwHzTarget - formants_[i].bwHz) * aForm;
        if (std::abs(dF) > 0.001f || std::abs(dBw) > 0.001f) {
            formants_[i].fHz  += dF;
            formants_[i].bwHz += dBw;
            needRecompute[i] = true;
        }
    }
    for (int i = 0; i < 5; ++i) {
        if (needRecompute[i]) recomputeFormantCoeffs(formants_[i]);
    }
}

void KlattVoice::generate(float* out, int n) {
    if (out == nullptr || n <= 0) return;

    const float dt = 1.0f / sampleRate_;
    for (int i = 0; i < n; ++i) {
        if ((i & 31) == 0) interpolateTowardsTargets();

        // Vibrato + jitter sobre F0
        vibratoPhase_ += kTwoPi * 5.0f * dt;
        if (vibratoPhase_ > kTwoPi) vibratoPhase_ -= kTwoPi;
        const float vibrato = 1.0f + 0.02f * std::sin(vibratoPhase_);
        if ((i % 480) == 0) jitterRand_ = 0.015f * frand();
        const float f0Inst = f0_ * vibrato * (1.0f + jitterRand_);

        // Pulso glotal triangular asimétrico (apertura 70 %, cierre 30 %).
        // Tiene componentes hasta ~5 F0, decayendo ~ -12 dB/oct.
        phase_ += kTwoPi * f0Inst * dt;
        while (phase_ >= kTwoPi) phase_ -= kTwoPi;
        const float openFrac = 0.7f;
        const float p = phase_ / kTwoPi;
        float glottal;
        if (p < openFrac) {
            glottal = 2.0f * (p / openFrac) - 1.0f;
        } else {
            glottal = 1.0f - 2.0f * (p - openFrac) / (1.0f - openFrac);
        }

        // Fuente: pulso glotal + aspiración.
        const float src = glottal * (1.0f - aspirAmp_) + aspirAmp_ * frand();

        // Filtros formantes en PARALELO (suma ponderada).
        // BPF cookbook RBJ Direct Form I:
        //   y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2]
        //                  - a1*y[n-1] - a2*y[n-2]
        // Para BPF: b1 = 0, b2 = -b0.
        float voiced = 0.0f;
        for (int k = 0; k < 5; ++k) {
            Resonator& r = formants_[k];
            const float y = r.b0 * src
                          + (-r.b0) * r.xz2
                          - r.a1 * r.yz1
                          - r.a2 * r.yz2;
            r.xz2 = r.xz1;
            r.xz1 = src;
            r.yz2 = r.yz1;
            r.yz1 = y;
            voiced += kFormantWeight[k] * y;
        }

        // Modulación silábica lenta (~4 Hz, ±20 %) y nivel objetivo.
        const float syll = 1.0f + 0.20f * std::sin(kTwoPi * 4.0f * t_);
        out[i] = amp_ * syll * voiced;
        t_ += dt;
    }
}

} // namespace klatt
} // namespace smart_scene

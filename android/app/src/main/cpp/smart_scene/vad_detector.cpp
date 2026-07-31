/// @file vad_detector.cpp
/// @brief Implementación del VAD híbrido robusto.
///
/// Ver vad_detector.h y Amplificador/.kiro/specs/smart-scene-engine/vad-redesign.md
/// para la justificación de cada feature, los pesos y los gates.
///
/// Validates: Requirements 2.1, 2.2, 2.3.

#include "vad_detector.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace smart_scene {

// ─────────────────────────────────────────────────────────────────────────────
// Construcción / init
// ─────────────────────────────────────────────────────────────────────────────

VadDetector::VadDetector() = default;

void VadDetector::init(int sampleRate) {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000;
    // lag = sampleRate / pitch  →  lag más grande = pitch más bajo.
    minLag_ = static_cast<int>(static_cast<float>(sampleRate_) / kPitchMaxHz);
    maxLag_ = static_cast<int>(static_cast<float>(sampleRate_) / kPitchMinHz);
    if (minLag_ < 1) minLag_ = 1;
    // Garantizar que el buffer es suficiente para la ventana de pitch.
    if (maxLag_ >= kPitchBufferSize - 32) {
        maxLag_ = kPitchBufferSize - 32;
    }
    reset();
}

void VadDetector::reset() {
    samplesAccumulated_ = 0;
    hpfXPrev_           = 0.0f;
    hpfYPrev_           = 0.0f;
    std::fill(pitchBuffer_, pitchBuffer_ + kPitchBufferSize, 0.0f);

    for (int b = 0; b < kSceneNumBands; ++b) {
        xiPrev_[b] = 0.0f;
        for (int i = 0; i < kLtsdWindow; ++i) ltsdHistory_[i][b] = -90.0f;
        for (int i = 0; i < kStatWindow; ++i) statHistory_[i][b] = -90.0f;
    }
    ltsdIdx_ = 0;
    ltsdFill_ = 0;
    statIdx_ = 0;
    statFill_ = 0;

    smoothedScore_  = 0.0f;
    pitchStrength_  = 0.0f;
    lrtScore_       = 0.0f;
    midSnrDb_       = 0.0f;
    ltsdDb_         = 0.0f;
    stationarity_   = 0.0f;
    hangover_       = 0;
    voiceActive_    = false;
    hangoverActive_ = false;
    impulseHoldoff_ = 0;
    onsetSustain_   = 0;
    voicingSustain_ = 0;
    prevEnergyDb_   = -90.0f;
    flatnessHighStreak_ = 0;
    zcrRatio_           = 0.0f;
    centroidEma_        = 0.0f;
    pitchDensity_       = 0.0f;
    pitchHistIdx_       = 0;
    pitchHistFill_      = 0;
    std::memset(pitchHistory_, 0, sizeof(pitchHistory_));
}

// ─────────────────────────────────────────────────────────────────────────────
// Pipeline principal
// ─────────────────────────────────────────────────────────────────────────────

void VadDetector::process(const float* samples,
                          int numSamples,
                          const float bandEnergyDb[kSceneNumBands],
                          const float noiseFloorDb[kSceneNumBands],
                          float flatness,
                          float spectralTiltDb,
                          float spectralCentroidHz,
                          float energyDbSpl) {
    if (samples == nullptr || numSamples <= 0 ||
        bandEnergyDb == nullptr || noiseFloorDb == nullptr) {
        return;
    }
    if (!std::isfinite(energyDbSpl)) energyDbSpl = 0.0f;
    if (!std::isfinite(flatness))    flatness    = 1.0f;
    if (!std::isfinite(spectralTiltDb)) spectralTiltDb = 0.0f;
    if (!std::isfinite(spectralCentroidHz) || spectralCentroidHz < 0.0f) {
        spectralCentroidHz = 0.0f;
    }

    // Suavizamos el centroide con EMA. La FFT de 256 puntos sobre ruido
    // pasabandeado da varianza alta del centroide entre frames; un único
    // frame puede caer brevemente al rango vocal por azar y abrir el gate.
    // El EMA reduce esa fuga sin afectar voz real (cuyo centroide es
    // estable en 800-1500 Hz durante toda la fonación).
    if (centroidEma_ <= 0.0f) {
        centroidEma_ = spectralCentroidHz;
    } else {
        centroidEma_ = kCentroidEmaAlpha * spectralCentroidHz +
                       (1.0f - kCentroidEmaAlpha) * centroidEma_;
    }

    // 1) Acumular muestras con HPF para matar DC + hum.
    pushSamplesWithHpf(samples, numSamples);

    // 1b) ZCR sobre el bloque pre-blanqueado (NAIST breath detection).
    //     Aprovechamos los últimos `numSamples` valores ya HPF-eados que
    //     acabamos de empujar al ringbuffer. Los leemos de la cola del
    //     pitchBuffer_ para no recomputar.
    {
        const int n = std::min(numSamples, kPitchBufferSize);
        const int start = kPitchBufferSize - n;
        zcrRatio_ = computeZcr(pitchBuffer_ + start, n);
    }

    // 2) Pitch strength sobre el buffer ya pre-blanqueado.
    pitchStrength_ = (samplesAccumulated_ > maxLag_ + 1)
                         ? computePitchStrength()
                         : 0.0f;
    if (!std::isfinite(pitchStrength_)) pitchStrength_ = 0.0f;
    pitchStrength_ = std::clamp(pitchStrength_, 0.0f, 1.0f);

    // 2b) Densidad de pitch en ventana de ~200 ms (rVAD extended-pitch).
    pitchHistory_[pitchHistIdx_] =
        (pitchStrength_ > kVoicingMinPitch) ? 1u : 0u;
    pitchHistIdx_ = (pitchHistIdx_ + 1) % kPitchDensityWindow;
    if (pitchHistFill_ < kPitchDensityWindow) ++pitchHistFill_;
    {
        int hits = 0;
        for (int i = 0; i < pitchHistFill_; ++i) hits += pitchHistory_[i];
        pitchDensity_ = (pitchHistFill_ > 0)
                            ? static_cast<float>(hits) /
                                  static_cast<float>(pitchHistFill_)
                            : 0.0f;
    }

    // 3) Decision-directed a-priori SNR.
    updateAprioriSnr(bandEnergyDb, noiseFloorDb);

    // 4) LRT promediado en bandas vocales.
    lrtScore_ = computeLrt(bandEnergyDb, noiseFloorDb);

    // 5) Mid-band SNR.
    midSnrDb_ = computeMidSnrDb(bandEnergyDb, noiseFloorDb);

    // 6) LTSD ventana 8 frames.
    pushLtsdHistory(bandEnergyDb);
    ltsdDb_ = computeLtsdDb(noiseFloorDb);

    // 7) Noise stationarity.
    pushStatHistory(bandEnergyDb);
    stationarity_ = computeStationarity();

    // 8) Combinar (todas las features están en escalas comparables tras
    //    su normalización).
    const float lrtNorm  = sigmoid((lrtScore_ - 0.5f) / 1.5f);
    const float msnrNorm = std::clamp((midSnrDb_ - 3.0f) / 12.0f, 0.0f, 1.0f);
    const float ltsdNorm = std::clamp((ltsdDb_ - 8.0f) / 12.0f, 0.0f, 1.0f);
    const float pitchNorm = pitchStrength_;

    // FIX B — Peso dinámico del LRT bajo ruido estacionario con baja density.
    // Cuando el a-priori SNR (xi_prev) está biased por ruido brownish/tráfico,
    // el LRT normalizado sube aunque no haya voz. Si el espectro es estacionario
    // Y la pitch density es baja (sin voz sostenida), el LRT no es confiable:
    // reducimos su peso efectivo.
    // Esto es análogo al paso de flatness post-denoising de rVAD-fast (Tan 2020):
    // bajo ruido brownish post-supresión, la flatness es alta porque no hay
    // formantes; aquí lo proxiamos con stationarity_ + pitchDensity_.
    const bool lrtBiased = (stationarity_  > kLrtStatGateThresh) &&
                           (pitchDensity_  < kLrtPitchDensityGate);
    const float effectiveLrtWeight = lrtBiased
                                         ? (kWeightLrt * kLrtBiasedWeightFactor)
                                         : kWeightLrt;

    float instantaneous = effectiveLrtWeight * lrtNorm
                        + kWeightPitch  * pitchNorm
                        + kWeightMidSnr * msnrNorm
                        + kWeightLtsd   * ltsdNorm;
    instantaneous = std::clamp(instantaneous, 0.0f, 1.0f);

    // 9) EMA suavizado.
    smoothedScore_ = kEmaAlpha * instantaneous +
                     (1.0f - kEmaAlpha) * smoothedScore_;

    // 10) Decisión con gates + histéresis + hangover.
    //
    // Detección de transitorio (golpe, palmada, click): salto > 12 dB
    // venido desde silencio. Bloquea voice_active durante 8 frames para
    // que no lo confunda con voz un VAD "score-only".
    const float energySafe = std::isfinite(energyDbSpl) ? energyDbSpl : -90.0f;
    if (prevEnergyDb_ < kImpulsePrevQuietDb &&
        (energySafe - prevEnergyDb_) > kImpulseRiseDb) {
        impulseHoldoff_ = kImpulseHoldoffFrames;
    }
    if (impulseHoldoff_ > 0) {
        --impulseHoldoff_;
    }
    prevEnergyDb_ = energySafe;

    // Voicing sustain: contador de frames consecutivos con pitch fuerte.
    // Sin pitch sostenido NO puede haber voz humana — bloquea respiración,
    // golpes, tipeo, viento, agua corriendo, todos los transitorios sin
    // estructura tonal estable.
    if (pitchStrength_ > kVoicingMinPitch) {
        if (voicingSustain_ < 1000) ++voicingSustain_;
    } else {
        voicingSustain_ = 0;
    }
    const bool voicingOk = voicingSustain_ >= kVoicingMinFrames;
    (void)pitchDensity_; // disponible vía getPitchDensity() para diagnóstico.

    // Flatness streak: respiración / roce / viento sostenidos dan flatness
    // > 0.65 durante varios frames. Si no hay pitch real, bloqueamos.
    if (flatness > kFlatnessVoiceMax) {
        if (flatnessHighStreak_ < 1000) ++flatnessHighStreak_;
    } else {
        flatnessHighStreak_ = 0;
    }
    const bool flatnessGateBlock =
        (flatnessHighStreak_ >= kFlatnessGateFrames) &&
        (pitchStrength_      <  kVoicingMinPitch);

    // ZCR gate: respiración / fricativas tienen ZCR alta. Sin pitch real
    // y ZCR alta → ruido turbulento, no voz.
    const bool zcrBreathBlock =
        (zcrRatio_      > kZcrUnvoicedRatio) &&
        (pitchStrength_ < kVoicingMinPitch);

    // Tilt gate: voz tiene tilt fuertemente negativo. Respiración / roce
    // tienen tilt cercano a 0 o positivo. Combinado con flatness alta y
    // sin pitch sostenido = ruido aerodinámico.
    const bool tiltGateBlock =
        (spectralTiltDb > kTiltVoiceMaxDbOct) &&
        (flatness        > kTiltGateFlatnessMin) &&
        (pitchStrength_  < kVoicingMinPitch);

    // Centroid gate: ruido pasabandeado en 200-2000 Hz con LPF de 1er
    // orden (proxy de respiración) deja un centroid > 3.5 kHz porque la
    // cola de alta frecuencia no se atenúa lo suficiente. Voz vocal real
    // tiene centroid en 800-1500 Hz (vocales) y < 2.5 kHz incluso con
    // fricativas. Si el centroid suavizado se va arriba del rango vocal
    // y NO hay pitch sostenido, es ruido aerodinámico — bloqueamos.
    // Este gate captura el caso T4/T4b/T4c donde flatness, ZCR y tilt
    // están dentro de rangos "vocales" pero la masa espectral está
    // concentrada fuera de la banda formántica.
    const bool centroidGateBlock =
        (centroidEma_      > kCentroidVoiceMaxHz) &&
        (pitchStrength_    < kVoicingMinPitch);

    // Veto: si hay evidencia clara de voz (LRT alto Y mid-SNR alto) los
    // gates de no-vocal no pueden bloquear. Esto protege la voz natural
    // que momentáneamente arroja flatness alta entre vocal y consonante.
    // PERO el veto exige también que el centroide caiga dentro del rango
    // vocal — sin esa condición, la envolvente del breath proxy a 0.5 Hz
    // levanta midSnr arriba de 6 dB en sus picos y dispara el onset.
    const bool centroidInVocalRange =
        centroidEma_ < kCentroidVoiceMaxHz;
    const bool voiceEvidenceStrong =
        centroidInVocalRange &&
        ((lrtScore_ > 1.0f) || (midSnrDb_ > kNonVocalGateMidSnrDb));
    const bool nonVocalGateBlock =
        !voiceEvidenceStrong &&
        (flatnessGateBlock || zcrBreathBlock || tiltGateBlock ||
         centroidGateBlock);

    if (energyDbSpl < kMinSpeechDbSpl) {
        // Gate 1: silencio absoluto.
        voiceActive_   = false;
        hangover_      = 0;
        hangoverActive_ = false;
        onsetSustain_  = 0;
    } else if (impulseHoldoff_ > 0) {
        // Gate 0: transitorio reciente (golpe / click / palmada).
        // Bloqueamos voice_active hasta que pasen los frames de holdoff.
        voiceActive_   = false;
        hangover_      = 0;
        hangoverActive_ = false;
        onsetSustain_  = 0;
    } else if (stationarity_ > kStationarityGate &&
               midSnrDb_ < kMidSnrGateDb &&
               !voiceActive_) {
        // Gate 2: ruido continuo dominante (ventilador, AC, motores).
        // Sólo aplica al ARRANQUE — si ya estamos en voz, no la matamos
        // por estacionariedad puntual; la histéresis del score lo hará
        // de forma natural cuando termine el enunciado.
        voiceActive_   = false;
        hangover_      = 0;
        hangoverActive_ = false;
        onsetSustain_  = 0;
    } else if (nonVocalGateBlock && !voiceActive_) {
        // Gate 3: respiración / roce / viento / fricativa sostenida.
        // Idem Gate 2: sólo bloquea ARRANQUE de voz.
        voiceActive_   = false;
        hangover_      = 0;
        hangoverActive_ = false;
        onsetSustain_  = 0;
    } else if (centroidGateBlock && voiceActive_ && !voiceEvidenceStrong) {
        // Gate 3b: si ya estamos en voz pero el centroide se va arriba
        // del rango vocal Y no hay pitch sostenido Y no hay evidencia
        // espectral fuerte, cortamos. Voz humana real nunca sostiene un
        // centroide > 3 kHz; si pasa, es porque el breath proxy ganó la
        // hysteresis tras un pico de envolvente. Sin este corte de la
        // banda muerta el detector queda enganchado los 5 segundos del
        // test T4/T4b/T4c.
        voiceActive_   = false;
        hangover_      = 0;
        hangoverActive_ = false;
        onsetSustain_  = 0;
    } else if (voiceActive_) {
        if (smoothedScore_ > kVoiceThresholdLow) {
            voiceActive_   = true;
            hangoverActive_ = false;
        } else if (hangover_ > 0) {
            voiceActive_   = true;
            hangoverActive_ = true;
            --hangover_;
        } else {
            voiceActive_   = false;
            hangoverActive_ = false;
        }
    } else {
        // Onset: requiere sustain de N frames consecutivos arriba del
        // threshold high. La condición es voicingOk (pitch sostenido)
        // O voiceLikelyByLrt (evidencia espectral fuerte). Esta segunda
        // rama cubre voz real saturada por el AGC del celular, donde
        // el autocorrelograma colapsa a < 0.18 a pesar de que LRT,
        // midSnr y LTSD son claramente vocales.
        // pitchDensity_ NO se exige aquí — sirve solo como diagnóstico,
        // porque al inicio del primer enunciado el ringbuffer está vacío
        // y bloquearíamos los primeros 200 ms de voz tras el silencio.
        const bool voiceLikelyByLrt =
            (lrtScore_ > kVoiceLikelyLrtThresh) &&
            (midSnrDb_ > kVoiceLikelyMidSnrThresh) &&
            (pitchDensity_ >= kVoiceLikelyPitchDensMin);
        const bool onsetCondOk = voicingOk || voiceLikelyByLrt;
        if (smoothedScore_ > kVoiceThresholdHigh && onsetCondOk) {
            ++onsetSustain_;
            if (onsetSustain_ >= kSustainFramesForOnset) {
                voiceActive_   = true;
                hangover_      = kHangoverFrames;
                hangoverActive_ = false;
            } else {
                voiceActive_   = false;
                hangoverActive_ = false;
            }
        } else {
            onsetSustain_  = 0;
            voiceActive_   = false;
            hangoverActive_ = false;
        }
    }
}

float VadDetector::getConfidence() const {
    // Confianza = qué tan lejos está el score del 0.5 central.
    // Score = 0.5 → confidence ~ 0; score = 0 ó 1 → confidence ~ 1.
    float dist = std::abs(smoothedScore_ - 0.5f) * 2.0f;
    return std::clamp(dist, 0.0f, 1.0f);
}

// ─────────────────────────────────────────────────────────────────────────────
// Push de samples con HPF de primer orden
// ─────────────────────────────────────────────────────────────────────────────

void VadDetector::pushSamplesWithHpf(const float* samples, int numSamples) {
    // y[n] = a*(y[n-1] + x[n] - x[n-1])
    const float a = kHpfCoeff;

    if (numSamples >= kPitchBufferSize) {
        // Bloque más grande que el buffer: aplicamos HPF a los últimos N
        // y reemplazamos todo el contenido. Inicializamos prev con el
        // primer sample del segmento que entra.
        const int start = numSamples - kPitchBufferSize;
        float xPrev = samples[start];
        float yPrev = 0.0f;
        for (int i = 0; i < kPitchBufferSize; ++i) {
            const float x = samples[start + i];
            const float y = a * (yPrev + x - xPrev);
            pitchBuffer_[i] = y;
            xPrev = x;
            yPrev = y;
        }
        hpfXPrev_ = xPrev;
        hpfYPrev_ = yPrev;
        samplesAccumulated_ = kPitchBufferSize;
        return;
    }

    // Caso normal: shift left y append con HPF aplicado.
    const int keep = kPitchBufferSize - numSamples;
    std::memmove(pitchBuffer_, pitchBuffer_ + numSamples,
                 keep * sizeof(float));
    for (int i = 0; i < numSamples; ++i) {
        const float x = samples[i];
        const float y = a * (hpfYPrev_ + x - hpfXPrev_);
        pitchBuffer_[keep + i] = y;
        hpfXPrev_ = x;
        hpfYPrev_ = y;
    }
    samplesAccumulated_ =
        std::min(samplesAccumulated_ + numSamples, kPitchBufferSize);
}

// ─────────────────────────────────────────────────────────────────────────────
// Pitch strength (autocorrelación normalizada sobre buffer pre-blanqueado)
// ─────────────────────────────────────────────────────────────────────────────

float VadDetector::computePitchStrength() const {
    const int n = samplesAccumulated_;
    if (n <= maxLag_ + 1) return 0.0f;

    // R(0): energía total del segmento blanqueado.
    double r0 = 0.0;
    for (int i = 0; i < n; ++i) {
        r0 += static_cast<double>(pitchBuffer_[i]) * pitchBuffer_[i];
    }
    if (r0 < 1e-9) return 0.0f;

    double maxRatio = 0.0;
    for (int lag = minLag_; lag <= maxLag_; ++lag) {
        double rLag = 0.0;
        const int m = n - lag;
        for (int i = 0; i < m; ++i) {
            rLag += static_cast<double>(pitchBuffer_[i]) *
                    pitchBuffer_[i + lag];
        }
        const double ratio = rLag / r0;
        if (ratio > maxRatio) maxRatio = ratio;
    }

    if (maxRatio < 0.0) maxRatio = 0.0;
    if (maxRatio > 1.0) maxRatio = 1.0;
    return static_cast<float>(maxRatio);
}

// ─────────────────────────────────────────────────────────────────────────────
// A-priori SNR decision-directed (Ephraim-Malah / Sohn)
// ─────────────────────────────────────────────────────────────────────────────

void VadDetector::updateAprioriSnr(const float bandEnergyDb[kSceneNumBands],
                                   const float noiseFloorDb[kSceneNumBands]) {
    for (int b = 0; b < kSceneNumBands; ++b) {
        float postDb = bandEnergyDb[b] - noiseFloorDb[b];
        if (!std::isfinite(postDb)) postDb = 0.0f;
        if (postDb < 0.0f) postDb = 0.0f;
        // Convertir a γ a posteriori lineal: γ = 10^(postDb/10).
        const float gammaLin = std::pow(10.0f, postDb * 0.1f);
        const float instant  = std::max(0.0f, gammaLin - 1.0f);
        // Decision-directed update (Ephraim-Malah).
        xiPrev_[b] = kAlphaDD * xiPrev_[b] + (1.0f - kAlphaDD) * instant;
        if (!std::isfinite(xiPrev_[b]) || xiPrev_[b] < 0.0f) {
            xiPrev_[b] = 0.0f;
        }
        // FIX A — Anti-bias DD-SNR bajo ruido estacionario coloreado.
        // Con ruido brownish/tráfico (1/f²), el xi_prev acumula un bias
        // positivo sostenido que infla el LRT artificialmente incluso sin voz.
        // Cuando el espectro es altamente estacionario (stationarity_ > umbral),
        // aplicamos un decay suave para que xi_prev converja hacia el piso real.
        // Voz real mantiene stationarity_ < 0.75 por la modulación de formantes.
        // Ref: Gerkmann & Hendriks, EURASIP J. Audio SP (2019) — bias del DD
        //      en presencia de ruido coloreado de banda limitada.
        if (stationarity_ > kXiDecayStatThresh) {
            xiPrev_[b] *= kXiDecayStationaryAlpha;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// LRT estilo Sohn 1999 simplificado, promediado en bandas vocales
// ─────────────────────────────────────────────────────────────────────────────

float VadDetector::computeLrt(const float bandEnergyDb[kSceneNumBands],
                              const float noiseFloorDb[kSceneNumBands]) const {
    // Λ_b = (xi/(1+xi)) * gamma_lin - log(1 + xi)
    // donde gamma es γ a posteriori. Promediado sobre [kBandLrtLo, kBandLrtHi].
    double sum = 0.0;
    int count = 0;
    for (int b = kBandLrtLo; b <= kBandLrtHi && b < kSceneNumBands; ++b) {
        const float xi = xiPrev_[b];
        float postDb = bandEnergyDb[b] - noiseFloorDb[b];
        if (!std::isfinite(postDb)) postDb = 0.0f;
        if (postDb < 0.0f) postDb = 0.0f;
        const float gammaLin = std::pow(10.0f, postDb * 0.1f);
        const float lambdaB =
            (xi / (1.0f + xi + 1e-9f)) * gammaLin - std::log1p(xi);
        if (std::isfinite(lambdaB)) {
            sum += static_cast<double>(lambdaB);
            ++count;
        }
    }
    if (count == 0) return 0.0f;
    return static_cast<float>(sum / count);
}

// ─────────────────────────────────────────────────────────────────────────────
// Mid-band SNR (1.1-5.5 kHz)
// ─────────────────────────────────────────────────────────────────────────────

float VadDetector::computeMidSnrDb(const float bandEnergyDb[kSceneNumBands],
                                   const float noiseFloorDb[kSceneNumBands])
    const {
    double sum = 0.0;
    int count = 0;
    for (int b = kBandMidLo; b <= kBandMidHi && b < kSceneNumBands; ++b) {
        float diff = bandEnergyDb[b] - noiseFloorDb[b];
        if (!std::isfinite(diff)) diff = 0.0f;
        sum += static_cast<double>(diff);
        ++count;
    }
    if (count == 0) return 0.0f;
    return static_cast<float>(sum / count);
}

// ─────────────────────────────────────────────────────────────────────────────
// LTSD (Ramirez 2004): pico sobre ventana - piso de ruido
// ─────────────────────────────────────────────────────────────────────────────

void VadDetector::pushLtsdHistory(const float bandEnergyDb[kSceneNumBands]) {
    for (int b = 0; b < kSceneNumBands; ++b) {
        float v = bandEnergyDb[b];
        if (!std::isfinite(v)) v = -90.0f;
        ltsdHistory_[ltsdIdx_][b] = v;
    }
    ltsdIdx_ = (ltsdIdx_ + 1) % kLtsdWindow;
    if (ltsdFill_ < kLtsdWindow) ++ltsdFill_;
}

float VadDetector::computeLtsdDb(const float noiseFloorDb[kSceneNumBands])
    const {
    if (ltsdFill_ == 0) return 0.0f;
    double sum = 0.0;
    int count = 0;
    for (int b = kBandLrtLo; b <= kBandLrtHi && b < kSceneNumBands; ++b) {
        float peak = ltsdHistory_[0][b];
        for (int i = 1; i < ltsdFill_; ++i) {
            if (ltsdHistory_[i][b] > peak) peak = ltsdHistory_[i][b];
        }
        float diff = peak - noiseFloorDb[b];
        if (!std::isfinite(diff)) diff = 0.0f;
        sum += static_cast<double>(diff);
        ++count;
    }
    if (count == 0) return 0.0f;
    return static_cast<float>(sum / count);
}

// ─────────────────────────────────────────────────────────────────────────────
// Noise stationarity (varianza temporal en bandas vocales)
// ─────────────────────────────────────────────────────────────────────────────

void VadDetector::pushStatHistory(const float bandEnergyDb[kSceneNumBands]) {
    for (int b = 0; b < kSceneNumBands; ++b) {
        float v = bandEnergyDb[b];
        if (!std::isfinite(v)) v = -90.0f;
        statHistory_[statIdx_][b] = v;
    }
    statIdx_ = (statIdx_ + 1) % kStatWindow;
    if (statFill_ < kStatWindow) ++statFill_;
}

float VadDetector::computeStationarity() const {
    // Necesitamos suficientes frames para que la varianza tenga sentido.
    if (statFill_ < kStatWindow / 2) return 0.0f;

    double sumVar = 0.0;
    int count = 0;
    for (int b = kBandLrtLo; b <= kBandLrtHi && b < kSceneNumBands; ++b) {
        // Media.
        double mean = 0.0;
        for (int i = 0; i < statFill_; ++i) {
            mean += static_cast<double>(statHistory_[i][b]);
        }
        mean /= statFill_;
        // Varianza poblacional.
        double var = 0.0;
        for (int i = 0; i < statFill_; ++i) {
            const double d = statHistory_[i][b] - mean;
            var += d * d;
        }
        var /= statFill_;
        sumVar += var;
        ++count;
    }
    if (count == 0) return 0.0f;
    const double meanVar = sumVar / count;
    // Mapeo: var = 0 (idéntico) → station = 1.
    //        var = 50 dB² (típico voz natural) → station = 0.
    double s = 1.0 - (meanVar / 50.0);
    if (s < 0.0) s = 0.0;
    if (s > 1.0) s = 1.0;
    return static_cast<float>(s);
}

// ─────────────────────────────────────────────────────────────────────────────
// ZCR — cuenta cruces por cero sobre buffer pre-blanqueado
// ─────────────────────────────────────────────────────────────────────────────

float VadDetector::computeZcr(const float* samples, int numSamples) const {
    if (samples == nullptr || numSamples < 2) return 0.0f;
    int zc = 0;
    for (int i = 1; i < numSamples; ++i) {
        const bool prevPos = samples[i - 1] >= 0.0f;
        const bool currPos = samples[i]     >= 0.0f;
        if (prevPos != currPos) ++zc;
    }
    const float ratio =
        static_cast<float>(zc) / static_cast<float>(numSamples - 1);
    return std::clamp(ratio, 0.0f, 1.0f);
}

// ─────────────────────────────────────────────────────────────────────────────
// Sigmoid utility
// ─────────────────────────────────────────────────────────────────────────────

float VadDetector::sigmoid(float x) {
    // Saturar para evitar exp() de números enormes.
    if (x >  20.0f) return 1.0f;
    if (x < -20.0f) return 0.0f;
    return 1.0f / (1.0f + std::exp(-x));
}

} // namespace smart_scene

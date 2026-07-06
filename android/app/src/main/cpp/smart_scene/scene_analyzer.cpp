/// @file scene_analyzer.cpp
/// @brief Implementación del orquestador del Smart Scene Engine.
///
/// FFT radix-2 in-place clásica (Cooley-Tukey) con bit-reversal y butterfly.
/// El analyzer NO toma decisiones de clasificación todavía (Fase 1).
///
/// Validates: Requirements 1.1, 6.2, 7.1

#include "scene_analyzer.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace smart_scene {

namespace {

constexpr float kPi = 3.14159265358979323846f;

// ── Constantes del fix de escala R2 (tareas 2.2/2.3) ─────────────────────────
/// Piso de ruido acotado defensivamente al rango físico del mic real (dBFS).
constexpr float kNoiseFloorMinDbFs = -60.0f;
constexpr float kNoiseFloorMaxDbFs = -40.0f;
/// Tope físico del SNR estimado (dB). Sin saturación artificial en 40.
constexpr float kSnrMinDb = -20.0f;
constexpr float kSnrMaxDb =  40.0f;

/// Bit-reversal in-place sobre arrays real/imag de tamaño N (potencia de 2).
inline void bitReverse(float* re, float* im, int N) {
    int j = 0;
    for (int i = 1; i < N - 1; ++i) {
        int bit = N >> 1;
        for (; j & bit; bit >>= 1) {
            j ^= bit;
        }
        j ^= bit;
        if (i < j) {
            std::swap(re[i], re[j]);
            std::swap(im[i], im[j]);
        }
    }
}

/// FFT radix-2 Cooley-Tukey in-place. N debe ser potencia de 2.
inline void fftRadix2(float* re, float* im, int N) {
    bitReverse(re, im, N);
    for (int size = 2; size <= N; size <<= 1) {
        int halfSize = size >> 1;
        float angleStep = -2.0f * kPi / static_cast<float>(size);
        for (int i = 0; i < N; i += size) {
            for (int k = 0; k < halfSize; ++k) {
                float angle = angleStep * static_cast<float>(k);
                float cosA = std::cos(angle);
                float sinA = std::sin(angle);
                int idxEven = i + k;
                int idxOdd = idxEven + halfSize;
                float tRe = cosA * re[idxOdd] - sinA * im[idxOdd];
                float tIm = sinA * re[idxOdd] + cosA * im[idxOdd];
                re[idxOdd] = re[idxEven] - tRe;
                im[idxOdd] = im[idxEven] - tIm;
                re[idxEven] += tRe;
                im[idxEven] += tIm;
            }
        }
    }
}

} // namespace

// ─────────────────────────────────────────────────────────────────────────────
// Construcción / Init
// ─────────────────────────────────────────────────────────────────────────────

SceneAnalyzer::SceneAnalyzer() {
    std::memset(fftBuffer_, 0, sizeof(fftBuffer_));
    std::memset(fftReal_, 0, sizeof(fftReal_));
    std::memset(fftImag_, 0, sizeof(fftImag_));
    std::memset(hannWindow_, 0, sizeof(hannWindow_));
    std::memset(magnitude_, 0, sizeof(magnitude_));
    std::memset(prevMagnitude_, 0, sizeof(prevMagnitude_));
    std::memset(&snapshot_, 0, sizeof(snapshot_));
}

void SceneAnalyzer::init(int sampleRate, float splOffset) {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000;
    splOffset_ = splOffset;

    // Precomputar ventana Hann.
    for (int n = 0; n < kFftSize; ++n) {
        hannWindow_[n] = 0.5f * (1.0f - std::cos(2.0f * kPi *
                                                  static_cast<float>(n) /
                                                  static_cast<float>(kFftSize - 1)));
    }

    vad_.init(sampleRate_);
    noise_.reset();

    fftBufferPos_ = 0;
    blockCounter_ = 0;
    hasPrevMagnitude_ = false;
    startTime_ = std::chrono::steady_clock::now();
    std::memset(&snapshot_, 0, sizeof(snapshot_));
    snapshot_.scene_class = static_cast<uint8_t>(SceneClass::UNKNOWN);
    snapshot_.scene_confidence = 0.0f;
    initialized_ = true;
}

void SceneAnalyzer::reset() {
    fftBufferPos_ = 0;
    blockCounter_ = 0;
    hasPrevMagnitude_ = false;
    vad_.reset();
    noise_.reset();
    std::memset(magnitude_, 0, sizeof(magnitude_));
    std::memset(prevMagnitude_, 0, sizeof(prevMagnitude_));
    std::memset(&snapshot_, 0, sizeof(snapshot_));
    snapshot_.scene_class = static_cast<uint8_t>(SceneClass::UNKNOWN);
    seq_.fetch_add(2, std::memory_order_release);  // par → consistente
}

void SceneAnalyzer::setSplOffset(float offset) {
    splOffset_ = offset;
}

// ─────────────────────────────────────────────────────────────────────────────
// Procesamiento (hilo de audio)
// ─────────────────────────────────────────────────────────────────────────────

void SceneAnalyzer::process(const float* block, int numSamples) {
    if (!initialized_ || block == nullptr || numSamples <= 0) {
        return;
    }

    // Acumular en el buffer FFT.
    int idx = 0;
    while (idx < numSamples) {
        int space = kFftSize - fftBufferPos_;
        int copy = std::min(space, numSamples - idx);
        std::memcpy(fftBuffer_ + fftBufferPos_, block + idx,
                    copy * sizeof(float));
        fftBufferPos_ += copy;
        idx += copy;

        if (fftBufferPos_ >= kFftSize) {
            // Decimación: si kFftDecimation > 1 saltamos FFTs.
            ++blockCounter_;
            if ((blockCounter_ % kFftDecimation) == 0) {
                computeFft();
            }
            // Shift del 50% para overlap (mejora resolución temporal).
            int half = kFftSize / 2;
            std::memmove(fftBuffer_, fftBuffer_ + half, half * sizeof(float));
            fftBufferPos_ = half;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FFT y publicación de snapshot
// ─────────────────────────────────────────────────────────────────────────────

void SceneAnalyzer::computeFft() {
    // 1) Aplicar ventana Hann y copiar a fftReal_/fftImag_.
    for (int i = 0; i < kFftSize; ++i) {
        fftReal_[i] = fftBuffer_[i] * hannWindow_[i];
        fftImag_[i] = 0.0f;
    }

    // 2) RMS lineal del bloque sin ventana → dB SPL.
    float rmsLinear = computeRms(fftBuffer_, kFftSize);
    float inputDbSpl = rmsToDbSpl(rmsLinear);

    // 3) FFT.
    fftRadix2(fftReal_, fftImag_, kFftSize);

    // 4) Magnitudes en bins útiles.
    if (hasPrevMagnitude_) {
        std::memcpy(prevMagnitude_, magnitude_, sizeof(magnitude_));
    }
    for (int k = 0; k < kSceneFftBins; ++k) {
        float re = fftReal_[k];
        float im = fftImag_[k];
        magnitude_[k] = std::sqrt(re * re + im * im) /
                        static_cast<float>(kFftSize);
    }

    // 5) Features espectrales.
    SpectralFeatures features{};
    SpectralFeatures_F::compute(magnitude_,
                                hasPrevMagnitude_ ? prevMagnitude_ : nullptr,
                                sampleRate_,
                                features);
    hasPrevMagnitude_ = true;

    // 6) Bandas EQ y noise profile.
    float bandsDb[kSceneNumBands];
    for (int b = 0; b < kSceneNumBands; ++b) {
        bandsDb[b] = features.band_energy_db[b];
    }
    noise_.update(bandsDb);
    float noiseFloorDb = noise_.getNoiseFloorDb();

    // ── FIX escala R2 (mvdr-noise-clarity-tuning, tareas 2.2/2.3) ──────────
    // DECISIÓN T1(c): se corrige la ESCALA del snr_db del snapshot (no se
    // reemplaza por el SNR autoconsistente de estimateSnrFromNr). Motivo: el
    // SNR autoconsistente vive en el path del NR Wiener (DspPipeline, otro
    // hilo) y ya alimenta el EnvironmentClassifier; acoplarlo al SceneAnalyzer
    // cruzaría dos módulos/hilos independientes. El fix mínimo y autocontenido
    // es unificar la referencia de nivel.
    //
    // Bug original: inputDbSpl está en dB SPL (rms + splOffset≈93) pero
    // noiseFloorDb viene de energías FFT por banda SIN calibrar (~dBFS). La
    // resta mezclaba referencias → SNR saturaba en el tope (40 dB) y el piso
    // se reportaba en -77..-97 dBFS. Ahora:
    //   1) Se acota el piso a [-60, -40] dBFS (rango físico del mic real).
    //   2) El SNR se computa con AMBOS términos en dBFS: se le quita el
    //      splOffset al input (inputDbFs = inputDbSpl - splOffset_) para que
    //      snr = inputDbFs - noiseFloorDb sea coherente.
    //   3) El clamp de SNR pasa a ser un tope físico [-20, 40] sin saturar
    //      artificialmente en 40 (el valor ahora varía con el contenido).
    if (noiseFloorDb < kNoiseFloorMinDbFs) noiseFloorDb = kNoiseFloorMinDbFs;
    if (noiseFloorDb > kNoiseFloorMaxDbFs) noiseFloorDb = kNoiseFloorMaxDbFs;

    const float inputDbFs = inputDbSpl - splOffset_;
    float snrDb = inputDbFs - noiseFloorDb;
    if (snrDb < kSnrMinDb) snrDb = kSnrMinDb;
    if (snrDb > kSnrMaxDb) snrDb = kSnrMaxDb;

    // 8) VAD híbrido robusto: usa muestras de tiempo + bandas + piso de
    //    ruido + flatness + tilt + centroide. El nuevo VAD reactiva
    //    flatness como gate anti respiración / roce, y consume tilt y
    //    centroide como discriminadores adicionales contra ruidos
    //    aerodinámicos pasabandeados (breath proxy 200-2 kHz, viento,
    //    agua corriendo) que dejan masa espectral fuera del rango
    //    formántico.
    vad_.process(fftBuffer_, kFftSize,
                 bandsDb,
                 noise_.getProfileDb(),
                 features.flatness,
                 features.tilt_db_per_octave,
                 features.centroid_hz,
                 inputDbSpl);

    // 9) Construir snapshot.
    SceneSnapshot snap{};
    snap.timestamp_us = getElapsedUs();
    snap.input_db_spl = inputDbSpl;
    snap.noise_floor_db_spl = noiseFloorDb;
    snap.snr_db = snrDb;
    snap.vad_score = vad_.getScore();
    snap.vad_confidence = vad_.getConfidence();
    snap.voice_active = vad_.isVoiceActive() ? 1 : 0;
    snap.vad_hangover_active = vad_.isHangoverActive() ? 1 : 0;
    {
        // Stationarity ya está en [0,1] → mapear a Q8.
        float st = vad_.getStationarity();
        if (st < 0.0f) st = 0.0f;
        if (st > 1.0f) st = 1.0f;
        snap.vad_stationarity_q8 =
            static_cast<uint8_t>(st * 255.0f + 0.5f);
        // Mid-band SNR: clamp a [0, 30] dB y mapear a [0, 255].
        float midSnr = vad_.getMidSnrDb();
        if (midSnr < 0.0f) midSnr = 0.0f;
        if (midSnr > 30.0f) midSnr = 30.0f;
        snap.vad_mid_snr_q8 =
            static_cast<uint8_t>((midSnr / 30.0f) * 255.0f + 0.5f);
    }
    snap.spectral_tilt_db = features.tilt_db_per_octave;
    snap.spectral_centroid_hz = features.centroid_hz;
    snap.spectral_flatness = features.flatness;
    snap.spectral_flux = features.flux;
    snap.low_band_energy_db = features.low_band_db;
    snap.mid_band_energy_db = features.mid_band_db;
    snap.high_band_energy_db = features.high_band_db;
    for (int b = 0; b < kSceneNumBands; ++b) {
        snap.noise_per_band_db[b] = noise_.getProfileDb()[b];
    }
    snap.impulse_count = 0;

    // ── R4 (mvdr-noise-clarity-tuning, tarea 3.2): decisión de SceneClass ──
    // DECISIÓN T1(b): la métrica "Clase detectada" de la UI
    // (smart_scene_screen.dart, _MetricRow) lee snapshot.sceneClass CRUDO,
    // que estaba hardcodeado a UNKNOWN (Fase 1) → de ahí el "unknown 100%".
    // El path del SmartScene auto (scene_engine → SceneDecisionMaker en Dart)
    // reclasifica desde las métricas del snapshot y NO usa este campo, pero
    // depende del snr_db (ya corregido en R2). Habilitamos aquí la decisión
    // usando el snr_db/piso corregidos + VAD + nivel + features, de modo que
    // el campo crudo también converja (R4 AC1/AC6). La lógica es un espejo
    // conservador de la del SceneDecisionMaker de Dart.
    float sceneConfidence = 0.0f;
    snap.scene_class = static_cast<uint8_t>(
        classifyScene(inputDbSpl, snrDb, features,
                      vad_.isVoiceActive(), sceneConfidence));
    snap.scene_confidence = sceneConfidence;

    publishSnapshot(snap);
}

// ─────────────────────────────────────────────────────────────────────────────
// Lectura thread-safe (seqlock simple)
// ─────────────────────────────────────────────────────────────────────────────

void SceneAnalyzer::publishSnapshot(const SceneSnapshot& snap) {
    // Seqlock: incrementar a impar antes de escribir, par después.
    uint32_t s = seq_.load(std::memory_order_relaxed);
    seq_.store(s + 1, std::memory_order_release);
    snapshot_ = snap;
    seq_.store(s + 2, std::memory_order_release);
}

SceneSnapshot SceneAnalyzer::getSnapshot() const {
    SceneSnapshot copy{};
    // Seqlock: reintentar mientras el escritor esté activo.
    for (int attempt = 0; attempt < 8; ++attempt) {
        uint32_t s1 = seq_.load(std::memory_order_acquire);
        if (s1 & 1u) continue;  // escritor en curso
        copy = snapshot_;
        uint32_t s2 = seq_.load(std::memory_order_acquire);
        if (s1 == s2) {
            return copy;
        }
    }
    // Fallback: copia "best effort".
    return snapshot_;
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

float SceneAnalyzer::computeRms(const float* buffer, int numSamples) {
    if (buffer == nullptr || numSamples <= 0) return 0.0f;
    double acc = 0.0;
    for (int i = 0; i < numSamples; ++i) {
        acc += static_cast<double>(buffer[i]) * buffer[i];
    }
    return static_cast<float>(std::sqrt(acc / numSamples));
}

float SceneAnalyzer::rmsToDbSpl(float rmsLinear) const {
    if (rmsLinear < 1e-10f) {
        return 0.0f;
    }
    return 20.0f * std::log10(rmsLinear) + splOffset_;
}

float SceneAnalyzer::dbSplToRms(float dbSpl) const {
    return std::pow(10.0f, (dbSpl - splOffset_) / 20.0f);
}

uint64_t SceneAnalyzer::getElapsedUs() const {
    auto now = std::chrono::steady_clock::now();
    auto delta = now - startTime_;
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(delta).count());
}

// ─────────────────────────────────────────────────────────────────────────────
// Decisión de escena (R4, tarea 3.2) — espejo conservador del
// SceneDecisionMaker de Dart (lib/scene/scene_decision_maker.dart).
// Consume el snr_db/piso YA corregidos por el fix de escala R2.
// ─────────────────────────────────────────────────────────────────────────────
SceneClass SceneAnalyzer::classifyScene(float inputDbSpl,
                                        float snrDb,
                                        const SpectralFeatures& f,
                                        bool voiceActive,
                                        float& confidenceOut) const {
    // Umbrales alineados con SceneDecisionMaker (Dart) para coherencia.
    constexpr float kSilenceDbSpl        = 30.0f;
    constexpr float kCleanSpeechSnrDb    = 15.0f;
    constexpr float kLowDominantTiltMax  = -8.0f;  // dB/octava
    constexpr float kHighDominantTiltMin =  2.0f;  // dB/octava
    constexpr float kMusicFlatnessMax    = 0.10f;
    constexpr float kMusicCentroidMinHz  = 600.0f;

    auto confFromDistance = [](float distance, float fullAt) -> float {
        if (distance < 0.0f) return 0.5f;
        if (fullAt <= 0.0f) return 1.0f;
        float c = 0.5f + 0.5f * (distance / fullAt);
        return c < 0.5f ? 0.5f : (c > 1.0f ? 1.0f : c);
    };

    // 1) Silencio: nivel muy bajo, precedencia sobre todo.
    if (inputDbSpl < kSilenceDbSpl) {
        confidenceOut = confFromDistance(kSilenceDbSpl - inputDbSpl, 10.0f);
        return SceneClass::SILENCE;
    }

    // 2) Música: armónica estable, flatness baja, sin voz, nivel alto.
    if (!voiceActive && f.flatness < kMusicFlatnessMax &&
        f.centroid_hz >= kMusicCentroidMinHz && inputDbSpl >= 50.0f) {
        float c = ((kMusicFlatnessMax - f.flatness) / kMusicFlatnessMax) * 0.6f +
                  ((f.centroid_hz - kMusicCentroidMinHz) / 4000.0f) * 0.4f;
        confidenceOut = c < 0.0f ? 0.0f : (c > 1.0f ? 1.0f : c);
        return SceneClass::MUSIC;
    }

    // 3) Voz (VAD activo): sub-clase por SNR y tilt.
    if (voiceActive) {
        if (snrDb >= kCleanSpeechSnrDb) {
            confidenceOut = confFromDistance(snrDb - kCleanSpeechSnrDb, 10.0f);
            return SceneClass::VOICE_ONLY;
        }
        if (f.tilt_db_per_octave < kLowDominantTiltMax) {
            confidenceOut = confFromDistance(
                kLowDominantTiltMax - f.tilt_db_per_octave, 6.0f);
            return SceneClass::VOICE_IN_NOISE_LOW;
        }
        float c = 1.0f - (snrDb / kCleanSpeechSnrDb);
        confidenceOut = c < 0.4f ? 0.4f : (c > 1.0f ? 1.0f : c);
        return SceneClass::VOICE_IN_NOISE_MID;
    }

    // 4) Sin voz, no silencio, no música → ruido; grave vs agudo por tilt.
    if (f.tilt_db_per_octave < kLowDominantTiltMax) {
        confidenceOut = confFromDistance(
            kLowDominantTiltMax - f.tilt_db_per_octave, 8.0f);
        return SceneClass::NOISE_LOW_DOMINANT;
    }
    if (f.tilt_db_per_octave > kHighDominantTiltMin) {
        confidenceOut = confFromDistance(
            f.tilt_db_per_octave - kHighDominantTiltMin, 8.0f);
        return SceneClass::NOISE_HIGH_DOMINANT;
    }
    // Ruido balanceado sin voz: convención noise_high_dominant (menos NR).
    confidenceOut = 0.4f;
    return SceneClass::NOISE_HIGH_DOMINANT;
}

void SceneAnalyzer::buildBandEnergies(float bandsDb[kSceneNumBands]) const {
    // No usado directamente — se construye dentro de computeFft via features.
    // Lo dejamos para que un futuro consumer pueda derivar bandas sobre el
    // último magnitude_ sin recomputar la FFT.
    if (bandsDb == nullptr) return;
    for (int b = 0; b < kSceneNumBands; ++b) {
        bandsDb[b] = -90.0f;
    }
}

} // namespace smart_scene

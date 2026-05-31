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

    // 7) SNR estimado (dB), clampeado al rango del clasificador existente.
    float snrDb = inputDbSpl - noiseFloorDb;
    if (snrDb < -20.0f) snrDb = -20.0f;
    if (snrDb >  40.0f) snrDb =  40.0f;

    // 8) VAD pitch-based con la ventana de tiempo (sin Hann para preservar
    //    la energía y la autocorrelación).
    vad_.process(fftBuffer_, kFftSize, features.flatness, inputDbSpl);

    // 9) Construir snapshot.
    SceneSnapshot snap{};
    snap.timestamp_us = getElapsedUs();
    snap.input_db_spl = inputDbSpl;
    snap.noise_floor_db_spl = noiseFloorDb;
    snap.snr_db = snrDb;
    snap.vad_score = vad_.getScore();
    snap.vad_confidence = vad_.getConfidence();
    snap.voice_active = vad_.isVoiceActive() ? 1 : 0;
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
    snap.scene_class = static_cast<uint8_t>(SceneClass::UNKNOWN); // Fase 1
    snap.scene_confidence = 0.0f;

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

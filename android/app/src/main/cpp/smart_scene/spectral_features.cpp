/// @file spectral_features.cpp
/// @brief Implementación de features espectrales del Smart Scene Engine.
///
/// Sin estado: cada función es pura sobre el buffer de magnitud lineal.
///
/// Validates: Requirements 1.1, 7.1

#include "spectral_features.h"

#include <algorithm>
#include <cmath>

namespace smart_scene {

namespace {

/// Frecuencia central del bin k para una FFT de tamaño N a sampleRate.
inline float binFrequency(int k, int sampleRate) {
    return (static_cast<float>(k) * static_cast<float>(sampleRate)) /
           static_cast<float>(kSceneFftSize);
}

/// Bandas log usadas para band_energy_db (12 bandas, 100 Hz a 12 kHz).
/// Coinciden aproximadamente con las 12 bandas EQ del proyecto.
struct LogBand {
    float fLow;
    float fHigh;
};
constexpr LogBand kLogBands[kSceneNumLogBands] = {
    {  100.0f,   200.0f}, // 1 — sub graves
    {  200.0f,   400.0f}, // 2 — graves bajos (250 Hz)
    {  400.0f,   700.0f}, // 3 — graves (500 Hz)
    {  700.0f,  1100.0f}, // 4 — medio-graves (1 kHz)
    { 1100.0f,  1800.0f}, // 5 — medios (1.5 kHz)
    { 1800.0f,  2500.0f}, // 6 — medios (2 kHz)
    { 2500.0f,  3200.0f}, // 7 — medios-agudos (3 kHz)
    { 3200.0f,  4200.0f}, // 8 — agudos (4 kHz)
    { 4200.0f,  5500.0f}, // 9 — agudos
    { 5500.0f,  7000.0f}, // 10 — agudos altos (6 kHz)
    { 7000.0f,  9000.0f}, // 11 — muy agudos
    { 9000.0f, 12000.0f}, // 12 — extremos (8 kHz+)
};

} // namespace

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

float SpectralFeatures_F::toDb(float energyLinear) {
    if (energyLinear <= 1e-10f) {
        return -90.0f;
    }
    return 10.0f * std::log10(energyLinear);
}

// ─────────────────────────────────────────────────────────────────────────────
// Compute principal — agrega todas las features
// ─────────────────────────────────────────────────────────────────────────────

void SpectralFeatures_F::compute(const float* magnitude,
                                 const float* prevMagnitude,
                                 int sampleRate,
                                 SpectralFeatures& out) {
    if (magnitude == nullptr) {
        out = SpectralFeatures{};
        out.tilt_db_per_octave = 0.0f;
        out.centroid_hz = 0.0f;
        out.flatness = 1.0f;  // ruido blanco como default seguro
        out.flux = 0.0f;
        out.low_band_db = -90.0f;
        out.mid_band_db = -90.0f;
        out.high_band_db = -90.0f;
        for (int i = 0; i < kSceneNumLogBands; ++i) {
            out.band_energy_db[i] = -90.0f;
        }
        return;
    }

    out.tilt_db_per_octave = spectralTilt(magnitude, sampleRate);
    out.centroid_hz = spectralCentroid(magnitude, sampleRate);
    out.flatness = spectralFlatness(magnitude);
    out.flux = (prevMagnitude != nullptr)
                   ? spectralFlux(magnitude, prevMagnitude)
                   : 0.0f;
    out.low_band_db  = bandEnergyDb(magnitude, sampleRate,  250.0f,  750.0f);
    out.mid_band_db  = bandEnergyDb(magnitude, sampleRate,  750.0f, 3000.0f);
    out.high_band_db = bandEnergyDb(magnitude, sampleRate, 3000.0f, 8000.0f);
    for (int i = 0; i < kSceneNumLogBands; ++i) {
        out.band_energy_db[i] = bandEnergyDb(magnitude, sampleRate,
                                             kLogBands[i].fLow,
                                             kLogBands[i].fHigh);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tilt — pendiente lineal en escala log-log
// ─────────────────────────────────────────────────────────────────────────────

float SpectralFeatures_F::spectralTilt(const float* magnitude, int sampleRate) {
    // Regresión lineal de log10(magnitude^2) vs log2(freq)
    // Pendiente = dB / octava (porque 10*log10(x) y log2(freq)).
    double sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumXY = 0.0;
    int n = 0;

    // Saltamos los bins por debajo de ~100 Hz (DC e infrabajos no son
    // representativos del tilt percibido).
    for (int k = 1; k < kSceneFftBins; ++k) {
        float freq = binFrequency(k, sampleRate);
        if (freq < 100.0f) continue;
        if (freq > 8000.0f) break;
        float energy = magnitude[k] * magnitude[k];
        if (energy <= 1e-10f) continue;

        double x = std::log2(static_cast<double>(freq));
        double y = 10.0 * std::log10(static_cast<double>(energy));
        sumX += x;
        sumY += y;
        sumXX += x * x;
        sumXY += x * y;
        ++n;
    }

    if (n < 4) return 0.0f;
    double denom = (n * sumXX) - (sumX * sumX);
    if (std::abs(denom) < 1e-9) return 0.0f;
    double slope = ((n * sumXY) - (sumX * sumY)) / denom;
    // Clamp a rango razonable.
    if (slope < -30.0) slope = -30.0;
    if (slope >  30.0) slope =  30.0;
    return static_cast<float>(slope);
}

// ─────────────────────────────────────────────────────────────────────────────
// Centroide — frecuencia "promedio" ponderada por energía
// ─────────────────────────────────────────────────────────────────────────────

float SpectralFeatures_F::spectralCentroid(const float* magnitude,
                                           int sampleRate) {
    double weightedSum = 0.0;
    double totalEnergy = 0.0;

    for (int k = 1; k < kSceneFftBins; ++k) {
        float freq = binFrequency(k, sampleRate);
        float energy = magnitude[k] * magnitude[k];
        weightedSum += static_cast<double>(freq) * energy;
        totalEnergy += energy;
    }

    if (totalEnergy < 1e-10) return 0.0f;
    return static_cast<float>(weightedSum / totalEnergy);
}

// ─────────────────────────────────────────────────────────────────────────────
// Flatness — geometric mean / arithmetic mean
// ─────────────────────────────────────────────────────────────────────────────

float SpectralFeatures_F::spectralFlatness(const float* magnitude) {
    // Solo bins útiles (1..N/2-1) sobre el rango audible aproximado.
    double logSum = 0.0;
    double sum = 0.0;
    int n = 0;

    for (int k = 1; k < kSceneFftBins; ++k) {
        float energy = magnitude[k] * magnitude[k];
        if (energy < 1e-12f) energy = 1e-12f;
        logSum += std::log(static_cast<double>(energy));
        sum += energy;
        ++n;
    }

    if (n == 0 || sum <= 1e-12) return 1.0f;
    double geomMean = std::exp(logSum / n);
    double arithMean = sum / n;
    if (arithMean <= 1e-12) return 1.0f;
    double flatness = geomMean / arithMean;
    if (flatness < 0.0) flatness = 0.0;
    if (flatness > 1.0) flatness = 1.0;
    return static_cast<float>(flatness);
}

// ─────────────────────────────────────────────────────────────────────────────
// Flux — distancia L2 normalizada entre frames consecutivos
// ─────────────────────────────────────────────────────────────────────────────

float SpectralFeatures_F::spectralFlux(const float* magnitude,
                                       const float* prevMagnitude) {
    if (prevMagnitude == nullptr) return 0.0f;

    double accDiff = 0.0;
    double accCur = 0.0;

    for (int k = 1; k < kSceneFftBins; ++k) {
        double cur = magnitude[k];
        double prev = prevMagnitude[k];
        double diff = cur - prev;
        // Half-wave rectified flux (sólo aumentos cuentan, como en
        // Onset Detection clásico).
        if (diff < 0.0) diff = 0.0;
        accDiff += diff * diff;
        accCur += cur * cur;
    }

    if (accCur < 1e-12) return 0.0f;
    double normalized = std::sqrt(accDiff) / std::sqrt(accCur);
    if (normalized > 1.0) normalized = 1.0;
    return static_cast<float>(normalized);
}

// ─────────────────────────────────────────────────────────────────────────────
// Energía promedio en una banda [fLow, fHigh] en dB
// ─────────────────────────────────────────────────────────────────────────────

float SpectralFeatures_F::bandEnergyDb(const float* magnitude,
                                       int sampleRate,
                                       float fLowHz,
                                       float fHighHz) {
    if (fHighHz <= fLowHz) return -90.0f;

    // Convertir bordes a índices de bin.
    int kLow = static_cast<int>(std::floor(
        fLowHz * static_cast<float>(kSceneFftSize) /
        static_cast<float>(sampleRate)));
    int kHigh = static_cast<int>(std::ceil(
        fHighHz * static_cast<float>(kSceneFftSize) /
        static_cast<float>(sampleRate)));
    if (kLow < 1) kLow = 1;
    if (kHigh > kSceneFftBins - 1) kHigh = kSceneFftBins - 1;
    if (kHigh <= kLow) return -90.0f;

    double sum = 0.0;
    int n = 0;
    for (int k = kLow; k <= kHigh; ++k) {
        double energy = static_cast<double>(magnitude[k]) * magnitude[k];
        sum += energy;
        ++n;
    }
    if (n == 0 || sum < 1e-12) return -90.0f;
    double avg = sum / n;
    return toDb(static_cast<float>(avg));
}

} // namespace smart_scene

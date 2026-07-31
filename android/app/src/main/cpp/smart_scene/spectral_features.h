/// @file spectral_features.h
/// @brief Features espectrales para clasificación de escena.
///
/// Provee tilt, centroid, flux, flatness y energía por banda calculadas
/// sobre la magnitud lineal de un FFT de tamaño FFT_SIZE muestras.
/// Todas las funciones son estáticas y sin estado interno: el llamador
/// es dueño del buffer FFT y de los buffers de banda.
///
/// Referencias:
/// - design.md: spectral_features.{h,cpp} — tilt, centroid, flux, bandEnergy
/// - VAD-PITCH-2019 (Springer) para la flatness usada por el VAD
///
/// Validates: Requirements 1.1, 7.1

#ifndef HEARING_AID_SMART_SCENE_SPECTRAL_FEATURES_H
#define HEARING_AID_SMART_SCENE_SPECTRAL_FEATURES_H

#include <cstdint>

namespace smart_scene {

/// Tamaño de FFT usado por el SceneAnalyzer.
/// 256 puntos a 48 kHz = ~5.3 ms ventana, suficiente para pitch 80 Hz.
static constexpr int kSceneFftSize = 256;
static constexpr int kSceneFftBins = kSceneFftSize / 2; // 128 bins útiles

/// Cantidad de bandas mel usadas internamente (lookup table simplificada).
/// Las 40 bandas mel del design se simplifican a 12 bandas log para Fase 1
/// (suficiente para tilt y energía por sección y matching con EQ).
static constexpr int kSceneNumLogBands = 12;

/// Conjunto de features extraídas de un buffer de magnitud lineal.
struct SpectralFeatures {
    float tilt_db_per_octave;   ///< Pendiente promedio en dB/octava.
    float centroid_hz;          ///< Centroide espectral (Hz).
    float flatness;             ///< Geometric/arithmetic mean [0, 1].
    float flux;                 ///< Distancia L2 normalizada al frame anterior.
    float low_band_db;          ///< Energía 250-750 Hz (dB).
    float mid_band_db;          ///< Energía 750-3000 Hz (dB).
    float high_band_db;         ///< Energía 3000-8000 Hz (dB).
    float band_energy_db[kSceneNumLogBands]; ///< Energía log en 12 bandas.
};

/// Funciones estáticas — no guardan estado entre llamadas.
class SpectralFeatures_F {
public:
    /// Calcula todas las features para un buffer de magnitud lineal.
    /// @param magnitude Buffer de kSceneFftBins valores ≥ 0 (magnitud lineal).
    /// @param prevMagnitude Buffer anterior para calcular flux. Si es nullptr
    ///                      el flux se devuelve como 0.
    /// @param sampleRate Frecuencia de muestreo del audio en Hz.
    /// @param out Estructura de salida (escrita siempre).
    static void compute(const float* magnitude,
                        const float* prevMagnitude,
                        int sampleRate,
                        SpectralFeatures& out);

    /// Tilt espectral simple — pendiente lineal de log-magnitud vs log-freq.
    /// @return Pendiente en dB/octava, ya en escala log.
    static float spectralTilt(const float* magnitude, int sampleRate);

    /// Centroide espectral (frecuencia "promedio ponderado por energía").
    static float spectralCentroid(const float* magnitude, int sampleRate);

    /// Flatness — ratio de media geométrica sobre media aritmética. [0, 1].
    /// 0 = puro tono, 1 = ruido blanco perfecto.
    static float spectralFlatness(const float* magnitude);

    /// Flux — distancia entre dos frames consecutivos.
    /// @return Distancia L2 normalizada [0, 1].
    static float spectralFlux(const float* magnitude,
                              const float* prevMagnitude);

    /// Energía promedio en una ventana de frecuencia [fLow, fHigh] en dB.
    /// @return dB con piso a -90 dB.
    static float bandEnergyDb(const float* magnitude,
                              int sampleRate,
                              float fLowHz,
                              float fHighHz);

private:
    /// Convierte energía lineal a dB con piso de -90.
    static float toDb(float energyLinear);
};

} // namespace smart_scene

#endif // HEARING_AID_SMART_SCENE_SPECTRAL_FEATURES_H

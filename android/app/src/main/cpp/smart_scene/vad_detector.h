/// @file vad_detector.h
/// @brief Voice Activity Detection pitch-based para el Smart Scene Engine.
///
/// Combina tres features con pesos del Springer 2019 paper:
///
///     score = pitch_strength * 0.5
///           + (1 - spectral_flatness) * 0.3
///           + energy_normalized * 0.2
///
/// El score se suaviza con EMA (alpha=0.3) y se umbraliza en 0.5 para
/// flag voice_active.
///
/// Referencias:
/// - VAD-PITCH-2019 (Springer): pesos, pitch range, EMA alpha y threshold.
/// - design.md: vad_detector.{h,cpp}
///
/// Validates: Requirements 2.1, 2.2, 2.3

#ifndef HEARING_AID_SMART_SCENE_VAD_DETECTOR_H
#define HEARING_AID_SMART_SCENE_VAD_DETECTOR_H

#include <cstddef>
#include <cstdint>
#include <vector>

namespace smart_scene {

class VadDetector {
public:
    /// Pitch range humano (Hz). Adultos: ~80-250 Hz.
    static constexpr float kPitchMinHz = 80.0f;
    static constexpr float kPitchMaxHz = 250.0f;

    /// Suavizado EMA del score (paper Springer 2019).
    static constexpr float kEmaAlpha = 0.3f;

    /// Umbral para decidir voice_active.
    static constexpr float kVoiceThreshold = 0.5f;

    /// Pesos (deben sumar 1.0).
    static constexpr float kWeightPitch    = 0.5f;
    static constexpr float kWeightFlatness = 0.3f;
    static constexpr float kWeightEnergy   = 0.2f;

    VadDetector();

    /// Inicializa el detector para un sample rate dado.
    /// Calcula los lags de autocorrelación equivalentes a kPitchMinHz/MaxHz.
    void init(int sampleRate);

    /// Procesa un frame de tiempo (ya pre-procesado, mono float).
    /// @param samples Bloque de audio (los últimos N samples del analyzer).
    /// @param numSamples Cantidad de samples en el bloque.
    /// @param flatness Flatness espectral del mismo frame [0, 1].
    /// @param energyDbSpl Nivel RMS del frame en dB SPL.
    void process(const float* samples,
                 int numSamples,
                 float flatness,
                 float energyDbSpl);

    /// Score combinado (0-1) suavizado con EMA. Después de process().
    float getScore() const { return smoothedScore_; }

    /// Confianza derivada del score (margen al threshold). [0, 1].
    float getConfidence() const;

    /// Pitch strength del último frame [0, 1].
    float getPitchStrength() const { return lastPitchStrength_; }

    /// True si el voice flag está activado tras suavizado y threshold.
    bool isVoiceActive() const { return voiceActive_; }

    /// Reinicia el estado del detector.
    void reset();

private:
    /// Calcula el pitch strength por autocorrelación normalizada
    /// en el rango [kPitchMinHz, kPitchMaxHz]. Devuelve [0, 1].
    float computePitchStrength(const float* samples, int numSamples) const;

    /// Normaliza el nivel SPL a [0, 1] usando rango [30, 80] dB SPL.
    static float normalizeEnergy(float dbSpl);

    int sampleRate_ = 48000;
    int minLag_ = 0;
    int maxLag_ = 0;

    // Buffer interno para autocorrelación. El FFT del SceneAnalyzer es de
    // 256 muestras (~5.3 ms a 48 kHz) — insuficiente para pitch de 80 Hz
    // (período ~600 muestras). Acumulamos 1536 muestras (~32 ms a 48 kHz)
    // para tener al menos 2 períodos del pitch más bajo + headroom.
    static constexpr int kPitchBufferSize = 1536;
    float pitchBuffer_[kPitchBufferSize] = {0};
    int samplesAccumulated_ = 0;

    float smoothedScore_ = 0.0f;
    float lastPitchStrength_ = 0.0f;
    bool voiceActive_ = false;
};

} // namespace smart_scene

#endif // HEARING_AID_SMART_SCENE_VAD_DETECTOR_H

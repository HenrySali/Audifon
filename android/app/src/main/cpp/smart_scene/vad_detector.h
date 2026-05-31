/// @file vad_detector.h
/// @brief Voice Activity Detection robusto frente a ruido continuo.
///
/// Reemplaza el VAD pitch-only (Springer 2019) por un detector híbrido
/// inspirado en literatura clásica de VAD robusto. El objetivo concreto
/// es eliminar el flicker observado en producción cuando el celular
/// captura ruido estacionario (ventilador, tráfico, hum 50/60 Hz) sin voz.
///
/// Combina cinco features:
///   1) Pitch strength con HPF de 80 Hz (mata DC + hum + rumble).
///   2) Per-band log-LRT en bandas 3-9 (~0.4-5.5 kHz, banda fonémica).
///      Estilo Sohn 1999 con a-priori SNR decision-directed (Ephraim-Malah).
///   3) Mid-band SNR en bandas 4-9 (~1.1-5.5 kHz).
///   4) Long-Term Spectral Divergence (Ramirez 2004) ventana 8 frames.
///   5) Noise stationarity gating — varianza temporal en bandas vocales,
///      bloquea voiceActive cuando el espectro no se mueve durante > 1 s.
///
/// Anti respiración / golpes / roces (NUEVO):
///   - Flatness gate: respiración / roce / viento dan flatness > 0.55
///     sostenida durante varios frames sin pitch real → bloquear.
///   - ZCR gate: respiración y fricativas tienen ZCR alta (> 6 % de
///     muestras), voz vocal tiene ZCR baja. Sin pitch + ZCR alta = ruido.
///   - Pitch density: voz natural sostiene ≥ 30 % de frames con pitch
///     fuerte sobre una ventana de 200 ms. Respiración no.
///   - Tilt gate: voz tiene tilt fuertemente negativo (-6..-12 dB/oct).
///     Respiración, roce y viento tienen tilt cerca de 0 o positivo.
///
/// La decisión final aplica:
///   - Gate SPL duro a 30 dB SPL (silencio absoluto).
///   - Gate de impulso (golpes / clicks).
///   - Gate de stationarity + mid SNR (ruido continuo dominante).
///   - Gate de respiración / roce (flatness OR ZCR OR tilt sin pitch).
///   - Histéresis ancha 0.65/0.35.
///   - Hangover de 12 frames (60-120 ms a tasas típicas).
///
/// Latencia agregada por bloque < 0.5 ms en target Android. Memoria
/// adicional ≈ 2 KB. Sin dependencias externas (solo <cmath>, <cstring>,
/// <algorithm>, <cstdint>).
///
/// Referencias (parafraseadas — ver Amplificador/.kiro/specs/smart-scene-engine/vad-redesign.md):
///   - Sohn, Kim, Sung 1999 (LRT estadístico).
///   - Martin 2001 (minimum statistics, ya consumido del NoiseProfile).
///   - Ramirez et al. 2004 (LTSD).
///   - Tan, Sarkar, Dehak 2020 (rVAD-fast: a posteriori SNR weighted +
///                                extended pitch segment density).
///   - WebRTC VAD (sub-band GMM, hangover).
///   - Springer 2019 (VAD-PITCH-2019, baseline original que mejoramos).
///   - Tsinghua 2005 (entropy + BIC, motivó el flatness gate).
///   - NAIST / arXiv 2402.00288 (Frame-Wise Breath Detection, ZCR + VMS).
///   - Eng. Appl. AI 2024 (Detection of breath sounds in speech, ZCR +
///                          spectral centroid).
///
/// Validates: Requirements 2.1, 2.2, 2.3 (smart-scene-engine spec).

#ifndef HEARING_AID_SMART_SCENE_VAD_DETECTOR_H
#define HEARING_AID_SMART_SCENE_VAD_DETECTOR_H

#include <cstddef>
#include <cstdint>

#include "scene_types.h"

namespace smart_scene {

/// Voice Activity Detector robusto.
///
/// El SceneAnalyzer le entrega:
///   - Las muestras de tiempo del bloque actual (para pitch).
///   - El array `band_energy_db[12]` ya calculado (de SpectralFeatures).
///   - El array `noise_floor_db[12]` ya calculado (de NoiseProfile).
///   - El nivel `energy_db_spl` del bloque (para el gate SPL).
///
/// Toda la información espectral se reusa — no recomputamos FFT.
class VadDetector {
public:
    // ─── Pitch detection ────────────────────────────────────────────────
    /// Pitch range humano (Hz). Adultos típicos: 80-250 Hz; niños hasta ~300
    /// pero limitamos a 250 para evitar lags muy cortos donde la
    /// autocorrelación es ruidosa.
    static constexpr float kPitchMinHz = 80.0f;
    static constexpr float kPitchMaxHz = 250.0f;

    /// HPF de primer orden ~76 Hz cutoff a 48 kHz. Coeficiente para la
    /// forma `y[n] = a*(y[n-1] + x[n] - x[n-1])`. Mata DC, hum 50/60 Hz
    /// y rumble subsónico antes de la autocorrelación.
    static constexpr float kHpfCoeff = 0.99f;

    /// Buffer interno para autocorrelación. 1024 samples ≈ 21 ms a 48 kHz,
    /// suficiente para 2.5 períodos de pitch a 80 Hz (12.5 ms cada uno).
    /// Más chico que el original (1536) — menos memmove por bloque.
    static constexpr int kPitchBufferSize = 1024;

    // ─── Bandas usadas para LRT y mid-SNR ──────────────────────────────
    /// El array band_energy_db tiene 12 bandas (kSceneNumLogBands). Las
    /// 7 bandas vocales (índices 2..8 = ~750 Hz a 5.5 kHz) son donde vive
    /// la inteligibilidad fonémica.
    static constexpr int kBandLrtLo  = 2;
    static constexpr int kBandLrtHi  = 8;
    static constexpr int kBandMidLo  = 3;
    static constexpr int kBandMidHi  = 8;

    // ─── Suavizado y gates ─────────────────────────────────────────────
    /// EMA del score combinado. Más lento que el 0.3 original — los
    /// 5 ms del callback de audio + ruido random necesitan suavizar más.
    static constexpr float kEmaAlpha = 0.15f;

    /// Decision-directed SNR per banda (Ephraim-Malah 1984 / Sohn 1999).
    /// Alpha alto = a priori SNR confía más en la decisión anterior,
    /// reduce ruido musical pero atrasa la detección. 0.85 es un balance
    /// para frames cortos (5 ms).
    static constexpr float kAlphaDD  = 0.85f;

    /// Histéresis ancha. La banda muerta es 0.25.
    /// Bajado de 0.65 → 0.55 porque voz bajita real (~55 dB SPL) llega al
    /// score ~0.50-0.55 y no estaba activando voz. La diferencia con el
    /// threshold low (0.30) sigue siendo suficiente para evitar flicker.
    static constexpr float kVoiceThresholdHigh = 0.55f;
    static constexpr float kVoiceThresholdLow  = 0.30f;

    /// Gate por nivel absoluto: por debajo de este SPL forzamos silencio.
    static constexpr float kMinSpeechDbSpl = 30.0f;

    /// Gate por estacionariedad: si el espectro vocal cambia menos de
    /// `1 - kStationarityGate` durante la ventana stat, lo declaramos
    /// "ruido continuo" y bloqueamos voice_active.
    static constexpr float kStationarityGate = 0.85f;
    static constexpr float kMidSnrGateDb     = 4.0f;

    /// Hangover en frames después de que el score cae bajo el threshold.
    /// 12 frames * 5-10 ms ≈ 60-120 ms — cubre pausas inter-silábicas
    /// sin extender artificialmente las ráfagas de voz.
    static constexpr int kHangoverFrames = 12;

    /// Cantidad de frames consecutivos con score > threshold high requeridos
    /// para activar voice_active desde estado OFF. Mata transitorios cortos
    /// (golpes al mic, palmas, click de tipeo) que cubren 1-2 frames.
    static constexpr int kSustainFramesForOnset = 3;

    /// Pitch mínimo que debe estar sostenido para considerar "voz".
    /// Voces sostienen 0.35-0.8 durante una vocal. Respiración, golpes,
    /// viento, tipeo dan pitch ≤ 0.25. 0.35 es el punto de quiebre clásico
    /// del autocorrelograma post-HPF para distinguir vocal vs ruido.
    static constexpr float kVoicingMinPitch = 0.35f;

    /// Frames consecutivos con pitch > kVoicingMinPitch necesarios.
    /// 5 frames * ~5-10 ms ≈ 25-50 ms — duración mínima de una vocal corta.
    static constexpr int kVoicingMinFrames = 5;

    /// Densidad de pitch en ventana extendida (rVAD "extended pitch
    /// segment"). Solo se usa como diagnóstico — el onset NO la requiere
    /// para no perder los primeros 200 ms del primer enunciado tras
    /// silencio (cuando el ringbuffer está vacío de historial).
    static constexpr int   kPitchDensityWindow = 40;    ///< ~200 ms a 5 ms/frame.
    static constexpr float kPitchDensityMin    = 0.20f;

    /// Detección de impulso: si la energía sube más que kImpulseRiseDb
    /// en un solo frame venido desde un nivel bajo, es un transitorio
    /// (golpe, palmada, click). Se bloquea voice_active durante
    /// kImpulseHoldoffFrames frames.
    static constexpr float kImpulseRiseDb       = 12.0f;
    static constexpr float kImpulsePrevQuietDb  = 35.0f;
    static constexpr int   kImpulseHoldoffFrames = 8;

    // ─── Gates anti respiración / roce / fricativa sostenida ────────────
    /// Flatness gate (Tsinghua 2005, Springer 2019): voz vocal rara vez
    /// sostiene flatness > 0.65 durante > 50-80 ms. Respiración, roce,
    /// viento sí. Si el gate se activa Y el LRT espectral está bajo,
    /// bloqueamos. El umbral se relaja respecto del 0.55 inicial para no
    /// matar las consonantes /s/ /f/ /sh/ que son legítimas en habla.
    static constexpr float kFlatnessVoiceMax   = 0.65f;
    static constexpr int   kFlatnessGateFrames = 8;

    /// ZCR gate (NAIST breath detection, Aalto): respiración / fricativas
    /// dan tasa de cruces por cero alta sobre el buffer pre-blanqueado.
    /// 0.06 = ~ 9 cruces por bloque post-HPF. Voz vocal: 0.005-0.025;
    /// fricativa de habla legítima: 0.025-0.05; breath / viento: > 0.06.
    static constexpr float kZcrUnvoicedRatio   = 0.06f;

    /// Tilt gate: voz tiene tilt fuertemente negativo (-6..-12 dB/oct).
    /// Respiración / roce / viento tienen tilt cercano a 0 o positivo.
    /// Usamos +1 dB/oct como umbral (más permisivo que el -2 anterior)
    /// porque el tilt ya sirve combinado con flatness alta y mid-SNR bajo.
    static constexpr float kTiltVoiceMaxDbOct  = 1.0f;
    static constexpr float kTiltGateFlatnessMin = 0.55f;

    /// Mínimo SNR mid-band para considerar legítima la actividad. Si
    /// estamos arriba de este umbral hay energía vocal real, no breath:
    /// ningún gate de no-vocal puede dispararse para bloquear voz.
    static constexpr float kNonVocalGateMidSnrDb = 6.0f;

    // ─── Pesos de la combinación ────────────────────────────────────────
    /// Suma debe ser 1.0. LRT pesa más por ser el feature más robusto
    /// teóricamente. Pitch baja del 0.5 anterior al 0.25 — el pre-blanqueo
    /// lo hace utilizable pero ya no es el feature dominante.
    static constexpr float kWeightLrt    = 0.35f;
    static constexpr float kWeightPitch  = 0.25f;
    static constexpr float kWeightMidSnr = 0.25f;
    static constexpr float kWeightLtsd   = 0.15f;

    // ─── Tamaños de ventanas ───────────────────────────────────────────
    /// LTSD: pico de energía vocal en los últimos 8 frames - piso de
    /// ruido. Robusto contra ruido no estacionario (Ramirez 2004).
    static constexpr int kLtsdWindow = 8;

    /// Stationarity: varianza temporal de la energía vocal en los últimos
    /// 32 frames. 32 * 5 ms ≈ 160 ms — suficiente para no mezclar voz
    /// con silencio pero corto para reaccionar a cambios de escena.
    static constexpr int kStatWindow = 32;

    VadDetector();

    /// Inicializa el detector para un sample rate dado.
    /// Calcula los lags de autocorrelación equivalentes a kPitchMinHz/MaxHz.
    void init(int sampleRate);

    /// Procesa un frame del callback de audio.
    /// @param samples       Muestras de tiempo del bloque actual.
    /// @param numSamples    Cantidad de muestras.
    /// @param bandEnergyDb  Energía por banda (12 bandas EQ) en dB.
    /// @param noiseFloorDb  Piso de ruido por banda (del NoiseProfile).
    /// @param flatness      Spectral flatness [0,1]. Reactivada como gate
    ///                      anti respiración / roce.
    /// @param spectralTiltDb Tilt espectral en dB/octava. Voz tiene tilt
    ///                      muy negativo; respiración / roce ≈ 0.
    /// @param energyDbSpl   Nivel RMS del bloque en dB SPL.
    void process(const float* samples,
                 int numSamples,
                 const float bandEnergyDb[kSceneNumBands],
                 const float noiseFloorDb[kSceneNumBands],
                 float flatness,
                 float spectralTiltDb,
                 float energyDbSpl);

    /// True si el voice flag está activado tras suavizado, histéresis,
    /// hangover y gates.
    bool isVoiceActive() const { return voiceActive_; }

    /// True si el flag está activo solo por hangover (la decisión cruda
    /// ya cayó bajo el threshold). Útil para diagnosticar cómo afecta el
    /// hangover a las métricas de la UI.
    bool isHangoverActive() const { return hangoverActive_; }

    /// Score combinado [0,1] post-EMA. Después de process().
    float getScore() const { return smoothedScore_; }

    /// Confianza derivada del score (margen al 0.5 central). [0,1].
    float getConfidence() const;

    // ─── Indicadores diagnósticos (para SceneSnapshot / UI) ────────────
    float getPitchStrength() const { return pitchStrength_; }
    float getMidSnrDb()      const { return midSnrDb_; }
    float getLrtScore()      const { return lrtScore_; }
    float getLtsdDb()        const { return ltsdDb_; }
    float getStationarity()  const { return stationarity_; }
    float getZcrRatio()      const { return zcrRatio_; }
    float getPitchDensity()  const { return pitchDensity_; }

    /// Reinicia el estado del detector.
    void reset();

private:
    // ─── Helpers algorítmicos ──────────────────────────────────────────

    /// Empuja `numSamples` muestras al `pitchBuffer_` aplicando HPF de
    /// 1er orden. La HPF es la responsable de eliminar DC + hum 50/60 Hz
    /// + rumble antes de la autocorrelación, lo que evita falsos pitch
    /// con ruido continuo.
    void pushSamplesWithHpf(const float* samples, int numSamples);

    /// Pitch strength por autocorrelación normalizada en `[minLag_, maxLag_]`.
    /// Devuelve `R(lag*) / R(0)` clipeado a [0, 1].
    float computePitchStrength() const;

    /// Actualiza la a-priori SNR per banda (decision-directed).
    /// Usa `xi[t] = α * xi[t-1] + (1-α) * max(0, γ_post - 1)` simplificado.
    void updateAprioriSnr(const float bandEnergyDb[kSceneNumBands],
                          const float noiseFloorDb[kSceneNumBands]);

    /// LRT promediado en bandas vocales (Sohn 1999 simplificado).
    /// Devuelve un valor que usualmente está en [-2, +6] dB-equivalent.
    float computeLrt(const float bandEnergyDb[kSceneNumBands],
                     const float noiseFloorDb[kSceneNumBands]) const;

    /// SNR promedio en bandas mid (1.1-5.5 kHz) en dB.
    float computeMidSnrDb(const float bandEnergyDb[kSceneNumBands],
                          const float noiseFloorDb[kSceneNumBands]) const;

    /// Empuja band_energy actual al ringbuffer LTSD.
    void pushLtsdHistory(const float bandEnergyDb[kSceneNumBands]);

    /// LTSD = pico (sobre la ventana) - piso de ruido, promediado en
    /// bandas vocales. En dB.
    float computeLtsdDb(const float noiseFloorDb[kSceneNumBands]) const;

    /// Empuja band_energy actual al ringbuffer de stationarity.
    void pushStatHistory(const float bandEnergyDb[kSceneNumBands]);

    /// Stationarity = 1 - clamp(varianza_promedio / 50.0, 0, 1).
    /// Cerca de 1 → ruido muy estacionario (ventilador, AC).
    /// Cerca de 0 → señal modulada (voz, música).
    float computeStationarity() const;

    /// ZCR sobre el buffer pre-blanqueado del último frame.
    /// Devuelve cruces / (numSamples - 1) ∈ [0, 1].
    /// Voz vocal: ≈ 0.005-0.025. Respiración / fricativas: > 0.04.
    float computeZcr(const float* samples, int numSamples) const;

    /// Sigmoid logística usada para mapear el LRT a [0,1].
    static float sigmoid(float x);

    // ─── Estado ─────────────────────────────────────────────────────────
    int sampleRate_ = 48000;
    int minLag_     = 0;
    int maxLag_     = 0;

    // Pitch buffer + HPF state
    float pitchBuffer_[kPitchBufferSize] = {0};
    int   samplesAccumulated_            = 0;
    float hpfXPrev_                      = 0.0f;
    float hpfYPrev_                      = 0.0f;

    // Decision-directed a-priori SNR per banda (lineal)
    float xiPrev_[kSceneNumBands] = {0};

    // Ringbuffers
    float ltsdHistory_[kLtsdWindow][kSceneNumBands] = {{0}};
    int   ltsdIdx_  = 0;
    int   ltsdFill_ = 0;

    float statHistory_[kStatWindow][kSceneNumBands] = {{0}};
    int   statIdx_  = 0;
    int   statFill_ = 0;

    // Outputs / state
    float smoothedScore_ = 0.0f;
    float pitchStrength_ = 0.0f;
    float lrtScore_      = 0.0f;
    float midSnrDb_      = 0.0f;
    float ltsdDb_        = 0.0f;
    float stationarity_  = 0.0f;
    int   hangover_      = 0;
    bool  voiceActive_   = false;
    bool  hangoverActive_ = false;

    // Anti-transitorios: detector de impulso + counter de sustain.
    int   impulseHoldoff_ = 0;     ///< Frames restantes bloqueando voice_active.
    int   onsetSustain_   = 0;     ///< Frames consecutivos con score alto.
    int   voicingSustain_ = 0;     ///< Frames consecutivos con pitch sostenido.
    float prevEnergyDb_   = -90.0f;

    // Anti-respiración / roce / fricativa sostenida.
    int   flatnessHighStreak_ = 0; ///< Frames consecutivos con flatness alta.
    float zcrRatio_           = 0.0f; ///< ZCR del último bloque [0, 1].
    uint8_t pitchHistory_[kPitchDensityWindow] = {0}; ///< 0/1 por frame.
    int   pitchHistIdx_       = 0;
    int   pitchHistFill_      = 0;
    float pitchDensity_       = 0.0f; ///< Densidad de frames con pitch fuerte.
};

} // namespace smart_scene

#endif // HEARING_AID_SMART_SCENE_VAD_DETECTOR_H

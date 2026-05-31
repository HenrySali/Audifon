/// @file scene_analyzer.h
/// @brief Orquestador del Smart Scene Engine — Fase 1.
///
/// Encapsula:
/// - Acumulador de muestras hacia un buffer FFT.
/// - FFT radix-2 in-place y ventana Hann.
/// - SpectralFeatures sobre la magnitud lineal.
/// - VadDetector pitch-based (paper Springer 2019).
/// - NoiseProfile (minimum statistics simplificado).
/// - SceneSnapshot atómico para lectura desde Dart.
///
/// Diseñado para llamarse desde el callback de audio (DspPipeline). El estado
/// se publica en un `std::atomic<SceneSnapshot>` (POD) para lectura sin lock
/// desde otros hilos.
///
/// FASE 1: la clasificación devuelve siempre SceneClass::UNKNOWN — el
/// decision maker se implementa en Fase 2 según `tasks.md`.
///
/// Validates: Requirements 1.1, 6.2, 7.1

#ifndef HEARING_AID_SMART_SCENE_SCENE_ANALYZER_H
#define HEARING_AID_SMART_SCENE_SCENE_ANALYZER_H

#include <atomic>
#include <chrono>
#include <cstdint>

#include "scene_types.h"
#include "spectral_features.h"
#include "vad_detector.h"
#include "noise_profile.h"

namespace smart_scene {

class SceneAnalyzer {
public:
    SceneAnalyzer();
    ~SceneAnalyzer() = default;

    SceneAnalyzer(const SceneAnalyzer&) = delete;
    SceneAnalyzer& operator=(const SceneAnalyzer&) = delete;

    /// Inicializa el analyzer con sample rate y offset SPL.
    /// El offset SPL es el mismo del DspPipeline (compatibilidad con la
    /// calibración existente del audífono).
    void init(int sampleRate, float splOffset);

    /// Procesa un bloque del callback de audio. Hace push al buffer FFT,
    /// dispara una FFT cuando se llena, y publica un nuevo snapshot.
    /// Llamado desde el hilo de audio.
    /// @param block Bloque de audio mono float [-1, 1].
    /// @param numSamples Cantidad de samples en el bloque.
    void process(const float* block, int numSamples);

    /// Devuelve una copia del snapshot más reciente (thread-safe).
    SceneSnapshot getSnapshot() const;

    /// Reinicia todo el estado interno.
    void reset();

    /// Configura el offset SPL (cuando cambia la calibración).
    void setSplOffset(float offset);

private:
    /// Tamaño del FFT — coincide con kSceneFftSize.
    static constexpr int kFftSize = kSceneFftSize;

    /// Cantidad de bloques que dejamos pasar entre FFTs (1 = cada bloque).
    /// Si performance se queda corto, este factor sube a 2 para hacer FFT
    /// cada 2 bloques (ver design.md y reglas técnicas).
    static constexpr int kFftDecimation = 1;

    /// Computa la FFT in-place sobre fftBuffer_.
    /// Aplica ventana Hann, bit-reversal y radix-2 butterfly.
    void computeFft();

    /// Calcula el RMS lineal de un buffer.
    static float computeRms(const float* buffer, int numSamples);

    /// Convierte RMS lineal a dB SPL usando splOffset_.
    float rmsToDbSpl(float rmsLinear) const;

    /// Convierte dB SPL a RMS lineal (utility).
    float dbSplToRms(float dbSpl) const;

    /// Promedia magnitudes en 12 bandas EQ y entrega el array por banda.
    void buildBandEnergies(float bandsDb[kSceneNumBands]) const;

    /// Publica el snapshot atómicamente.
    void publishSnapshot(const SceneSnapshot& snap);

    /// Microsegundos transcurridos desde init().
    uint64_t getElapsedUs() const;

    // ─── Estado de configuración ─────────────────────────────────────────
    int sampleRate_ = 48000;
    float splOffset_ = 93.0f;
    bool initialized_ = false;

    // ─── Buffer FFT y ventana Hann ───────────────────────────────────────
    float fftBuffer_[kFftSize];
    float fftReal_[kFftSize];
    float fftImag_[kFftSize];
    float hannWindow_[kFftSize];
    float magnitude_[kSceneFftBins];
    float prevMagnitude_[kSceneFftBins];
    int fftBufferPos_ = 0;
    int blockCounter_ = 0;
    bool hasPrevMagnitude_ = false;

    // ─── Submódulos ──────────────────────────────────────────────────────
    VadDetector vad_;
    NoiseProfile noise_;

    // ─── Snapshot publicado (lock-free) ──────────────────────────────────
    /// Doble buffer atómico: escribimos por completo en `pendingSnapshot_`
    /// y luego hacemos store() en `currentSnapshot_`. Para tipos POD lo
    /// más simple es proteger las lecturas con un seqlock simple.
    /// Aquí usamos std::atomic<SceneSnapshot> que el compilador promueve
    /// a lock-free para POD ≤ 16 bytes en muchas plataformas; para 100+
    /// bytes recurrimos a un seqlock.
    mutable std::atomic<uint32_t> seq_{0};
    SceneSnapshot snapshot_{};

    // ─── Tiempo ──────────────────────────────────────────────────────────
    std::chrono::steady_clock::time_point startTime_;
};

} // namespace smart_scene

#endif // HEARING_AID_SMART_SCENE_SCENE_ANALYZER_H

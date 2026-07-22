/// @file artifact_monitor.h
/// @brief Detector RT-safe de "matraca" (clicks/crackle) + métricas de calidad
///        para un punto de medición (tap) de la cadena de audio.
///
/// La "matraca" (a.k.a. "tktktkt", crackle, chasquidos) se manifiesta como
/// discontinuidades impulsivas en la forma de onda: saltos abruptos entre
/// muestras contiguas, picos de curvatura (segunda diferencia), clipping o
/// valores no finitos (NaN/Inf) producidos por un módulo DSP inestable.
///
/// Este monitor analiza un buffer mono float32 [-1,+1] SIN modificarlo y
/// acumula estadísticas de forma lock-free. Está diseñado para llamarse desde
/// el hilo de audio (0 alloc, 0 lock) y ser leído desde el hilo de control
/// vía `snapshot()`. Un ArtifactMonitor mide UN tap; el DenoiserArtifactLog
/// (denoiser_artifact_log.h) combina varios taps (entrada, cada sistema de
/// limpieza, salida final) para atribuir el origen de la matraca.
///
/// Modelo de hilos:
///   - configure()/reset(): hilo de control, con el audio detenido.
///   - feed(): SOLO hilo de audio (único productor).
///   - snapshot(): cualquier hilo (consumidor). Lecturas benignas (worst-case
///     stale por 1 bloque), igual que el resto del motor (ring de diagnóstico).

#ifndef HEARING_AID_ARTIFACT_MONITOR_H
#define HEARING_AID_ARTIFACT_MONITOR_H

#include <atomic>
#include <algorithm>
#include <cmath>
#include <cstdint>

/// Snapshot POD de las métricas acumuladas de un tap.
struct ArtifactSnapshot {
    uint64_t blocks       = 0;   ///< Bloques procesados.
    uint64_t samples      = 0;   ///< Muestras procesadas.
    uint64_t clickCount   = 0;   ///< Muestras marcadas como click/crackle.
    uint64_t clipCount    = 0;   ///< Muestras en clipping (|x| ≥ ~1.0).
    uint64_t nanInfCount  = 0;   ///< Muestras NaN/Inf (falla numérica grave).
    float    maxAbsJump   = 0.0f;///< Mayor salto |x[n]-x[n-1]| de la sesión.
    float    lastRmsDbfs  = -120.0f; ///< RMS del último bloque (dBFS).
    float    lastPeakDbfs = -120.0f; ///< Pico del último bloque (dBFS).
    float    meanRmsDbfs  = -120.0f; ///< RMS medio de la sesión (dBFS).
    float    lastQuality  = 100.0f;  ///< Calidad del último bloque [0,100].
    float    worstQuality = 100.0f;  ///< Peor calidad de bloque de la sesión.
    float    sessionQuality = 100.0f;///< Calidad agregada de toda la sesión.
    double   elapsedSec   = 0.0;     ///< Tiempo de audio procesado (s).
    double   clicksPerSec = 0.0;     ///< Tasa de clicks (eventos/s).
    double   worstEventSec = 0.0;    ///< Instante del peor bloque (s).
    float    worstEventJump = 0.0f;  ///< Salto máx en el peor bloque.
    bool     active       = false;   ///< true si se procesó al menos 1 bloque.
};

/// Detector de artefactos + calidad para un tap de la cadena DSP.
class ArtifactMonitor {
public:
    ArtifactMonitor() { reset(); }

    /// Configura la frecuencia de muestreo y resetea el estado.
    void configure(int sampleRate) {
        sampleRate_ = (sampleRate > 0) ? sampleRate : 48000;
        reset();
    }

    /// Resetea todos los contadores y el estado interno (hilo de control).
    void reset() {
        blocks_.store(0, std::memory_order_relaxed);
        samples_.store(0, std::memory_order_relaxed);
        clickCount_.store(0, std::memory_order_relaxed);
        clipCount_.store(0, std::memory_order_relaxed);
        nanInfCount_.store(0, std::memory_order_relaxed);
        maxAbsJump_.store(0.0f, std::memory_order_relaxed);
        lastRmsDbfs_.store(-120.0f, std::memory_order_relaxed);
        lastPeakDbfs_.store(-120.0f, std::memory_order_relaxed);
        sumRmsLin_.store(0.0, std::memory_order_relaxed);
        lastQuality_.store(100.0f, std::memory_order_relaxed);
        worstQuality_.store(100.0f, std::memory_order_relaxed);
        worstEventSec_.store(0.0, std::memory_order_relaxed);
        worstEventJump_.store(0.0f, std::memory_order_relaxed);
        prev1_ = 0.0f;
        prev2_ = 0.0f;
        hasPrev_ = false;
        rmsEnv_ = 1e-4f;
    }

    /// Alimenta un bloque mono float32. SOLO desde el hilo de audio.
    /// No modifica `buf`.
    void feed(const float* buf, int n) {
        if (buf == nullptr || n <= 0) return;

        double sumSq = 0.0;
        float  peak  = 0.0f;
        uint64_t clicks = 0, clips = 0, nans = 0;
        float  localMaxJump = 0.0f;

        float p1 = prev1_, p2 = prev2_;
        bool  hp = hasPrev_;
        float env = rmsEnv_;

        for (int i = 0; i < n; ++i) {
            float x = buf[i];

            // ─── Falla numérica: NaN/Inf ⇒ matraca garantizada ──────────
            if (!std::isfinite(x)) {
                ++nans;
                x = 0.0f;  // tratamos como 0 para no envenenar el estado local
            }

            const float ax = std::fabs(x);
            if (ax > peak) peak = ax;
            sumSq += static_cast<double>(x) * static_cast<double>(x);

            // ─── Clipping ───────────────────────────────────────────────
            if (ax >= kClipThreshold) ++clips;

            // ─── Click/crackle: 1ª y 2ª diferencia con umbral adaptativo ─
            if (hp) {
                const float d1  = x - p1;               // 1ª diferencia (salto)
                const float ad1 = std::fabs(d1);
                if (ad1 > localMaxJump) localMaxJump = ad1;

                const float d2  = x - 2.0f * p1 + p2;   // 2ª diferencia (impulso)
                const float ad2 = std::fabs(d2);

                // Umbral relativo al envelope lento de |x| (evita falsos
                // positivos con voz/transientes naturales) más un piso
                // absoluto (para señales de bajo nivel donde env≈0).
                const float thr = kClickRelFactor * env + kClickAbsFloor;
                if (ad2 > thr && ad1 > kClickAbsMin) {
                    ++clicks;
                }
            }

            p2 = p1;
            p1 = x;
            hp = true;

            // Envelope lento del nivel |x| (~sample-by-sample, tau largo).
            env += kEnvCoeff * (ax - env);
        }

        prev1_   = p1;
        prev2_   = p2;
        hasPrev_ = hp;
        rmsEnv_  = env;

        const float rms  = std::sqrt(static_cast<float>(sumSq / static_cast<double>(n)));
        const float rmsDb  = 20.0f * std::log10(std::max(rms,  1e-10f));
        const float peakDb = 20.0f * std::log10(std::max(peak, 1e-10f));

        // ─── Actualizar acumuladores atómicos (único productor) ─────────
        const uint64_t totalSamples = samples_.load(std::memory_order_relaxed)
                                      + static_cast<uint64_t>(n);
        blocks_.fetch_add(1, std::memory_order_relaxed);
        samples_.store(totalSamples, std::memory_order_relaxed);
        if (clicks) clickCount_.fetch_add(clicks, std::memory_order_relaxed);
        if (clips)  clipCount_.fetch_add(clips,   std::memory_order_relaxed);
        if (nans)   nanInfCount_.fetch_add(nans,  std::memory_order_relaxed);

        if (localMaxJump > maxAbsJump_.load(std::memory_order_relaxed)) {
            maxAbsJump_.store(localMaxJump, std::memory_order_relaxed);
        }
        lastRmsDbfs_.store(rmsDb, std::memory_order_relaxed);
        lastPeakDbfs_.store(peakDb, std::memory_order_relaxed);
        sumRmsLin_.store(sumRmsLin_.load(std::memory_order_relaxed) + rms,
                         std::memory_order_relaxed);

        // ─── Calidad del bloque + registro del peor evento ──────────────
        const float q = blockQuality(clicks, clips, nans, n);
        lastQuality_.store(q, std::memory_order_relaxed);
        if (q < worstQuality_.load(std::memory_order_relaxed)) {
            worstQuality_.store(q, std::memory_order_relaxed);
            worstEventSec_.store(
                static_cast<double>(totalSamples) / static_cast<double>(sampleRate_),
                std::memory_order_relaxed);
            worstEventJump_.store(localMaxJump, std::memory_order_relaxed);
        }
    }

    /// Toma un snapshot consistente de las métricas (cualquier hilo).
    ArtifactSnapshot snapshot() const {
        ArtifactSnapshot s;
        s.blocks      = blocks_.load(std::memory_order_relaxed);
        s.samples     = samples_.load(std::memory_order_relaxed);
        s.clickCount  = clickCount_.load(std::memory_order_relaxed);
        s.clipCount   = clipCount_.load(std::memory_order_relaxed);
        s.nanInfCount = nanInfCount_.load(std::memory_order_relaxed);
        s.maxAbsJump  = maxAbsJump_.load(std::memory_order_relaxed);
        s.lastRmsDbfs = lastRmsDbfs_.load(std::memory_order_relaxed);
        s.lastPeakDbfs= lastPeakDbfs_.load(std::memory_order_relaxed);
        s.lastQuality = lastQuality_.load(std::memory_order_relaxed);
        s.worstQuality= worstQuality_.load(std::memory_order_relaxed);
        s.worstEventSec = worstEventSec_.load(std::memory_order_relaxed);
        s.worstEventJump= worstEventJump_.load(std::memory_order_relaxed);

        const double sumRms = sumRmsLin_.load(std::memory_order_relaxed);
        s.meanRmsDbfs = (s.blocks > 0)
            ? 20.0f * std::log10(std::max(
                  static_cast<float>(sumRms / static_cast<double>(s.blocks)), 1e-10f))
            : -120.0f;
        s.elapsedSec = (sampleRate_ > 0)
            ? static_cast<double>(s.samples) / static_cast<double>(sampleRate_)
            : 0.0;
        s.clicksPerSec = (s.elapsedSec > 1e-6)
            ? static_cast<double>(s.clickCount) / s.elapsedSec
            : 0.0;
        s.sessionQuality = sessionQuality(s.clickCount, s.clipCount,
                                          s.nanInfCount, s.samples);
        s.active = (s.blocks > 0);
        return s;
    }

    /// Calidad agregada [0,100] a partir de contadores totales de una sesión.
    /// 100 = sin artefactos; baja con la tasa de clicks, clipping y NaN/Inf.
    static float sessionQuality(uint64_t clicks, uint64_t clips,
                                uint64_t nanInf, uint64_t samples) {
        if (samples == 0) return 100.0f;
        const double clicksPerK = static_cast<double>(clicks)
                                  / static_cast<double>(samples) * 1000.0;
        const double clipFrac   = static_cast<double>(clips)
                                  / static_cast<double>(samples);
        float q = 100.0f;
        q -= static_cast<float>(std::min(70.0, clicksPerK * 40.0));
        q -= static_cast<float>(std::min(25.0, clipFrac * 300.0));
        if (nanInf > 0) q -= 40.0f;
        return (q < 0.0f) ? 0.0f : q;
    }

private:
    /// Calidad de un solo bloque (para detectar spikes puntuales).
    float blockQuality(uint64_t clicks, uint64_t clips,
                       uint64_t nans, int n) const {
        return sessionQuality(clicks, clips, nans, static_cast<uint64_t>(n));
    }

    // ─── Parámetros del detector (constantes de diseño) ─────────────────
    /// Umbral de clipping (|x| ≥ este valor cuenta como clip).
    static constexpr float kClipThreshold  = 0.999f;
    /// Coeficiente del envelope lento de |x| (~tau de varios ms).
    static constexpr float kEnvCoeff       = 0.001f;
    /// Factor relativo: la 2ª diferencia debe superar N× el envelope.
    static constexpr float kClickRelFactor = 6.0f;
    /// Piso absoluto del umbral de la 2ª diferencia (señales de bajo nivel).
    static constexpr float kClickAbsFloor  = 0.05f;
    /// Salto mínimo |x[n]-x[n-1]| para considerar click (anti falsos +).
    static constexpr float kClickAbsMin    = 0.08f;

    int sampleRate_ = 48000;

    // ─── Estado audio-thread-only (no atómico) ──────────────────────────
    float prev1_ = 0.0f;   ///< x[n-1] entre bloques.
    float prev2_ = 0.0f;   ///< x[n-2] entre bloques.
    bool  hasPrev_ = false;
    float rmsEnv_ = 1e-4f; ///< Envelope lento de |x|.

    // ─── Acumuladores atómicos (1 productor / N consumidores) ───────────
    std::atomic<uint64_t> blocks_{0};
    std::atomic<uint64_t> samples_{0};
    std::atomic<uint64_t> clickCount_{0};
    std::atomic<uint64_t> clipCount_{0};
    std::atomic<uint64_t> nanInfCount_{0};
    std::atomic<float>    maxAbsJump_{0.0f};
    std::atomic<float>    lastRmsDbfs_{-120.0f};
    std::atomic<float>    lastPeakDbfs_{-120.0f};
    std::atomic<double>   sumRmsLin_{0.0};
    std::atomic<float>    lastQuality_{100.0f};
    std::atomic<float>    worstQuality_{100.0f};
    std::atomic<double>   worstEventSec_{0.0};
    std::atomic<float>    worstEventJump_{0.0f};
};

#endif  // HEARING_AID_ARTIFACT_MONITOR_H

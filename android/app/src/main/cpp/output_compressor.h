/// @file output_compressor.h
/// @brief Compresor / soft-limiter de SALIDA — freno de amplificación pre-MPO.
///
/// Problema que resuelve (Causa A, residual de saturación):
///   El WDRC decide la compresión con el nivel PRE-EQ. Por lo tanto, la
///   amplificación que meten el EQ (prescripción alta) y el Volume (+10 dB)
///   llega al final de la cadena SIN que ningún compresor la controle según el
///   nivel REAL de salida. El único freno que queda es el MPO, que es un
///   limitador de techo duro (hard-clamp): cuando la señal le pega fuerte
///   recorta los picos muestra-a-muestra → genera armónicos (THD) → se escucha
///   como un "silbido de saturación" residual al subir ganancias / cambiar
///   preset / ambiente.
///
/// Estrategia (header-only, solo atenúa, activo por default como TNR/FBS):
///   Un compresor feed-forward con DETECTOR DE ENVOLVENTE DE PICO que mira la
///   señal REAL que va a salir (post-EQ / post-Volume / post-FBS) y baja la
///   ganancia de forma SUAVE (soft-knee + ratio finito) ANTES de que la señal
///   llegue al MPO. Así:
///     - Los picos quedan por debajo del techo del MPO la mayor parte del
///       tiempo → el MPO casi nunca tiene que hacer hard-clamp → MUCHO menos THD.
///     - El MPO sigue intacto como red de seguridad DURA (garantía |y| ≤ techo).
///     - A nivel de conversación normal (~65 dB SPL) los picos no superan el
///       threshold → ganancia = 1.0 → TRANSPARENTE (no altera la voz).
///
/// Threshold: se ancla unos dB POR DEBAJO del techo del MPO (kHeadroom). El
/// pipeline lo re-deriva cada vez que cambia el threshold del MPO
/// (applyMpoThresholdFromDbSpl), así el freno "sigue" al MPO clínico del
/// paciente automáticamente (severa/moderada/leve) sin configuración extra.
///
/// Diseño DSP: ganancia derivada de la ENVOLVENTE (no del |sample|
/// instantáneo) + ratio finito + soft-knee → un tono sostenido se ESCALA de
/// forma uniforme (sigue sinusoidal) en vez de recortarse → THD ≈ 0 propio.
/// Mismo fundamento que el detector de envolvente del MPO (decisión D,
/// audifono-v3) pero con ratio finito y knee suave en vez de hard-clamp.
///
/// Solo atenúa (gain ∈ (0, 1]) → seguro para las 3 apps (técnico/paciente/V3).
/// Se inserta DESPUÉS del Volume + FBS y ANTES del MPO.
///
/// Referencias: compresión WDRC vs peak-clipping y desempeño armónico bajo SPL
/// altos (Harmonic/IMD performance of hearing aids, ScienceDirect 2009;
/// Compression Hearing Aids, PMC4172289); curva estática soft-knee
/// (Zölzer, DAFX; Reiss & McPherson, Audio Effects).

#ifndef HEARING_AID_OUTPUT_COMPRESSOR_H
#define HEARING_AID_OUTPUT_COMPRESSOR_H

#include <atomic>
#include <cmath>

/// Compresor / soft-limiter de salida (freno de amplificación pre-MPO).
///
/// Uso típico:
/// @code
///   OutputCompressor oc;
///   oc.init(16000);
///   oc.setEnabled(true);
///   oc.setThresholdLinear(0.0675f); // ETAPA 1: 22 dB bajo el techo del MPO
///   oc.process(buffer, blockSize); // in-place, post-FBS / pre-MPO
/// @endcode
class OutputCompressor {
public:
    OutputCompressor() = default;
    ~OutputCompressor() = default;

    /// Inicializa con el sample rate del sistema.
    /// @param sampleRate Hz (típicamente 16000 o 48000)
    void init(int sampleRate) {
        sampleRate_ = (sampleRate > 0) ? sampleRate : 16000;

        // Detector de envolvente de pico:
        //  - attack 5 ms: lo bastante rápido para atrapar el ataque de un
        //    sonido fuerte ANTES de que el MPO tenga que recortar.
        //  - release 80 ms: ≫ período de la voz/tono → la ganancia no sigue el
        //    rizado intra-ciclo (eso reintroduciría THD) y evita bombeo/pumping.
        attackCoeff_  = 1.0f - std::exp(-1.0f / (kAttackSec  * sampleRate_));
        releaseCoeff_ = 1.0f - std::exp(-1.0f / (kReleaseSec * sampleRate_));

        // Reset de estado.
        env_ = 0.0f;
        gainLin_ = 1.0f;
        currentGain_.store(1.0f, std::memory_order_relaxed);
        lastReductionFraction_.store(0.0f, std::memory_order_relaxed);
    }

    /// Procesa un bloque de audio in-place. SOLO atenúa (gain ≤ 1).
    /// @param buffer Audio float32 [-1.0, +1.0]
    /// @param blockSize Número de muestras
    void process(float* buffer, int blockSize) {
        if (!enabled_.load(std::memory_order_relaxed)) return;
        if (buffer == nullptr || blockSize <= 0) return;

        const float thLin = thresholdLinear_.load(std::memory_order_relaxed);
        if (thLin <= 0.0f) return; // threshold inválido → no tocar (seguridad)

        const float thDb    = 20.0f * std::log10(thLin);
        const float ratio   = ratio_.load(std::memory_order_relaxed);
        const float kneeDb  = kneeDb_.load(std::memory_order_relaxed);
        const float slope   = 1.0f - 1.0f / ratio;  // pendiente de reducción
        const float halfKnee = 0.5f * kneeDb;

        int reducedSamples = 0;

        for (int i = 0; i < blockSize; ++i) {
            const float x = buffer[i];
            const float ax = std::fabs(x);

            // Envolvente de pico: attack rápido (sube), release lento (baja).
            if (ax > env_) {
                env_ += attackCoeff_ * (ax - env_);
            } else {
                env_ += releaseCoeff_ * (ax - env_);
            }

            // Curva estática soft-knee → ganancia objetivo en dB (≤ 0).
            float targetGainDb = 0.0f;
            if (env_ > 1e-9f) {
                const float levelDb = 20.0f * std::log10(env_);
                const float over = levelDb - thDb; // dB por encima del threshold
                if (over <= -halfKnee) {
                    targetGainDb = 0.0f;                  // bajo el knee: transparente
                } else if (over >= halfKnee) {
                    targetGainDb = -slope * over;         // sobre el knee: compresión plena
                } else {
                    // Región del knee: transición cuadrática suave.
                    const float t = over + halfKnee;      // 0 .. kneeDb
                    targetGainDb = -slope * (t * t) / (2.0f * kneeDb);
                }
            }

            // La ganancia se deriva directamente de la envolvente (ya suavizada
            // por el peak-follower) → sin zipper, sin segundo suavizado.
            float gain = (targetGainDb < 0.0f)
                       ? std::pow(10.0f, targetGainDb / 20.0f)
                       : 1.0f;
            if (gain > 1.0f) gain = 1.0f;  // NUNCA amplifica
            if (gain < 0.0f) gain = 0.0f;
            gainLin_ = gain;

            if (gain < 0.999f) reducedSamples++;

            buffer[i] = x * gain;
        }

        currentGain_.store(gainLin_, std::memory_order_relaxed);
        lastReductionFraction_.store(
            static_cast<float>(reducedSamples) / static_cast<float>(blockSize),
            std::memory_order_relaxed);
    }

    /// Habilita/deshabilita el compresor de salida (thread-safe). Default: ON.
    void setEnabled(bool enabled) {
        enabled_.store(enabled, std::memory_order_relaxed);
    }
    bool isEnabled() const {
        return enabled_.load(std::memory_order_relaxed);
    }

    /// Fija el threshold en amplitud lineal. El pipeline lo ancla unos dB por
    /// debajo del techo del MPO para que el freno actúe ANTES que el hard-clamp.
    /// @param linear Threshold lineal (> 0). Valores ≤ 0 se ignoran (seguridad).
    void setThresholdLinear(float linear) {
        if (linear > 0.0f && std::isfinite(linear)) {
            thresholdLinear_.store(linear, std::memory_order_relaxed);
        }
    }
    float getThresholdLinear() const {
        return thresholdLinear_.load(std::memory_order_relaxed);
    }

    /// Ratio de compresión (input:output) por encima del threshold.
    /// Default: 10.0 (10:1). Rango: 2.0 (suave) a 20.0 (casi limitador).
    void setRatio(float ratio) {
        if (ratio < 1.5f) ratio = 1.5f;
        if (ratio > 20.0f) ratio = 20.0f;
        ratio_.store(ratio, std::memory_order_relaxed);
    }
    float getRatio() const {
        return ratio_.load(std::memory_order_relaxed);
    }

    /// Ancho del soft-knee en dB. Default: 6 dB. 0 = hard-knee.
    void setKneeDb(float kneeDb) {
        if (kneeDb < 0.0f) kneeDb = 0.0f;
        if (kneeDb > 24.0f) kneeDb = 24.0f;
        kneeDb_.store(kneeDb, std::memory_order_relaxed);
    }
    float getKneeDb() const {
        return kneeDb_.load(std::memory_order_relaxed);
    }

    // --- Diagnóstico (lectura desde hilo de UI) ---

    /// Última ganancia aplicada (1.0 = sin compresión).
    float getCurrentGain() const {
        return currentGain_.load(std::memory_order_relaxed);
    }
    /// Fracción [0,1] de muestras del último bloque que el compresor atenuó.
    float getReductionFraction() const {
        return lastReductionFraction_.load(std::memory_order_relaxed);
    }

private:
    // --- Constantes de diseño (tiempos del detector de envolvente) ---
    /// Attack del peak-follower (5 ms): atrapa el ataque del sonido fuerte.
    static constexpr float kAttackSec  = 0.005f;
    /// Release del peak-follower (80 ms): ≫ período de voz → sin rizado/bombeo.
    static constexpr float kReleaseSec = 0.080f;

    // --- Configuración del sistema ---
    int sampleRate_ = 16000;
    float attackCoeff_ = 0.0f;
    float releaseCoeff_ = 0.0f;

    // --- Estado del detector (audio thread) ---
    float env_ = 0.0f;
    float gainLin_ = 1.0f;

    // --- Parámetros atómicos (UI thread settable) ---
    std::atomic<bool>  enabled_{true};
    /// Default standalone (sin pipeline): ≈ kMpoDigitalCeiling (0.85) ×
    /// 0.0794 ≈ 0.0675, equivalente a 22 dB de headroom contra el techo
    /// digital. ETAPA 1 ShaMPO broadband: 12 dB crest factor habla + 10.8 dB
    /// suma RMS multitono N=12. NOTA: cuando el módulo se usa dentro de
    /// DspPipeline (caso real), este valor se override en init() vía
    /// applyMpoThresholdFromDbSpl(), que ancla el threshold al techo MPO
    /// clínico del paciente con el mismo headroom.
    std::atomic<float> thresholdLinear_{0.0675f};
    std::atomic<float> ratio_{10.0f};           ///< 10:1
    std::atomic<float> kneeDb_{6.0f};           ///< soft-knee 6 dB

    // --- Diagnóstico (UI thread readable) ---
    std::atomic<float> currentGain_{1.0f};
    std::atomic<float> lastReductionFraction_{0.0f};
};

#endif // HEARING_AID_OUTPUT_COMPRESSOR_H

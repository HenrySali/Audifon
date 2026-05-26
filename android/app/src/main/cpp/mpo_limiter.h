/// @file mpo_limiter.h
/// @brief Limitador MPO (Maximum Power Output) de picos muestra-por-muestra.
/// Red de seguridad absoluta — ÚLTIMA etapa del pipeline antes de la salida.
/// Garantiza que ninguna muestra excede el threshold configurado.
///
/// Diseño:
/// - Threshold: 100 dB SPL equivalente (configurable vía setThreshold)
/// - Attack: 0.5 ms (< 1 ms = < 16 muestras a 16 kHz)
/// - Release: 10 ms (recuperación lenta a ganancia unitaria)
/// - Ganancia ≤ 1.0 — MPO nunca amplifica
/// - Hard-clamp final como garantía absoluta de seguridad
///
/// Invariante crítico: |output[i]| ≤ thresholdLinear para TODA muestra.

#ifndef HEARING_AID_MPO_LIMITER_H
#define HEARING_AID_MPO_LIMITER_H

#include <atomic>
#include <cmath>

/// Limitador de picos muestra-por-muestra.
///
/// Algoritmo:
/// 1. Para cada muestra, si |sample| > threshold → attack rápido hacia ganancia objetivo
/// 2. Si |sample| ≤ threshold → release lento hacia ganancia unitaria (1.0)
/// 3. Aplicar ganancia suavizada a la muestra
/// 4. Hard-clamp final: si |output| > threshold → copysign(threshold, output)
///
/// El hard-clamp garantiza seguridad incluso durante el transitorio de attack
/// donde la ganancia suavizada podría no haber convergido completamente.
class MpoLimiter {
public:
    /// Constructor. Inicializa con parámetros por defecto:
    /// - Threshold: 100 dB SPL con offset 120 → -20 dBFS → 0.1 lineal
    /// - Attack: 0.5 ms
    /// - Release: 10 ms
    /// - Sample rate: 16000 Hz
    MpoLimiter();
    ~MpoLimiter() = default;

    /// Inicializa el limitador con sample rate específico.
    /// Recalcula coeficientes de attack/release.
    /// @param sampleRate Frecuencia de muestreo en Hz (default: 16000)
    void init(int sampleRate);

    /// Procesa un bloque de audio aplicando limitación de picos in-place.
    /// Opera muestra-por-muestra dentro del bloque.
    /// Garantiza: |buffer[i]| ≤ thresholdLinear después del procesamiento.
    /// @param buffer Puntero al buffer de audio float32
    /// @param blockSize Número de muestras en el buffer
    void process(float* buffer, int blockSize);

    /// Establece el threshold del MPO en dB SPL.
    /// Se convierte internamente a amplitud lineal usando el offset SPL.
    /// @param thresholdDbSpl Threshold en dB SPL (default: 100)
    /// @param splOffset Offset dBFS→dB SPL (default: 120 para mic real)
    void setThreshold(float thresholdDbSpl, float splOffset);

    /// Establece el threshold directamente en amplitud lineal.
    /// Útil para testing o cuando ya se tiene el valor lineal calculado.
    /// @param linear Threshold en amplitud lineal (debe ser > 0)
    void setThresholdLinear(float linear);

    /// Obtiene el threshold actual en amplitud lineal.
    /// @return Threshold lineal actual
    float getThresholdLinear() const;

    /// Obtiene la ganancia actual del limitador (para diagnóstico).
    /// @return Ganancia actual ∈ (0.0, 1.0]
    float getCurrentGain() const;

    /// Resetea el estado interno del limitador (ganancia a 1.0).
    /// Útil al cambiar de configuración o reiniciar el pipeline.
    void reset();

private:
    /// Calcula coeficientes de attack/release basados en tiempos y sample rate.
    void computeCoefficients();

    // --- Parámetros (thread-safe) ---

    /// Threshold en amplitud lineal (default: 10^((100-120)/20) = 0.1)
    std::atomic<float> thresholdLinear_{0.1f};

    // --- Estado interno (solo accedido desde hilo de audio) ---

    /// Ganancia actual del limitador. Siempre ∈ (0.0, 1.0].
    /// Empieza en 1.0 (sin limitación). Solo decrece cuando se detecta pico.
    float gain_ = 1.0f;

    /// Coeficiente de attack (convergencia rápida hacia ganancia objetivo).
    /// attackCoeff = 1 - exp(-1 / (attackTimeSec * sampleRate))
    /// Para 0.5 ms @ 16 kHz: ≈ 0.1175
    float attackCoeff_ = 0.1175f;

    /// Coeficiente de release (recuperación lenta hacia ganancia unitaria).
    /// releaseCoeff = 1 - exp(-1 / (releaseTimeSec * sampleRate))
    /// Para 10 ms @ 16 kHz: ≈ 0.00625
    float releaseCoeff_ = 0.00625f;

    // --- Configuración ---

    /// Sample rate en Hz (para cálculo de coeficientes)
    int sampleRate_ = 16000;

    /// Tiempo de attack en segundos (0.5 ms = 0.0005 s)
    static constexpr float kAttackTimeSec = 0.0005f;

    /// Tiempo de release en segundos (10 ms = 0.01 s)
    static constexpr float kReleaseTimeSec = 0.01f;
};

#endif // HEARING_AID_MPO_LIMITER_H

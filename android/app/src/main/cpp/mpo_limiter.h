/// @file mpo_limiter.h
/// @brief Limitador MPO (Maximum Power Output) con detector de envolvente.
/// Red de seguridad absoluta — ÚLTIMA etapa del pipeline antes de la salida.
/// Garantiza que ninguna muestra excede el threshold configurado.
///
/// Diseño (decisión D audifono-v3, tarea 12.2 — anti-distorsión):
/// - Threshold: 100 dB SPL equivalente (configurable vía setThreshold)
/// - La ganancia se deriva de la ENVOLVENTE DE PICO de la señal (peak-follower
///   con attack 3 ms / release 50 ms), NO del |sample| instantáneo. Así un
///   sonido fuerte sostenido se escala de forma uniforme (sigue siendo
///   sinusoidal) en vez de recortarse muestra-a-muestra → mucho menos THD.
/// - Ganancia ≤ 1.0 — MPO nunca amplifica.
/// - Hard-clamp final como garantía absoluta de seguridad (instantánea e
///   independiente de los tiempos de envolvente): |output[i]| ≤ thresholdLinear.
///
/// Fundamento: bajo SPL altos el peak-clipping tiene el peor desempeño
/// armónico, mientras que una función entrada-salida compresiva (ganancia
/// derivada de la envolvente) tiene el mejor (lit. de desempeño armónico/IMD
/// en audífonos). Validado en tools/sim_v3/validate_antidistortion.py:
/// THD@1kHz 18.9% → 4.4% (objetivo ≤ 5%), manteniendo |y| ≤ techo.
///
/// Invariante crítico: |output[i]| ≤ thresholdLinear para TODA muestra.

#ifndef HEARING_AID_MPO_LIMITER_H
#define HEARING_AID_MPO_LIMITER_H

#include <atomic>
#include <cmath>

/// Limitador de picos muestra-por-muestra.
///
/// Algoritmo (detector de envolvente):
/// 1. Seguir la envolvente de pico |sample| con attack rápido / release lento.
/// 2. Ganancia objetivo = threshold / envolvente (si envolvente > threshold;
///    si no, 1.0). La envolvente es suave → la ganancia no oscila dentro del
///    ciclo → no se introduce distorsión armónica en régimen sostenido.
/// 3. Aplicar la ganancia a la muestra.
/// 4. Hard-clamp final: si |output| > threshold → copysign(threshold, output).
///
/// El hard-clamp garantiza seguridad de forma instantánea, incluso durante el
/// transitorio de attack de la envolvente (los primeros ms de un sonido fuerte
/// repentino), donde la ganancia aún no convergió.
class MpoLimiter {
public:
    /// Constructor. Inicializa con parámetros por defecto:
    /// - Threshold: 100 dB SPL con offset 120 → -20 dBFS → 0.1 lineal
    /// - Envolvente: attack 3 ms / release 50 ms (detector de pico)
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

    /// Establece el ancho de la RODILLA SUAVE (soft-knee) del limitador, en dB.
    /// FIX voz ronca (grabaciones Moto G32): el limitador reduce la ganancia de
    /// forma PROGRESIVA en la ventana [threshold·10^(-knee/2/20), threshold]
    /// (por DEBAJO del techo) en vez de recortar la onda de golpe. Por encima
    /// del knee se comporta como brickwall (ganancia = threshold/env) y el
    /// hard-clamp final sigue siendo la red de seguridad absoluta.
    /// - knee = 0 → comportamiento hard-clamp clásico (sin rodilla).
    /// - knee > 0 → compresión de rodilla cuadrática antes del techo.
    /// El INVARIANTE |output| ≤ thresholdLinear se mantiene siempre: la rodilla
    /// sólo actúa por debajo del techo, nunca lo eleva.
    /// @param kneeWidthDb Ancho de rodilla en dB (default seguro: 6 dB).
    void setKneeWidthDb(float kneeWidthDb);

    /// Obtiene el ancho de rodilla suave actual en dB.
    /// @return Ancho de rodilla ∈ [0, ∞).
    float getKneeWidthDb() const;

    /// Obtiene el threshold actual en amplitud lineal.
    /// @return Threshold lineal actual
    float getThresholdLinear() const;

    /// Obtiene la ganancia actual del limitador (para diagnóstico).
    /// @return Ganancia actual ∈ (0.0, 1.0]
    float getCurrentGain() const;

    /// Fracción de muestras del ÚLTIMO bloque procesado en las que el
    /// limitador estuvo activo (ganancia por debajo de kLimitingGainThreshold).
    /// Rango [0.0, 1.0]. Usado por el aviso de limitación de la app (R9.2).
    /// @return Fracción de muestras limitadas en el último bloque.
    float getLimitingFraction() const;

    /// Indica si el limitador estuvo actuando de forma SOSTENIDA (más de
    /// kSustainedLimitMs de limitación cuasi-continua). Es la señal que la
    /// app usa para mostrar el aviso visible de nivel cercano al límite de
    /// seguridad (Requirement 9.2 de audifono-v3).
    ///
    /// "Sostenido" = se acumularon ≥ kSustainedLimitMs de muestras
    /// consecutivas con ganancia < kLimitingGainThreshold (el contador de
    /// consecutivas cruza el umbral en algún punto del bloque). El estado se
    /// recalcula por bloque; el contador de consecutivas persiste entre
    /// bloques mientras la limitación no se interrumpa.
    /// @return true si hubo limitación sostenida en el último bloque.
    bool isLimitingSustained() const;

    /// Resetea el estado interno del limitador (ganancia a 1.0).
    /// Útil al cambiar de configuración o reiniciar el pipeline.
    void reset();

private:
    /// Calcula coeficientes de attack/release basados en tiempos y sample rate.
    void computeCoefficients();

    // --- Parámetros (thread-safe) ---

    /// Threshold en amplitud lineal (default: 10^((100-120)/20) = 0.1)
    std::atomic<float> thresholdLinear_{0.1f};

    /// Ancho de la rodilla suave (soft-knee) en dB. Default 6 dB: la ganancia
    /// empieza a reducirse ~3 dB por debajo del techo y llega a la reducción
    /// plena (brickwall) al alcanzarlo. Valor conservador que suaviza el
    /// recorte sin sacrificar headroom clínico. 0 → hard-clamp clásico.
    std::atomic<float> kneeWidthDb_{kDefaultKneeWidthDb};

    /// Ancho de rodilla por defecto (dB). Subido de 6 a 12 dB: con 6 dB los
    /// picos que exceden el techo por ~7 dB (medido en dispositivo) todavía
    /// entran al hard-clamp y distorsionan. Con 12 dB la rodilla empieza a
    /// comprimir 6 dB ANTES del techo → captura los 7 dB de exceso dentro de
    /// la zona de compresión progresiva sin recortar la onda (AGCo de salida,
    /// PMC4172289/PMC4172235: compression limiting preferido sobre peak clipping
    /// por menor distorsión armónica y mejor inteligibilidad; DSL v5 pediátrico
    /// recomienda ratios bajos + compression limiting para minimizar distorsión).
    static constexpr float kDefaultKneeWidthDb = 12.0f;

    // --- Estado interno (solo accedido desde hilo de audio) ---

    /// Ganancia actual del limitador. Siempre ∈ (0.0, 1.0].
    /// Empieza en 1.0 (sin limitación). Solo decrece cuando se detecta pico.
    float gain_ = 1.0f;

    /// Envolvente de pico de la señal (detector con attack/release). La
    /// ganancia se deriva de aquí (threshold / env_) en vez del |sample|
    /// instantáneo — esto evita el recorte muestra-a-muestra que generaba THD
    /// en sonidos fuertes sostenidos (decisión D audifono-v3, tarea 12.2).
    /// Empieza en 0.0 (sin señal). Solo accedido desde el hilo de audio.
    float env_ = 0.0f;

    // --- Detección de limitación sostenida (aviso R9.2 de audifono-v3) ---

    /// Muestras consecutivas (a través de bloques) en las que el limitador
    /// estuvo activo (gain_ < kLimitingGainThreshold). Se resetea a 0 en
    /// cuanto una muestra deja de estar limitada. Solo accedido desde el
    /// hilo de audio (estado interno de process()).
    int consecutiveLimitedSamples_ = 0;

    /// Fracción [0,1] de muestras limitadas en el último bloque. Snapshot
    /// atómico legible desde el hilo de UI (polling de métricas ~10 Hz).
    std::atomic<float> lastLimitingFraction_{0.0f};

    /// true si el último bloque tuvo limitación sostenida (las consecutivas
    /// cruzaron kSustainedLimitMs). Snapshot atómico legible desde UI.
    std::atomic<bool> limitingSustained_{false};

    /// Umbral de ganancia por debajo del cual se considera que el limitador
    /// está "actuando" sobre la muestra. 0.97 ≈ -0.26 dB de reducción: con
    /// una señal fuerte sostenida la ganancia queda deprimida de forma
    /// continua (release de 10 ms), así que este umbral detecta la
    /// limitación real sin disparar por transitorios aislados.
    static constexpr float kLimitingGainThreshold = 0.97f;

    /// Ventana mínima de limitación cuasi-continua para considerarla
    /// "sostenida" (200 ms). Por debajo de esto el aviso no se dispara
    /// (evita falsos positivos por picos breves).
    static constexpr float kSustainedLimitMs = 200.0f;

    /// Coeficiente de attack del DETECTOR DE ENVOLVENTE (qué tan rápido sube la
    /// envolvente ante un pico). attackCoeff = 1 - exp(-1 / (attackTimeSec * fs)).
    /// Para 3 ms @ 16 kHz: ≈ 0.0205.
    float attackCoeff_ = 0.0205f;

    /// Coeficiente de release del DETECTOR DE ENVOLVENTE (qué tan lento baja la
    /// envolvente cuando la señal cae). Debe ser ≫ período de la señal para no
    /// seguir el rizado del ciclo (si no, reintroduce THD).
    /// releaseCoeff = 1 - exp(-1 / (releaseTimeSec * fs)). Para 50 ms @ 16 kHz: ≈ 0.00125.
    float releaseCoeff_ = 0.00125f;

    // --- Configuración ---

    /// Sample rate en Hz (para cálculo de coeficientes)
    int sampleRate_ = 16000;

    /// Tiempo de attack del detector de envolvente (3 ms = 0.003 s).
    /// Validado en validate_antidistortion.py: minimiza el THD peor-caso
    /// (aislado + cadena) manteniendo |y| ≤ techo (decisión D, tarea 12.2).
    static constexpr float kAttackTimeSec = 0.003f;

    /// Tiempo de release del detector de envolvente (50 ms = 0.05 s).
    static constexpr float kReleaseTimeSec = 0.05f;
};

#endif // HEARING_AID_MPO_LIMITER_H

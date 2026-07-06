/// @file mpo_limiter.cpp
/// @brief Implementación del limitador MPO de picos muestra-por-muestra.
///
/// El MPO (Maximum Power Output) es la ÚLTIMA etapa del pipeline DSP.
/// Su función es garantizar que ninguna muestra de salida exceda el threshold
/// configurado, protegiendo la audición del usuario.
///
/// Algoritmo por muestra (detector de envolvente):
/// 1. Calcular |sample|
/// 2. Seguir la envolvente de pico con attack rápido (sube) / release lento (baja)
/// 3. Ganancia = threshold / envolvente (si envolvente > threshold; si no, 1.0)
/// 4. Aplicar ganancia: output = sample * gain
/// 5. Hard-clamp de seguridad: si |output| > threshold → saturar a threshold
///
/// El hard-clamp en paso 5 es la garantía absoluta e instantánea. Incluso si la
/// envolvente no convergió (transitorio de attack de un sonido fuerte
/// repentino), la salida NUNCA excede el threshold.
///
/// Por qué la envolvente y no el |sample| instantáneo: derivar la ganancia del
/// pico instantáneo recortaba muestra-a-muestra y hacía oscilar la ganancia
/// dentro de cada ciclo → armónicos (THD alto) en sonidos fuertes sostenidos.
/// La envolvente es suave, así que un tono sostenido se escala de forma
/// uniforme (sigue siendo sinusoidal) → THD bajo. (decisión D, tarea 12.2;
/// validado en tools/sim_v3/validate_antidistortion.py: 18.9% → 4.4% @ 1 kHz.)
///
/// Parámetros por defecto:
/// - Threshold: 100 dB SPL con offset 120 → -20 dBFS → 0.1 lineal
/// - Envolvente attack: 3 ms → attackCoeff ≈ 0.0205 @ 16 kHz
/// - Envolvente release: 50 ms → releaseCoeff ≈ 0.00125 @ 16 kHz
///
/// Requisitos validados: 2.6, 7.3, 9.1, 9.5

#include "mpo_limiter.h"

#include <algorithm>
#include <cmath>

// ============================================================================
// Constructor
// ============================================================================

MpoLimiter::MpoLimiter() {
    computeCoefficients();
}

// ============================================================================
// Inicialización
// ============================================================================

void MpoLimiter::init(int sampleRate) {
    sampleRate_ = sampleRate > 0 ? sampleRate : 16000;
    computeCoefficients();
    reset();
}

// ============================================================================
// Procesamiento principal — bloque completo
// ============================================================================

void MpoLimiter::process(float* buffer, int blockSize) {
    if (buffer == nullptr || blockSize <= 0) {
        return;
    }

    // Leer threshold una vez por bloque (atómico, thread-safe)
    const float threshold = thresholdLinear_.load(std::memory_order_relaxed);

    // Protección: threshold debe ser positivo y razonable
    if (threshold <= 0.0f) {
        return;
    }

    // Ancho de rodilla suave (dB). Leído una vez por bloque (atómico).
    const float kneeWidthDb = kneeWidthDb_.load(std::memory_order_relaxed);
    const float halfKneeDb = 0.5f * kneeWidthDb;

    // Umbral de "sostenido" en muestras, derivado del sample rate actual.
    // Al menos 1 muestra para evitar degenerados con sampleRate inválido.
    const int sustainedThreshSamples = std::max(
        1, static_cast<int>(kSustainedLimitMs * static_cast<float>(sampleRate_) / 1000.0f));
    int limitedInBlock = 0;
    bool sustainedHit = false;

    // Procesar muestra por muestra
    for (int i = 0; i < blockSize; ++i) {
        const float sample = buffer[i];
        const float absSample = std::fabs(sample);

        // --- Detector de envolvente de pico (decisión D, tarea 12.2) ---
        // La envolvente sigue |sample| con attack rápido (sube) / release lento
        // (baja). Derivar la ganancia de la ENVOLVENTE (no del |sample|
        // instantáneo) evita que la ganancia oscile dentro de cada ciclo, que
        // era la fuente de THD en sonidos fuertes sostenidos.
        const float envCoeff = (absSample > env_) ? attackCoeff_ : releaseCoeff_;
        env_ += envCoeff * (absSample - env_);

        // --- Ganancia objetivo con RODILLA SUAVE (soft-knee) ---
        // FIX voz ronca (grabaciones Moto G32): en vez de saltar de ganancia
        // 1.0 (sin limitar) a threshold/env (brickwall) justo en el techo —lo
        // que hacía que la señal muy por encima entrara casi entera al
        // hard-clamp y se recortara duro (THD → voz ronca)— aplicamos una
        // rodilla cuadrática que reduce la ganancia PROGRESIVAMENTE en la
        // ventana [-knee/2, +knee/2] dB alrededor del threshold. Por encima de
        // la rodilla actúa el brickwall (threshold/env) y el hard-clamp final
        // sigue garantizando el techo. La rodilla actúa SIEMPRE por debajo del
        // techo → el invariante |output| ≤ threshold se mantiene.
        //
        // Sea overshootDb = 20·log10(env/threshold):
        //   overshootDb ≤ -knee/2  → gain = 1.0 (sin limitar)
        //   overshootDb ≥ +knee/2  → gain = threshold/env (brickwall)
        //   en la rodilla          → gainDb = -(overshootDb+knee/2)² / (2·knee)
        if (env_ <= 0.0f) {
            gain_ = 1.0f;
        } else if (kneeWidthDb <= 0.0f) {
            // Sin rodilla → hard-clamp clásico (comportamiento previo).
            gain_ = (env_ > threshold) ? (threshold / env_) : 1.0f;
        } else {
            const float overshootDb = 20.0f * std::log10(env_ / threshold);
            if (overshootDb <= -halfKneeDb) {
                gain_ = 1.0f;
            } else if (overshootDb >= halfKneeDb) {
                gain_ = threshold / env_;  // brickwall
            } else {
                // Rodilla cuadrática (ratio→∞): la ganancia baja suave desde
                // 0 dB en el borde inferior hasta la reducción plena arriba.
                const float x = overshootDb + halfKneeDb;
                const float gainDb = -(x * x) / (2.0f * kneeWidthDb);
                gain_ = std::pow(10.0f, gainDb / 20.0f);
            }
        }

        // Asegurar que la ganancia nunca excede 1.0 (MPO nunca amplifica)
        if (gain_ > 1.0f) {
            gain_ = 1.0f;
        }

        // Asegurar que la ganancia nunca es negativa (protección numérica)
        if (gain_ < 0.0f) {
            gain_ = 0.0f;
        }

        // --- Tracking de limitación sostenida (aviso R9.2 audifono-v3) ---
        // Una muestra cuenta como "limitada" cuando la ganancia del limitador
        // está deprimida por debajo de kLimitingGainThreshold. Con señal
        // fuerte sostenida la ganancia se mantiene baja de forma continua, así
        // que las consecutivas se acumulan a través de bloques.
        if (gain_ < kLimitingGainThreshold) {
            ++consecutiveLimitedSamples_;
            ++limitedInBlock;
            if (consecutiveLimitedSamples_ >= sustainedThreshSamples) {
                sustainedHit = true;
            }
        } else {
            consecutiveLimitedSamples_ = 0;
        }

        // Aplicar ganancia suavizada
        float output = sample * gain_;

        // --- HARD-CLAMP DE SEGURIDAD ---
        // Garantía absoluta: incluso durante transitorio de attack,
        // la salida NUNCA excede el threshold.
        if (output > threshold) {
            output = threshold;
        } else if (output < -threshold) {
            output = -threshold;
        }

        buffer[i] = output;
    }

    // Publicar snapshots de limitación para el polling de métricas (UI thread).
    lastLimitingFraction_.store(
        static_cast<float>(limitedInBlock) / static_cast<float>(blockSize),
        std::memory_order_relaxed);
    limitingSustained_.store(sustainedHit, std::memory_order_relaxed);
}

// ============================================================================
// Configuración de threshold
// ============================================================================

void MpoLimiter::setThreshold(float thresholdDbSpl, float splOffset) {
    // Convertir dB SPL a dBFS usando el offset
    // dBFS = dB_SPL - splOffset
    const float thresholdDbFs = thresholdDbSpl - splOffset;

    // Convertir dBFS a amplitud lineal
    // linear = 10^(dBFS / 20)
    const float linear = std::pow(10.0f, thresholdDbFs / 20.0f);

    // Almacenar atómicamente (thread-safe)
    thresholdLinear_.store(linear, std::memory_order_relaxed);
}

void MpoLimiter::setThresholdLinear(float linear) {
    if (linear > 0.0f) {
        thresholdLinear_.store(linear, std::memory_order_relaxed);
    }
}

void MpoLimiter::setKneeWidthDb(float kneeWidthDb) {
    // Rechazar NaN/Inf; acotar a [0, 24] dB (una rodilla > 24 dB no aporta
    // y arrancaría a atenuar la voz conversacional). 0 → hard-clamp clásico.
    if (!std::isfinite(kneeWidthDb) || kneeWidthDb < 0.0f) {
        return;
    }
    if (kneeWidthDb > 24.0f) {
        kneeWidthDb = 24.0f;
    }
    kneeWidthDb_.store(kneeWidthDb, std::memory_order_relaxed);
}

float MpoLimiter::getKneeWidthDb() const {
    return kneeWidthDb_.load(std::memory_order_relaxed);
}

// ============================================================================
// Getters
// ============================================================================

float MpoLimiter::getThresholdLinear() const {
    return thresholdLinear_.load(std::memory_order_relaxed);
}

float MpoLimiter::getCurrentGain() const {
    return gain_;
}

float MpoLimiter::getLimitingFraction() const {
    return lastLimitingFraction_.load(std::memory_order_relaxed);
}

bool MpoLimiter::isLimitingSustained() const {
    return limitingSustained_.load(std::memory_order_relaxed);
}

// ============================================================================
// Reset
// ============================================================================

void MpoLimiter::reset() {
    gain_ = 1.0f;
    env_ = 0.0f;
    consecutiveLimitedSamples_ = 0;
    lastLimitingFraction_.store(0.0f, std::memory_order_relaxed);
    limitingSustained_.store(false, std::memory_order_relaxed);
}

// ============================================================================
// Cálculo de coeficientes internos
// ============================================================================

void MpoLimiter::computeCoefficients() {
    // Coeficientes del DETECTOR DE ENVOLVENTE (peak-follower).
    // attackCoeff = 1 - exp(-1 / (attackTime_sec * sampleRate))
    // Para 3 ms @ 16 kHz: 1 - exp(-1 / (0.003 * 16000))
    //                    = 1 - exp(-1 / 48)
    //                    ≈ 1 - 0.97947
    //                    ≈ 0.02053
    const float attackSamples = kAttackTimeSec * static_cast<float>(sampleRate_);
    if (attackSamples > 0.0f) {
        attackCoeff_ = 1.0f - std::exp(-1.0f / attackSamples);
    } else {
        attackCoeff_ = 1.0f; // Instantáneo si tiempo = 0
    }

    // releaseCoeff = 1 - exp(-1 / (releaseTime_sec * sampleRate))
    // Para 50 ms @ 16 kHz: 1 - exp(-1 / (0.05 * 16000))
    //                     = 1 - exp(-1 / 800)
    //                     ≈ 1 - 0.99875
    //                     ≈ 0.00125
    const float releaseSamples = kReleaseTimeSec * static_cast<float>(sampleRate_);
    if (releaseSamples > 0.0f) {
        releaseCoeff_ = 1.0f - std::exp(-1.0f / releaseSamples);
    } else {
        releaseCoeff_ = 1.0f; // Instantáneo si tiempo = 0
    }
}

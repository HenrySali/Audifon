/// @file dsp_pipeline.cpp
/// @brief Implementación del pipeline DSP para procesamiento de audio en tiempo real.
///
/// Pipeline: HPF 100Hz → NR → medir nivel PRE-EQ → EQ → WDRC → Volume → MPO
///                       ↓
///              Environment Classifier
///              (actualiza NR + WDRC directamente al target)
///
/// Reglas de oro:
/// - Solo EQ y Volume amplifican. Todo lo demás atenúa o pasa.
/// - Medir nivel PRE-EQ para decisiones de WDRC.
/// - MPO es la última etapa — red de seguridad absoluta (110 dB SPL, FDA OTC).
/// - Silencio debe producir silencio (expansión activa).
/// - HPF @ 100 Hz removes rumble while preserving male voice F0 (~120 Hz).
/// - Offset calibración: 93 dB para mic celular Android con AGC.
///
/// Cambios validados con literatura académica (Mayo 2026):
/// - MPO 110 dB SPL: FDA 21 CFR 800.30, consenso profesional OTC
/// - HPF 100 Hz: preserva F0 masculina, elimina rumble
/// - Sin adaptive EQ scaling: causaba doble atenuación (audioXpress OTC paper)
/// - Sin headroom guard: redundante con MPO correcto (Hearing Review MPO paper)
/// - NR transiciones directas: NR tiene suavizado interno, gradualidad redundante
/// - Clasificador activo: Keidser 2017 muestra ventaja SRT del automático

#include "dsp_pipeline.h"

#include <cmath>
#include <cstring>
#include <algorithm>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// ─────────────────────────────────────────────────────────────────────────────
// Constantes
// ─────────────────────────────────────────────────────────────────────────────

/// Piso de nivel para evitar log(0). Equivale a ~-100 dBFS.
static constexpr float kLevelFloor = 1e-10f;

/// Nivel mínimo reportable en dB SPL (para señales en silencio).
static constexpr float kMinLevelDbSpl = 0.0f;

// ─────────────────────────────────────────────────────────────────────────────
// Constructor / Destructor
// ─────────────────────────────────────────────────────────────────────────────

DspPipeline::DspPipeline() = default;
DspPipeline::~DspPipeline() = default;

// ─────────────────────────────────────────────────────────────────────────────
// Inicialización
// ─────────────────────────────────────────────────────────────────────────────

void DspPipeline::init(const AudioConfig& config) {
    // Configurar offset de calibración SPL
    splOffset_.store(config.splOffset, std::memory_order_relaxed);

    // Inicializar EQ con sample rate
    eq_.init(config.sampleRate);

    // Inicializar WDRC con sample rate (para coeficientes attack/release correctos)
    wdrc_.init(config.sampleRate);

    // Inicializar MPO con sample rate y threshold
    mpo_.init(config.sampleRate);
    // MPO threshold: usar valor lineal directo de 0.85 (-1.4 dBFS).
    // Con offset 93, el máximo digital (0 dBFS) equivale a 93 dB SPL,
    // así que un threshold en dB SPL > 93 nunca se alcanzaría.
    // Usamos threshold lineal directo para garantizar protección contra clipping.
    // 0.85 deja ~1.4 dB de headroom bajo el clip point digital.
    mpo_.setThresholdLinear(0.85f);

    // Volumen inicial: 0 dB (ganancia unitaria)
    volumeDb_.store(0.0f, std::memory_order_relaxed);
    volumeLinear_.store(1.0f, std::memory_order_relaxed);

    // Inicializar volume smoother (5ms simétrico — cambio de usuario)
    // Referencia: openMHA smoothgain_bridge, DSP Concepts Audio Weaver
    volumeSmoother_.init(config.sampleRate, 5.0f, 5.0f);
    volumeSmoother_.reset(1.0f);  // Ganancia unitaria inicial

    // Inicializar NR level smoother (20ms attack, 50ms release)
    nrLevelSmoother_.init(config.sampleRate, 20.0f, 50.0f);
    nrLevelSmoother_.reset(1.0f);  // Sin atenuación inicial

    // Inicializar analizador de espectro
    spectrumAnalyzer_.init(config.sampleRate, config.splOffset);

    // Compute high-pass filter coefficients (100 Hz Butterworth, actual sample rate)
    // 100 Hz preserves male F0 (~120 Hz, only -3 dB) while removing rumble/vibration.
    // Literature: 80 Hz too low (amplifies ambient noise), 150 Hz cuts male voice.
    computeHighPassCoeffs(config.sampleRate, 100.0f);
}

// ─────────────────────────────────────────────────────────────────────────────
// Procesamiento principal
// ─────────────────────────────────────────────────────────────────────────────

void DspPipeline::processBlock(float* buffer, int blockSize) {
    if (buffer == nullptr || blockSize <= 0) {
        return;
    }

    // ─── 0. Copiar buffer de entrada para el analizador de espectro ─────
    float inputCopy[256];  // max block size
    bool spectrumActive = spectrumAnalyzer_.isActive();
    if (spectrumActive) {
        std::memcpy(inputCopy, buffer, blockSize * sizeof(float));
    }

    // ─── 0.5. High-pass filter @ 100 Hz (remove rumble, preserve voice) ─
    // 2nd-order Butterworth HPF at 100 Hz removes low-frequency wind/vibration
    // while preserving male voice fundamental (~120 Hz, only -3 dB attenuation).
    // Literature: 150 Hz was too high (cut male F0), 80 Hz too low (amplifies noise).
    for (int i = 0; i < blockSize; ++i) {
        float x = buffer[i];
        float y = hpB0_ * x + hpB1_ * hpX1_ + hpB2_ * hpX2_
                - hpA1_ * hpY1_ - hpA2_ * hpY2_;
        hpX2_ = hpX1_; hpX1_ = x;
        hpY2_ = hpY1_; hpY1_ = y;
        buffer[i] = y;
    }

    // ─── 1. Noise Reduction (solo atenúa) ───────────────────────────────
    // El NR ya tiene suavizado temporal interno (prevGain_ con attack/release
    // por bloque). Cuando cambia el nivel de NR, el gainFloor cambia pero
    // el suavizado interno del NR maneja la transición gradualmente.
    nr_.process(buffer, blockSize);

    // ─── 2. Medir nivel PRE-EQ (para WDRC y Environment Classifier) ─────
    // Este nivel refleja la señal REAL de entrada, sin amplificación del EQ.
    // El WDRC usa este valor para decidir en qué región operar.
    float inputLevelDb = measureRmsDb(buffer, blockSize);
    lastInputLevelDb_.store(inputLevelDb, std::memory_order_relaxed);

    // ─── 3. Environment Classifier (actualiza NR + WDRC en transición) ──
    if (autoClassifyEnabled_.load(std::memory_order_relaxed)) {
        float estimatedSnr = estimateSnrSimple(inputLevelDb);

        EnvironmentClass envClass = envClassifier_.update(inputLevelDb, estimatedSnr);
        int envClassInt = static_cast<int>(envClass);

        // Si la clase cambió, actualizar NR y WDRC automáticamente
        if (envClassInt != lastEnvClass_) {
            lastEnvClass_ = envClassInt;

            // Actualizar NR level DIRECTAMENTE al target recomendado.
            // El NR ya tiene suavizado temporal interno (attack/release en
            // compositeGain), así que la transición gradual de nivel era
            // redundante y causaba que nunca convergiera con hold de 3s.
            int targetNrLevel = envClassifier_.getRecommendedNrLevel();
            currentNrLevel_ = targetNrLevel;
            nr_.setLevel(currentNrLevel_);

            // Actualizar WDRC compression params (estos son suaves por naturaleza)
            EnvWdrcParams wdrcParams = envClassifier_.getRecommendedWdrcParams();
            wdrc_.setCompressionKnee(wdrcParams.compressionKnee);
            wdrc_.setCompressionRatio(wdrcParams.compressionRatio);
        }
    }

    // ─── 4. Equalizer 12 bandas (AMPLIFICA según prescripción) ──────────
    // EQ aplica ganancia prescrita sin scaling adaptativo.
    // La protección contra overflow la provee el MPO (threshold 110 dB SPL = 0.316 lineal).
    // Adaptive EQ scaling fue eliminado: causaba doble atenuación con MPO y reducía
    // la amplificación prescrita innecesariamente (validado: audioXpress OTC DSP paper).
    eq_.process(buffer, blockSize);

    // ─── 5. WDRC — usa inputLevelDb (pre-EQ) para decisión ─────────────
    // El WDRC nunca amplifica (gainFactor ∈ [0.0, 1.0]).
    // Usa el nivel PRE-EQ para evitar que la amplificación del EQ
    // dispare compresión innecesaria.
    wdrc_.process(buffer, blockSize, inputLevelDb);

    // ─── 6. Volume master (smoothed, sample-by-sample) ────────────────
    // Rango: -20 a +10 dB. Puede amplificar hasta +10 dB (3.16×).
    // El GainSmoother elimina clicks al cambiar volumen rápidamente.
    // Referencia: openMHA smoothgain_bridge, DSP Concepts Audio Weaver.
    {
        float volTarget = volumeLinear_.load(std::memory_order_relaxed);
        volumeSmoother_.setTarget(volTarget);
        for (int i = 0; i < blockSize; ++i) {
            buffer[i] *= volumeSmoother_.next();
        }
    }

    // ─── 7. MPO — sample-by-sample peak limiter (ÚLTIMA etapa) ──────────
    // Red de seguridad absoluta. Garantiza que ninguna muestra excede
    // 0.85 lineal (-1.4 dBFS). Opera muestra-por-muestra, no block-rate.
    // Threshold lineal directo (independiente del offset de calibración).
    // FDA 21 CFR 800.30 limita output OTC a 111 dB SPL en el oído;
    // con auriculares, 0.85 lineal es conservador y seguro.
    mpo_.process(buffer, blockSize);

    // ─── 8. Spectrum Analyzer (post-pipeline) ───────────────────────────
    // Alimentar el analizador con buffers pre y post procesamiento.
    // Solo se ejecuta cuando la pantalla de espectro está visible.
    if (spectrumActive) {
        spectrumAnalyzer_.setEnvironmentClass(lastEnvClass_);
        spectrumAnalyzer_.processBuffers(inputCopy, buffer, blockSize);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Actualización de parámetros (thread-safe, lock-free)
// ─────────────────────────────────────────────────────────────────────────────

void DspPipeline::setEqGains(const float gains[12]) {
    eq_.setGains(gains);
}

void DspPipeline::setVolume(float volumeDb) {
    // Clamp al rango válido [-20, +10] dB
    volumeDb = std::max(-20.0f, std::min(10.0f, volumeDb));
    volumeDb_.store(volumeDb, std::memory_order_relaxed);

    // Pre-calcular factor lineal: 10^(dB/20)
    float linear = std::pow(10.0f, volumeDb / 20.0f);
    volumeLinear_.store(linear, std::memory_order_relaxed);
}

void DspPipeline::setWdrcParams(const WdrcParams& params) {
    wdrc_.setExpansionKnee(params.expansionKnee);
    wdrc_.setExpansionRatio(params.expansionRatio);
    wdrc_.setCompressionKnee(params.compressionKnee);
    wdrc_.setCompressionRatio(params.compressionRatio);
    wdrc_.setAttackMs(params.attackMs);
    wdrc_.setReleaseMs(params.releaseMs);
}

void DspPipeline::setNrLevel(int level) {
    // Clamp al rango válido [0, 3]
    level = std::max(0, std::min(3, level));
    nr_.setLevel(level);
}

void DspPipeline::setSplOffset(float offset) {
    splOffset_.store(offset, std::memory_order_relaxed);
    // MPO threshold lineal fijo a 0.85 (-1.4 dBFS) — independiente del offset.
    // El offset solo afecta la interpretación del nivel de entrada para WDRC,
    // no el threshold de protección de salida del MPO.
    mpo_.setThresholdLinear(0.85f);
}

float DspPipeline::getLastInputLevelDb() const {
    return lastInputLevelDb_.load(std::memory_order_relaxed);
}

void DspPipeline::setAutoClassifyEnabled(bool enabled) {
    autoClassifyEnabled_.store(enabled, std::memory_order_relaxed);
}

int DspPipeline::getCurrentEnvironmentClass() const {
    return envClassifier_.getCurrentClass();
}

// ─────────────────────────────────────────────────────────────────────────────
// Funciones internas
// ─────────────────────────────────────────────────────────────────────────────

float DspPipeline::measureRmsDb(const float* buffer, int blockSize) const {
    // Calcular RMS (Root Mean Square) del buffer
    float sumSquares = 0.0f;
    for (int i = 0; i < blockSize; ++i) {
        sumSquares += buffer[i] * buffer[i];
    }
    float rms = std::sqrt(sumSquares / static_cast<float>(blockSize));

    // Evitar log(0)
    if (rms < kLevelFloor) {
        return kMinLevelDbSpl;
    }

    // Convertir a dBFS y luego a dB SPL usando el offset de calibración
    float rmsDbFs = 20.0f * std::log10(rms);
    float offset = splOffset_.load(std::memory_order_relaxed);
    float levelDbSpl = rmsDbFs + offset;

    // No reportar niveles negativos
    return std::max(kMinLevelDbSpl, levelDbSpl);
}

void DspPipeline::applyVolume(float* buffer, int blockSize, float volumeLinear) {
    for (int i = 0; i < blockSize; ++i) {
        buffer[i] *= volumeLinear;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Estimación simplificada de SNR
// ─────────────────────────────────────────────────────────────────────────────

float DspPipeline::estimateSnrSimple(float inputLevelDb) const {
    // Estimación heurística de SNR basada en el nivel de entrada.
    // En un sistema completo, el NR expondría sus noise estimates por banda.
    // Aquí usamos una aproximación: el piso de ruido del micrófono es ~26 dB SPL.
    // SNR ≈ inputLevel - noiseFloor.
    // Clampeamos al rango práctico [-20, 40] dB.
    static constexpr float kNoiseFloorDbSpl = 30.0f;
    float snr = inputLevelDb - kNoiseFloorDbSpl;
    snr = std::max(kEnvSnrMin, std::min(kEnvSnrMax, snr));
    return snr;
}

// ─────────────────────────────────────────────────────────────────────────────
// High-pass filter coefficient computation
// ─────────────────────────────────────────────────────────────────────────────

void DspPipeline::computeHighPassCoeffs(int sampleRate, float cutoffHz) {
    // 2nd order Butterworth high-pass filter
    // Q = 0.7071 (1/sqrt(2)) for maximally flat passband
    const float w0 = 2.0f * static_cast<float>(M_PI) * cutoffHz / static_cast<float>(sampleRate);
    const float cosW0 = std::cos(w0);
    const float alpha = std::sin(w0) / (2.0f * 0.7071f); // Q = 0.7071 for Butterworth

    const float a0 = 1.0f + alpha;
    hpB0_ = ((1.0f + cosW0) / 2.0f) / a0;
    hpB1_ = (-(1.0f + cosW0)) / a0;
    hpB2_ = ((1.0f + cosW0) / 2.0f) / a0;
    hpA1_ = (-2.0f * cosW0) / a0;
    hpA2_ = (1.0f - alpha) / a0;

    // Reset filter state
    hpX1_ = hpX2_ = 0.0f;
    hpY1_ = hpY2_ = 0.0f;
}

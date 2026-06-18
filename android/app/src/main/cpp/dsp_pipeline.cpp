/// @file dsp_pipeline.cpp
/// @brief Implementación del pipeline DSP para procesamiento de audio en tiempo real.
///
/// Pipeline: HPF → TNR → NR → medir nivel PRE-EQ → EQ → WDRC → Volume → FBS → OC → MPO
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

    // Inicializar AFC (Adaptive Feedback Canceller) — estima el feedback path
    // y resta la estimación del mic antes de que entre al pipeline. Preventivo.
    // Activado por default; solo resta (seguro). El FBS queda como respaldo.
    afc_.init(config.sampleRate);

    // Inicializar EQ con sample rate
    eq_.init(config.sampleRate);

    // Inicializar NR con el sample rate real (FIX sim_v3): recalcula los
    // bandpass de las 8 sub-bandas a la fs efectiva en vez de asumir 48 kHz.
    // El NR solo atenúa, así que esto no introduce riesgo de clipping.
    nr_.init(config.sampleRate);

    // Inicializar TNR (Transient Noise Reducer) — para impulsos abruptos
    tnr_.init(config.sampleRate);
    tnr_.setEnabled(true); // Activado por default
    tnr_.setThreshold(8.0f);
    tnr_.setAttenuationDb(-12.0f);

    // Inicializar Feedback Suppressor (anti-howling) — rompe el lazo Larsen
    // que aparece a ganancia alta (mic+parlante cercanos en el teléfono).
    //
    // DESHABILITADO POR DEFAULT (bug "trompeta al final del ruido"):
    // En el caso de uso real del proyecto el audio sale por BT → audífono
    // externo, NO por el parlante del celular. NO hay path acústico de
    // feedback (mic celu ↔ parlante celu). El FBS engancha notches al
    // detectar tonalidad sostenida (golpes al mic, vocales largas, click
    // de teclado), los mantiene 1500 ms y baja el guard a -24 dB →
    // "trompeta sostenida" en la salida. Validado en
    // tools/sim_v3/simulate_trompeta_fbs.py:
    //   - 2 notches enganchados con golpes inocuos
    //   - 86% del run con notches activos
    //   - Guard atenuado -24 dB durante 2.55 s de un run de 3 s
    //
    // El AFC (NLMS adaptivo) ya cubre el feedback eléctrico residual del
    // DSP. Si en el futuro se usa el celu como audífono directo (mic celu
    // → parlante celu), reactivar este flag desde un toggle dev/clínico.
    fbs_.init(config.sampleRate);
    fbs_.setEnabled(false);
    fbs_.setDepthDb(-18.0f);

    // Inicializar Output Compressor (freno de amplificación pre-MPO) — baja la
    // ganancia de forma SUAVE (soft-knee 6 dB + ratio 4:1) sobre la envolvente
    // real de salida, de modo que el MPO casi nunca tenga que hacer hard-clamp
    // (menos THD = se va el silbido residual). Activado por default como TNR/FBS;
    // solo atenúa. Su threshold se ancla bajo el techo del MPO en
    // applyMpoThresholdFromDbSpl() (más abajo, tras mpo_.init()).
    // ETAPA 1 hotfix: ratio 4:1 (antes 10:1) para que voz normal pase
    // transparente y solo los picos sostenidos se atenúen suavemente.
    oc_.init(config.sampleRate);
    oc_.setEnabled(true);
    oc_.setRatio(4.0f);
    oc_.setKneeDb(6.0f);

    // Inicializar WDRC con sample rate (para coeficientes attack/release correctos)
    wdrc_.init(config.sampleRate);

    // Inicializar MPO con sample rate y threshold
    mpo_.init(config.sampleRate);
    // MPO clínico reconciliado (decisión B audifono-v3): el threshold se
    // deriva del MPO en dB SPL con kMpoSplOffset=120 (calibración acústica de
    // SALIDA, en el oído), NO con splOffset (93, mic de ENTRADA). Así el MPO
    // clínico del audiograma [80, ~118.6] dB SPL es OPERATIVO y distinguible,
    // manteniendo 0.85 lineal (-1.4 dBFS) como red de seguridad dura.
    // Validado en tools/sim_v3/validate_mpo.py (Property 1: |y| ≤ techo).
    // Persistir el dB SPL inicial para re-derivar si cambia la calibración.
    mpoThresholdDbSpl_.store(config.mpoThresholdDbSpl, std::memory_order_relaxed);
    applyMpoThresholdFromDbSpl(config.mpoThresholdDbSpl);

    // Volumen inicial: 0 dB (ganancia unitaria)
    volumeDb_.store(0.0f, std::memory_order_relaxed);
    volumeLinear_.store(1.0f, std::memory_order_relaxed);

    // Inicializar analizador de espectro
    spectrumAnalyzer_.init(config.sampleRate, config.splOffset);

    // Compute high-pass filter coefficients (100 Hz Butterworth, actual sample rate)
    // 100 Hz preserves male F0 (~120 Hz, only -3 dB) while removing rumble/vibration.
    // Literature: 80 Hz too low (amplifies ambient noise), 150 Hz cuts male voice.
    computeHighPassCoeffs(config.sampleRate, 100.0f);

    // FIX Causa A (smart-scene-diagnostico-chasquido.md):
    // Inicializar las rampas de WDRC + NR a los valores default del WdrcParams
    // (compKnee=55 dB SPL, compRatio=2.0, nrLevel=0). Sin esto, el primer
    // cambio de clase produciría un salto desde 0/0/0 hacia el target.
    wdrcKneeRamp_   = 55.0f;
    wdrcKneeTarget_ = 55.0f;
    wdrcRatioRamp_   = 2.0f;
    wdrcRatioTarget_ = 2.0f;
    nrLevelTarget_                = 0;
    currentNrLevel_               = 0;
    nrLevelRampBlocksRemaining_   = 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Procesamiento principal
// ─────────────────────────────────────────────────────────────────────────────

void DspPipeline::processBlock(float* buffer, int blockSize, float externalLevelDb) {
    if (buffer == nullptr || blockSize <= 0) {
        return;
    }

    // ─── 0. Copiar buffer de entrada para el analizador de espectro ─────
    float inputCopy[256];  // max block size
    bool spectrumActive = spectrumAnalyzer_.isActive();
    if (spectrumActive) {
        std::memcpy(inputCopy, buffer, blockSize * sizeof(float));
    }

    // ─── 0.1. AFC — restar estimación del feedback path del mic ──────────
    // Opera sobre la señal CRUDA del mic, ANTES del HPF y todo lo demás.
    // Usa el historial del parlante (capturado al final del bloque anterior)
    // como referencia para el NLMS. Si el AFC aún no convergió o está
    // deshabilitado, pasa sin cambio (solo resta ~0). El FBS (notch+guard)
    // queda como respaldo reactivo más adelante en el pipeline.
    afc_.removeFeedback(buffer, blockSize);

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

    // ─── 0.7. Transient Noise Reducer (TNR) ─────────────────────────────
    // Atenúa impulsos abruptos (timbre subte, puertas, bocinas) sample-by-sample.
    // Detecta cuando la energía instantánea es 8× sobre el promedio de fondo
    // y aplica -12 dB durante 20ms con recovery de 30ms.
    // Referencia: Phonak SoundRelax (2006), Acta Acustica 2023.
    tnr_.process(buffer, blockSize);

    // ─── 1. Noise Reduction (solo atenúa) ───────────────────────────────
    // Si nrBypassed_=true, otro denoiser externo (DNN) procesó el buffer
    // antes (en el AudioEngine), así que evitamos doble NR.
    if (!nrBypassed_.load(std::memory_order_acquire)) {
        nr_.process(buffer, blockSize);
    } else {
        // NR Wiener bypasseado (un denoiser DNN externo ya procesó el buffer).
        // Aun así actualizamos las estimaciones de potencia por banda del NR
        // para que el SNR del clasificador de entorno siga vivo (no congelado).
        nr_.analyzeOnly(buffer, blockSize);
    }

    // Métrica: nivel post-NR
    lastPostNrLevelDb_.store(measureRmsDb(buffer, blockSize), std::memory_order_relaxed);

    // ─── 2. Determinar nivel para WDRC y Environment Classifier ─────────
    // Si el AudioEngine pasó un nivel externo válido (medido pre-DNN, antes
    // de la atenuación de la red neuronal), lo usamos directamente. Esto
    // evita que el WDRC opere sobre la señal ya atenuada por la DNN
    // (sub-compresión / región de expansión espuria).
    //
    // Sentinel -1.0f (default del .h) o NaN/Inf → fallback a medición
    // local con measureRmsDb(buffer, blockSize), preservando exactamente
    // el comportamiento previo a esta optimización (retrocompatibilidad
    // bit-exacta para callers existentes — incluida la app del paciente
    // que clona este código).
    //
    // Validates Property 4 (design.md): fallback to local measurement.
    float inputLevelDb;
    bool usesExternalLevel = false;
    if (externalLevelDb >= 0.0f && std::isfinite(externalLevelDb)) {
        inputLevelDb = externalLevelDb;
        usesExternalLevel = true;
    } else {
        inputLevelDb = measureRmsDb(buffer, blockSize);
    }
    lastInputLevelDb_.store(inputLevelDb, std::memory_order_relaxed);
    wdrcUsesExternalLevel_.store(usesExternalLevel, std::memory_order_relaxed);

    // ─── 3. Environment Classifier (actualiza NR + WDRC en transición) ──
    if (autoClassifyEnabled_.load(std::memory_order_relaxed)) {
        // FIX clasificador: SNR REAL desde las estimaciones por banda del NR
        // (potencias de señal y ruido), en vez del SNR falso (nivel − 30) que
        // nunca permitía alcanzar NOISE/Ruidoso (colapsaba a QUIET/SPEECH).
        // Validado en tools/sim_v3/validate_classifier.py.
        float sigEst[kNrSubBands];
        float noiEst[kNrSubBands];
        nr_.getSignalEstimate(sigEst, kNrSubBands);
        nr_.getNoiseEstimate(noiEst, kNrSubBands);
        float estimatedSnr = EnvironmentClassifier::estimateSnrFromNr(
            sigEst, noiEst, kNrSubBands);

        EnvironmentClass envClass = envClassifier_.update(inputLevelDb, estimatedSnr);
        int envClassInt = static_cast<int>(envClass);

        // Si la clase cambió, actualizar NR y WDRC automáticamente
        if (envClassInt != lastEnvClass_) {
            lastEnvClass_ = envClassInt;

            // FIX Causa A (smart-scene-diagnostico-chasquido.md):
            // ANTES: aquí se sustituía el knee, ratio y nrLevel directamente,
            //        produciendo un escalón en un solo sample → CHASQUIDO.
            // AHORA: solo fijamos los TARGETS. La rampa exponencial del WDRC
            //        (kWdrcRampAlpha → ~200 ms) y el step discreto del NR
            //        (kNrLevelStepBlocks → ~300 ms entre niveles) corren cada
            //        bloque más abajo, antes de wdrc_.process().
            EnvWdrcParams wdrcParams = envClassifier_.getRecommendedWdrcParams();
            wdrcKneeTarget_  = wdrcParams.compressionKnee;
            wdrcRatioTarget_ = wdrcParams.compressionRatio;
            nrLevelTarget_   = envClassifier_.getRecommendedNrLevel();
            nrLevelRampBlocksRemaining_ = kNrLevelInitialDelayBlocks;
        }
    }

    // FIX Causa A (smart-scene-diagnostico-chasquido.md):
    // Rampa de WDRC + NR ejecutada CADA bloque (sin condicional sobre cambio
    // de clase). Esto garantiza que cualquier diferencia entre el valor actual
    // y el target se reduzca exponencialmente, eliminando los chasquidos al
    // transitar entre escenas (SPEECH→NOISE, QUIET→SPEECH, etc.).
    //
    // FIX saturación transitoria preset bajo→alto (Opción C: "WDRC first"):
    // Si el target implica MÁS compresión (CR sube o knee baja), aplicar
    // INSTANTÁNEO para que la compresión "esté lista" cuando las gains EQ
    // suban (evita picos transitorios que disparan el MPO). Si implica MENOS
    // compresión (CR baja o knee sube), rampear suave para evitar que el
    // nivel suba de golpe. Patrón estándar de audífonos: attack rápido /
    // release lento, pero a nivel de PARÁMETROS en vez de señal.
    {
        // 1) Knee: baja = más compresión = instantáneo; sube = menos = rampear.
        if (wdrcKneeTarget_ < wdrcKneeRamp_) {
            // Knee bajando → más compresión → aplicar instantáneo (protege)
            wdrcKneeRamp_ = wdrcKneeTarget_;
        } else {
            // Knee subiendo → menos compresión → rampear suave (evita pico)
            wdrcKneeRamp_ += kWdrcRampAlpha * (wdrcKneeTarget_ - wdrcKneeRamp_);
        }

        // 2) Ratio: sube = más compresión = instantáneo; baja = menos = rampear.
        if (wdrcRatioTarget_ > wdrcRatioRamp_) {
            // Ratio subiendo → más compresión → aplicar instantáneo (protege)
            wdrcRatioRamp_ = wdrcRatioTarget_;
        } else {
            // Ratio bajando → menos compresión → rampear suave (evita pico)
            wdrcRatioRamp_ += kWdrcRampAlpha * (wdrcRatioTarget_ - wdrcRatioRamp_);
        }

        wdrc_.setCompressionKnee(wdrcKneeRamp_);
        wdrc_.setCompressionRatio(wdrcRatioRamp_);

        // 2) NR level: step discreto. El gainFloor de NoiseReduction salta
        //    en escalones (1.0 / 0.55 / 0.32 / 0.18) que el suavizado interno
        //    NO interpola, así que avanzamos UN nivel cada kNrLevelStepBlocks.
        if (nrLevelRampBlocksRemaining_ > 0) {
            nrLevelRampBlocksRemaining_--;
        } else if (currentNrLevel_ != nrLevelTarget_) {
            int step = (nrLevelTarget_ > currentNrLevel_) ? 1 : -1;
            currentNrLevel_ += step;
            nr_.setLevel(currentNrLevel_);
            nrLevelRampBlocksRemaining_ = kNrLevelStepBlocks;
        }
    }

    // ─── 4. Equalizer 12 bandas (AMPLIFICA según prescripción) ──────────
    // EQ aplica ganancia prescrita sin scaling adaptativo.
    // La protección contra overflow la provee el MPO (threshold 110 dB SPL = 0.316 lineal).
    // Adaptive EQ scaling fue eliminado: causaba doble atenuación con MPO y reducía
    // la amplificación prescrita innecesariamente (validado: audioXpress OTC DSP paper).
    eq_.process(buffer, blockSize);

    // Métrica: nivel post-EQ + peak
    lastPostEqLevelDb_.store(measureRmsDb(buffer, blockSize), std::memory_order_relaxed);

    // ─── 5. WDRC — usa inputLevelDb (pre-EQ) para decisión ─────────────
    // El WDRC nunca amplifica (gainFactor ∈ [0.0, 1.0]).
    // Usa el nivel PRE-EQ para evitar que la amplificación del EQ
    // dispare compresión innecesaria.
    wdrc_.process(buffer, blockSize, inputLevelDb);

    // Métrica: nivel post-WDRC
    lastPostWdrcLevelDb_.store(measureRmsDb(buffer, blockSize), std::memory_order_relaxed);

    // ─── 6. Volume master ───────────────────────────────────────────────
    // Rango: -20 a +10 dB. Puede amplificar hasta +10 dB (3.16×).
    float volLinear = volumeLinear_.load(std::memory_order_relaxed);
    applyVolume(buffer, blockSize, volLinear);

    // Métrica: nivel post-Volume
    lastPostVolumeLevelDb_.store(measureRmsDb(buffer, blockSize), std::memory_order_relaxed);

    // ─── 6.5. Feedback Suppressor (anti-howling) ────────────────────────
    // Última etapa "inteligente" antes del MPO. Opera sobre la señal que va
    // a salir por el parlante (la que realimenta al mic). Detecta el pitido
    // tonal del lazo Larsen y lo ataca con notches adaptativos; si persiste,
    // un guard de ganancia de respaldo baja unos dB hasta estabilizar.
    // Solo atenúa, así que no agrega riesgo de clipping para el MPO.
    fbs_.process(buffer, blockSize);

    // ─── 6.7. Output Compressor — freno de amplificación pre-MPO ─────────
    // Mira la envolvente REAL de salida (post-EQ/Volume/FBS) y baja la ganancia
    // de forma SUAVE (soft-knee + ratio finito) cuando los picos se acercan al
    // techo del MPO. Esto descarga al MPO: en vez de recortar duro los picos
    // (hard-clamp → THD → "silbido"), el MPO recibe una señal ya contenida y
    // casi nunca tiene que actuar. Solo atenúa. Su threshold está anclado
    // 12 dB bajo el techo del MPO (kSoftLimiterHeadroom, ETAPA 1 hotfix:
    // bajamos de 22 dB a 12 dB para no atenuar la voz conversacional, ya que
    // 22 dB hacía que el peak-follower tomara los picos de habla normales y
    // sostuviera la atenuación con release 80 ms, bajando el volumen).
    // A nivel de voz conversacional (picos ~-13 dBFS) cae justo en el knee
    // → atenuación < 1 dB → transparente. Ante multitono broadband o picos
    // agresivos, frena con ratio 4:1 ANTES del MPO sin opacar la voz.
    oc_.process(buffer, blockSize);

    // ─── 7. MPO — sample-by-sample peak limiter (ÚLTIMA etapa) ──────────
    // Red de seguridad absoluta. Garantiza que ninguna muestra excede
    // 0.85 lineal (-1.4 dBFS). Opera muestra-por-muestra, no block-rate.
    // Threshold lineal directo (independiente del offset de calibración).
    // FDA 21 CFR 800.30 limita output OTC a 111 dB SPL en el oído;
    // con auriculares, 0.85 lineal es conservador y seguro.
    mpo_.process(buffer, blockSize);

    // ─── 7.5. AFC — inyectar probe noise + capturar referencia ───────────
    // El probe noise (~-50 dBFS, inaudible) se suma a la señal de salida
    // que va al parlante. Esta señal completa (DSP + probe) se almacena
    // como referencia para el NLMS del bloque siguiente. El probe
    // decorrelaciona la referencia de la señal deseada y evita entrainment.
    // DESPUÉS del MPO para que el probe no dispare el limiter (nivel << th).
    afc_.injectProbeAndCapture(buffer, blockSize);

    // Métricas finales: output level, peak, clip count
    {
        float peak = 0.0f;
        int clips = 0;
        for (int i = 0; i < blockSize; ++i) {
            float absSample = std::fabs(buffer[i]);
            if (absSample > peak) peak = absSample;
            if (absSample >= 1.0f) clips++;
        }
        lastOutputLevelDb_.store(measureRmsDb(buffer, blockSize), std::memory_order_relaxed);
        lastPeakSample_.store(peak, std::memory_order_relaxed);
        lastClipCount_.store(clips, std::memory_order_relaxed);
    }

    // Métrica WDRC: determinar región basada en inputLevelDb.
    // FIX (auditoría sim_v3): antes usaba compKnee=55 hardcodeado, lo que
    // reportaba la región equivocada cuando el clasificador de entorno había
    // rampado el knee a otro valor (p.ej. 40 dB SPL en NOISE). Ahora usa el
    // valor SUAVIZADO real (wdrcKneeRamp_) para que el diagnóstico coincida
    // con la compresión efectivamente aplicada. Solo afecta la métrica de
    // diagnóstico; no altera el audio.
    {
        const float expKnee = 35.0f;          // knee de expansión (default WdrcParams)
        const float compKnee = wdrcKneeRamp_;  // knee de compresión REAL (rampado)
        int region = 1; // linear
        if (inputLevelDb < expKnee) region = 0; // expansion
        else if (inputLevelDb > compKnee) region = 2; // compression
        lastWdrcRegion_.store(region, std::memory_order_relaxed);
    }

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
    // Expansion knee/ratio + attack/release: aplicar inmediato (no producen
    // saltos audibles — la expansión atenúa señales ya débiles y los tiempos
    // de envolvente son suaves por naturaleza).
    wdrc_.setExpansionKnee(params.expansionKnee);
    wdrc_.setExpansionRatio(params.expansionRatio);
    wdrc_.setAttackMs(params.attackMs);
    wdrc_.setReleaseMs(params.releaseMs);

    // Compression knee/ratio: fijar TARGETS de la rampa exponencial existente
    // (kWdrcRampAlpha=0.02, ~200 ms). La rampa corre cada bloque en
    // processBlock() y converge suavemente al target, eliminando el "pop" al
    // cambiar de preset o togglear MHL ON/OFF desde Dart.
    // ANTES: se pisaba directamente wdrc_.setCompressionKnee/Ratio → salto
    //        brusco de compresión (audible como click/pop).
    // AHORA: la misma rampa que suaviza los cambios del clasificador automático
    //        suaviza también los cambios desde Dart (presets, MHL, manual).
    wdrcKneeTarget_  = params.compressionKnee;
    wdrcRatioTarget_ = params.compressionRatio;
}

void DspPipeline::setNrLevel(int level) {
    // Clamp al rango válido [0, 3]
    level = std::max(0, std::min(3, level));
    nr_.setLevel(level);
}

void DspPipeline::setSplOffset(float offset) {
    splOffset_.store(offset, std::memory_order_relaxed);
    // El MPO clínico se deriva con kMpoSplOffset (calibración de SALIDA),
    // NO con el offset de entrada del mic. Por lo tanto, cambiar la
    // calibración del micrófono NO altera el techo de protección del MPO.
    // Reaplicamos el threshold (idempotente) para cubrir el caso de que el
    // MPO clínico se hubiera fijado antes de este cambio de offset.
    applyMpoThresholdFromDbSpl(mpoThresholdDbSpl_.load(std::memory_order_relaxed));
}

void DspPipeline::setMpoThresholdDbSpl(float thresholdDbSpl) {
    // Validación interna: rechazar NaN/Inf. La validación de rango clínico
    // [80, 132] dB SPL la hace el caller (Dart AudioBridgeImpl).
    if (!std::isfinite(thresholdDbSpl)) {
        return;
    }

    // Persistir el valor en dB SPL (permite re-derivar en setSplOffset).
    mpoThresholdDbSpl_.store(thresholdDbSpl, std::memory_order_relaxed);

    // Aplicar usando la calibración de SALIDA dedicada (kMpoSplOffset),
    // manteniendo el clamp a la red de seguridad digital (kMpoDigitalCeiling).
    applyMpoThresholdFromDbSpl(thresholdDbSpl);
}

void DspPipeline::applyMpoThresholdFromDbSpl(float dbSpl) {
    // MPO clínico no seteado (NaN) → techo digital puro (comportamiento legacy).
    if (!std::isfinite(dbSpl)) {
        mpo_.setThresholdLinear(kMpoDigitalCeiling);
        // El freno de salida se ancla bajo el techo digital del MPO.
        // ETAPA 1 v3: techo digital ≈ 118.6 dB SPL (≥ HIGH) → headroom -12 dB.
        oc_.setThresholdLinear(kMpoDigitalCeiling *
                               computeSoftLimiterHeadroom(dbSpl));
        return;
    }

    // Reconciliación decisión B (audifono-v3): conversión dB SPL → lineal con
    // la calibración de SALIDA (oído), NO con el offset de entrada del mic.
    //   linear = 10^((dbSpl - kMpoSplOffset) / 20)
    const float linear = std::pow(10.0f, (dbSpl - kMpoSplOffset) / 20.0f);

    // Clamp al techo de seguridad digital (≈ -1.4 dBFS) para preservar la
    // protección anti-clipping del pipeline (garantía |y| ≤ kMpoDigitalCeiling).
    const float safeLinear = (linear > kMpoDigitalCeiling) ? kMpoDigitalCeiling : linear;
    if (safeLinear > 0.0f) {
        mpo_.setThresholdLinear(safeLinear);
        // ETAPA 1 v3 (headroom condicional según MPO clínico):
        //   - MHL Prescripción ON (dbSpl ≤ 100 dB SPL): headroom -6 dB. El MPO
        //     clínico ya es per-band conservador → el OC sólo debe frenar
        //     picos extremos. -6 dB deja la voz conversacional totalmente
        //     transparente (caso real reportado: MPO 98.75 dB SPL → threshold
        //     OC ≈ 92.75 dB SPL > picos voz normal).
        //   - MHL OFF / MPO alto (dbSpl ≥ 110 dB SPL): headroom -12 dB. El OC
        //     es la primera defensa contra suma multitono y transitorios.
        //   - Entre 100 y 110 dB SPL: rampa lineal en dB → sin "click" al
        //     activar/desactivar MHL durante el fitting.
        // El threshold "sigue" automáticamente al techo MPO clínico del paciente
        // (severa/moderada/leve) sin que la app tenga que tocar nada extra.
        const float headroom = computeSoftLimiterHeadroom(dbSpl);
        oc_.setThresholdLinear(safeLinear * headroom);
    }
}

float DspPipeline::computeSoftLimiterHeadroom(float mpoDbSpl) noexcept {
    // MPO no clínico (NaN/Inf) o ≥ HIGH (MHL OFF / techo digital):
    //   modo "normal" → -12 dB de headroom (cubre crest factor habla +
    //   suma RMS multitono).
    if (!std::isfinite(mpoDbSpl) || mpoDbSpl >= kSoftLimiterMpoHighDbSpl) {
        return kSoftLimiterHeadroom; // 0.2512 ≈ -12 dB
    }
    // MHL Prescripción ON (MPO clínico bajo, conservador):
    //   headroom relajado → -6 dB. El MPO ya limita per-band, el OC sólo
    //   actúa como red de seguridad final para picos extremos.
    if (mpoDbSpl <= kSoftLimiterMpoLowDbSpl) {
        return kSoftLimiterHeadroomMhl; // 0.5012 ≈ -6 dB
    }
    // Zona de transición [LOW, HIGH]: interpolación lineal EN DB para no
    // generar "click" perceptible al cambiar el MPO clínico (activar/
    // desactivar MHL Prescripción). Lineal en dB ↔ exponencial en lineal,
    // que es lo que el oído percibe como rampa uniforme.
    constexpr float kHeadroomMhlDb    = -6.0f;
    constexpr float kHeadroomNormalDb = -12.0f;
    const float t =
        (mpoDbSpl - kSoftLimiterMpoLowDbSpl) /
        (kSoftLimiterMpoHighDbSpl - kSoftLimiterMpoLowDbSpl); // 0..1
    const float headroomDb =
        kHeadroomMhlDb + t * (kHeadroomNormalDb - kHeadroomMhlDb);
    return std::pow(10.0f, headroomDb / 20.0f);
}

float DspPipeline::getLastInputLevelDb() const {
    return lastInputLevelDb_.load(std::memory_order_relaxed);
}

DspPipeline::StageMetrics DspPipeline::getStageMetrics() const {
    StageMetrics m;
    m.inputLevel = lastInputLevelDb_.load(std::memory_order_relaxed);
    m.postNrLevel = lastPostNrLevelDb_.load(std::memory_order_relaxed);
    m.postEqLevel = lastPostEqLevelDb_.load(std::memory_order_relaxed);
    m.postWdrcLevel = lastPostWdrcLevelDb_.load(std::memory_order_relaxed);
    m.postVolumeLevel = lastPostVolumeLevelDb_.load(std::memory_order_relaxed);
    m.outputLevel = lastOutputLevelDb_.load(std::memory_order_relaxed);
    m.peakSample = lastPeakSample_.load(std::memory_order_relaxed);
    m.clipCount = lastClipCount_.load(std::memory_order_relaxed);
    m.wdrcGainFactor = lastWdrcGainFactor_.load(std::memory_order_relaxed);
    m.wdrcRegion = lastWdrcRegion_.load(std::memory_order_relaxed);
    m.eqMaxGain = eq_.getMaxGain();
    m.environmentClass = envClassifier_.getCurrentClass();
    // Diagnóstico: origen del nivel WDRC (Property 8 del design).
    // Cuando wdrcUsesExternalLevel_ es true, lastInputLevelDb_ contiene el
    // nivel pre-DNN pasado por el AudioEngine; lo exponemos como
    // preDnnLevelDb. Si fue medición local, dejamos el sentinel -1.0f.
    m.wdrcUsesExternalLevel = wdrcUsesExternalLevel_.load(std::memory_order_relaxed);
    m.preDnnLevelDb = m.wdrcUsesExternalLevel ? m.inputLevel : -1.0f;
    // Aviso de limitación sostenida del MPO (R9.2 audifono-v3).
    m.mpoLimitingFraction = mpo_.getLimitingFraction();
    m.mpoLimitingSustained = mpo_.isLimitingSustained();
    return m;
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

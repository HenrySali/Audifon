/// @file mvdr_beamformer.h
/// @brief MVDR Beamformer de 2 microfonos para realce de voz frontal (header-only).
///
/// Opera en dominio frecuencia (STFT) con overlap-add.
///
/// Papers de referencia:
///   - PMC7545265: VAD-assisted MVDR en smartphone
///   - PMC7398114: MVDR + DNN para hearing aids
///   - PMC7928060: Efficient two-microphone speech enhancement
///   - Ephraim & Malah (1984): decision-directed a priori SNR.
///   - Lotter & Vary (2005): SGJMAP speech estimator (super-Gaussian prior).
///   - Cox et al.: robust MVDR / diagonal loading.
///
/// Uso:
///   MvdrBeamformer bf;
///   bf.init(sampleRate);
///   // En el callback de audio:
///   bf.process(ch0, ch1, output, numFrames, vadActive);
///
/// =====================================================================
/// FIXES MVDR 1-4 (validados en Octave: ANALISIS_MVDR/mvdr_run_fix.m,
/// RESUMEN_MVDR_FIX.txt). Diagnostico: la salida sonaba a "emisora sin
/// sintonia" con voz ronca porque Rnn absorbia la propia voz (auto-
/// cancelacion) y el WNG se disparaba.
///
///   FIX #1  AUTO-CANCELACION (causa principal). Se elimino el refresh
///           periodico forzado de Rnn (kRnnRefreshInterval) que actualizaba
///           CON voz presente, y se dejo de depender del VAD externo (se
///           pega en true por histeresis). Ahora la deteccion noise-only es
///           INTERNA y robusta: energia de trama vs piso con min-tracking
///           (thrFactor=3.0, riseFactor=1.01) + estacionariedad espectral
///           (flujo log-espectral < fluxThr=6.0). Rnn se actualiza SOLO en
///           noise-only (o durante el warmup inicial); se CONGELA con voz.
///           Resultado sim: updates-durante-voz 58 -> 0; correlacion de voz
///           0.374 -> 0.497; SNR de voz -7.9 dB -> -4.8 dB.
///
///   FIX #2  POST-FILTRO SGJMAP (Super-Gaussian JMAP estimator) tras el
///           MVDR. Reemplaza al Wiener DD por preservar 3× mas los onsets
///           (30.9% vs 10.5%, validado en mvdr_run_sgjmap.m). Ganancia:
///           G = max(1 - mu/(2*gamma*sqrt(xi)), Gmin). xi se estima con DD
///           suave (sgjBeta=0.5). Piso gMinDb=-12 dB. La potencia de ruido
///           a la salida sale de w^H*Rnn*w.
///
///   FIX #3  DIAGONAL LOADING ADAPTATIVO = loadMu*trace(Rnn)/2 (loadMu=1.0),
///           con piso 1e-9, en vez del kReg=1e-3 fijo. Acota el white-noise-
///           gain: ||w||^2 max 1.98 -> 0.67.
///
///   FIX #4  DEREVERB SUAVIZADO: over 1.6->1.1, floor 0.30->0.40 y suavizado
///           temporal de la ganancia (drGainSmooth=0.60) anti musical-noise.
///
/// Todos los parametros nuevos son miembros atomicos con setters (patron
/// setDereverb*) y DEFAULTS = valores validados, para afinar sin recompilar
/// si luego se cablea JNI. El argumento vadActive de process() quedo sin uso
/// funcional (la deteccion es interna); se mantiene por compatibilidad de ABI.
/// =====================================================================

#ifndef HEARING_AID_MVDR_BEAMFORMER_H
#define HEARING_AID_MVDR_BEAMFORMER_H

#include <cmath>
#include <complex>
#include <cstring>
#include <atomic>
#include <algorithm>

/// MVDR Beamformer de 2 microfonos para realce de voz frontal.
///
/// Implementacion header-only (como feedback_suppressor.h, transient_reducer.h)
/// para evitar cambios en CMakeLists.txt. Opera en dominio frecuencia (STFT)
/// con overlap-add y estima la matriz de correlacion del ruido usando VAD.
class MvdrBeamformer {
public:
    // Constantes del STFT
    static constexpr int kFftSize = 256;                  ///< N-point FFT
    static constexpr int kHopSize = kFftSize / 2;         ///< 128 (50% overlap)
    static constexpr int kNumBins = kFftSize / 2 + 1;     ///< 129 bins

    // Parametros del algoritmo
    static constexpr float kRnnAlpha = 0.98f;             ///< Smoothing exponencial de Rnn
    // Diagonal loading (regularizacion). Subido de 1e-6 a 1e-3: con carga muy
    // baja, en silencio los pesos MVDR se disparan y amplifican el ruido propio
    // de los micrófonos (hiss residual). 1e-3 calma el beamformer en niveles
    // bajos sin distorsionar la voz (robust MVDR / diagonal loading clásico,
    // Cox et al.; validado en implementaciones de audífono smartphone).
    static constexpr float kReg = 1e-3f;                  ///< Diagonal loading (regularizacion)
    static constexpr float kMicSpacing = 0.16f;           ///< Separacion entre mics (metros) — Moto G32: 160mm bottom-to-top
    static constexpr float kSoundSpeed = 343.0f;          ///< Velocidad del sonido (m/s)
    static constexpr float kPi = 3.14159265358979f;

    using Complex = std::complex<float>;

    /// Inicializa el beamformer con la sample rate del stream.
    /// Debe llamarse antes del primer process().
    void init(int sampleRate) {
        sampleRate_ = sampleRate;
        enabled_.store(false, std::memory_order_relaxed);

        // Limpiar buffers
        std::memset(inputBuf0_, 0, sizeof(inputBuf0_));
        std::memset(inputBuf1_, 0, sizeof(inputBuf1_));
        std::memset(outputBuf_, 0, sizeof(outputBuf_));
        inputBufPos_ = 0;
        outputBufPos_ = 0;

        // Inicializar Rnn a ceros. Fix #8 (auditoria MVDR): NO precargar la
        // diagonal con kReg aqui, porque computeMvdrWeights() ya suma kReg a
        // la diagonal justo antes de invertir. Inicializarla aca provocaba
        // doble diagonal loading (2*kReg efectivo) hasta que updateRnn()
        // sobrescribiera la estimacion. Con ceros, mientras rnnInitialized_
        // es false se usa delay-and-sum; una vez que hay ruido estimado, el
        // unico loading es el de computeMvdrWeights.
        for (int k = 0; k < kNumBins; ++k) {
            rnn_[k][0][0] = Complex(0.0f, 0.0f);
            rnn_[k][0][1] = Complex(0.0f, 0.0f);
            rnn_[k][1][0] = Complex(0.0f, 0.0f);
            rnn_[k][1][1] = Complex(0.0f, 0.0f);
        }

        // Calcular steering vector para el angulo configurado (default 0
        // grados = broadside frontal). Ver setSteeringAngle() y Fix #6:
        // 0 grados da poca discriminacion (~3.78 dB en la sim Octave); se
        // deja como default pero es ajustable segun orientacion del telefono.
        computeSteeringVector(steeringAngleDeg_);

        // Calcular ventana de Hann
        for (int n = 0; n < kFftSize; ++n) {
            window_[n] = 0.5f * (1.0f - std::cos(2.0f * kPi * static_cast<float>(n) / static_cast<float>(kFftSize)));
        }

        rnnInitialized_ = false;
        firstFrameProcessed_ = false;
        frameCount_ = 0;

        // Estado del supresor de reverberacion tardia (dereverb espectral).
        for (int k = 0; k < kNumBins; ++k) {
            revPowerPrev_[k] = 0.0f;
            drGain_[k] = 1.0f;          // FIX #4: ganancia dereverb suavizada
            prevLmag_[k] = 0.0f;        // FIX #1: log-mag previo (flujo espectral)
            Gprev_[k] = 1.0f;           // FIX #2: ganancia SGJMAP previa (DD)
            gammaPrev_[k] = 1.0f;       // FIX #2: SNR a posteriori previo (DD)
        }

        // FIX #1: estado de deteccion noise-only interna.
        noiseE_ = 0.0f;
        haveFloor_ = false;
        havePrevL_ = false;
    }

    /// Habilita o deshabilita el beamformer en runtime (thread-safe).
    void setEnabled(bool enabled) {
        enabled_.store(enabled, std::memory_order_release);
    }

    /// Retorna true si el beamformer esta habilitado.
    bool isEnabled() const {
        return enabled_.load(std::memory_order_acquire);
    }

    /// Ajusta el angulo de steering del beamformer (en grados) y recalcula
    /// el steering vector.
    ///
    /// Fix #6 (auditoria MVDR): con la fuente en broadside (0 grados, default)
    /// y esta geometria de mics (kMicSpacing=0.14 m), la simulacion Octave
    /// mostro una mejora de solo ~3.78 dB — la discriminacion espacial en
    /// broadside es intrinsecamente pobre porque el retardo inter-mic es ~0.
    /// Este setter permite experimentar con otros angulos segun la orientacion
    /// real del telefono respecto a la fuente de voz (p. ej. el usuario
    /// sostiene el telefono con el eje de mics apuntando al interlocutor).
    /// El default se mantiene en 0 grados para no cambiar el comportamiento
    /// actual; ajustar segun caracterizacion del hardware/uso.
    ///
    /// NOTA: no es thread-safe respecto al callback de audio (reescribe
    /// steeringVec_). Llamar solo con el beamformer detenido o aceptando un
    /// glitch transitorio de 1 frame.
    ///
    /// @param deg Angulo de arribo de la fuente objetivo, en grados.
    void setSteeringAngle(float deg) {
        steeringAngleDeg_ = deg;
        computeSteeringVector(deg);
    }

    /// @return Angulo de steering actual (grados).
    float getSteeringAngle() const { return steeringAngleDeg_; }

    // ─── Supresor de reverberacion tardia (R5, tarea 5.1) ────────────────
    // Toggle + parametros del dereverb espectral (Lebart/Habets simplificado).
    // Defaults = comportamiento previo (ON, decay 0.80, over 1.6, floor 0.30).

    /// Toggle del dereverb (AC3). Default ON (comportamiento actual). Poner en
    /// false devuelve la salida del MVDR sin la etapa de dereverb.
    void setDereverbEnabled(bool e) {
        dereverbEnabled_.store(e, std::memory_order_release);
    }
    bool isDereverbEnabled() const {
        return dereverbEnabled_.load(std::memory_order_acquire);
    }

    /// Intensidad de la sobre-sustraccion (over-subtraction factor, AC2).
    /// Mayor = mas supresion de la cola tardia. Default 1.6.
    void setDereverbStrength(float over) {
        if (over < 1.0f) over = 1.0f;
        if (over > 4.0f) over = 4.0f;
        dereverbOver_.store(over, std::memory_order_relaxed);
    }

    /// Suelo espectral de ganancia (spectral floor, AC2/AC4). Preserva la voz
    /// directa: cuanto mas alto, menos supresion maxima. Default 0.30
    /// (≈ -10 dB de supresion maxima).
    void setDereverbFloor(float floor) {
        if (floor < 0.05f) floor = 0.05f;
        if (floor > 1.0f) floor = 1.0f;
        dereverbFloor_.store(floor, std::memory_order_relaxed);
    }

    /// Factor de decaimiento (RT60 proxy, AC1). Default 0.80 (RT60~0.5 s a
    /// Tframe=8 ms). Mayor = cola mas larga asumida.
    void setDereverbDecay(float decay) {
        if (decay < 0.0f) decay = 0.0f;
        if (decay > 0.99f) decay = 0.99f;
        dereverbDecay_.store(decay, std::memory_order_relaxed);
    }

    /// FIX #4: suavizado temporal de la ganancia de dereverb (anti musical-
    /// noise). g_smooth[k] = s*g_smooth[k] + (1-s)*g_inst[k]. Default 0.60.
    void setDereverbGainSmooth(float s) {
        if (s < 0.0f) s = 0.0f;
        if (s > 0.99f) s = 0.99f;
        dereverbGainSmooth_.store(s, std::memory_order_relaxed);
    }

    // ─── FIX #1: deteccion noise-only interna (reemplaza dependencia del VAD) ─
    // Rnn se actualiza SOLO cuando la trama es noise-only (energia baja vs
    // piso min-tracked + estacionariedad espectral) o durante el warmup.

    /// Umbral de energia noise-only: E < thrFactor*pisoRuido. Default 3.0.
    void setNoiseThrFactor(float f) {
        if (f < 1.0f) f = 1.0f;
        noiseThrFactor_.store(f, std::memory_order_relaxed);
    }
    /// Tasa de subida del piso de ruido (min-tracking). Default 1.01.
    void setNoiseRiseFactor(float f) {
        if (f < 1.0f) f = 1.0f;
        if (f > 1.5f) f = 1.5f;
        noiseRiseFactor_.store(f, std::memory_order_relaxed);
    }
    /// Exigir tambien estacionariedad espectral para noise-only. Default true.
    void setNoiseUseFlux(bool e) {
        noiseUseFlux_.store(e, std::memory_order_relaxed);
    }
    /// Umbral de flujo log-espectral (var trama a trama). Default 6.0.
    void setNoiseFluxThr(float f) {
        if (f < 0.0f) f = 0.0f;
        noiseFluxThr_.store(f, std::memory_order_relaxed);
    }

    // ─── FIX #3: diagonal loading adaptativo ─────────────────────────────
    /// Factor del loading adaptativo: reg = loadMu*trace(Rnn)/2. Default 1.0.
    /// loadMu<=0 => usa el loading fijo kReg de respaldo.
    void setLoadMu(float mu) {
        loadMu_.store(mu, std::memory_order_relaxed);
    }

    // ─── FIX #2: post-filtro SGJMAP (reemplaza Wiener DD) ───────────────
    /// Toggle del post-filtro SGJMAP. Default ON.
    void setWienerEnabled(bool e) {
        wienerEnabled_.store(e, std::memory_order_release);
    }
    bool isWienerEnabled() const {
        return wienerEnabled_.load(std::memory_order_acquire);
    }
    /// Piso de ganancia SGJMAP en dB. Default -12 dB.
    void setWienerGMinDb(float db) {
        if (db > 0.0f) db = 0.0f;
        if (db < -60.0f) db = -60.0f;
        wienerGMinDb_.store(db, std::memory_order_relaxed);
    }
    /// Factor decision-directed suave para xi (a priori SNR). Default 0.5.
    /// Mas bajo que Wiener DD (0.98) para preservar onsets.
    void setSgjBeta(float b) {
        if (b < 0.0f) b = 0.0f;
        if (b > 0.99f) b = 0.99f;
        sgjBeta_.store(b, std::memory_order_relaxed);
    }
    /// Parametro de forma super-Gaussiana (mu). Default 1.0, rango [0.1, 3.0].
    /// mu=1 ~ Laplaciano; mu>1 mas agresivo; mu<1 mas conservador.
    void setSgjMu(float mu) {
        if (mu < 0.1f) mu = 0.1f;
        if (mu > 3.0f) mu = 3.0f;
        sgjMu_.store(mu, std::memory_order_relaxed);
    }

    /// Procesa un bloque de audio estereo y produce salida mono beamformed.
    /// Usa overlap-add internamente para manejar bloques de cualquier tamano.
    /// @param ch0 Canal 0 (mic inferior), numFrames muestras float32
    /// @param ch1 Canal 1 (mic superior), numFrames muestras float32
    /// @param output Buffer de salida mono, numFrames muestras float32
    /// @param numFrames Numero de muestras por canal
    /// @param vadActive true si el VAD detecta voz (NO actualizar Rnn)
    void process(const float* ch0, const float* ch1,
                 float* output, int numFrames, bool vadActive) {
        if (!enabled_.load(std::memory_order_acquire)) {
            // Bypass: copiar canal 0 directamente
            std::memcpy(output, ch0, numFrames * sizeof(float));
            return;
        }

        // Passthrough ch0 until the first full STFT frame has been
        // synthesized, to avoid startup silence from empty outputBuf_.
        if (!firstFrameProcessed_) {
            // Feed input into STFT buffers (building up for first frame)
            int samplesProcessed = 0;
            while (samplesProcessed < numFrames) {
                int samplesToAdd = std::min(
                    kFftSize - inputBufPos_, numFrames - samplesProcessed);

                for (int i = 0; i < samplesToAdd; ++i) {
                    inputBuf0_[inputBufPos_ + i] = ch0[samplesProcessed + i];
                    inputBuf1_[inputBufPos_ + i] = ch1[samplesProcessed + i];
                }
                inputBufPos_ += samplesToAdd;
                samplesProcessed += samplesToAdd;

                if (inputBufPos_ >= kFftSize) {
                    processFrame(vadActive);
                    std::memmove(inputBuf0_, inputBuf0_ + kHopSize,
                                 kHopSize * sizeof(float));
                    std::memmove(inputBuf1_, inputBuf1_ + kHopSize,
                                 kHopSize * sizeof(float));
                    inputBufPos_ = kHopSize;
                    firstFrameProcessed_ = true;
                    break;
                }
            }

            if (!firstFrameProcessed_) {
                // Still priming: passthrough ch0 for this block
                std::memcpy(output, ch0, numFrames * sizeof(float));
                return;
            }

            // First frame just processed. For this transitional block,
            // passthrough ch0 to avoid partial/glitchy output.
            std::memcpy(output, ch0, numFrames * sizeof(float));
            // Fix #4 (auditoría MVDR): NO borrar outputBuf_ con memset. El
            // frame recién sintetizado en processFrame() ya quedó acumulado
            // (overlap-add) y debe consumirse en el próximo callback, no
            // descartarse — descartarlo producía un dropout en la transición
            // passthrough→beamformed. Solo reseteamos el índice de lectura.
            outputBufPos_ = 0;
            return;
        }

        int samplesProcessed = 0;
        while (samplesProcessed < numFrames) {
            // Llenar el buffer de entrada hasta kFftSize
            int samplesToAdd = std::min(
                kFftSize - inputBufPos_, numFrames - samplesProcessed);

            for (int i = 0; i < samplesToAdd; ++i) {
                inputBuf0_[inputBufPos_ + i] = ch0[samplesProcessed + i];
                inputBuf1_[inputBufPos_ + i] = ch1[samplesProcessed + i];
            }
            inputBufPos_ += samplesToAdd;
            samplesProcessed += samplesToAdd;

            // Cuando tenemos un frame completo, procesar
            if (inputBufPos_ >= kFftSize) {
                processFrame(vadActive);
                // Shift buffer: mover la segunda mitad al inicio (overlap)
                std::memmove(inputBuf0_, inputBuf0_ + kHopSize,
                             kHopSize * sizeof(float));
                std::memmove(inputBuf1_, inputBuf1_ + kHopSize,
                             kHopSize * sizeof(float));
                inputBufPos_ = kHopSize;
            }
        }

        // Extraer output del buffer de overlap-add
        for (int i = 0; i < numFrames; ++i) {
            output[i] = outputBuf_[outputBufPos_ + i];
        }
        // Shift output buffer
        int remaining = kFftSize * 2 - outputBufPos_ - numFrames;
        if (remaining > 0) {
            std::memmove(outputBuf_, outputBuf_ + numFrames,
                         remaining * sizeof(float));
            std::memset(outputBuf_ + remaining, 0, numFrames * sizeof(float));
        } else {
            std::memset(outputBuf_, 0, sizeof(outputBuf_));
        }
        // outputBufPos_ stays at 0 since we shifted
        outputBufPos_ = 0;
    }

private:
    /// Procesa un frame completo (kFftSize muestras) con STFT -> MVDR -> ISTFT
    void processFrame(bool vadActive) {
        Complex X0[kNumBins], X1[kNumBins];
        Complex Y[kNumBins];
        float frameBuf[kFftSize];

        // Energia de la trama (2 mics, muestras ventaneadas) para FIX #1.
        float frameEnergy = 0.0f;

        // --- STFT del canal 0 ---
        for (int n = 0; n < kFftSize; ++n) {
            frameBuf[n] = inputBuf0_[n] * window_[n];
            frameEnergy += frameBuf[n] * frameBuf[n];
        }
        realFFT(frameBuf, X0, kFftSize);

        // --- STFT del canal 1 ---
        for (int n = 0; n < kFftSize; ++n) {
            frameBuf[n] = inputBuf1_[n] * window_[n];
            frameEnergy += frameBuf[n] * frameBuf[n];
        }
        realFFT(frameBuf, X1, kFftSize);

        // --- FIX #1: actualizar Rnn SOLO en noise-only (deteccion interna) ---
        // Diagnostico (RESUMEN_MVDR_FIX.txt): el refresh periodico forzado y
        // la dependencia del VAD externo (que se pega en true por histeresis:
        // vadScore 0.37-0.81 mantiene voz) hacian que Rnn se actualizara CON
        // voz presente => el MVDR aprendia la voz como "ruido" y la cancelaba
        // (updates-durante-voz=58). Se elimina el refresh periodico y el VAD;
        // la deteccion noise-only es interna y robusta:
        //   (a) energia baja: E < thrFactor * pisoRuido, con piso por
        //       min-tracking (baja instantanea, sube lento *riseFactor).
        //   (b) estacionariedad: flujo log-espectral < fluxThr.
        // Rnn se actualiza solo si noise-only (o warmup inicial); se CONGELA
        // con voz. El argumento vadActive queda sin uso (compat. ABI).
        (void)vadActive;
        constexpr int kRnnWarmupFrames = 50;

        const float thrFactor  = noiseThrFactor_.load(std::memory_order_relaxed);
        const float riseFactor = noiseRiseFactor_.load(std::memory_order_relaxed);
        const bool  useFlux    = noiseUseFlux_.load(std::memory_order_relaxed);
        const float fluxThr    = noiseFluxThr_.load(std::memory_order_relaxed);

        // Piso de ruido por min-tracking sobre la energia de trama.
        if (!haveFloor_) {
            noiseE_ = frameEnergy;
            haveFloor_ = true;
        } else if (frameEnergy < noiseE_) {
            noiseE_ = frameEnergy;                 // baja instantanea
        } else {
            noiseE_ *= riseFactor;                 // sube lento (min-tracking)
            if (noiseE_ > frameEnergy) noiseE_ = frameEnergy;
        }
        const bool lowEnergy = (frameEnergy < thrFactor * noiseE_);

        // Estacionariedad espectral: varianza del log-espectro trama a trama.
        bool stationary = true;
        {
            float flux = 0.0f;
            for (int k = 0; k < kNumBins; ++k) {
                const float mag2 = X0[k].real() * X0[k].real()
                                 + X0[k].imag() * X0[k].imag();
                const float lmag = 10.0f * std::log10(mag2 + 1e-9f);
                if (useFlux && havePrevL_) {
                    const float d = lmag - prevLmag_[k];
                    flux += d * d;
                }
                prevLmag_[k] = lmag;
            }
            if (useFlux && havePrevL_) {
                flux /= static_cast<float>(kNumBins);
                stationary = (flux < fluxThr);
            }
            havePrevL_ = true;
        }

        const bool noiseOnly = lowEnergy && stationary;
        const bool warmup = (frameCount_ < kRnnWarmupFrames);

        // doUpdate replica mvdr_run_fix.m: (noiseOnly || !init) && (noiseOnly || warmup).
        // La 1ra trama inicializa con alpha=0 (carga directa); luego solo
        // se actualiza en noise-only (o warmup si aun no habia init).
        const bool doUpdate = noiseOnly || !rnnInitialized_;
        if (doUpdate && (noiseOnly || warmup)) {
            const float a = rnnInitialized_ ? kRnnAlpha : 0.0f;
            updateRnn(X0, X1, a);
            rnnInitialized_ = true;
        }

        // --- Calcular y aplicar pesos MVDR por bin ---
        // noisePow[k] = potencia de ruido a la salida (w^H*Rnn*w), la usa el
        // post-filtro SGJMAP (FIX #2).
        float noisePow[kNumBins];
        for (int k = 0; k < kNumBins; ++k) {
            if (!rnnInitialized_) {
                // Sin estimacion de ruido aun: delay-and-sum simple
                Y[k] = (X0[k] + X1[k]) * 0.5f;
                noisePow[k] = 0.5f * (X0[k].real() * X0[k].real() + X0[k].imag() * X0[k].imag()
                                    + X1[k].real() * X1[k].real() + X1[k].imag() * X1[k].imag());
            } else {
                // Vector de observacion x = [X0[k], X1[k]]^T
                // w = Rnn^{-1} * d / (d^H * Rnn^{-1} * d)
                Complex w[2];
                computeMvdrWeights(k, w);
                // y[k] = w^H * x = conj(w0)*X0 + conj(w1)*X1
                Y[k] = std::conj(w[0]) * X0[k] + std::conj(w[1]) * X1[k];
                // Potencia de ruido a la salida: w^H * Rnn * w (Rnn sin loading).
                const Complex Rw0 = rnn_[k][0][0] * w[0] + rnn_[k][0][1] * w[1];
                const Complex Rw1 = rnn_[k][1][0] * w[0] + rnn_[k][1][1] * w[1];
                const float np = (std::conj(w[0]) * Rw0 + std::conj(w[1]) * Rw1).real();
                noisePow[k] = (np > 1e-12f) ? np : 1e-12f;
            }
        }

        // --- FIX #2: post-filtro SGJMAP (Super-Gaussian JMAP estimator) ------
        // Reemplaza Wiener DD. Preserva 3× mas onsets (30.9% vs 10.5%,
        // validado en mvdr_run_sgjmap.m).
        // Ganancia: G = max(1 - mu / (2*gamma*sqrt(xi)), Gmin)
        //   gamma = |Y|^2 / noisePow        (SNR a posteriori, instantaneo)
        //   xi = sgjBeta*(Gprev^2*gammaPrev) + (1-sgjBeta)*max(gamma-1,0)
        //        (DD suave, beta=0.5 << 0.98 del Wiener => onsets rapidos)
        if (wienerEnabled_.load(std::memory_order_acquire) && rnnInitialized_) {
            const float gMinDb  = wienerGMinDb_.load(std::memory_order_relaxed);
            const float beta    = sgjBeta_.load(std::memory_order_relaxed);
            const float mu      = sgjMu_.load(std::memory_order_relaxed);
            const float Gmin    = std::pow(10.0f, gMinDb / 20.0f);   // piso en amplitud
            for (int k = 0; k < kNumBins; ++k) {
                const float Ypow  = Y[k].real() * Y[k].real() + Y[k].imag() * Y[k].imag();
                const float gamma = Ypow / (noisePow[k] + 1e-12f);   // a posteriori
                // xi: a priori SNR con DD suave (beta=0.5)
                float xi = beta * (Gprev_[k] * Gprev_[k] * gammaPrev_[k])
                         + (1.0f - beta) * std::max(gamma - 1.0f, 0.0f);
                if (xi < 1e-6f) xi = 1e-6f;   // proteccion sqrt
                // SGJMAP gain
                float G = 1.0f - mu / (2.0f * gamma * sqrtf(xi) + 1e-9f);
                if (G < Gmin) G = Gmin;
                if (G > 1.0f) G = 1.0f;
                Y[k] *= G;
                Gprev_[k] = G;
                gammaPrev_[k] = gamma;
            }
        }

        // --- Supresion de reverberacion tardia (dereverb espectral) ---
        // Ataca el "eco" de la sala que el MVDR (beamforming espacial) NO quita
        // y que antes eliminaba el WPE (removido por el crash de LAPACK).
        //
        // Modelo (Lebart/Habets simplificado, sin matrices): la reverberacion
        // tardia decae exponencialmente. Estimamos su energia como una version
        // atenuada de la potencia del frame anterior y la restamos del actual.
        // La voz directa tiene ataques (energia creciente) -> gain ~1; la cola
        // reverberante (energia decreciente/estacionaria) -> gain baja.
        //
        // kReverbDecay = 10^(-6 * Tframe / RT60), RT60~0.5s (sala hogar),
        //   Tframe = kHopSize/fs = 128/16000 = 8 ms -> ~0.80.
        // kReverbOver = factor de sobre-sustraccion. kReverbFloor = piso de
        //   ganancia (max ~10 dB de supresion, conservador para no distorsionar).
        if (dereverbEnabled_.load(std::memory_order_acquire)) {
            // R5 (mvdr-noise-clarity-tuning, tarea 5.1): parametros del
            // dereverb promovidos de constexpr locales a miembros atomicos con
            // setters. Defaults = valores previos (decay 0.80, over 1.6, floor
            // 0.30) → comportamiento identico si Dart no los cambia (R6.5).
            const float kReverbDecay = dereverbDecay_.load(std::memory_order_relaxed);
            const float kReverbOver  = dereverbOver_.load(std::memory_order_relaxed);
            const float kReverbFloor = dereverbFloor_.load(std::memory_order_relaxed);
            // FIX #4: suavizado temporal de la ganancia (anti musical-noise).
            const float kGainSmooth  = dereverbGainSmooth_.load(std::memory_order_relaxed);
            for (int k = 0; k < kNumBins; ++k) {
                const float power = Y[k].real() * Y[k].real()
                                  + Y[k].imag() * Y[k].imag();
                const float lateRev = kReverbDecay * revPowerPrev_[k];
                float gain = 1.0f;
                if (power > 1e-12f) {
                    gain = (power - kReverbOver * lateRev) / power;
                }
                if (gain < kReverbFloor) gain = kReverbFloor;
                if (gain > 1.0f) gain = 1.0f;
                // FIX #4: suavizar la ganancia en el tiempo por bin.
                drGain_[k] = kGainSmooth * drGain_[k] + (1.0f - kGainSmooth) * gain;
                const float g = drGain_[k];
                Y[k] *= g;
                // Actualizar tracker con la potencia (post-gain) para que la
                // cola se siga rastreando sin realimentar la parte suprimida.
                const float powerPost = power * g * g;
                revPowerPrev_[k] = kReverbDecay * revPowerPrev_[k]
                                 + (1.0f - kReverbDecay) * powerPost;
            }
        }

        // --- ISTFT (overlap-add) ---
        realIFFT(Y, frameBuf, kFftSize);

        // Aplicar ventana de sintesis y acumular en output buffer
        // Normalizacion: Hann ventana analisis+sintesis con 50% overlap
        // produce un factor COLA de 0.75. Compensamos con 1/0.75 = 4/3.
        static constexpr float kOlaNorm = 1.0f / 0.75f;
        for (int n = 0; n < kFftSize; ++n) {
            outputBuf_[n] += frameBuf[n] * window_[n] * kOlaNorm;
        }

        frameCount_++;
    }

    /// Actualiza la matriz de correlacion espacial del ruido (Rnn)
    /// con suavizado exponencial. Solo llamar durante noise-only.
    /// Nota: diagonal loading se aplica en computeMvdrWeights() justo antes
    /// de la inversion, no durante la acumulacion, para evitar drift.
    /// @param alpha factor de suavizado (FIX #1: alpha=0 en la 1ra trama para
    ///        cargar Rnn directo; kRnnAlpha en las siguientes).
    void updateRnn(const Complex* X0, const Complex* X1, float alpha = kRnnAlpha) {
        const float oneMinusAlpha = 1.0f - alpha;

        for (int k = 0; k < kNumBins; ++k) {
            // Rnn[k] = alpha * Rnn[k] + (1-alpha) * x * x^H
            Complex x0 = X0[k];
            Complex x1 = X1[k];

            rnn_[k][0][0] = alpha * rnn_[k][0][0] +
                            oneMinusAlpha * (x0 * std::conj(x0));
            rnn_[k][0][1] = alpha * rnn_[k][0][1] +
                            oneMinusAlpha * (x0 * std::conj(x1));
            rnn_[k][1][0] = alpha * rnn_[k][1][0] +
                            oneMinusAlpha * (x1 * std::conj(x0));
            rnn_[k][1][1] = alpha * rnn_[k][1][1] +
                            oneMinusAlpha * (x1 * std::conj(x1));
        }
    }

    /// Calcula los pesos MVDR para un bin de frecuencia.
    /// Invierte la matriz 2x2 Rnn analiticamente y aplica la formula cerrada.
    /// Diagonal loading (kReg) se aplica aqui justo antes de la inversion
    /// para no acumular regularizacion en la estimacion de Rnn.
    void computeMvdrWeights(int k, Complex* w) const {
        // FIX #3: diagonal loading ADAPTATIVO = loadMu * trace(Rnn)/2, con
        // piso 1e-9. Acota el white-noise-gain (||w||^2 max 1.98 -> 0.67 en la
        // sim) sin el kReg=1e-3 fijo, que en bins de baja energia sobre-
        // regularizaba y en bins de alta energia casi no cargaba. loadMu<=0
        // vuelve al kReg fijo de respaldo.
        const float loadMu = loadMu_.load(std::memory_order_relaxed);
        float reg;
        if (loadMu > 0.0f) {
            reg = loadMu * 0.5f * (rnn_[k][0][0].real() + rnn_[k][1][1].real());
            if (reg < 1e-9f) reg = 1e-9f;
        } else {
            reg = kReg;
        }

        // Aplicar diagonal loading a una copia local antes de invertir
        Complex R00 = rnn_[k][0][0] + Complex(reg, 0.0f);
        Complex R01 = rnn_[k][0][1];
        Complex R10 = rnn_[k][1][0];
        Complex R11 = rnn_[k][1][1] + Complex(reg, 0.0f);

        // Rnn^{-1} para matriz 2x2:
        // inv(R) = (1/det) * [R11, -R01; -R10, R00]
        Complex det = R00 * R11 - R01 * R10;

        // Guard contra determinante cercano a cero
        float detMag = std::abs(det);
        if (detMag < 1e-10f) {
            // Fallback: delay-and-sum
            w[0] = Complex(0.5f, 0.0f);
            w[1] = Complex(0.5f, 0.0f);
            return;
        }

        Complex invDet = 1.0f / det;
        Complex Rinv[2][2];
        Rinv[0][0] =  R11 * invDet;
        Rinv[0][1] = -R01 * invDet;
        Rinv[1][0] = -R10 * invDet;
        Rinv[1][1] =  R00 * invDet;

        // Rinv * d
        Complex Rinv_d[2];
        Rinv_d[0] = Rinv[0][0] * steeringVec_[k][0] +
                    Rinv[0][1] * steeringVec_[k][1];
        Rinv_d[1] = Rinv[1][0] * steeringVec_[k][0] +
                    Rinv[1][1] * steeringVec_[k][1];

        // d^H * Rinv * d (escalar)
        Complex dH_Rinv_d = std::conj(steeringVec_[k][0]) * Rinv_d[0] +
                            std::conj(steeringVec_[k][1]) * Rinv_d[1];

        // Guard contra denominador cercano a cero
        float denom = std::abs(dH_Rinv_d);
        if (denom < 1e-10f) {
            w[0] = Complex(0.5f, 0.0f);
            w[1] = Complex(0.5f, 0.0f);
            return;
        }

        // w = Rinv_d / dH_Rinv_d
        w[0] = Rinv_d[0] / dH_Rinv_d;
        w[1] = Rinv_d[1] / dH_Rinv_d;
    }

    /// Calcula el steering vector para un angulo dado (en grados).
    /// Para 2 mics lineales separados d metros, fuente a angulo theta:
    ///   d[k] = [1, exp(-j*2*pi*f_k*tau)]   donde tau = d_mic*sin(theta)/c
    void computeSteeringVector(float angleDeg) {
        float angleRad = angleDeg * kPi / 180.0f;
        float tau = kMicSpacing * std::sin(angleRad) / kSoundSpeed;

        for (int k = 0; k < kNumBins; ++k) {
            float freq = static_cast<float>(k) * static_cast<float>(sampleRate_) / static_cast<float>(kFftSize);
            float phase = -2.0f * kPi * freq * tau;
            steeringVec_[k][0] = Complex(1.0f, 0.0f);
            steeringVec_[k][1] = Complex(std::cos(phase), std::sin(phase));
        }
    }

    // --- FFT in-place (Cooley-Tukey radix-2, real-input) ---
    // Implementacion minima para mantener el header autosuficiente.
    // En produccion se puede reusar la FFT existente del proyecto.

    void realFFT(const float* input, Complex* output, int N) const {
        // Copiar a buffer complejo temporal
        Complex buf[kFftSize];
        for (int i = 0; i < N; ++i) {
            buf[i] = Complex(input[i], 0.0f);
        }

        // Bit-reversal permutation
        for (int i = 1, j = 0; i < N; ++i) {
            int bit = N >> 1;
            for (; j & bit; bit >>= 1) {
                j ^= bit;
            }
            j ^= bit;
            if (i < j) std::swap(buf[i], buf[j]);
        }

        // Butterfly stages
        for (int len = 2; len <= N; len <<= 1) {
            float ang = -2.0f * kPi / static_cast<float>(len);
            Complex wlen(std::cos(ang), std::sin(ang));
            for (int i = 0; i < N; i += len) {
                Complex w(1.0f, 0.0f);
                for (int j = 0; j < len / 2; ++j) {
                    Complex u = buf[i + j];
                    Complex v = buf[i + j + len / 2] * w;
                    buf[i + j] = u + v;
                    buf[i + j + len / 2] = u - v;
                    w *= wlen;
                }
            }
        }

        // Copiar bins positivos (espectro unilateral)
        for (int k = 0; k < kNumBins; ++k) {
            output[k] = buf[k];
        }
    }

    void realIFFT(const Complex* input, float* output, int N) const {
        Complex buf[kFftSize];
        // Reconstruir espectro completo (simetria hermitiana)
        for (int k = 0; k < kNumBins; ++k) {
            buf[k] = input[k];
        }
        for (int k = kNumBins; k < N; ++k) {
            buf[k] = std::conj(input[N - k]);
        }

        // IFFT = conj(FFT(conj(x))) / N
        for (int i = 0; i < N; ++i) {
            buf[i] = std::conj(buf[i]);
        }

        // Bit-reversal
        for (int i = 1, j = 0; i < N; ++i) {
            int bit = N >> 1;
            for (; j & bit; bit >>= 1) {
                j ^= bit;
            }
            j ^= bit;
            if (i < j) std::swap(buf[i], buf[j]);
        }

        // Butterfly stages
        for (int len = 2; len <= N; len <<= 1) {
            float ang = -2.0f * kPi / static_cast<float>(len);
            Complex wlen(std::cos(ang), std::sin(ang));
            for (int i = 0; i < N; i += len) {
                Complex w(1.0f, 0.0f);
                for (int j = 0; j < len / 2; ++j) {
                    Complex u = buf[i + j];
                    Complex v = buf[i + j + len / 2] * w;
                    buf[i + j] = u + v;
                    buf[i + j + len / 2] = u - v;
                    w *= wlen;
                }
            }
        }

        // Conjugar y dividir por N
        float invN = 1.0f / static_cast<float>(N);
        for (int i = 0; i < N; ++i) {
            output[i] = buf[i].real() * invN;
        }
    }

    // --- Estado interno ---
    std::atomic<bool> enabled_{false};
    int sampleRate_ = 16000;

    // Buffers de entrada (con espacio para overlap)
    float inputBuf0_[kFftSize * 2] = {};   ///< Canal 0
    float inputBuf1_[kFftSize * 2] = {};   ///< Canal 1
    int inputBufPos_ = 0;

    // Buffer de salida (overlap-add)
    float outputBuf_[kFftSize * 2] = {};
    int outputBufPos_ = 0;

    // Ventana de Hann
    float window_[kFftSize] = {};

    // Steering vector por bin [kNumBins][2]
    Complex steeringVec_[kNumBins][2] = {};

    // Angulo de steering (grados). Cambiado de 0 (broadside) a 90 (endfire):
    // En el Moto G32 los mics estan arriba y abajo (eje vertical). Con 0 deg
    // la separacion era minima (~3.78 dB en la sim). Con 90 deg (endfire) la
    // fuente esta en el eje de mics → maxima diferencia de tiempo → mejor
    // rechazo de ruido lateral. Paper (ResearchGate 2024): "el desempeno
    // optimo del MVDR ocurre en la direccion endfire". El usuario habla frente
    // al telefono (mic inferior apuntando a la boca) → ~90 deg es correcto.
    float steeringAngleDeg_ = 90.0f;

    // Matriz de correlacion del ruido [kNumBins][2][2]
    Complex rnn_[kNumBins][2][2] = {};

    bool rnnInitialized_ = false;
    bool firstFrameProcessed_ = false;
    int frameCount_ = 0;

    // Supresor de reverberacion tardia: potencia rastreada por bin.
    float revPowerPrev_[kNumBins] = {};
    // FIX #4: ganancia de dereverb suavizada por bin (init 1.0 en init()).
    float drGain_[kNumBins] = {};
    // Toggle del dereverb (default ON; ataca el "eco" de la sala).
    std::atomic<bool> dereverbEnabled_{true};
    // Parametros del dereverb. FIX #4: defaults SUAVIZADOS validados en Octave
    // (over 1.6->1.1, floor 0.30->0.40) + suavizado temporal de la ganancia.
    std::atomic<float> dereverbDecay_{0.80f};       ///< RT60 proxy (AC1)
    std::atomic<float> dereverbOver_{1.1f};         ///< over-subtraction (FIX #4)
    std::atomic<float> dereverbFloor_{0.40f};       ///< spectral floor (FIX #4)
    std::atomic<float> dereverbGainSmooth_{0.60f};  ///< suavizado ganancia (FIX #4)

    // ─── FIX #1: estado de deteccion noise-only interna ──────────────────
    float noiseE_ = 0.0f;              ///< piso de ruido (min-tracking)
    bool  haveFloor_ = false;          ///< piso inicializado
    float prevLmag_[kNumBins] = {};    ///< log-espectro previo (flujo)
    bool  havePrevL_ = false;          ///< log-espectro previo valido
    std::atomic<float> noiseThrFactor_{3.0f};   ///< E < thrFactor*piso => low energy
    std::atomic<float> noiseRiseFactor_{1.01f}; ///< tasa de subida del piso
    std::atomic<bool>  noiseUseFlux_{true};     ///< exigir estacionariedad
    std::atomic<float> noiseFluxThr_{6.0f};     ///< umbral de flujo espectral

    // ─── FIX #3: diagonal loading adaptativo ─────────────────────────────
    std::atomic<float> loadMu_{1.0f};  ///< reg = loadMu*trace(Rnn)/2 (<=0 => kReg)

    // ─── FIX #2: post-filtro SGJMAP (reemplaza Wiener DD) ───────────────
    std::atomic<bool>  wienerEnabled_{true};    ///< toggle post-filtro (default ON)
    std::atomic<float> wienerGMinDb_{-12.0f};   ///< piso de ganancia (dB)
    std::atomic<float> sgjBeta_{0.5f};          ///< DD suave para xi (0.5 preserva onsets)
    std::atomic<float> sgjMu_{1.0f};            ///< forma super-Gaussiana (1.0=Laplaciano)
    float Gprev_[kNumBins] = {};                ///< ganancia SGJMAP previa (DD)
    float gammaPrev_[kNumBins] = {};            ///< SNR a posteriori previo (DD)
};

#endif // HEARING_AID_MVDR_BEAMFORMER_H

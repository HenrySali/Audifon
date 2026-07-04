/// @file mvdr_beamformer.h
/// @brief MVDR Beamformer de 2 microfonos para realce de voz frontal (header-only).
///
/// Opera en dominio frecuencia (STFT) con overlap-add.
/// Usa el VAD externo (SceneAnalyzer) para estimar la matriz de
/// correlacion del ruido durante segmentos noise-only.
///
/// Papers de referencia:
///   - PMC7545265: VAD-assisted MVDR en smartphone
///   - PMC7398114: MVDR + DNN para hearing aids
///   - PMC7928060: Efficient two-microphone speech enhancement
///
/// Uso:
///   MvdrBeamformer bf;
///   bf.init(sampleRate);
///   // En el callback de audio:
///   bf.process(ch0, ch1, output, numFrames, vadActive);

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
    static constexpr float kReg = 1e-6f;                  ///< Diagonal loading (regularizacion)
    static constexpr float kMicSpacing = 0.14f;           ///< Separacion entre mics (metros)
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

        // Inicializar Rnn como identidad (diagonal loading)
        for (int k = 0; k < kNumBins; ++k) {
            rnn_[k][0][0] = Complex(kReg, 0.0f);
            rnn_[k][0][1] = Complex(0.0f, 0.0f);
            rnn_[k][1][0] = Complex(0.0f, 0.0f);
            rnn_[k][1][1] = Complex(kReg, 0.0f);
        }

        // Calcular steering vector para fuente frontal (0 grados)
        computeSteeringVector(0.0f);

        // Calcular ventana de Hann
        for (int n = 0; n < kFftSize; ++n) {
            window_[n] = 0.5f * (1.0f - std::cos(2.0f * kPi * static_cast<float>(n) / static_cast<float>(kFftSize)));
        }

        rnnInitialized_ = false;
        firstFrameProcessed_ = false;
        frameCount_ = 0;
    }

    /// Habilita o deshabilita el beamformer en runtime (thread-safe).
    void setEnabled(bool enabled) {
        enabled_.store(enabled, std::memory_order_release);
    }

    /// Retorna true si el beamformer esta habilitado.
    bool isEnabled() const {
        return enabled_.load(std::memory_order_acquire);
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
            // Reset output buffer state for clean start on next call
            std::memset(outputBuf_, 0, sizeof(outputBuf_));
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

        // --- STFT del canal 0 ---
        for (int n = 0; n < kFftSize; ++n) {
            frameBuf[n] = inputBuf0_[n] * window_[n];
        }
        realFFT(frameBuf, X0, kFftSize);

        // --- STFT del canal 1 ---
        for (int n = 0; n < kFftSize; ++n) {
            frameBuf[n] = inputBuf1_[n] * window_[n];
        }
        realFFT(frameBuf, X1, kFftSize);

        // --- Actualizar Rnn durante segmentos noise-only ---
        if (!vadActive) {
            updateRnn(X0, X1);
            rnnInitialized_ = true;
        }

        // --- Calcular y aplicar pesos MVDR por bin ---
        for (int k = 0; k < kNumBins; ++k) {
            if (!rnnInitialized_) {
                // Sin estimacion de ruido aun: delay-and-sum simple
                Y[k] = (X0[k] + X1[k]) * 0.5f;
            } else {
                // Vector de observacion x = [X0[k], X1[k]]^T
                // w = Rnn^{-1} * d / (d^H * Rnn^{-1} * d)
                Complex w[2];
                computeMvdrWeights(k, w);
                // y[k] = w^H * x = conj(w0)*X0 + conj(w1)*X1
                Y[k] = std::conj(w[0]) * X0[k] + std::conj(w[1]) * X1[k];
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
    void updateRnn(const Complex* X0, const Complex* X1) {
        const float alpha = kRnnAlpha;
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
        // Aplicar diagonal loading a una copia local antes de invertir
        Complex R00 = rnn_[k][0][0] + Complex(kReg, 0.0f);
        Complex R01 = rnn_[k][0][1];
        Complex R10 = rnn_[k][1][0];
        Complex R11 = rnn_[k][1][1] + Complex(kReg, 0.0f);

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

    // Matriz de correlacion del ruido [kNumBins][2][2]
    Complex rnn_[kNumBins][2][2] = {};

    bool rnnInitialized_ = false;
    bool firstFrameProcessed_ = false;
    int frameCount_ = 0;
};

#endif // HEARING_AID_MVDR_BEAMFORMER_H

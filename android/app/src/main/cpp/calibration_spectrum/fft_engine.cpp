/// @file fft_engine.cpp
/// @brief Implementación de FftEngine: FFT propia del validador.

#include "fft_engine.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace cal_spectrum {

namespace {

constexpr float kPi = 3.14159265358979323846f;

/// Dos·pi.
constexpr float kTwoPi = 2.0f * kPi;

/// Tamaño máximo soportado.
constexpr int kFftMin = 256;
constexpr int kFftMax = 16384;

/// Verifica que `n` sea potencia de 2 y esté en rango.
bool isValidFftSize(int n) {
    if (n < kFftMin || n > kFftMax) return false;
    return (n & (n - 1)) == 0;
}

/// Coeficientes Blackman-Harris (4-term) según Harris 1978.
constexpr float kBh_a0 = 0.35875f;
constexpr float kBh_a1 = 0.48829f;
constexpr float kBh_a2 = 0.14128f;
constexpr float kBh_a3 = 0.01168f;

}  // namespace

// ─────────────────────────────────────────────────────────────────────────────
// Constructor / Destructor
// ─────────────────────────────────────────────────────────────────────────────

FftEngine::FftEngine() = default;

FftEngine::~FftEngine() = default;

// ─────────────────────────────────────────────────────────────────────────────
// init — aloca buffers y precomputa ventana
// ─────────────────────────────────────────────────────────────────────────────

bool FftEngine::init(int fft_size, WindowType window) {
    if (!isValidFftSize(fft_size)) {
        return false;
    }

    fft_size_ = fft_size;
    window_   = window;

    window_buffer_.assign(fft_size, 0.0f);
    real_.assign(fft_size, 0.0f);
    imag_.assign(fft_size, 0.0f);

    buildWindow();

    initialized_ = true;
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// buildWindow — Hann o Blackman-Harris precomputada
// ─────────────────────────────────────────────────────────────────────────────

void FftEngine::buildWindow() {
    const int n = fft_size_;
    if (n <= 1) return;

    // Suma cuadrática para calcular ENBW.
    float sum_w  = 0.0f;
    float sum_w2 = 0.0f;

    for (int i = 0; i < n; ++i) {
        const float x = static_cast<float>(i) / static_cast<float>(n - 1);
        float w;

        if (window_ == WindowType::Hann) {
            // Hann: 0.5 · (1 - cos(2π·x))
            w = 0.5f * (1.0f - std::cos(kTwoPi * x));
        } else {  // BlackmanHarris (4-term)
            const float p2 = kTwoPi * x;
            w = kBh_a0
              - kBh_a1 * std::cos(p2)
              + kBh_a2 * std::cos(2.0f * p2)
              - kBh_a3 * std::cos(3.0f * p2);
        }

        window_buffer_[i] = w;
        sum_w  += w;
        sum_w2 += w * w;
    }

    // ENBW [bins] = N · sum(w²) / (sum(w))²
    if (sum_w > 0.0f) {
        enbw_bins_ = static_cast<float>(n) * sum_w2 / (sum_w * sum_w);
    } else {
        enbw_bins_ = 1.0f;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// compute — aplica ventana y corre FFT in-place
// ─────────────────────────────────────────────────────────────────────────────

FftResult FftEngine::compute(const float* buffer, int n_samples) {
    FftResult result{};
    result.real   = real_.data();
    result.imag   = imag_.data();
    result.n_bins = fft_size_;
    result.valid  = false;

    if (!initialized_ || buffer == nullptr || n_samples <= 0) {
        // Resetear a ceros para que el caller no lea basura.
        std::fill(real_.begin(), real_.end(), 0.0f);
        std::fill(imag_.begin(), imag_.end(), 0.0f);
        return result;
    }

    const int copy_len = std::min(n_samples, fft_size_);

    // 1. Aplicar ventana sobre las muestras válidas.
    for (int i = 0; i < copy_len; ++i) {
        real_[i] = buffer[i] * window_buffer_[i];
        imag_[i] = 0.0f;
    }
    // 2. Zero-pad si n_samples < fft_size.
    for (int i = copy_len; i < fft_size_; ++i) {
        real_[i] = 0.0f;
        imag_[i] = 0.0f;
    }

    runFftInPlace();

    result.valid = true;
    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// runFftInPlace — Cooley-Tukey radix-2 estándar
// ─────────────────────────────────────────────────────────────────────────────

void FftEngine::runFftInPlace() {
    const int N = fft_size_;
    float* re = real_.data();
    float* im = imag_.data();

    // Permutación bit-reversal.
    for (int i = 1, j = 0; i < N; ++i) {
        int bit = N >> 1;
        while (j & bit) {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if (i < j) {
            std::swap(re[i], re[j]);
            std::swap(im[i], im[j]);
        }
    }

    // log2(N) etapas butterfly.
    for (int len = 2; len <= N; len <<= 1) {
        const float angle  = -kTwoPi / static_cast<float>(len);
        const float wReal0 = std::cos(angle);
        const float wImag0 = std::sin(angle);

        for (int i = 0; i < N; i += len) {
            float curReal = 1.0f;
            float curImag = 0.0f;

            const int half = len / 2;
            for (int k = 0; k < half; ++k) {
                const int evenIdx = i + k;
                const int oddIdx  = i + k + half;

                const float tReal = curReal * re[oddIdx] - curImag * im[oddIdx];
                const float tImag = curReal * im[oddIdx] + curImag * re[oddIdx];

                re[oddIdx] = re[evenIdx] - tReal;
                im[oddIdx] = im[evenIdx] - tImag;
                re[evenIdx] += tReal;
                im[evenIdx] += tImag;

                const float newCurReal = curReal * wReal0 - curImag * wImag0;
                curImag                = curReal * wImag0 + curImag * wReal0;
                curReal                = newCurReal;
            }
        }
    }
}

}  // namespace cal_spectrum

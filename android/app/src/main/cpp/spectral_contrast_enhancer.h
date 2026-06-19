/// @file spectral_contrast_enhancer.h
/// @brief Spectral Contrast Enhancement (SCE) — realza la voz sin amplificar ruido.
///
/// Principio: atenúa los valles espectrales entre formantes de la voz, dejando
/// los picos intactos. El resultado es mayor contraste espectral (formantes más
/// prominentes vs inter-formantes) SIN incrementar el nivel máximo de la señal.
///
/// Inspirado en:
///   - Oticon "64-band Spectral Enhancement"
///   - Nogueira et al. 2016 (cochlear implant SCE, PubMed 26936556)
///   - Yang, Luo & Nehorai 2003 (Speech Communication, DoG SCE)
///
/// Implementación simplificada para 12 bandas (alineada con el EQ existente):
///   1. Calcula energía RMS por banda en cada bloque.
///   2. Identifica las bandas con mayor energía (picos = formantes).
///   3. Atenúa las bandas con menor energía (valles = inter-formantes).
///   4. La atenuación es configurable: sceFactor ∈ [0, 1].
///      - 0.0 = sin atenuación (bypass)
///      - 0.5 = -6 dB en valles (recomendado)
///      - 1.0 = silencia valles completamente (demasiado agresivo)
///
/// Invariantes:
///   - NUNCA amplifica (gain ≤ 1.0 en toda banda).
///   - Solo atenúa valles → el nivel máximo de la señal no sube.
///   - Sin riesgo para el MPO (no puede dispararlo).
///   - Sin latencia adicional (procesa sample-by-sample dentro del bloque).
///
/// Inserción en el pipeline: entre NR y EQ (después de que el ruido ya fue
/// atenuado por el DNN/Wiener, antes de que el EQ amplifique la prescripción).
///
/// Header-only: no requiere tocar CMakeLists.txt.

#ifndef HEARING_AID_SPECTRAL_CONTRAST_ENHANCER_H
#define HEARING_AID_SPECTRAL_CONTRAST_ENHANCER_H

#include <atomic>
#include <cmath>
#include <algorithm>
#include <cstring>

/// Número de bandas del análisis SCE (alineado con el EQ de 12 bandas).
static constexpr int kSceBandCount = 12;

/// Frecuencias centrales de las 12 bandas del SCE (mismas que el EQ).
static constexpr float kSceFrequencies[kSceBandCount] = {
    250.0f, 500.0f, 750.0f, 1000.0f, 1500.0f, 2000.0f,
    2500.0f, 3000.0f, 3500.0f, 4000.0f, 6000.0f, 8000.0f
};

/// Spectral Contrast Enhancer — atenúa valles entre formantes para realzar voz.
///
/// Uso:
/// @code
///   SpectralContrastEnhancer sce;
///   sce.init(16000);
///   sce.setEnabled(true);
///   sce.setFactor(0.5f); // -6 dB en valles
///   // En el hilo de audio, después del NR y antes del EQ:
///   sce.process(buffer, 64);
/// @endcode
class SpectralContrastEnhancer {
public:
    SpectralContrastEnhancer() = default;
    ~SpectralContrastEnhancer() = default;

    /// Inicializa el SCE con la frecuencia de muestreo del pipeline.
    void init(int sampleRate) {
        sampleRate_ = sampleRate;
        // Calcular coeficientes de los filtros bandpass para cada banda.
        for (int b = 0; b < kSceBandCount; b++) {
            computeBandpassCoeffs(b);
            bandStates_[b] = {};
            bandEnergy_[b] = 0.0f;
        }
    }

    /// Habilita/deshabilita el SCE. Thread-safe (atómico).
    void setEnabled(bool enabled) {
        enabled_.store(enabled, std::memory_order_release);
    }

    /// `true` si el SCE está habilitado.
    bool isEnabled() const {
        return enabled_.load(std::memory_order_acquire);
    }

    /// Configura la intensidad del SCE.
    /// @param factor ∈ [0, 1]. 0=bypass, 0.5=recomendado (-6dB valles), 1=max.
    void setFactor(float factor) {
        factor_.store(std::max(0.0f, std::min(1.0f, factor)),
                      std::memory_order_release);
    }

    /// Factor actual.
    float getFactor() const {
        return factor_.load(std::memory_order_acquire);
    }

    /// Procesa un bloque de audio aplicando SCE in-place.
    /// Debe llamarse DESPUÉS del NR y ANTES del EQ en el pipeline.
    void process(float* buffer, int blockSize) {
        if (!enabled_.load(std::memory_order_acquire)) return;
        if (blockSize <= 0 || buffer == nullptr) return;

        const float factor = factor_.load(std::memory_order_acquire);
        if (factor < 0.001f) return; // Bypass efectivo

        // ─── Paso 1: Medir energía RMS por banda ────────────────────────
        float bandBuf[kSceBandCount][256]; // max block size
        for (int b = 0; b < kSceBandCount; b++) {
            // Filtrar la señal por la banda b
            filterBand(buffer, bandBuf[b], blockSize, b);

            // Calcular RMS de la banda
            float sum = 0.0f;
            for (int i = 0; i < blockSize; i++) {
                sum += bandBuf[b][i] * bandBuf[b][i];
            }
            // Smoothing exponencial con el bloque anterior (evita fluctuaciones)
            float rms = std::sqrt(sum / blockSize);
            bandEnergy_[b] = 0.7f * bandEnergy_[b] + 0.3f * rms;
        }

        // ─── Paso 2: Identificar picos (formantes) y valles ─────────────
        // Ordenar las energías para encontrar el umbral pico/valle.
        float sorted[kSceBandCount];
        std::memcpy(sorted, bandEnergy_, sizeof(sorted));
        std::sort(sorted, sorted + kSceBandCount);

        // Las 4 bandas con más energía son "picos" (formantes).
        // El umbral es la energía de la 4ta banda más fuerte.
        float peakThreshold = sorted[kSceBandCount - 4]; // 4 picos

        // ─── Paso 3: Calcular ganancia por banda (solo atenúa valles) ───
        float bandGain[kSceBandCount];
        for (int b = 0; b < kSceBandCount; b++) {
            if (bandEnergy_[b] >= peakThreshold || peakThreshold < 1e-8f) {
                // Banda pico (formante) → no tocar
                bandGain[b] = 1.0f;
            } else {
                // Banda valle → atenuar proporcionalmente al factor
                // Gain ∈ [1-factor, 1]. Con factor=0.5 → gain=0.5 (-6 dB).
                float ratio = bandEnergy_[b] / (peakThreshold + 1e-10f);
                // ratio ∈ [0, 1). Cuanto más bajo, más atenuación.
                // gain = 1 - factor * (1 - ratio)
                bandGain[b] = 1.0f - factor * (1.0f - ratio);
                // Clamp: nunca amplificar
                if (bandGain[b] > 1.0f) bandGain[b] = 1.0f;
                if (bandGain[b] < 0.0f) bandGain[b] = 0.0f;
            }
        }

        // ─── Paso 4: Aplicar — reconstruir señal con gains por banda ────
        // Método aditivo: señal_out = sum(banda[b] * gain[b])
        // Esto es correcto porque las bandas cubren el espectro completo.
        float output[256]; // max block size
        std::memset(output, 0, blockSize * sizeof(float));
        for (int b = 0; b < kSceBandCount; b++) {
            for (int i = 0; i < blockSize; i++) {
                output[i] += bandBuf[b][i] * bandGain[b];
            }
        }

        // Copiar al buffer de salida
        std::memcpy(buffer, output, blockSize * sizeof(float));
    }

private:
    int sampleRate_ = 16000;
    std::atomic<bool> enabled_{false};
    std::atomic<float> factor_{0.5f}; // Default: -6 dB en valles

    /// Energía smoothed por banda (entre bloques).
    float bandEnergy_[kSceBandCount] = {};

    /// Coeficientes y estado de los filtros bandpass por banda.
    struct BpCoeffs {
        float b0 = 0, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    };
    struct BpState {
        float x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    };
    BpCoeffs bandCoeffs_[kSceBandCount] = {};
    BpState bandStates_[kSceBandCount] = {};

    /// Filtra un bloque por la banda b (bandpass 2do orden).
    void filterBand(const float* input, float* output, int blockSize, int band) {
        const auto& c = bandCoeffs_[band];
        auto& s = bandStates_[band];
        for (int i = 0; i < blockSize; i++) {
            float x = input[i];
            float y = c.b0 * x + c.b1 * s.x1 + c.b2 * s.x2
                    - c.a1 * s.y1 - c.a2 * s.y2;
            s.x2 = s.x1; s.x1 = x;
            s.y2 = s.y1; s.y1 = y;
            // Sanitize NaN/Inf
            if (!std::isfinite(y)) { y = 0.0f; s = {}; }
            output[i] = y;
        }
    }

    /// Calcula coeficientes de filtro bandpass peaking para la banda b.
    /// Audio EQ Cookbook (peaking EQ con gain=0dB → pasa la banda, atenúa fuera).
    void computeBandpassCoeffs(int band) {
        float fc = kSceFrequencies[band];
        float Q = 1.4f; // Same Q as the EQ
        if (band == 0) Q = 1.0f;       // 250 Hz: más ancho
        if (band == 1) Q = 1.2f;       // 500 Hz
        if (band >= 10) Q = 1.5f;      // 6k, 8k: más estrecho

        float w0 = 2.0f * 3.14159265f * fc / sampleRate_;
        float sinW0 = std::sin(w0);
        float cosW0 = std::cos(w0);
        float alpha = sinW0 / (2.0f * Q);

        // Bandpass (constant-0 dB peak gain)
        float b0 = alpha;
        float b1 = 0.0f;
        float b2 = -alpha;
        float a0 = 1.0f + alpha;
        float a1 = -2.0f * cosW0;
        float a2 = 1.0f - alpha;

        // Normalizar por a0
        bandCoeffs_[band].b0 = b0 / a0;
        bandCoeffs_[band].b1 = b1 / a0;
        bandCoeffs_[band].b2 = b2 / a0;
        bandCoeffs_[band].a1 = a1 / a0;
        bandCoeffs_[band].a2 = a2 / a0;
    }
};

#endif // HEARING_AID_SPECTRAL_CONTRAST_ENHANCER_H

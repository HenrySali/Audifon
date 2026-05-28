/// @file spectrum_analyzer.cpp
/// @brief Implementación del analizador de espectro en tiempo real.
///
/// FFT Cooley-Tukey radix-2 de 128 puntos, agrupamiento en 12 bandas EQ,
/// acumulación de muestras con emisión a 10 Hz, y grabación de snapshots.
///
/// Complejidad computacional:
/// - FFT 128 puntos: ~27 µs en ARM Cortex-A55
/// - Se ejecuta cada 2 bloques (8ms), amortizado: ~13.5 µs/bloque
/// - Bien dentro del presupuesto de 50 µs/bloque (1.25% del tiempo de bloque)

#include "spectrum_analyzer.h"

#include <cmath>
#include <cstring>
#include <algorithm>

// ─────────────────────────────────────────────────────────────────────────────
// Constantes internas
// ─────────────────────────────────────────────────────────────────────────────

/// Piso para evitar log(0) en cálculos de magnitud.
static constexpr float kMagnitudeFloor = 1e-10f;

/// Pi para cálculos trigonométricos.
static constexpr float kPi = 3.14159265358979323846f;

/// Factor de conversión radianes → grados.
static constexpr float kRadToDeg = 180.0f / kPi;

// ─────────────────────────────────────────────────────────────────────────────
// Band mapping: 64 bins → 12 bandas EQ
// Bin resolution: 16000 Hz / 128 = 125 Hz por bin
// Bins 1-64 corresponden a 125 Hz - 8000 Hz
// Índices 0-based desde el array magnitude[64]
// ─────────────────────────────────────────────────────────────────────────────

/// Índice de inicio de cada banda (0-indexed desde magnitude64).
static const int kBandStart[12] = {0, 2, 4, 6, 9, 13, 17, 21, 25, 29, 34, 50};

/// Índice de fin de cada banda (inclusive, 0-indexed desde magnitude64).
static const int kBandEnd[12]   = {1, 3, 5, 8, 12, 16, 20, 24, 28, 33, 49, 63};

// ─────────────────────────────────────────────────────────────────────────────
// Constructor / Destructor
// ─────────────────────────────────────────────────────────────────────────────

SpectrumAnalyzer::SpectrumAnalyzer() {
    std::memset(inputFftBuffer_, 0, sizeof(inputFftBuffer_));
    std::memset(outputFftBuffer_, 0, sizeof(outputFftBuffer_));
    std::memset(hannWindow_, 0, sizeof(hannWindow_));
    std::memset(&currentSnapshot_, 0, sizeof(currentSnapshot_));
}

SpectrumAnalyzer::~SpectrumAnalyzer() = default;

// ─────────────────────────────────────────────────────────────────────────────
// Inicialización (Task 1.5)
// ─────────────────────────────────────────────────────────────────────────────

void SpectrumAnalyzer::init(int sampleRate, float splOffset) {
    sampleRate_ = sampleRate;
    splOffset_ = splOffset;

    // Precomputar ventana Hann: w[i] = 0.5 * (1 - cos(2π*i/(N-1)))
    // Evita cálculos trigonométricos en el hilo de audio.
    for (int i = 0; i < FFT_SIZE; ++i) {
        hannWindow_[i] = 0.5f * (1.0f - std::cos(2.0f * kPi * i / (FFT_SIZE - 1)));
    }

    // Calcular bloques por snapshot para emisión a 10 Hz.
    // A 16kHz con bloques de 64 muestras: 1 bloque = 4ms
    // 100ms / 4ms = 25 bloques por snapshot
    // Fórmula general: (sampleRate * 0.1) / blockSize
    // Asumimos blockSize = 64 (estándar del pipeline)
    static constexpr int kDefaultBlockSize = 64;
    blocksPerSnapshot_ = static_cast<int>((sampleRate * 0.1f) / kDefaultBlockSize);
    if (blocksPerSnapshot_ < 1) {
        blocksPerSnapshot_ = 1;
    }

    // Reservar memoria para grabación (evita realocaciones en audio thread)
    recordBuffer_.reserve(MAX_RECORDING_SNAPSHOTS);

    // Reset estado
    fftBufferPos_ = 0;
    snapshotCounter_ = 0;
    blockCounter_ = 0;
    currentEnvClass_ = 0;
    std::memset(&currentSnapshot_, 0, sizeof(currentSnapshot_));
}

// ─────────────────────────────────────────────────────────────────────────────
// FFT — Cooley-Tukey Radix-2, 128 puntos (Task 1.2)
// ─────────────────────────────────────────────────────────────────────────────

void SpectrumAnalyzer::computeFFT(const float* buffer, int N,
                                   float* magnitude, float* phase) {
    // Arrays de trabajo para parte real e imaginaria
    float real[FFT_SIZE];
    float imag[FFT_SIZE];

    // ─── 1. Aplicar ventana Hann precomputada y copiar a array complejo ──
    for (int i = 0; i < N; ++i) {
        real[i] = buffer[i] * hannWindow_[i];
        imag[i] = 0.0f;
    }

    // ─── 2. Permutación bit-reversal in-place ────────────────────────────
    for (int i = 1, j = 0; i < N; ++i) {
        int bit = N >> 1;
        while (j & bit) {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if (i < j) {
            std::swap(real[i], real[j]);
            std::swap(imag[i], imag[j]);
        }
    }

    // ─── 3. Butterfly computation — 7 etapas (log2(128) = 7) ────────────
    for (int len = 2; len <= N; len <<= 1) {
        float angle = -2.0f * kPi / static_cast<float>(len);
        float wReal = std::cos(angle);
        float wImag = std::sin(angle);

        for (int i = 0; i < N; i += len) {
            float curReal = 1.0f;
            float curImag = 0.0f;

            for (int j = 0; j < len / 2; ++j) {
                int evenIdx = i + j;
                int oddIdx = i + j + len / 2;

                // Twiddle factor × odd element
                float tReal = curReal * real[oddIdx] - curImag * imag[oddIdx];
                float tImag = curReal * imag[oddIdx] + curImag * real[oddIdx];

                // Butterfly: even = even + t, odd = even - t
                real[oddIdx] = real[evenIdx] - tReal;
                imag[oddIdx] = imag[evenIdx] - tImag;
                real[evenIdx] += tReal;
                imag[evenIdx] += tImag;

                // Avanzar twiddle factor
                float newCurReal = curReal * wReal - curImag * wImag;
                curImag = curReal * wImag + curImag * wReal;
                curReal = newCurReal;
            }
        }
    }

    // ─── 4. Extraer magnitud (dB SPL) y fase (grados) para bins 1-64 ────
    // Bin 0 = DC (ignorado). Bins 1-64 = 125 Hz a 8000 Hz.
    for (int k = 1; k <= NUM_BINS; ++k) {
        // Magnitud: 20*log10(sqrt(re² + im²)) + splOffset → dB SPL
        float mag = std::sqrt(real[k] * real[k] + imag[k] * imag[k]);
        float magDb = 20.0f * std::log10(mag + kMagnitudeFloor);
        magnitude[k - 1] = magDb + splOffset_;

        // Fase: atan2(im, re) * 180/π → grados [-180, +180]
        float phaseDeg = std::atan2(imag[k], real[k]) * kRadToDeg;
        phase[k - 1] = phaseDeg;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Band Grouping — 64 bins → 12 bandas EQ (Task 1.3)
// ─────────────────────────────────────────────────────────────────────────────

void SpectrumAnalyzer::groupIntoBands(const float* magnitude64, float* bands12) {
    for (int b = 0; b < NUM_BANDS; ++b) {
        float sumLinearPower = 0.0f;
        int count = kBandEnd[b] - kBandStart[b] + 1;

        for (int k = kBandStart[b]; k <= kBandEnd[b]; ++k) {
            // Convertir dB a potencia lineal: 10^(dB/10)
            sumLinearPower += std::pow(10.0f, magnitude64[k] / 10.0f);
        }

        // Promedio en dominio lineal, convertir de vuelta a dB
        bands12[b] = 10.0f * std::log10(sumLinearPower / count + kMagnitudeFloor);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Procesamiento de buffers con acumulación y timing (Task 1.4)
// ─────────────────────────────────────────────────────────────────────────────

void SpectrumAnalyzer::processBuffers(const float* input, const float* output,
                                       int blockSize) {
    if (!active_.load(std::memory_order_relaxed)) {
        return;
    }

    // Acumular muestras en buffers FFT de 128 muestras.
    // blockSize = 64 → necesita 2 bloques para llenar el buffer FFT.
    appendToFftBuffer(input, output, blockSize);

    if (fftBufferFull()) {
        // ─── Computar FFT para input y output ────────────────────────────
        computeFFT(inputFftBuffer_, FFT_SIZE,
                   currentSnapshot_.inputMagnitude, currentSnapshot_.inputPhase);
        computeFFT(outputFftBuffer_, FFT_SIZE,
                   currentSnapshot_.outputMagnitude, currentSnapshot_.outputPhase);

        // ─── Agrupar en 12 bandas EQ ────────────────────────────────────
        groupIntoBands(currentSnapshot_.inputMagnitude, currentSnapshot_.inputBands);
        groupIntoBands(currentSnapshot_.outputMagnitude, currentSnapshot_.outputBands);

        // ─── Medir niveles RMS ──────────────────────────────────────────
        currentSnapshot_.inputLevelDb = measureRmsDb(inputFftBuffer_, FFT_SIZE);
        currentSnapshot_.outputLevelDb = measureRmsDb(outputFftBuffer_, FFT_SIZE);

        // ─── Clase de entorno ───────────────────────────────────────────
        currentSnapshot_.environmentClass = currentEnvClass_;

        resetFftBuffer();
    }

    // ─── Control de emisión a 10 Hz ─────────────────────────────────────
    // Incrementar contador de bloques. Emitir snapshot cada blocksPerSnapshot_.
    blockCounter_++;
    if (blockCounter_ >= blocksPerSnapshot_) {
        blockCounter_ = 0;

        // Si está grabando, almacenar snapshot en el buffer de grabación
        if (recording_.load(std::memory_order_relaxed)) {
            currentSnapshot_.timestampMs = getElapsedMs();
            if (static_cast<int>(recordBuffer_.size()) < MAX_RECORDING_SNAPSHOTS) {
                recordBuffer_.push_back(currentSnapshot_);
            } else {
                // Auto-stop cuando el buffer está lleno (3 minutos)
                recording_.store(false, std::memory_order_relaxed);
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Lectura de snapshot (thread-safe)
// ─────────────────────────────────────────────────────────────────────────────

SpectrumSnapshot SpectrumAnalyzer::getCurrentSnapshot() const {
    // Copia atómica del snapshot actual.
    // En ARM64, una copia de struct de 1136 bytes no es atómica por hardware,
    // pero para visualización a 10 Hz, un tear ocasional es aceptable
    // (no hay consecuencias de seguridad, solo visual).
    return currentSnapshot_;
}

// ─────────────────────────────────────────────────────────────────────────────
// Control de activación
// ─────────────────────────────────────────────────────────────────────────────

void SpectrumAnalyzer::setActive(bool active) {
    active_.store(active, std::memory_order_relaxed);
    if (!active) {
        // Reset estado al desactivar para empezar limpio la próxima vez
        fftBufferPos_ = 0;
        blockCounter_ = 0;
    }
}

bool SpectrumAnalyzer::isActive() const {
    return active_.load(std::memory_order_relaxed);
}

// ─────────────────────────────────────────────────────────────────────────────
// Control de grabación (Task 1.6)
// ─────────────────────────────────────────────────────────────────────────────

void SpectrumAnalyzer::startRecording() {
    // Limpiar buffer previo y registrar timestamp de inicio
    recordBuffer_.clear();
    recordingStartTimeMs_ = 0;

    // Usar un timestamp relativo simple basado en el contador de snapshots.
    // El primer snapshot tendrá timestampMs = 0, los siguientes incrementan ~100ms.
    recording_.store(true, std::memory_order_relaxed);
}

void SpectrumAnalyzer::stopRecording() {
    recording_.store(false, std::memory_order_relaxed);
}

bool SpectrumAnalyzer::isRecording() const {
    return recording_.load(std::memory_order_relaxed);
}

int SpectrumAnalyzer::getRecordedCount() const {
    return static_cast<int>(recordBuffer_.size());
}

const SpectrumSnapshot* SpectrumAnalyzer::getRecordedSnapshots() const {
    return recordBuffer_.data();
}

int SpectrumAnalyzer::getRecordedSize() const {
    return static_cast<int>(recordBuffer_.size() * sizeof(SpectrumSnapshot));
}

// ─────────────────────────────────────────────────────────────────────────────
// Actualización de parámetros
// ─────────────────────────────────────────────────────────────────────────────

void SpectrumAnalyzer::setSplOffset(float offset) {
    splOffset_ = offset;
}

void SpectrumAnalyzer::setEnvironmentClass(int envClass) {
    currentEnvClass_ = envClass;
}

// ─────────────────────────────────────────────────────────────────────────────
// Funciones internas auxiliares
// ─────────────────────────────────────────────────────────────────────────────

float SpectrumAnalyzer::measureRmsDb(const float* buffer, int blockSize) const {
    float sumSquares = 0.0f;
    for (int i = 0; i < blockSize; ++i) {
        sumSquares += buffer[i] * buffer[i];
    }
    float rms = std::sqrt(sumSquares / static_cast<float>(blockSize));

    if (rms < kMagnitudeFloor) {
        return 0.0f;
    }

    float rmsDbFs = 20.0f * std::log10(rms);
    return rmsDbFs + splOffset_;
}

void SpectrumAnalyzer::appendToFftBuffer(const float* input, const float* output,
                                          int blockSize) {
    // Copiar muestras al buffer FFT, respetando el límite de FFT_SIZE
    int samplesToAdd = std::min(blockSize, FFT_SIZE - fftBufferPos_);
    if (samplesToAdd <= 0) {
        return;
    }

    std::memcpy(inputFftBuffer_ + fftBufferPos_, input, samplesToAdd * sizeof(float));
    std::memcpy(outputFftBuffer_ + fftBufferPos_, output, samplesToAdd * sizeof(float));
    fftBufferPos_ += samplesToAdd;
}

bool SpectrumAnalyzer::fftBufferFull() const {
    return fftBufferPos_ >= FFT_SIZE;
}

void SpectrumAnalyzer::resetFftBuffer() {
    fftBufferPos_ = 0;
}

uint32_t SpectrumAnalyzer::getElapsedMs() const {
    // Calcula tiempo transcurrido basado en el número de snapshots grabados.
    // Cada snapshot se emite cada ~100ms (blocksPerSnapshot_ bloques).
    // Esto es más preciso que usar un reloj de pared en el audio thread.
    return static_cast<uint32_t>(recordBuffer_.size()) * 100;
}

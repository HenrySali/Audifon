/// @file diagnostic_recorder.cpp
/// @brief Implementación del grabador de diagnóstico DSP.

#include "diagnostic_recorder.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <chrono>

// ─────────────────────────────────────────────────────────────────────────────
// Constructor / Destructor
// ─────────────────────────────────────────────────────────────────────────────

DiagnosticRecorder::DiagnosticRecorder() {
    std::memset(ringBuffer_, 0, sizeof(ringBuffer_));
    std::memset(preConvertBuf_, 0, sizeof(preConvertBuf_));
    std::memset(postConvertBuf_, 0, sizeof(postConvertBuf_));
}

DiagnosticRecorder::~DiagnosticRecorder() {
    // Asegurar limpieza si se destruye durante grabación
    if (state_.load(std::memory_order_acquire) == DiagRecorderState::RECORDING) {
        stop();
    }
    if (writerThread_.joinable()) {
        writerThread_.join();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Conversión float32 → int16
// ─────────────────────────────────────────────────────────────────────────────

int16_t DiagnosticRecorder::floatToInt16(float sample) {
    // Saturar a [-1.0, 1.0]
    float clamped = std::fmax(-1.0f, std::fmin(1.0f, sample));
    // Escalar a rango int16 [-32768, 32767]
    float scaled = clamped * 32767.0f;
    return static_cast<int16_t>(scaled);
}

// ─────────────────────────────────────────────────────────────────────────────
// Ring Buffer helpers
// ─────────────────────────────────────────────────────────────────────────────

int DiagnosticRecorder::availableForRead() const {
    int wp = writePos_.load(std::memory_order_acquire);
    int rp = readPos_.load(std::memory_order_acquire);
    if (wp >= rp) {
        return (wp - rp) / 2; // frames (each frame = 2 samples)
    } else {
        return (RING_BUFFER_SAMPLES - rp + wp) / 2;
    }
}

int DiagnosticRecorder::availableForWrite() const {
    // Dejar siempre 1 frame libre para distinguir lleno de vacío
    return RING_BUFFER_FRAMES - 1 - availableForRead();
}

bool DiagnosticRecorder::pushToRingBuffer(const int16_t* preBuf, const int16_t* postBuf, int numFrames) {
    if (availableForWrite() < numFrames) {
        return false; // Overflow — no hay espacio
    }

    int wp = writePos_.load(std::memory_order_relaxed);

    for (int i = 0; i < numFrames; ++i) {
        // Intercalar: L=pre-DSP, R=post-DSP
        ringBuffer_[wp] = preBuf[i];
        ringBuffer_[wp + 1] = postBuf[i];
        wp += 2;
        if (wp >= RING_BUFFER_SAMPLES) {
            wp = 0; // Wrap around
        }
    }

    writePos_.store(wp, std::memory_order_release);
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Feed methods (llamados desde el hilo de audio)
// ─────────────────────────────────────────────────────────────────────────────

void DiagnosticRecorder::feedPreDsp(const float* data, int numFrames) {
    if (state_.load(std::memory_order_acquire) != DiagRecorderState::RECORDING) {
        return;
    }

    // Limitar a MAX_BLOCK_SIZE
    int frames = std::min(numFrames, MAX_BLOCK_SIZE);

    // Convertir float→int16 y almacenar temporalmente
    for (int i = 0; i < frames; ++i) {
        preConvertBuf_[i] = floatToInt16(data[i]);
    }
    currentBlockFrames_ = frames;
}

void DiagnosticRecorder::feedPostDsp(const float* data, int numFrames) {
    if (state_.load(std::memory_order_acquire) != DiagRecorderState::RECORDING) {
        return;
    }

    // Limitar a MAX_BLOCK_SIZE y al número de frames pre-DSP ya almacenados
    int frames = std::min(numFrames, currentBlockFrames_);
    if (frames <= 0) {
        return;
    }

    // Convertir float→int16
    for (int i = 0; i < frames; ++i) {
        postConvertBuf_[i] = floatToInt16(data[i]);
    }

    // Verificar si ya alcanzamos el target de muestras
    int64_t currentProduced = framesProduced_.load(std::memory_order_relaxed);
    int64_t remaining = config_.targetSamples - currentProduced;
    if (remaining <= 0) {
        return; // Ya se alcanzó el objetivo
    }

    // Limitar frames al remanente
    int framesToPush = static_cast<int>(std::min(static_cast<int64_t>(frames), remaining));

    // Empujar al ring buffer intercalado
    if (!pushToRingBuffer(preConvertBuf_, postConvertBuf_, framesToPush)) {
        // Overflow — el hilo escritor no está drenando suficientemente rápido
        state_.store(DiagRecorderState::ERROR, std::memory_order_release);
        return;
    }

    framesProduced_.fetch_add(framesToPush, std::memory_order_relaxed);
    currentBlockFrames_ = 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// start()
// ─────────────────────────────────────────────────────────────────────────────

bool DiagnosticRecorder::start(const std::string& filePath) {
    // Solo se puede iniciar desde IDLE o COMPLETED
    DiagRecorderState expected = state_.load(std::memory_order_acquire);
    if (expected != DiagRecorderState::IDLE && expected != DiagRecorderState::COMPLETED) {
        return false;
    }

    // Esperar a que el hilo anterior termine si existe
    if (writerThread_.joinable()) {
        writerThread_.join();
    }

    // Reset de estado
    filePath_ = filePath;
    samplesWritten_.store(0, std::memory_order_relaxed);
    framesProduced_.store(0, std::memory_order_relaxed);
    writePos_.store(0, std::memory_order_relaxed);
    readPos_.store(0, std::memory_order_relaxed);
    currentBlockFrames_ = 0;
    stopRequested_.store(false, std::memory_order_relaxed);

    // Abrir archivo WAV
    wavFile_ = std::fopen(filePath_.c_str(), "wb");
    if (!wavFile_) {
        state_.store(DiagRecorderState::ERROR, std::memory_order_release);
        return false;
    }

    // Escribir encabezado WAV placeholder
    if (!writeWavHeader()) {
        std::fclose(wavFile_);
        wavFile_ = nullptr;
        std::remove(filePath_.c_str());
        state_.store(DiagRecorderState::ERROR, std::memory_order_release);
        return false;
    }

    // Transicionar a RECORDING
    state_.store(DiagRecorderState::RECORDING, std::memory_order_release);

    // Lanzar hilo escritor
    writerRunning_.store(true, std::memory_order_release);
    writerThread_ = std::thread(&DiagnosticRecorder::writerLoop, this);

    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// stop()
// ─────────────────────────────────────────────────────────────────────────────

void DiagnosticRecorder::stop() {
    DiagRecorderState currentState = state_.load(std::memory_order_acquire);
    if (currentState != DiagRecorderState::RECORDING) {
        return;
    }

    // Señalar al hilo escritor que debe detenerse
    stopRequested_.store(true, std::memory_order_release);
    writerRunning_.store(false, std::memory_order_release);

    // Esperar a que el hilo escritor termine
    if (writerThread_.joinable()) {
        writerThread_.join();
    }

    // Cerrar archivo
    if (wavFile_) {
        std::fclose(wavFile_);
        wavFile_ = nullptr;
    }

    // Early stop: descartar archivo parcial
    if (!filePath_.empty()) {
        std::remove(filePath_.c_str());
    }

    // Volver a IDLE
    state_.store(DiagRecorderState::IDLE, std::memory_order_release);
}

// ─────────────────────────────────────────────────────────────────────────────
// Accessors
// ─────────────────────────────────────────────────────────────────────────────

int64_t DiagnosticRecorder::getElapsedMs() const {
    int64_t written = samplesWritten_.load(std::memory_order_acquire);
    if (config_.sampleRate == 0) return 0;
    return (written * 1000) / config_.sampleRate;
}

DiagRecorderState DiagnosticRecorder::getState() const {
    return state_.load(std::memory_order_acquire);
}

int64_t DiagnosticRecorder::getSamplesWritten() const {
    return samplesWritten_.load(std::memory_order_acquire);
}

// ─────────────────────────────────────────────────────────────────────────────
// WAV Header (placeholder)
// ─────────────────────────────────────────────────────────────────────────────

bool DiagnosticRecorder::writeWavHeader() {
    // Encabezado WAV estándar de 44 bytes con tamaños placeholder (0)
    // Se finalizará con tamaños reales al completar la grabación.

    const int32_t sampleRate = config_.sampleRate;
    const int16_t numChannels = static_cast<int16_t>(config_.channels);
    const int16_t bitsPerSample = static_cast<int16_t>(config_.bitsPerSample);
    const int16_t blockAlign = numChannels * (bitsPerSample / 8);
    const int32_t byteRate = sampleRate * blockAlign;

    // Placeholder para tamaños (se actualizan en finalizeWavHeader)
    const int32_t dataSize = 0;      // placeholder
    const int32_t riffSize = 36;     // placeholder (36 + dataSize)

    // RIFF chunk
    std::fwrite("RIFF", 1, 4, wavFile_);
    std::fwrite(&riffSize, 4, 1, wavFile_);
    std::fwrite("WAVE", 1, 4, wavFile_);

    // fmt sub-chunk
    std::fwrite("fmt ", 1, 4, wavFile_);
    const int32_t fmtChunkSize = 16;
    std::fwrite(&fmtChunkSize, 4, 1, wavFile_);
    const int16_t audioFormat = 1; // PCM
    std::fwrite(&audioFormat, 2, 1, wavFile_);
    std::fwrite(&numChannels, 2, 1, wavFile_);
    std::fwrite(&sampleRate, 4, 1, wavFile_);
    std::fwrite(&byteRate, 4, 1, wavFile_);
    std::fwrite(&blockAlign, 2, 1, wavFile_);
    std::fwrite(&bitsPerSample, 2, 1, wavFile_);

    // data sub-chunk
    std::fwrite("data", 1, 4, wavFile_);
    std::fwrite(&dataSize, 4, 1, wavFile_);

    // Verificar que se escribieron 44 bytes
    if (std::ftell(wavFile_) != 44) {
        return false;
    }

    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// finalizeWavHeader — escribe tamaños reales RIFF/data en el encabezado WAV
// ─────────────────────────────────────────────────────────────────────────────

bool DiagnosticRecorder::finalizeWavHeader() {
    if (!wavFile_) return false;

    int64_t written = samplesWritten_.load(std::memory_order_acquire);
    int32_t dataSize = static_cast<int32_t>(written * config_.channels * (config_.bitsPerSample / 8));
    int32_t riffSize = 36 + dataSize;

    // Seek a posición 4 para escribir RIFF chunk size
    if (std::fseek(wavFile_, 4, SEEK_SET) != 0) {
        return false;
    }
    if (std::fwrite(&riffSize, 4, 1, wavFile_) != 1) {
        return false;
    }

    // Seek a posición 40 para escribir data sub-chunk size
    if (std::fseek(wavFile_, 40, SEEK_SET) != 0) {
        return false;
    }
    if (std::fwrite(&dataSize, 4, 1, wavFile_) != 1) {
        return false;
    }

    // Flush para asegurar que los datos se escriben a disco
    std::fflush(wavFile_);

    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// writerLoop — Hilo escritor: drena ring buffer → disco, auto-stop, finalización
// ─────────────────────────────────────────────────────────────────────────────

void DiagnosticRecorder::writerLoop() {
    // Hilo escritor dedicado:
    //   - Drena continuamente el ring buffer SPSC
    //   - Escribe datos PCM16 intercalados a disco
    //   - Detecta auto-stop al alcanzar targetSamples (720,000)
    //   - Finaliza encabezado WAV con tamaños reales
    //   - Maneja errores de I/O y overflow del ring buffer

    while (writerRunning_.load(std::memory_order_acquire)) {
        // Verificar si se solicitó parada manual (stop())
        if (stopRequested_.load(std::memory_order_acquire)) {
            break;
        }

        // Verificar si otro hilo (feedPostDsp) detectó overflow → ERROR
        if (state_.load(std::memory_order_acquire) == DiagRecorderState::ERROR) {
            // Ring buffer overflow detectado en el hilo de audio — abortar
            writerRunning_.store(false, std::memory_order_relaxed);
            return;
        }

        // Drenar frames disponibles del ring buffer
        int available = availableForRead();
        if (available > 0) {
            int rp = readPos_.load(std::memory_order_relaxed);

            // Calcular cuántos frames escribir (limitado por target)
            int framesToWrite = available;
            int64_t currentWritten = samplesWritten_.load(std::memory_order_relaxed);
            int64_t remaining = config_.targetSamples - currentWritten;

            if (remaining <= 0) {
                // Ya alcanzado el objetivo — salir del loop para finalizar
                break;
            }

            // Limitar frames al remanente para no exceder targetSamples
            framesToWrite = static_cast<int>(std::min(static_cast<int64_t>(framesToWrite), remaining));

            for (int i = 0; i < framesToWrite; ++i) {
                // Cada frame = 2 muestras int16 (L=pre-DSP, R=post-DSP)
                int16_t samples[2];
                samples[0] = ringBuffer_[rp];
                samples[1] = ringBuffer_[rp + 1];
                rp += 2;
                if (rp >= RING_BUFFER_SAMPLES) {
                    rp = 0; // Wrap around
                }

                size_t written = std::fwrite(samples, sizeof(int16_t), 2, wavFile_);
                if (written != 2) {
                    // Error de I/O (disco lleno, permiso denegado, etc.)
                    state_.store(DiagRecorderState::ERROR, std::memory_order_release);
                    writerRunning_.store(false, std::memory_order_relaxed);
                    return;
                }
            }

            readPos_.store(rp, std::memory_order_release);
            samplesWritten_.fetch_add(framesToWrite, std::memory_order_relaxed);

            // Verificar si se alcanzó exactamente el target
            if (samplesWritten_.load(std::memory_order_relaxed) >= config_.targetSamples) {
                break;
            }
        } else {
            // No hay datos disponibles — dormir brevemente para no quemar CPU
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
    }

    // ─── Post-loop: Flush del ring buffer remanente ─────────────────────
    // Si no fue un stop manual ni un error, drenar cualquier dato restante
    // en el ring buffer antes de finalizar (hasta alcanzar targetSamples).
    if (!stopRequested_.load(std::memory_order_acquire) &&
        state_.load(std::memory_order_acquire) != DiagRecorderState::ERROR) {

        int64_t currentWritten = samplesWritten_.load(std::memory_order_relaxed);
        int64_t remaining = config_.targetSamples - currentWritten;

        if (remaining > 0) {
            // Aún faltan samples — drenar lo que quede en el ring buffer
            int available = availableForRead();
            if (available > 0) {
                int rp = readPos_.load(std::memory_order_relaxed);
                int framesToFlush = static_cast<int>(std::min(static_cast<int64_t>(available), remaining));

                for (int i = 0; i < framesToFlush; ++i) {
                    int16_t samples[2];
                    samples[0] = ringBuffer_[rp];
                    samples[1] = ringBuffer_[rp + 1];
                    rp += 2;
                    if (rp >= RING_BUFFER_SAMPLES) {
                        rp = 0;
                    }

                    size_t written = std::fwrite(samples, sizeof(int16_t), 2, wavFile_);
                    if (written != 2) {
                        state_.store(DiagRecorderState::ERROR, std::memory_order_release);
                        writerRunning_.store(false, std::memory_order_relaxed);
                        return;
                    }
                }

                readPos_.store(rp, std::memory_order_release);
                samplesWritten_.fetch_add(framesToFlush, std::memory_order_relaxed);
            }
        }
    }

    // ─── Finalización ───────────────────────────────────────────────────
    // Si se alcanzó el target (grabación completa), finalizar encabezado WAV
    if (!stopRequested_.load(std::memory_order_acquire) &&
        state_.load(std::memory_order_acquire) != DiagRecorderState::ERROR &&
        samplesWritten_.load(std::memory_order_relaxed) >= config_.targetSamples) {

        state_.store(DiagRecorderState::FINALIZING, std::memory_order_release);

        if (finalizeWavHeader()) {
            std::fclose(wavFile_);
            wavFile_ = nullptr;
            state_.store(DiagRecorderState::COMPLETED, std::memory_order_release);
        } else {
            // Error al finalizar encabezado — marcar como error
            std::fclose(wavFile_);
            wavFile_ = nullptr;
            state_.store(DiagRecorderState::ERROR, std::memory_order_release);
        }
    }

    writerRunning_.store(false, std::memory_order_relaxed);
}

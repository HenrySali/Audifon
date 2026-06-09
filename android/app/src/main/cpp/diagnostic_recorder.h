/// @file diagnostic_recorder.h
/// @brief Grabador de diagnóstico DSP: captura simultánea pre/post DSP en WAV estéreo.
///
/// Usa un ring buffer SPSC lock-free para desacoplar el hilo de audio (productor)
/// del hilo de escritura a disco (consumidor). El canal izquierdo almacena la señal
/// pre-DSP (micrófono crudo) y el canal derecho la señal post-DSP (salida procesada).

#ifndef HEARING_AID_DIAGNOSTIC_RECORDER_H
#define HEARING_AID_DIAGNOSTIC_RECORDER_H

#include <atomic>
#include <cstdint>
#include <string>
#include <thread>
#include <cstdio>

/// Estados del ciclo de vida del grabador de diagnóstico.
enum class DiagRecorderState {
    IDLE,       ///< Listo para grabar
    RECORDING,  ///< Capturando activamente
    FINALIZING, ///< Hilo escritor finalizando encabezado WAV
    COMPLETED,  ///< Grabación finalizada exitosamente
    ERROR       ///< Error (I/O, desbordamiento de buffer)
};

/// Configuración fija del grabador de diagnóstico.
struct DiagRecorderConfig {
    int sampleRate      = 48000;
    int bitsPerSample   = 16;
    int channels        = 2;       ///< Estéreo: L=pre-DSP, R=post-DSP
    int durationSeconds = 60;
    int64_t targetSamples = 2880000; ///< 60 × 48000
};

/// Grabador de diagnóstico DSP con ring buffer SPSC y hilo escritor dedicado.
///
/// Uso:
///   1. Llamar start(filePath) para iniciar grabación.
///   2. En el callback de audio, llamar feedPreDsp() y feedPostDsp() cada bloque.
///   3. La grabación termina automáticamente a los 60s, o con stop() (descarta).
class DiagnosticRecorder {
public:
    DiagnosticRecorder();
    ~DiagnosticRecorder();

    // No copiable ni movible
    DiagnosticRecorder(const DiagnosticRecorder&) = delete;
    DiagnosticRecorder& operator=(const DiagnosticRecorder&) = delete;

    /// Inicia grabación al path indicado.
    /// Crea archivo WAV, escribe encabezado placeholder, lanza hilo escritor.
    /// @param filePath Ruta absoluta para el archivo WAV de salida.
    /// @return true si la grabación inició correctamente.
    bool start(const std::string& filePath);

    /// Detiene la grabación. Si no se completaron 60s, descarta y borra el archivo.
    void stop();

    /// Alimenta muestras pre-DSP desde el callback de audio (float32 mono).
    /// Debe llamarse SOLO desde el hilo de audio.
    void feedPreDsp(const float* data, int numFrames);

    /// Alimenta muestras post-DSP desde el callback de audio (float32 mono).
    /// Debe llamarse SOLO desde el hilo de audio.
    /// Después de esta llamada, las muestras se intercalan y se empujan al ring buffer.
    void feedPostDsp(const float* data, int numFrames);

    /// Obtiene el tiempo transcurrido de grabación en milisegundos.
    int64_t getElapsedMs() const;

    /// Obtiene el estado actual del grabador.
    DiagRecorderState getState() const;

    /// Obtiene el total de muestras escritas por canal.
    int64_t getSamplesWritten() const;

private:
    // ─── Ring Buffer SPSC ────────────────────────────────────────────────
    // Capacidad: 9600 frames estéreo × 2 canales = 19200 muestras int16
    // Memoria: 9600 × 2 × 2 bytes = 38.4 KB
    static constexpr int RING_BUFFER_FRAMES = 9600;
    static constexpr int RING_BUFFER_SAMPLES = RING_BUFFER_FRAMES * 2; // L/R interleaved

    int16_t ringBuffer_[RING_BUFFER_SAMPLES];
    std::atomic<int> writePos_{0};  ///< Posición de escritura (productor/audio thread)
    std::atomic<int> readPos_{0};   ///< Posición de lectura (consumidor/writer thread)

    // ─── Buffers temporales para conversión float→int16 ─────────────────
    // Máximo tamaño de bloque esperado del callback de Oboe
    static constexpr int MAX_BLOCK_SIZE = 1024;
    int16_t preConvertBuf_[MAX_BLOCK_SIZE];
    int16_t postConvertBuf_[MAX_BLOCK_SIZE];

    // Almacena temporalmente los frames pre-DSP del bloque actual
    int currentBlockFrames_{0};

    // ─── Estado ─────────────────────────────────────────────────────────
    std::atomic<DiagRecorderState> state_{DiagRecorderState::IDLE};
    std::atomic<int64_t> samplesWritten_{0};  ///< Muestras escritas por canal
    std::atomic<int64_t> framesProduced_{0};  ///< Frames producidos al ring buffer
    DiagRecorderConfig config_;

    // ─── Hilo escritor ──────────────────────────────────────────────────
    std::thread writerThread_;
    std::atomic<bool> writerRunning_{false};
    std::atomic<bool> stopRequested_{false};
    FILE* wavFile_{nullptr};
    std::string filePath_;

    // ─── Métodos internos ───────────────────────────────────────────────
    /// Bucle del hilo escritor (drena ring buffer → disco).
    /// Esqueleto en task 1.1; implementación completa en task 1.2.
    void writerLoop();

    /// Escribe encabezado WAV con tamaños placeholder.
    bool writeWavHeader();

    /// Finaliza encabezado WAV con tamaños reales (seek a posición 0).
    bool finalizeWavHeader();

    /// Convierte float32 [-1.0, 1.0] a int16 con saturación.
    static int16_t floatToInt16(float sample);

    /// Calcula cuántos frames disponibles hay para leer en el ring buffer.
    int availableForRead() const;

    /// Calcula cuántos frames disponibles hay para escribir en el ring buffer.
    int availableForWrite() const;

    /// Empuja frames intercalados al ring buffer.
    /// @return true si todos los frames fueron empujados, false si overflow.
    bool pushToRingBuffer(const int16_t* preBuf, const int16_t* postBuf, int numFrames);
};

#endif // HEARING_AID_DIAGNOSTIC_RECORDER_H

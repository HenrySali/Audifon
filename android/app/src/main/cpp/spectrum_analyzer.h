/// @file spectrum_analyzer.h
/// @brief Analizador de espectro en tiempo real para el pipeline DSP.
///
/// Computa FFT de 128 puntos (Cooley-Tukey radix-2) sobre los buffers de
/// entrada y salida, extrae magnitud (dB SPL) y fase (grados) para 64 bins,
/// agrupa en 12 bandas EQ, y emite snapshots a 10 Hz para visualización.
///
/// Principios de diseño:
/// - Sin dependencias externas (solo cmath, cstring, vector, atomic).
/// - Lock-free en el hilo de audio (atomics para active_ y recording_).
/// - Ventana Hann precomputada en init() para evitar trig en audio thread.
/// - Grabación en memoria C++ (bulk transfer al exportar, evita JNI repetido).

#ifndef HEARING_AID_SPECTRUM_ANALYZER_H
#define HEARING_AID_SPECTRUM_ANALYZER_H

#include <cstdint>
#include <cmath>
#include <cstring>
#include <vector>
#include <atomic>

// ─────────────────────────────────────────────────────────────────────────────
// Data Model
// ─────────────────────────────────────────────────────────────────────────────

/// Snapshot completo del espectro en un instante de tiempo.
/// Contiene magnitud y fase para input y output (64 bins cada uno),
/// agrupamiento en 12 bandas EQ, niveles RMS, clase de entorno y timestamp.
/// Tamaño: ~1136 bytes.
struct SpectrumSnapshot {
    float inputMagnitude[64];   ///< dB SPL por bin (resolución 125 Hz)
    float inputPhase[64];       ///< grados [-180, +180] por bin
    float outputMagnitude[64];  ///< dB SPL por bin
    float outputPhase[64];      ///< grados [-180, +180] por bin
    float inputBands[12];       ///< magnitud promedio por banda EQ (dB SPL)
    float outputBands[12];      ///< magnitud promedio por banda EQ (dB SPL)
    float inputLevelDb;         ///< nivel RMS de entrada (dB SPL)
    float outputLevelDb;        ///< nivel RMS de salida (dB SPL)
    int environmentClass;       ///< 0=QUIET, 1=SPEECH, 2=SPEECH_IN_NOISE, 3=NOISE
    uint32_t timestampMs;       ///< milisegundos desde inicio de grabación
};

// ─────────────────────────────────────────────────────────────────────────────
// SpectrumAnalyzer Class
// ─────────────────────────────────────────────────────────────────────────────

/// Analizador de espectro en tiempo real integrado al pipeline DSP.
///
/// Uso típico:
/// @code
///   SpectrumAnalyzer analyzer;
///   analyzer.init(16000, 120.0f);
///   analyzer.setActive(true);
///   // En hilo de audio (cada bloque de 64 muestras):
///   analyzer.processBuffers(inputBuf, outputBuf, 64);
///   // Desde hilo de UI (polling a 10 Hz):
///   SpectrumSnapshot snap = analyzer.getCurrentSnapshot();
/// @endcode
class SpectrumAnalyzer {
public:
    SpectrumAnalyzer();
    ~SpectrumAnalyzer();

    // ─── Inicialización ─────────────────────────────────────────────────

    /// Inicializa el analizador con sample rate y offset de calibración SPL.
    /// Precomputa la ventana Hann y calcula blocksPerSnapshot.
    /// @param sampleRate Frecuencia de muestreo (típicamente 16000 Hz)
    /// @param splOffset Offset dBFS → dB SPL (120 para mic real, 76 para WAV)
    void init(int sampleRate, float splOffset);

    // ─── Procesamiento (hilo de audio) ──────────────────────────────────

    /// Procesa buffers de entrada y salida — llamado desde el hilo de audio.
    /// Acumula muestras hasta llenar el buffer FFT (128), luego computa FFT.
    /// Emite snapshot cada blocksPerSnapshot_ bloques (~100ms a 10 Hz).
    /// @param input Buffer de entrada pre-procesamiento (blockSize muestras)
    /// @param output Buffer de salida post-procesamiento (blockSize muestras)
    /// @param blockSize Número de muestras por bloque (típicamente 64)
    void processBuffers(const float* input, const float* output, int blockSize);

    // ─── Lectura de datos (hilo de UI) ──────────────────────────────────

    /// Obtiene el último snapshot computado (lectura thread-safe).
    /// @return Copia del snapshot actual
    SpectrumSnapshot getCurrentSnapshot() const;

    // ─── Control de activación ──────────────────────────────────────────

    /// Activa/desactiva el análisis de espectro (ahorra CPU cuando no visible).
    /// @param active true para activar, false para desactivar
    void setActive(bool active);

    /// Consulta si el analizador está activo.
    /// @return true si está computando FFT cada bloque
    bool isActive() const;

    // ─── Control de grabación ───────────────────────────────────────────

    /// Inicia grabación de snapshots (máximo 3 minutos / 1800 snapshots).
    /// Limpia el buffer de grabación previo y registra timestamp de inicio.
    void startRecording();

    /// Detiene la grabación manualmente.
    void stopRecording();

    /// Consulta si está grabando actualmente.
    /// @return true si recording_ está activo
    bool isRecording() const;

    /// Obtiene el número de snapshots grabados.
    /// @return Cantidad de snapshots en el buffer de grabación
    int getRecordedCount() const;

    /// Obtiene puntero a los snapshots grabados (válido hasta próximo startRecording).
    /// Solo debe leerse después de stopRecording() (sin acceso concurrente).
    /// @return Puntero al array interno de snapshots
    const SpectrumSnapshot* getRecordedSnapshots() const;

    /// Obtiene el tamaño en bytes de los datos grabados.
    /// @return count * sizeof(SpectrumSnapshot)
    int getRecordedSize() const;

    // ─── Actualización de parámetros ────────────────────────────────────

    /// Actualiza el offset de calibración SPL (cuando cambia la calibración).
    /// @param offset Nuevo offset dBFS → dB SPL
    void setSplOffset(float offset);

    /// Actualiza la clase de entorno actual (desde DspPipeline).
    /// @param envClass 0=QUIET, 1=SPEECH, 2=SPEECH_IN_NOISE, 3=NOISE
    void setEnvironmentClass(int envClass);

private:
    // ─── Algoritmos internos ────────────────────────────────────────────

    /// Computa FFT de 128 puntos (Cooley-Tukey radix-2 in-place).
    /// Aplica ventana Hann precomputada, bit-reversal, 7 etapas butterfly.
    /// Extrae magnitud (dB SPL) y fase (grados) para bins 1-64.
    /// @param buffer Buffer de 128 muestras float
    /// @param N Tamaño del FFT (128)
    /// @param magnitude Array de salida para magnitud (64 valores, dB SPL)
    /// @param phase Array de salida para fase (64 valores, grados [-180,+180])
    void computeFFT(const float* buffer, int N, float* magnitude, float* phase);

    /// Agrupa 64 bins de magnitud en 12 bandas EQ.
    /// Promedia en dominio de potencia lineal y convierte de vuelta a dB.
    /// @param magnitude64 Array de 64 magnitudes en dB SPL
    /// @param bands12 Array de salida para 12 bandas en dB SPL
    void groupIntoBands(const float* magnitude64, float* bands12);

    /// Mide el nivel RMS de un buffer y lo convierte a dB SPL.
    /// @param buffer Buffer de audio float32
    /// @param blockSize Número de muestras
    /// @return Nivel en dB SPL
    float measureRmsDb(const float* buffer, int blockSize) const;

    /// Acumula muestras de input y output en los buffers FFT.
    /// @param input Buffer de entrada (blockSize muestras)
    /// @param output Buffer de salida (blockSize muestras)
    /// @param blockSize Número de muestras a copiar
    void appendToFftBuffer(const float* input, const float* output, int blockSize);

    /// Verifica si el buffer FFT está lleno (128 muestras acumuladas).
    /// @return true si fftBufferPos_ >= FFT_SIZE
    bool fftBufferFull() const;

    /// Resetea la posición del buffer FFT a 0.
    void resetFftBuffer();

    /// Obtiene milisegundos transcurridos desde el inicio de la grabación.
    /// @return Tiempo en ms desde recordingStartTimeMs_
    uint32_t getElapsedMs() const;

    // ─── Constantes ─────────────────────────────────────────────────────

    static constexpr int FFT_SIZE = 128;
    static constexpr int NUM_BINS = 64;
    static constexpr int NUM_BANDS = 12;
    static constexpr int MAX_RECORDING_SNAPSHOTS = 1800;

    // ─── Buffers FFT (128 muestras cada uno) ────────────────────────────

    float inputFftBuffer_[FFT_SIZE];
    float outputFftBuffer_[FFT_SIZE];
    int fftBufferPos_ = 0;

    // ─── Ventana Hann (precomputada en init) ────────────────────────────

    float hannWindow_[FFT_SIZE];

    // ─── Snapshot actual (escrito por audio thread, leído por UI thread) ─

    SpectrumSnapshot currentSnapshot_;

    // ─── Grabación ──────────────────────────────────────────────────────

    std::vector<SpectrumSnapshot> recordBuffer_;
    std::atomic<bool> recording_{false};
    std::atomic<bool> active_{false};
    uint64_t recordingStartTimeMs_ = 0;

    // ─── Timing y configuración ─────────────────────────────────────────

    int snapshotCounter_ = 0;
    int blockCounter_ = 0;
    int blocksPerSnapshot_ = 25;  ///< 100ms / 4ms = 25 bloques (64 samples @ 16kHz)
    int sampleRate_ = 16000;
    float splOffset_ = 120.0f;
    int currentEnvClass_ = 0;
};

#endif // HEARING_AID_SPECTRUM_ANALYZER_H

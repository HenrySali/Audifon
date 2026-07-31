/// @file denoiser_selector.h
/// @brief Selector exclusivo de denoiser con crossfade entre motores.
///
/// Solo UN motor activo a la vez. Al cambiar selección se aplica crossfade
/// lineal de 20ms (960 samples @48kHz) entre motor saliente y entrante.
/// Fallback automático: si el seleccionado no está disponible, cae a
/// kDPDFNet2 → kRNNoise → bypass.
///
/// Requirements: 4.1, 4.2, 4.3, 5.3

#ifndef HEARING_AID_DENOISER_SELECTOR_H
#define HEARING_AID_DENOISER_SELECTOR_H

#include "i_denoiser_engine.h"
#include <array>
#include <atomic>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

/// Identificadores de los motores disponibles.
/// El valor numérico de cada entry es estable y se persiste en Hive (Dart).
/// kDPDFNet2 = 4 reemplaza al antiguo kDTLN = 4, preservando compatibilidad
/// con la persistencia existente.
enum class DenoiserType : int {
    kRNNoise  = 0,   ///< "Estándar" — RNNoise xiph
    kDFN3     = 1,   ///< "Premium" (DeepFilterNet3) — deprecated
    kGTCRN    = 2,   ///< "Analítico" (GTCRN) — deprecated
    kDPDFNet  = 3,   ///< "Ultra" — DPDFNet-4 via OnnxRuntime
    kDPDFNet2 = 4,   ///< "Inteligente" — DPDFNet-2 48kHz (reemplaza kDTLN)
    kCount    = 5    ///< Array size sentinel
};

/// Selector exclusivo de denoiser. Solo UNO activo a la vez.
/// Maneja crossfade entre motores al cambiar selección.
///
/// Thread model:
///   - select(), setEnabled(), setIntensity(): llamados desde hilo de control.
///   - process(): llamado SOLO desde audio thread.
///   - Getters: thread-safe (delegados a atomics del motor activo).
class DenoiserSelector {
public:
    DenoiserSelector();
    ~DenoiserSelector() = default;

    // No copiable
    DenoiserSelector(const DenoiserSelector&) = delete;
    DenoiserSelector& operator=(const DenoiserSelector&) = delete;

    /// Registra un motor (llamar al startup, antes de initializeAll).
    /// @param type Identificador del motor.
    /// @param engine Puntero no-owning al adapter (vive en AudioEngine).
    void registerEngine(DenoiserType type, IDenoiserEngine* engine);

    /// Inicializa todos los motores registrados.
    /// @return true si al menos uno se inicializó correctamente.
    bool initializeAll(AAssetManager* mgr);

    /// Selecciona el motor activo. Desactiva los otros.
    /// Si el motor seleccionado no está disponible (isActive()=false),
    /// cae al fallback automático: kDPDFNet2 → kRNNoise → bypass.
    /// Thread-safe (atómico + crossfade en audio thread).
    void select(DenoiserType type);

    /// @return motor actualmente seleccionado por el usuario.
    DenoiserType getSelected() const;

    /// @return motor realmente activo (puede diferir si hubo fallback).
    DenoiserType getActive() const;

    /// Procesa audio in-place. Delega al motor activo.
    /// Maneja crossfade entre motor saliente y entrante (20ms).
    /// SOLO desde audio thread.
    void process(float* buffer, int blockSize);

    /// Forward de setEnabled al motor activo (y a todos registrados para
    /// que al cambiar de motor el nuevo arranque en el estado correcto).
    void setEnabled(bool enabled);

    /// Forward de setIntensity a todos los motores registrados.
    void setIntensity(float intensity);

    /// @return true si el motor activo está procesando.
    bool isActive() const;

    /// @return true si el flag enabled global está seteado.
    bool isEnabled() const;

    /// @return intensidad efectiva del motor activo.
    float getEffectiveIntensity() const;

    /// @return total frames procesados por el motor activo.
    uint64_t getProcessedFrames() const;

    /// @return frames descartados por el motor activo.
    uint64_t getDroppedFrames() const;

    /// @return microsegundos última inferencia del motor activo.
    uint32_t getLastInferenceUs() const;

    /// @return nombre legible del motor activo.
    const char* getActiveName() const;

    // ─── Captura genérica IN/OUT del motor activo (diagnóstico) ──────────
    // Graba la señal pre-denoise (IN) y post-denoise (OUT) @48kHz de CUALQUIER
    // red activa (RNNoise/DFN3/DPDFNet/DPDFNet2), para comparar head-to-head.
    // RT-safe: el audio thread solo hace memcpy; la escritura va en un hilo.
    bool startCapture(const char* dir);
    void stopCapture();
    bool isCapturing() const;
    bool isCaptureReady() const;

private:
    /// Array de motores registrados (nullptr si no registrado).
    std::array<IDenoiserEngine*, static_cast<int>(DenoiserType::kCount)> engines_{};

    /// Tipo seleccionado por el usuario (lado control). Atómico para
    /// comunicación control thread → audio thread.
    std::atomic<int> selectedType_{0};

    /// Tipo activo en el audio thread (puede diferir del seleccionado
    /// tras fallback). SOLO tocado desde audio thread.
    int activeType_ = 0;

    /// Tipo del motor saliente durante un crossfade. Audio-thread-only.
    int prevType_ = -1;

    /// Flag enabled global (reflejo del último setEnabled).
    std::atomic<bool> enabled_{false};

    // ─── Crossfade entre motores (20ms @ 48kHz = 960 samples) ────────────
    static constexpr int kXfadeSamples = 960;

    /// Samples restantes del crossfade (0 = sin crossfade). Audio-thread-only.
    int xfadeRemaining_ = 0;

    /// Buffer temporal para renderizar el motor saliente durante crossfade.
    /// Tamaño fijo: 960 samples es el máximo que se procesa en una ventana.
    float xfadeBuf_[kXfadeSamples] = {};

    /// Resuelve fallback si el motor seleccionado no está disponible.
    /// Fallback chain: kDPDFNet2 → kRNNoise → bypass (-1).
    /// @return índice del motor a usar, o -1 si ninguno disponible (bypass).
    int resolveFallback(int requested) const;

    // ─── Captura IN/OUT (diagnóstico) ────────────────────────────────────
    void processImpl(float* buffer, int blockSize);  // lógica real de process()
    static constexpr int kCapSr   = 48000;
    static constexpr int kCapSecs = 10;
    static constexpr int kCapCap  = kCapSr * kCapSecs;   // 480000 floats
    std::vector<float> capIn_;
    std::vector<float> capOut_;
    int capInW_ = 0, capOutW_ = 0;
    std::atomic<bool> capturing_{false};
    std::atomic<bool> captureReady_{false};
    std::atomic<bool> flushRequested_{false};
    std::atomic<bool> writerRunning_{false};
    std::thread capWriter_;
    std::string capDir_;
    std::string capEngine_;
    char capTs_[24] = {0};
    void capWriterLoop_();
    void capWriteFiles_();
};

#endif // HEARING_AID_DENOISER_SELECTOR_H

/// @file denoiser_selector.h
/// @brief Selector exclusivo de denoiser con crossfade entre motores.
///
/// Solo UN motor activo a la vez. Al cambiar selección se aplica crossfade
/// lineal de 20ms (960 samples @48kHz) entre motor saliente y entrante.
/// Fallback automático: si el seleccionado no está disponible, cae a
/// RNNoise → GTCRN → bypass.
///
/// Spec: ruidolimpio.md § 4.2

#ifndef HEARING_AID_DENOISER_SELECTOR_H
#define HEARING_AID_DENOISER_SELECTOR_H

#include "i_denoiser_engine.h"
#include "denoiser_artifact_log.h"
#include <array>
#include <atomic>
#include <cstring>

/// Identificadores de los 3 motores disponibles.
enum class DenoiserType : int {
    kRNNoise = 0,   ///< "Estándar" — RNNoise xiph
    kDFN3    = 1,   ///< "Premium"  — DeepFilterNet3
    kGTCRN   = 2,   ///< "Analítico" — GTCRN via OnnxRuntime
    kCount   = 3
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
    /// cae al fallback automático (RNNoise → GTCRN → bypass).
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

    /// Conecta el registro de matraca/calidad (opcional). Cuando está seteado,
    /// process() alimenta el tap de ENTRADA (pre-denoise) y el tap de SALIDA
    /// del motor activo, permitiendo atribuir la matraca a un sistema concreto
    /// o determinar si viene de la fuente. Llamar desde el hilo de control
    /// (antes de arrancar el audio). Puntero no-owning (vive en AudioEngine).
    void setArtifactLog(DenoiserArtifactLog* log) { artifactLog_ = log; }

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
    /// @return índice del motor a usar (fallback chain: RNNoise → GTCRN → -1).
    int resolveFallback(int requested) const;

    /// Registro de matraca/calidad (no-owning, opcional). nullptr = deshabilitado.
    DenoiserArtifactLog* artifactLog_ = nullptr;
};

#endif // HEARING_AID_DENOISER_SELECTOR_H

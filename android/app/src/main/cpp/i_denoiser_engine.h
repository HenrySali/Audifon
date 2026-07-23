/// @file i_denoiser_engine.h
/// @brief Interfaz polimórfica para motores de denoising (RNNoise, DFN3, GTCRN).
///
/// Cada implementación hereda de IDenoiserEngine y delega a su clase concreta.
/// El DenoiserSelector usa esta interfaz para conmutar exclusivamente entre
/// motores con crossfade sin conocer la implementación subyacente.
///
/// Spec: ruidolimpio.md § 4.1

#ifndef HEARING_AID_I_DENOISER_ENGINE_H
#define HEARING_AID_I_DENOISER_ENGINE_H

#include <cstdint>
#include <string>

struct AAssetManager;

/// Interfaz polimórfica para motores de denoising.
/// Cada implementación (RNNoise, DFN3, GTCRN) hereda de esta.
class IDenoiserEngine {
public:
    virtual ~IDenoiserEngine() = default;

    /// Inicializa el motor. Retorna true si queda listo.
    /// @param mgr AAssetManager para cargar modelos (puede ser nullptr si no se necesita).
    virtual bool initialize(AAssetManager* mgr) = 0;

    /// Procesa audio in-place. Solo desde audio thread.
    /// @param buffer Float audio [-1,+1]. Modificado in-place.
    /// @param blockSize Número de samples.
    virtual void process(float* buffer, int blockSize) = 0;

    /// Habilita/deshabilita (con crossfade interno del motor).
    virtual void setEnabled(bool enabled) = 0;

    /// Mezcla dry/wet [0..1].
    virtual void setIntensity(float intensity) = 0;

    /// @return true si el motor está procesando audio (modelo listo, sin error).
    virtual bool isActive() const = 0;

    /// @return true si el flag enabled está seteado.
    virtual bool isEnabled() const = 0;

    /// Resetea estado interno (buffers, caches).
    virtual void reset() = 0;

    /// Nombre legible para UI/logs.
    virtual const char* name() const = 0;

    /// Getters de telemetría.
    virtual uint64_t getProcessedFrames() const = 0;
    virtual uint64_t getDroppedFrames() const = 0;
    virtual uint32_t getLastInferenceUs() const = 0;
    virtual float getEffectiveIntensity() const = 0;
};

#endif // HEARING_AID_I_DENOISER_ENGINE_H

/// @file denoiser_selector.cpp
/// @brief Implementación del DenoiserSelector — toggle exclusivo con crossfade.
///
/// Spec: ruidolimpio.md § 4.2

#include "denoiser_selector.h"

#include <algorithm>
#include <cstring>

#include <android/log.h>
#define LOG_TAG "DenoiserSelector"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

// ─────────────────────────────────────────────────────────────────────────────
// Constructor
// ─────────────────────────────────────────────────────────────────────────────

DenoiserSelector::DenoiserSelector() {
    engines_.fill(nullptr);
}

// ─────────────────────────────────────────────────────────────────────────────
// Registro e inicialización
// ─────────────────────────────────────────────────────────────────────────────

void DenoiserSelector::registerEngine(DenoiserType type, IDenoiserEngine* engine) {
    const int idx = static_cast<int>(type);
    if (idx >= 0 && idx < static_cast<int>(DenoiserType::kCount)) {
        engines_[idx] = engine;
    }
}

bool DenoiserSelector::initializeAll(AAssetManager* mgr) {
    bool anyOk = false;
    for (int i = 0; i < static_cast<int>(DenoiserType::kCount); ++i) {
        if (engines_[i]) {
            const bool ok = engines_[i]->initialize(mgr);
            if (ok) {
                LOGI("initializeAll: %s OK", engines_[i]->name());
                anyOk = true;
            } else {
                LOGW("initializeAll: %s FAILED", engines_[i]->name());
            }
        }
    }
    return anyOk;
}

// ─────────────────────────────────────────────────────────────────────────────
// Selección + fallback
// ─────────────────────────────────────────────────────────────────────────────

void DenoiserSelector::select(DenoiserType type) {
    const int idx = static_cast<int>(type);
    if (idx < 0 || idx >= static_cast<int>(DenoiserType::kCount)) return;

    // Guardar la selección del usuario. El audio thread la leerá y
    // disparará el crossfade si es distinta al activeType_ actual.
    selectedType_.store(idx, std::memory_order_release);

    LOGI("select: user selected %s (idx=%d)",
         engines_[idx] ? engines_[idx]->name() : "null", idx);
}

DenoiserType DenoiserSelector::getSelected() const {
    return static_cast<DenoiserType>(selectedType_.load(std::memory_order_acquire));
}

DenoiserType DenoiserSelector::getActive() const {
    // activeType_ se escribe solo desde audio thread, pero la lectura
    // desde otro hilo es benigna (worst case: stale por 1 callback).
    return static_cast<DenoiserType>(activeType_);
}

int DenoiserSelector::resolveFallback(int requested) const {
    // Si el solicitado está disponible, usarlo.
    if (requested >= 0 && requested < static_cast<int>(DenoiserType::kCount)
        && engines_[requested] && engines_[requested]->isActive()) {
        return requested;
    }

    // Fallback chain: intenta TODOS los motores por prioridad antes de
    // caer a bypass. Antes solo incluía {RNNoise, GTCRN}, por lo que si el
    // usuario elegía GTCRN/DPDFNet y ese motor no estaba disponible, el
    // selector NUNCA podía caer en DFN3 (el motor premium que sí carga en
    // muchos dispositivos) y terminaba en bypass silencioso.
    // Orden: RNNoise (primario) → DFN3 (premium) → GTCRN → DPDFNet.
    const int fallbackOrder[] = {
        static_cast<int>(DenoiserType::kRNNoise),
        static_cast<int>(DenoiserType::kDFN3),
        static_cast<int>(DenoiserType::kGTCRN),
        static_cast<int>(DenoiserType::kDPDFNet)
    };
    for (int f : fallbackOrder) {
        if (f != requested && engines_[f] && engines_[f]->isActive()) {
            LOGW("resolveFallback: %s no disponible, cayendo a %s",
                 engines_[requested] ? engines_[requested]->name() : "null",
                 engines_[f]->name());
            return f;
        }
    }
    // Ninguno disponible → bypass
    return -1;
}

// ─────────────────────────────────────────────────────────────────────────────
// Procesamiento (audio thread only)
// ─────────────────────────────────────────────────────────────────────────────

void DenoiserSelector::process(float* buffer, int blockSize) {
    if (blockSize <= 0 || buffer == nullptr) return;

    // ─── Tap de ENTRADA a los sistemas de limpieza (pre-denoise) ─────────
    // Mide la señal ANTES de que el motor la procese, para el registro de
    // matraca/calidad. Si la matraca ya aparece acá, la fuente es previa.
    if (artifactLog_) artifactLog_->feedDenoiserInput(buffer, blockSize);

    // Leer la selección del usuario.
    const int target = selectedType_.load(std::memory_order_acquire);
    const int resolved = resolveFallback(target);

    // Detectar cambio de estado (motor entrante o bypass).
    if (resolved != activeType_) {
        if (resolved >= 0) {
            // Cambio a un motor real → arrancar crossfade desde el saliente
            // (solo si veníamos de otro motor real; desde bypass no hay
            // señal previa que desvanecer).
            prevType_ = (activeType_ >= 0) ? activeType_ : -1;
            activeType_ = resolved;
            xfadeRemaining_ = (prevType_ >= 0) ? kXfadeSamples : 0;

            // Habilitar el motor entrante en el estado enabled correcto.
            if (engines_[activeType_]) {
                engines_[activeType_]->setEnabled(
                    enabled_.load(std::memory_order_acquire));
            }
        } else {
            // Ningún motor disponible → bypass HONESTO. Antes activeType_
            // quedaba congelado en el último motor real, así que getActive()
            // mentía (reportaba DFN3 aunque el audio pasara sin limpiar).
            // Ahora reportamos -1 (bypass) para que la UI lo muestre real.
            if (activeType_ >= 0 && engines_[activeType_]) {
                engines_[activeType_]->setEnabled(false);
            }
            activeType_ = -1;
            prevType_ = -1;
            xfadeRemaining_ = 0;
        }
    }

    // Si ningún motor disponible → bypass (buffer sin tocar).
    if (activeType_ < 0 || !engines_[activeType_]) {
        return;
    }

    // Si no hay crossfade → proceso simple.
    if (xfadeRemaining_ <= 0 || prevType_ < 0 || !engines_[prevType_]) {
        engines_[activeType_]->process(buffer, blockSize);
        xfadeRemaining_ = 0;
        // Tap de SALIDA del sistema activo (post-denoise) para el registro.
        if (artifactLog_) artifactLog_->feedEngineOutput(activeType_, buffer, blockSize);
        return;
    }

    // ─── Crossfade entre motor saliente (prevType_) y entrante (activeType_) ──
    // Procesamos en chunks de hasta kXfadeSamples para no desbordar xfadeBuf_.
    int offset = 0;
    int remaining = blockSize;

    while (remaining > 0) {
        if (xfadeRemaining_ <= 0) {
            // Crossfade terminó — solo motor entrante procesa el resto.
            engines_[activeType_]->process(buffer + offset, remaining);
            break;
        }

        const int chunk = std::min(remaining, std::min(xfadeRemaining_, kXfadeSamples));

        // Motor saliente procesa en buffer temporal.
        std::memcpy(xfadeBuf_, buffer + offset, chunk * sizeof(float));
        engines_[prevType_]->process(xfadeBuf_, chunk);

        // Motor entrante procesa in-place.
        engines_[activeType_]->process(buffer + offset, chunk);

        // Mezcla con weights complementarios (crossfade lineal).
        const float stepInv = 1.0f / static_cast<float>(kXfadeSamples);
        for (int i = 0; i < chunk; ++i) {
            // fadeIn: 0 → 1 conforme xfadeRemaining_ decrece.
            const float fadeIn = 1.0f -
                static_cast<float>(xfadeRemaining_) * stepInv;
            const float fadeOut = 1.0f - fadeIn;
            buffer[offset + i] = xfadeBuf_[i] * fadeOut +
                                 buffer[offset + i] * fadeIn;
            if (xfadeRemaining_ > 0) --xfadeRemaining_;
        }

        offset += chunk;
        remaining -= chunk;
    }

    // Post-crossfade: deshabilitar motor saliente (libera procesamiento).
    if (xfadeRemaining_ <= 0 && prevType_ >= 0 && prevType_ != activeType_) {
        if (engines_[prevType_]) {
            engines_[prevType_]->setEnabled(false);
        }
        prevType_ = -1;
    }

    // Tap de SALIDA del sistema entrante (post-denoise) para el registro.
    // Durante el crossfade el buffer ya contiene la mezcla dominada por el
    // motor entrante, así que se atribuye al motor activo (activeType_).
    if (artifactLog_) artifactLog_->feedEngineOutput(activeType_, buffer, blockSize);
}

// ─────────────────────────────────────────────────────────────────────────────
// Setters delegados
// ─────────────────────────────────────────────────────────────────────────────

void DenoiserSelector::setEnabled(bool enabled) {
    enabled_.store(enabled, std::memory_order_release);
    // Forward a todos los motores registrados para que al conmutar
    // el nuevo motor arranque en el estado enabled correcto.
    for (int i = 0; i < static_cast<int>(DenoiserType::kCount); ++i) {
        if (engines_[i]) {
            engines_[i]->setEnabled(enabled);
        }
    }
}

void DenoiserSelector::setIntensity(float intensity) {
    // Forward a todos — cada motor mantiene su propio atomic de intensity.
    for (int i = 0; i < static_cast<int>(DenoiserType::kCount); ++i) {
        if (engines_[i]) {
            engines_[i]->setIntensity(intensity);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Getters (delegados al motor activo)
// ─────────────────────────────────────────────────────────────────────────────

bool DenoiserSelector::isActive() const {
    if (activeType_ >= 0 && activeType_ < static_cast<int>(DenoiserType::kCount)
        && engines_[activeType_]) {
        return engines_[activeType_]->isActive();
    }
    return false;
}

bool DenoiserSelector::isEnabled() const {
    return enabled_.load(std::memory_order_acquire);
}

float DenoiserSelector::getEffectiveIntensity() const {
    if (activeType_ >= 0 && activeType_ < static_cast<int>(DenoiserType::kCount)
        && engines_[activeType_]) {
        return engines_[activeType_]->getEffectiveIntensity();
    }
    return 0.0f;
}

uint64_t DenoiserSelector::getProcessedFrames() const {
    if (activeType_ >= 0 && activeType_ < static_cast<int>(DenoiserType::kCount)
        && engines_[activeType_]) {
        return engines_[activeType_]->getProcessedFrames();
    }
    return 0;
}

uint64_t DenoiserSelector::getDroppedFrames() const {
    if (activeType_ >= 0 && activeType_ < static_cast<int>(DenoiserType::kCount)
        && engines_[activeType_]) {
        return engines_[activeType_]->getDroppedFrames();
    }
    return 0;
}

uint32_t DenoiserSelector::getLastInferenceUs() const {
    if (activeType_ >= 0 && activeType_ < static_cast<int>(DenoiserType::kCount)
        && engines_[activeType_]) {
        return engines_[activeType_]->getLastInferenceUs();
    }
    return 0;
}

const char* DenoiserSelector::getActiveName() const {
    if (activeType_ >= 0 && activeType_ < static_cast<int>(DenoiserType::kCount)
        && engines_[activeType_]) {
        return engines_[activeType_]->name();
    }
    return "Bypass";
}

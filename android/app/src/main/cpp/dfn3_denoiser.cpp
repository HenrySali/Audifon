/// @file dfn3_denoiser.cpp
/// @brief Implementación de Dfn3Denoiser — wrapper C++ para DeepFilterNet3 vía dlopen.
///
/// Carga libdfn3.so (Rust/tract) en runtime con dlopen/dlsym.
/// Si la librería no está disponible → bypass silencioso (graceful degradation).
///
/// Thread safety:
///   - process(): audio thread, nunca bloquea (try_lock inside Rust)
///   - setEnabled/setIntensity: thread-safe (atomic + dlsym → Rust mutex)
///   - initialize(): NO thread-safe, llamar UNA VEZ desde main thread
///
/// Manejo de bloques no alineados:
///   Usa residual_[] para acumular samples hasta completar un hop de 480.
///   Soporta cualquier blockSize (1..N), no solo múltiplos de 480.

#include "dfn3_denoiser.h"

#include <android/log.h>
#include <dlfcn.h>

#include <algorithm>
#include <cmath>
#include <cstring>

#define DFN3_LOG_TAG "Dfn3Denoiser"
#define DFN3_LOGI(...) __android_log_print(ANDROID_LOG_INFO,  DFN3_LOG_TAG, __VA_ARGS__)
#define DFN3_LOGW(...) __android_log_print(ANDROID_LOG_WARN,  DFN3_LOG_TAG, __VA_ARGS__)
#define DFN3_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, DFN3_LOG_TAG, __VA_ARGS__)

namespace dfn3_denoiser {

// ─────────────────────────────────────────────────────────────────────────────
// Function pointer types matching the Rust FFI exports
// ─────────────────────────────────────────────────────────────────────────────

using FnInit         = bool (*)(const char* model_dir);
using FnProcessHop   = bool (*)(float* buffer);
using FnSetIntensity = void (*)(float intensity);
using FnGetIntensity = float (*)();
using FnIsActive     = bool (*)();
using FnFree         = void (*)();

// ─────────────────────────────────────────────────────────────────────────────
// Static dlopen state (shared across all instances — singleton engine in Rust)
// ─────────────────────────────────────────────────────────────────────────────

static void*          s_libHandle      = nullptr;
static FnInit         s_fnInit         = nullptr;
static FnProcessHop   s_fnProcessHop   = nullptr;
static FnSetIntensity s_fnSetIntensity = nullptr;
static FnGetIntensity s_fnGetIntensity = nullptr;
static FnIsActive     s_fnIsActive     = nullptr;
static FnFree         s_fnFree         = nullptr;
static bool           s_libLoaded      = false;

/// Intenta cargar libdfn3.so y resolver todos los símbolos FFI.
/// Retorna true si todos los símbolos se resolvieron correctamente.
static bool loadLibrary() {
    if (s_libLoaded) return true;

    // Intentar abrir libdfn3.so desde el mismo directorio que la app nativa
    s_libHandle = dlopen("libdfn3.so", RTLD_NOW | RTLD_LOCAL);
    if (!s_libHandle) {
        DFN3_LOGW("dlopen(libdfn3.so) failed: %s — DFN3 disabled (bypass mode)",
                  dlerror());
        return false;
    }

    // Resolver símbolos
    s_fnInit         = reinterpret_cast<FnInit>(dlsym(s_libHandle, "dfn3_init"));
    s_fnProcessHop   = reinterpret_cast<FnProcessHop>(dlsym(s_libHandle, "dfn3_process_hop"));
    s_fnSetIntensity = reinterpret_cast<FnSetIntensity>(dlsym(s_libHandle, "dfn3_set_intensity"));
    s_fnGetIntensity = reinterpret_cast<FnGetIntensity>(dlsym(s_libHandle, "dfn3_get_intensity"));
    s_fnIsActive     = reinterpret_cast<FnIsActive>(dlsym(s_libHandle, "dfn3_is_active"));
    s_fnFree         = reinterpret_cast<FnFree>(dlsym(s_libHandle, "dfn3_free"));

    // Verificar que todos los símbolos críticos se resolvieron
    if (!s_fnInit || !s_fnProcessHop || !s_fnSetIntensity ||
        !s_fnGetIntensity || !s_fnIsActive || !s_fnFree) {
        DFN3_LOGE("dlsym failed: one or more symbols not found in libdfn3.so");
        dlclose(s_libHandle);
        s_libHandle = nullptr;
        s_fnInit = nullptr;
        s_fnProcessHop = nullptr;
        s_fnSetIntensity = nullptr;
        s_fnGetIntensity = nullptr;
        s_fnIsActive = nullptr;
        s_fnFree = nullptr;
        return false;
    }

    s_libLoaded = true;
    DFN3_LOGI("libdfn3.so loaded successfully — all FFI symbols resolved");
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Dfn3Denoiser implementation
// ─────────────────────────────────────────────────────────────────────────────

Dfn3Denoiser::~Dfn3Denoiser() {
    if (initialized_ && s_fnFree) {
        s_fnFree();
        DFN3_LOGI("DFN3 engine freed");
    }
    initialized_ = false;
}

bool Dfn3Denoiser::initialize(const std::string& modelDir) {
    if (initialized_) {
        DFN3_LOGW("initialize() called but already initialized — skipping");
        return true;
    }

    // Paso 1: Cargar libdfn3.so
    if (!loadLibrary()) {
        DFN3_LOGW("initialize(): libdfn3.so not available — DFN3 will bypass");
        return false;
    }

    // Paso 2: Inicializar el engine Rust con la ruta al directorio de modelos
    if (!s_fnInit(modelDir.c_str())) {
        DFN3_LOGE("initialize(): dfn3_init(\"%s\") failed — models not loaded",
                  modelDir.c_str());
        return false;
    }

    // Paso 3: Estado inicial
    residualCount_ = 0;
    std::memset(residual_, 0, sizeof(residual_));
    crossfadeGain_ = 0.0f;
    crossfadeTarget_ = 0.0f;
    effectiveIntensity_ = 0.6f;
    enabled_.store(false, std::memory_order_release);

    initialized_ = true;
    DFN3_LOGI("DFN3 initialized (modelDir=%s)", modelDir.c_str());
    return true;
}

void Dfn3Denoiser::process(float* buffer, int blockSize) {
    if (!buffer || blockSize <= 0) return;

    // ─── Bypass conditions ───────────────────────────────────────────────
    // Si no está inicializado o la librería no se cargó → no tocar el buffer
    if (!initialized_ || !s_libLoaded) return;

    // Leer estado atómico de enabled
    const bool wantEnabled = enabled_.load(std::memory_order_acquire);

    // Actualizar crossfade target
    crossfadeTarget_ = wantEnabled ? 1.0f : 0.0f;

    // Si crossfade está en 0 y target es 0 → completamente bypass, no procesar
    if (crossfadeGain_ <= 0.0f && crossfadeTarget_ <= 0.0f) {
        // Asegurar que el residual se limpia cuando estamos en bypass total
        residualCount_ = 0;
        return;
    }

    // ─── Procesar con acumulación de residual ────────────────────────────
    // Estrategia: copiar samples al residual_, y cuando se completa un hop
    // de kHopSize (480), procesarlo. Aplicar crossfade sample-by-sample
    // sobre la salida.

    int pos = 0;  // posición actual en el buffer de entrada

    while (pos < blockSize) {
        // ¿Cuántos samples necesitamos para completar el hop actual?
        const int needed = kHopSize - residualCount_;
        // ¿Cuántos samples quedan disponibles en el buffer?
        const int available = blockSize - pos;
        // Tomamos el mínimo
        const int toCopy = std::min(needed, available);

        // Copiar al residual
        std::memcpy(residual_ + residualCount_, buffer + pos, toCopy * sizeof(float));
        residualCount_ += toCopy;
        pos += toCopy;

        // Si completamos un hop → procesarlo
        if (residualCount_ == kHopSize) {
            // Guardar copia dry para crossfade
            float dry[kHopSize];
            std::memcpy(dry, residual_, kHopSize * sizeof(float));

            // Llamar al engine Rust — procesa in-place los 480 samples
            // dfn3_process_hop usa try_lock internamente, si falla retorna false
            // y el buffer queda sin modificar (= dry)
            const bool processed = s_fnProcessHop(residual_);

            // Aplicar crossfade sample-by-sample y escribir de vuelta al buffer
            // Los samples procesados en este hop corresponden a las posiciones
            // [pos - toCopy .. pos - toCopy + kHopSize - 1] en el buffer original.
            // Pero ojo: parte del hop puede venir de la llamada anterior a process().
            // Solo los últimos `toCopy` samples de este hop pertenecen al buffer actual.
            // Los primeros (kHopSize - toCopy) fueron del bloque anterior y ya se
            // escribieron. Necesitamos escribir solo lo que corresponde al buffer actual.

            // Posición en el buffer de salida donde empieza la parte de este hop
            // que pertenece al bloque actual:
            const int outStart = pos - toCopy;
            // Offset dentro del hop donde empieza la parte del bloque actual:
            const int hopOffset = kHopSize - toCopy;

            for (int i = 0; i < toCopy; ++i) {
                const int hopIdx = hopOffset + i;
                const int bufIdx = outStart + i;

                // Avanzar crossfade
                if (crossfadeGain_ < crossfadeTarget_) {
                    crossfadeGain_ = std::min(crossfadeGain_ + kCrossfadeStep,
                                              crossfadeTarget_);
                } else if (crossfadeGain_ > crossfadeTarget_) {
                    crossfadeGain_ = std::max(crossfadeGain_ - kCrossfadeStep,
                                              crossfadeTarget_);
                }

                // Mezclar dry/wet según crossfade y si el procesamiento tuvo éxito
                if (processed && crossfadeGain_ > 0.0f) {
                    const float wet = residual_[hopIdx];
                    const float d   = dry[hopIdx];
                    buffer[bufIdx] = d * (1.0f - crossfadeGain_) + wet * crossfadeGain_;
                }
                // Si !processed o crossfadeGain_==0: buffer[bufIdx] ya tiene el dry
                // (lo copiamos desde buffer al residual, así que era el valor original)
                // Solo si crossfadeGain_ está entre 0 y 1 y !processed, dejamos dry.
                else if (!processed || crossfadeGain_ <= 0.0f) {
                    // buffer[bufIdx] ya contiene el valor dry original — no tocar
                }
            }

            // Actualizar effectiveIntensity_ (para getters informativos)
            effectiveIntensity_ = crossfadeGain_;

            // Resetear residual para el próximo hop
            residualCount_ = 0;
        }
    }
}

void Dfn3Denoiser::setEnabled(bool enabled) {
    enabled_.store(enabled, std::memory_order_release);
    DFN3_LOGI("setEnabled(%s)", enabled ? "true" : "false");
}

void Dfn3Denoiser::setIntensity(float intensity) {
    if (!s_libLoaded || !s_fnSetIntensity) return;
    const float clamped = std::max(0.0f, std::min(1.0f, intensity));
    s_fnSetIntensity(clamped);
    DFN3_LOGI("setIntensity(%.2f)", clamped);
}

bool Dfn3Denoiser::isActive() const {
    if (!s_libLoaded || !s_fnIsActive) return false;
    return s_fnIsActive();
}

float Dfn3Denoiser::getIntensity() const {
    if (!s_libLoaded || !s_fnGetIntensity) return 0.6f;
    return s_fnGetIntensity();
}

}  // namespace dfn3_denoiser

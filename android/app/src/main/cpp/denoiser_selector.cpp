/// @file denoiser_selector.cpp
/// @brief Implementación del DenoiserSelector — toggle exclusivo con crossfade.
///
/// Spec: ruidolimpio.md § 4.2

#include "denoiser_selector.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>

#include <android/log.h>
#define LOG_TAG "DenoiserSelector"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

// ─────────────────────────────────────────────────────────────────────────────
// Constructor
// ─────────────────────────────────────────────────────────────────────────────

DenoiserSelector::DenoiserSelector() {
    engines_.fill(nullptr);
    capIn_.resize(static_cast<size_t>(kCapCap));
    capOut_.resize(static_cast<size_t>(kCapCap));
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

    // Fallback chain: RNNoise → GTCRN → bypass (-1)
    const int fallbackOrder[] = {
        static_cast<int>(DenoiserType::kRNNoise),
        static_cast<int>(DenoiserType::kGTCRN)
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
    // Wrapper con captura genérica IN/OUT (RT-safe: solo memcpy aquí).
    const bool cap = capturing_.load(std::memory_order_acquire);
    if (cap && buffer && blockSize > 0 && capInW_ < kCapCap) {
        int room = kCapCap - capInW_;
        int c = (blockSize < room) ? blockSize : room;
        std::memcpy(capIn_.data() + capInW_, buffer,
                    static_cast<size_t>(c) * sizeof(float));
        capInW_ += c;
    }

    processImpl(buffer, blockSize);

    if (cap && buffer && blockSize > 0) {
        if (capOutW_ < kCapCap) {
            int room = kCapCap - capOutW_;
            int c = (blockSize < room) ? blockSize : room;
            std::memcpy(capOut_.data() + capOutW_, buffer,
                        static_cast<size_t>(c) * sizeof(float));
            capOutW_ += c;
        }
        if (capInW_ >= kCapCap) {   // auto-stop al llenar ~10s
            capturing_.store(false, std::memory_order_release);
            flushRequested_.store(true, std::memory_order_release);
        }
    }
}

void DenoiserSelector::processImpl(float* buffer, int blockSize) {
    if (blockSize <= 0 || buffer == nullptr) return;

    // ─── Tap de ENTRADA a los sistemas de limpieza (pre-denoise) ─────────
    // Mide la señal ANTES de que el motor la procese, para el registro de
    // matraca/calidad. Si la matraca ya aparece acá, la fuente es previa.
    if (artifactLog_) artifactLog_->feedDenoiserInput(buffer, blockSize);

    // Leer la selección del usuario.
    const int target = selectedType_.load(std::memory_order_acquire);
    const int resolved = resolveFallback(target);

    // Detectar cambio de motor → arrancar crossfade.
    if (resolved != activeType_ && resolved >= 0) {
        prevType_ = activeType_;
        activeType_ = resolved;
        xfadeRemaining_ = kXfadeSamples;

        // Habilitar el motor entrante, deshabilitar el saliente (post-crossfade).
        if (engines_[activeType_]) {
            engines_[activeType_]->setEnabled(enabled_.load(std::memory_order_acquire));
        }
    }

    // Si ningún motor disponible → bypass (buffer sin tocar).
    if (resolved < 0 || !engines_[activeType_]) {
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

// ─────────────────────────────────────────────────────────────────────────────
// Captura genérica IN/OUT del motor activo (diagnóstico head-to-head)
// ─────────────────────────────────────────────────────────────────────────────

namespace {
bool writeWavF32(const std::string& path, const float* data, int n, int sr) {
    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) { LOGW("capture: no puedo abrir %s", path.c_str()); return false; }
    const uint32_t dataBytes = static_cast<uint32_t>(n) * 4u;
    const uint32_t riffSize  = 36u + dataBytes;
    const uint32_t fmtSize   = 16u;
    const uint16_t audioFmt  = 3;   // IEEE float
    const uint16_t channels  = 1;
    const uint32_t srate     = static_cast<uint32_t>(sr);
    const uint32_t byteRate  = srate * 4u;
    const uint16_t blockAlign = 4;
    const uint16_t bits      = 32;
    std::fwrite("RIFF", 1, 4, f); std::fwrite(&riffSize, 4, 1, f);
    std::fwrite("WAVE", 1, 4, f); std::fwrite("fmt ", 1, 4, f);
    std::fwrite(&fmtSize, 4, 1, f); std::fwrite(&audioFmt, 2, 1, f);
    std::fwrite(&channels, 2, 1, f); std::fwrite(&srate, 4, 1, f);
    std::fwrite(&byteRate, 4, 1, f); std::fwrite(&blockAlign, 2, 1, f);
    std::fwrite(&bits, 2, 1, f); std::fwrite("data", 1, 4, f);
    std::fwrite(&dataBytes, 4, 1, f);
    if (n > 0) std::fwrite(data, 4, static_cast<size_t>(n), f);
    std::fclose(f);
    return true;
}
} // namespace

void DenoiserSelector::capWriteFiles_() {
    // Nombre de motor sin espacios para el filename.
    std::string eng = capEngine_.empty() ? "unknown" : capEngine_;
    for (auto& ch : eng) if (ch == ' ' || ch == '/') ch = '_';
    const std::string base = capDir_ + "/denoise_" + capTs_ + "_" + eng;
    writeWavF32(base + "_IN.wav",  capIn_.data(),  capInW_,  kCapSr);
    writeWavF32(base + "_OUT.wav", capOut_.data(), capOutW_, kCapSr);
    FILE* f = std::fopen((base + "_meta.txt").c_str(), "w");
    if (f) {
        std::fprintf(f, "Denoiser IN/OUT capture\nengine=%s\ntimestamp=%s\n",
                     capEngine_.c_str(), capTs_);
        std::fprintf(f, "IN_samples=%d (%.2f s @%dk)\n", capInW_,
                     capInW_ / static_cast<double>(kCapSr), kCapSr / 1000);
        std::fprintf(f, "OUT_samples=%d (%.2f s @%dk)\n", capOutW_,
                     capOutW_ / static_cast<double>(kCapSr), kCapSr / 1000);
        std::fclose(f);
    }
    LOGI("capture: WAVs %s (IN=%d OUT=%d)", base.c_str(), capInW_, capOutW_);
}

void DenoiserSelector::capWriterLoop_() {
    while (writerRunning_.load(std::memory_order_acquire)) {
        if (flushRequested_.load(std::memory_order_acquire)) {
            capWriteFiles_();
            captureReady_.store(true, std::memory_order_release);
            capturing_.store(false, std::memory_order_release);
            flushRequested_.store(false, std::memory_order_release);
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(15));
    }
}

bool DenoiserSelector::startCapture(const char* dir) {
    if (capturing_.load(std::memory_order_acquire)) return false;
    if (capWriter_.joinable()) {
        writerRunning_.store(false, std::memory_order_release);
        capWriter_.join();
    }
    capDir_ = (dir && dir[0]) ? dir : "";
    capEngine_ = getActiveName();
    capInW_ = 0; capOutW_ = 0;
    captureReady_.store(false, std::memory_order_release);
    flushRequested_.store(false, std::memory_order_release);
    std::time_t t = std::time(nullptr);
    std::tm tmv{}; localtime_r(&t, &tmv);
    std::strftime(capTs_, sizeof(capTs_), "%Y%m%d_%H%M%S", &tmv);
    writerRunning_.store(true, std::memory_order_release);
    capWriter_ = std::thread(&DenoiserSelector::capWriterLoop_, this);
    capturing_.store(true, std::memory_order_release);
    LOGI("capture: START engine=%s dir=%s", capEngine_.c_str(), capDir_.c_str());
    return true;
}

void DenoiserSelector::stopCapture() {
    capturing_.store(false, std::memory_order_release);
    flushRequested_.store(true, std::memory_order_release);
    if (capWriter_.joinable()) capWriter_.join();
    LOGI("capture: STOP (flushed)");
}

bool DenoiserSelector::isCapturing() const {
    return capturing_.load(std::memory_order_acquire);
}

bool DenoiserSelector::isCaptureReady() const {
    return captureReady_.load(std::memory_order_acquire);
}

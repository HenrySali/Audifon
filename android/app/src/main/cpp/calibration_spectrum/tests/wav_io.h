/// @file wav_io.h
/// @brief Lectura/escritura mínima de WAV mono 16-bit (PCM little-endian).
///
/// Solo para uso en tests offline. NO se usa en la app en producción.
/// Soporta:
///  - Leer WAV mono 16-bit y devolver muestras float [-1, +1].
///  - Escribir WAV mono 16-bit desde un buffer float.
///  - Validar header básico (RIFF/WAVE/fmt/data).

#ifndef HEARING_AID_CAL_SPECTRUM_WAV_IO_H
#define HEARING_AID_CAL_SPECTRUM_WAV_IO_H

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace cal_spectrum_test {

struct WavData {
    std::vector<float> samples;   ///< Mono, normalizado a [-1, +1]
    int sample_rate_hz = 0;
    bool valid = false;
    std::string error;
};

inline WavData readWavMono16(const std::string& path) {
    WavData out;
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) {
        out.error = "no se pudo abrir " + path;
        return out;
    }

    auto fail = [&](const std::string& msg) {
        out.error = msg;
        std::fclose(f);
        return out;
    };

    char riff[4];
    uint32_t fileSize;
    char wave[4];
    if (std::fread(riff, 1, 4, f) != 4 || std::memcmp(riff, "RIFF", 4) != 0) {
        return fail("RIFF header inválido");
    }
    if (std::fread(&fileSize, 4, 1, f) != 1) return fail("fileSize ilegible");
    if (std::fread(wave, 1, 4, f) != 4 || std::memcmp(wave, "WAVE", 4) != 0) {
        return fail("WAVE header inválido");
    }

    uint16_t numChannels = 0;
    uint32_t sampleRate = 0;
    uint16_t bitsPerSample = 0;
    bool fmtSeen = false;
    std::vector<int16_t> pcm;

    char chunkId[4];
    uint32_t chunkSize;
    while (std::fread(chunkId, 1, 4, f) == 4 && std::fread(&chunkSize, 4, 1, f) == 1) {
        if (std::memcmp(chunkId, "fmt ", 4) == 0) {
            uint16_t audioFormat;
            std::fread(&audioFormat, 2, 1, f);
            std::fread(&numChannels, 2, 1, f);
            std::fread(&sampleRate, 4, 1, f);
            uint32_t byteRate;
            uint16_t blockAlign;
            std::fread(&byteRate, 4, 1, f);
            std::fread(&blockAlign, 2, 1, f);
            std::fread(&bitsPerSample, 2, 1, f);
            // Saltar cualquier byte extra del fmt chunk.
            const long extra = static_cast<long>(chunkSize) - 16;
            if (extra > 0) std::fseek(f, extra, SEEK_CUR);
            if (audioFormat != 1) return fail("solo PCM (fmt=1) soportado");
            if (numChannels != 1) return fail("solo mono soportado");
            if (bitsPerSample != 16) return fail("solo 16-bit soportado");
            fmtSeen = true;
        } else if (std::memcmp(chunkId, "data", 4) == 0) {
            if (!fmtSeen) return fail("data antes de fmt");
            const size_t numSamples = chunkSize / sizeof(int16_t);
            pcm.resize(numSamples);
            std::fread(pcm.data(), sizeof(int16_t), numSamples, f);
            break;
        } else {
            // Skip unknown chunk
            std::fseek(f, chunkSize, SEEK_CUR);
        }
    }

    std::fclose(f);
    if (pcm.empty()) {
        out.error = "data chunk vacío o ausente";
        return out;
    }

    out.samples.resize(pcm.size());
    constexpr float kInv = 1.0f / 32768.0f;
    for (size_t i = 0; i < pcm.size(); ++i) {
        out.samples[i] = static_cast<float>(pcm[i]) * kInv;
    }
    out.sample_rate_hz = static_cast<int>(sampleRate);
    out.valid = true;
    return out;
}

inline bool writeWavMono16(const std::string& path,
                           const float* samples,
                           int n_samples,
                           int sample_rate_hz) {
    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return false;

    constexpr uint16_t numChannels = 1;
    constexpr uint16_t bitsPerSample = 16;
    const uint32_t byteRate = sample_rate_hz * numChannels * bitsPerSample / 8;
    const uint16_t blockAlign = numChannels * bitsPerSample / 8;
    const uint32_t dataSize = static_cast<uint32_t>(n_samples) * sizeof(int16_t);
    const uint32_t fileSize = 36 + dataSize;

    auto w32 = [&](uint32_t v){ std::fwrite(&v, 4, 1, f); };
    auto w16 = [&](uint16_t v){ std::fwrite(&v, 2, 1, f); };

    std::fwrite("RIFF", 1, 4, f);
    w32(fileSize);
    std::fwrite("WAVE", 1, 4, f);
    std::fwrite("fmt ", 1, 4, f);
    w32(16);
    w16(1);
    w16(numChannels);
    w32(static_cast<uint32_t>(sample_rate_hz));
    w32(byteRate);
    w16(blockAlign);
    w16(bitsPerSample);
    std::fwrite("data", 1, 4, f);
    w32(dataSize);

    for (int i = 0; i < n_samples; ++i) {
        const float clamped = samples[i] < -1.0f ? -1.0f : (samples[i] > 1.0f ? 1.0f : samples[i]);
        const int16_t s = static_cast<int16_t>(clamped * 32767.0f);
        std::fwrite(&s, sizeof(int16_t), 1, f);
    }

    std::fclose(f);
    return true;
}

}  // namespace cal_spectrum_test

#endif

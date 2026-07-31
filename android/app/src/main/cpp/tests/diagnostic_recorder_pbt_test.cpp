/// @file diagnostic_recorder_pbt_test.cpp
/// @brief Property-Based Tests for DiagnosticRecorder.
///
/// This file contains property-based tests for the DiagnosticRecorder component.
/// Tests use custom random generators with <random> and run 100+ iterations each.
/// Supports both Google Test (if available) and standalone assert-based execution.
///
/// Properties implemented:
///   P1: WAV Format Integrity
///   P2: Exact Sample Count Invariant (placeholder for task 1.4)
///   P3: Channel Assignment Round-Trip (placeholder for task 1.5)
///   P4: WAV Header Consistency (placeholder for task 1.6)
///   P8: Early Stop Discards (placeholder for task 1.7)

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <random>
#include <string>
#include <vector>
#include <iostream>
#include <thread>
#include <chrono>

// Include DiagnosticRecorder
#include "../diagnostic_recorder.h"
#include "../diagnostic_recorder.cpp"

// ─────────────────────────────────────────────────────────────────────────────
// WAV Header structure for parsing produced files
// ─────────────────────────────────────────────────────────────────────────────

#pragma pack(push, 1)
struct WavHeader {
    char     riff[4];        // "RIFF"
    uint32_t fileSize;       // File size - 8
    char     wave[4];        // "WAVE"
    char     fmt[4];         // "fmt "
    uint32_t fmtSize;        // 16 for PCM
    uint16_t audioFormat;    // 1 = PCM
    uint16_t channels;       // Number of channels
    uint32_t sampleRate;     // Samples per second
    uint32_t byteRate;       // sampleRate * channels * bitsPerSample/8
    uint16_t blockAlign;     // channels * bitsPerSample/8
    uint16_t bitsPerSample;  // Bits per sample
    char     data[4];        // "data"
    uint32_t dataSize;       // Size of audio data
};
#pragma pack(pop)

static_assert(sizeof(WavHeader) == 44, "WavHeader must be exactly 44 bytes");

// ─────────────────────────────────────────────────────────────────────────────
// Test utilities
// ─────────────────────────────────────────────────────────────────────────────

/// Generate a temporary file path for test WAV output.
static std::string getTempWavPath(int iteration) {
    std::string tempDir;
#ifdef _WIN32
    const char* tmp = std::getenv("TEMP");
    if (!tmp) tmp = std::getenv("TMP");
    if (!tmp) tmp = ".";
    tempDir = tmp;
#else
    tempDir = "/tmp";
#endif
    return tempDir + "/diag_pbt_test_" + std::to_string(iteration) + ".wav";
}

/// Read and parse a WAV header from a file.
/// Returns true if header was read successfully.
static bool readWavHeader(const std::string& filePath, WavHeader& header) {
    FILE* f = std::fopen(filePath.c_str(), "rb");
    if (!f) return false;

    size_t bytesRead = std::fread(&header, 1, sizeof(WavHeader), f);
    std::fclose(f);

    return bytesRead == sizeof(WavHeader);
}

/// Feed random float32 blocks to the DiagnosticRecorder until it reaches COMPLETED state.
/// Uses block sizes in range [minBlockSize, maxBlockSize].
/// Returns true if recording completed successfully.
static bool feedUntilComplete(DiagnosticRecorder& recorder,
                              std::mt19937& rng,
                              int minBlockSize,
                              int maxBlockSize) {
    std::uniform_int_distribution<int> blockSizeDist(minBlockSize, maxBlockSize);
    std::uniform_real_distribution<float> sampleDist(-1.0f, 1.0f);

    // Maximum iterations to prevent infinite loop
    // At minimum 256 frames per block, need ~2813 blocks for 720,000 frames
    const int maxIterations = 20000;
    int iteration = 0;

    while (iteration < maxIterations) {
        DiagRecorderState state = recorder.getState();
        if (state == DiagRecorderState::COMPLETED) {
            return true;
        }
        if (state == DiagRecorderState::ERROR || state == DiagRecorderState::IDLE) {
            return false; // Unexpected state
        }

        // If FINALIZING, wait a bit for the writer thread to finish
        if (state == DiagRecorderState::FINALIZING) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            ++iteration;
            continue;
        }

        // Generate random block size
        int blockSize = blockSizeDist(rng);

        // Generate random pre-DSP buffer
        std::vector<float> preBuf(blockSize);
        for (int i = 0; i < blockSize; ++i) {
            preBuf[i] = sampleDist(rng);
        }

        // Generate random post-DSP buffer
        std::vector<float> postBuf(blockSize);
        for (int i = 0; i < blockSize; ++i) {
            postBuf[i] = sampleDist(rng);
        }

        // Feed to recorder
        recorder.feedPreDsp(preBuf.data(), blockSize);
        recorder.feedPostDsp(postBuf.data(), blockSize);

        ++iteration;
    }

    // Wait for writer thread to finish processing remaining data
    for (int wait = 0; wait < 500; ++wait) {
        DiagRecorderState state = recorder.getState();
        if (state == DiagRecorderState::COMPLETED) {
            return true;
        }
        if (state == DiagRecorderState::ERROR || state == DiagRecorderState::IDLE) {
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }

    return recorder.getState() == DiagRecorderState::COMPLETED;
}

// ─────────────────────────────────────────────────────────────────────────────
// Property 1: WAV Format Integrity
// ─────────────────────────────────────────────────────────────────────────────
//
// **Validates: Requirements 1.1, 1.2, 3.1**
//
// For any sequence of audio blocks fed to the DiagnosticRecorder that results
// in a completed recording, the produced WAV file SHALL have a valid RIFF header
// reporting:
//   - audio format = PCM (1)
//   - channels = 2
//   - sample rate = 48000
//   - bits per sample = 16
//
// Generator strategy: Random float32 buffers with block sizes in [256, 1024] frames.
// Minimum 100 iterations.
// ─────────────────────────────────────────────────────────────────────────────

static bool runProperty1_WavFormatIntegrity(int numIterations = 100) {
    std::cout << "=== Property 1: WAV Format Integrity ===" << std::endl;
    std::cout << "Running " << numIterations << " iterations..." << std::endl;

    std::mt19937 rng(42); // Fixed seed for reproducibility
    int passed = 0;

    for (int i = 0; i < numIterations; ++i) {
        // Use a different seed per iteration for variety in random data
        std::mt19937 iterRng(rng());

        std::string wavPath = getTempWavPath(i);

        // Create a fresh recorder
        DiagnosticRecorder recorder;

        // Start recording
        bool started = recorder.start(wavPath);
        if (!started) {
            std::cerr << "  FAIL [iter " << i << "]: Failed to start recording at "
                      << wavPath << std::endl;
            return false;
        }

        // Feed random audio blocks until completion
        // Block sizes: 256–1024 frames per block
        bool completed = feedUntilComplete(recorder, iterRng, 256, 1024);
        if (!completed) {
            std::cerr << "  FAIL [iter " << i << "]: Recording did not complete. State: "
                      << static_cast<int>(recorder.getState()) << std::endl;
            std::remove(wavPath.c_str());
            return false;
        }

        // Parse WAV header from the produced file
        WavHeader header;
        bool headerRead = readWavHeader(wavPath, header);
        if (!headerRead) {
            std::cerr << "  FAIL [iter " << i << "]: Could not read WAV header from "
                      << wavPath << std::endl;
            std::remove(wavPath.c_str());
            return false;
        }

        // ─── Assertions ─────────────────────────────────────────────────

        // RIFF chunk ID
        if (std::memcmp(header.riff, "RIFF", 4) != 0) {
            std::cerr << "  FAIL [iter " << i << "]: RIFF chunk ID mismatch" << std::endl;
            std::remove(wavPath.c_str());
            return false;
        }

        // WAVE format
        if (std::memcmp(header.wave, "WAVE", 4) != 0) {
            std::cerr << "  FAIL [iter " << i << "]: WAVE format mismatch" << std::endl;
            std::remove(wavPath.c_str());
            return false;
        }

        // fmt chunk ID
        if (std::memcmp(header.fmt, "fmt ", 4) != 0) {
            std::cerr << "  FAIL [iter " << i << "]: fmt chunk ID mismatch" << std::endl;
            std::remove(wavPath.c_str());
            return false;
        }

        // Audio format = PCM (1)
        if (header.audioFormat != 1) {
            std::cerr << "  FAIL [iter " << i << "]: audioFormat=" << header.audioFormat
                      << ", expected 1 (PCM)" << std::endl;
            std::remove(wavPath.c_str());
            return false;
        }

        // Channels = 2
        if (header.channels != 2) {
            std::cerr << "  FAIL [iter " << i << "]: channels=" << header.channels
                      << ", expected 2" << std::endl;
            std::remove(wavPath.c_str());
            return false;
        }

        // Sample rate = 48000
        if (header.sampleRate != 48000) {
            std::cerr << "  FAIL [iter " << i << "]: sampleRate=" << header.sampleRate
                      << ", expected 48000" << std::endl;
            std::remove(wavPath.c_str());
            return false;
        }

        // Bits per sample = 16
        if (header.bitsPerSample != 16) {
            std::cerr << "  FAIL [iter " << i << "]: bitsPerSample=" << header.bitsPerSample
                      << ", expected 16" << std::endl;
            std::remove(wavPath.c_str());
            return false;
        }

        // data chunk ID
        if (std::memcmp(header.data, "data", 4) != 0) {
            std::cerr << "  FAIL [iter " << i << "]: data chunk ID mismatch" << std::endl;
            std::remove(wavPath.c_str());
            return false;
        }

        // Verify derived fields for consistency
        uint16_t expectedBlockAlign = header.channels * (header.bitsPerSample / 8);
        if (header.blockAlign != expectedBlockAlign) {
            std::cerr << "  FAIL [iter " << i << "]: blockAlign=" << header.blockAlign
                      << ", expected " << expectedBlockAlign << std::endl;
            std::remove(wavPath.c_str());
            return false;
        }

        uint32_t expectedByteRate = header.sampleRate * header.blockAlign;
        if (header.byteRate != expectedByteRate) {
            std::cerr << "  FAIL [iter " << i << "]: byteRate=" << header.byteRate
                      << ", expected " << expectedByteRate << std::endl;
            std::remove(wavPath.c_str());
            return false;
        }

        // Clean up temp file
        std::remove(wavPath.c_str());
        ++passed;

        if ((i + 1) % 10 == 0) {
            std::cout << "  Progress: " << (i + 1) << "/" << numIterations << " passed" << std::endl;
        }
    }

    std::cout << "  PASSED: All " << passed << " iterations verified WAV format integrity."
              << std::endl;
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Google Test integration (if available)
// ─────────────────────────────────────────────────────────────────────────────

#ifdef HAS_GTEST
#include <gtest/gtest.h>

TEST(DiagnosticRecorderPBT, Property1_WavFormatIntegrity) {
    // **Validates: Requirements 1.1, 1.2, 3.1**
    ASSERT_TRUE(runProperty1_WavFormatIntegrity(100));
}

// Placeholder for P2 (Task 1.4)
// TEST(DiagnosticRecorderPBT, Property2_ExactSampleCountInvariant) { ... }

// Placeholder for P3 (Task 1.5)
// TEST(DiagnosticRecorderPBT, Property3_ChannelAssignmentRoundTrip) { ... }

// Placeholder for P4 (Task 1.6)
// TEST(DiagnosticRecorderPBT, Property4_WavHeaderConsistency) { ... }

// Placeholder for P8 (Task 1.7)
// TEST(DiagnosticRecorderPBT, Property8_EarlyStopDiscards) { ... }

#endif // HAS_GTEST

// ─────────────────────────────────────────────────────────────────────────────
// Standalone main (when running without Google Test)
// ─────────────────────────────────────────────────────────────────────────────

#ifndef HAS_GTEST

int main() {
    std::cout << "╔══════════════════════════════════════════════════════════╗" << std::endl;
    std::cout << "║  DiagnosticRecorder Property-Based Tests                ║" << std::endl;
    std::cout << "║  Feature: dsp-diagnostic-recorder                       ║" << std::endl;
    std::cout << "╚══════════════════════════════════════════════════════════╝" << std::endl;
    std::cout << std::endl;

    int totalTests = 0;
    int passedTests = 0;

    // Property 1: WAV Format Integrity
    ++totalTests;
    if (runProperty1_WavFormatIntegrity(100)) {
        ++passedTests;
    } else {
        std::cerr << "  >>> PROPERTY 1 FAILED <<<" << std::endl;
    }

    // Summary
    std::cout << std::endl;
    std::cout << "════════════════════════════════════════════════════════════" << std::endl;
    std::cout << "Results: " << passedTests << "/" << totalTests << " properties passed." << std::endl;
    std::cout << "════════════════════════════════════════════════════════════" << std::endl;

    return (passedTests == totalTests) ? 0 : 1;
}

#endif // !HAS_GTEST

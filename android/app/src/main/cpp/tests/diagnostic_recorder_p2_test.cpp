/// @file diagnostic_recorder_p2_test.cpp
/// @brief Property 2: Exact Sample Count Invariant
///
/// For any sequence of random block sizes (64–512 frames), when the total frames
/// reach or exceed 720,000, the recorder SHALL capture exactly 720,000 samples
/// per channel (no more, no less), transition to COMPLETED state, and produce a
/// WAV data section of exactly 2,880,000 bytes.
///
/// **Validates: Requirements 1.3, 1.4, 2.2, 8.1**
///
/// Uses C++ <random> for property-based iteration with 100 different seeds.
/// Supports both Google Test (when GTEST available) and standalone execution.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <random>
#include <string>
#include <vector>
#include <cassert>
#include <iostream>
#include <thread>
#include <chrono>

#ifdef _WIN32
#include <windows.h>
#endif

#include "../diagnostic_recorder.h"

// ─────────────────────────────────────────────────────────────────────────────
// Platform-agnostic temp file utility
// ─────────────────────────────────────────────────────────────────────────────

static std::string makeTempWavPath(int iteration) {
    std::string path;
#ifdef _WIN32
    char tmpDir[256];
    DWORD len = GetTempPathA(sizeof(tmpDir), tmpDir);
    if (len > 0) {
        path = std::string(tmpDir) + "diag_p2_test_" + std::to_string(iteration) + ".wav";
    } else {
        path = "diag_p2_test_" + std::to_string(iteration) + ".wav";
    }
#else
    const char* tmpDir = std::getenv("TMPDIR");
    if (!tmpDir) tmpDir = "/tmp";
    path = std::string(tmpDir) + "/diag_p2_test_" + std::to_string(iteration) + ".wav";
#endif
    return path;
}

// ─────────────────────────────────────────────────────────────────────────────
// WAV data section size reader utility
// ─────────────────────────────────────────────────────────────────────────────

/// Reads the WAV data sub-chunk size from the file header (bytes at offset 40-43).
/// Returns -1 on error.
static int64_t readWavDataSectionSize(const std::string& filePath) {
    FILE* f = std::fopen(filePath.c_str(), "rb");
    if (!f) return -1;

    // Seek to data sub-chunk size field (offset 40)
    if (std::fseek(f, 40, SEEK_SET) != 0) {
        std::fclose(f);
        return -1;
    }

    int32_t dataSize = 0;
    if (std::fread(&dataSize, 4, 1, f) != 1) {
        std::fclose(f);
        return -1;
    }

    std::fclose(f);
    return static_cast<int64_t>(dataSize);
}

/// Gets the total file size in bytes. Returns -1 on error.
static int64_t getFileSize(const std::string& filePath) {
    FILE* f = std::fopen(filePath.c_str(), "rb");
    if (!f) return -1;

    std::fseek(f, 0, SEEK_END);
    long size = std::ftell(f);
    std::fclose(f);
    return static_cast<int64_t>(size);
}

// ─────────────────────────────────────────────────────────────────────────────
// Property 2 Test: Exact Sample Count Invariant
// ─────────────────────────────────────────────────────────────────────────────

/// Single iteration of Property 2 test.
/// @param seed Random seed for this iteration
/// @return true if property holds, false on violation
static bool runProperty2Iteration(unsigned int seed) {
    std::mt19937 rng(seed);

    // Random block size distribution: 64–512 frames
    std::uniform_int_distribution<int> blockSizeDist(64, 512);

    // Random float sample distribution: [-1.0, 1.0]
    std::uniform_real_distribution<float> sampleDist(-1.0f, 1.0f);

    // Target: 720,000 samples per channel (15s @ 48kHz)
    static constexpr int64_t TARGET_SAMPLES = 720000;
    // Expected data section: 720,000 samples × 2 channels × 2 bytes = 2,880,000
    static constexpr int64_t EXPECTED_DATA_SIZE = 2880000;

    // Create recorder and start
    DiagnosticRecorder recorder;
    std::string wavPath = makeTempWavPath(seed);

    bool started = recorder.start(wavPath);
    if (!started) {
        std::cerr << "[P2] Iteration " << seed << ": Failed to start recorder" << std::endl;
        return false;
    }

    // Feed random-sized blocks of random float data until recorder stops
    int64_t totalFramesFed = 0;
    int maxBlocks = 200000; // Safety limit to prevent infinite loops
    int blockCount = 0;

    while (recorder.getState() == DiagRecorderState::RECORDING && blockCount < maxBlocks) {
        int blockSize = blockSizeDist(rng);

        // Generate random pre-DSP and post-DSP buffers
        std::vector<float> preBuf(blockSize);
        std::vector<float> postBuf(blockSize);

        for (int i = 0; i < blockSize; ++i) {
            preBuf[i] = sampleDist(rng);
            postBuf[i] = sampleDist(rng);
        }

        // Feed to recorder
        recorder.feedPreDsp(preBuf.data(), blockSize);
        recorder.feedPostDsp(postBuf.data(), blockSize);

        totalFramesFed += blockSize;
        ++blockCount;

        // Yield periodically to let writer thread drain the ring buffer,
        // simulating realistic audio callback pacing and preventing overflow.
        if (blockCount % 64 == 0) {
            std::this_thread::sleep_for(std::chrono::microseconds(100));
        }
    }

    // Wait for writer thread to finish (give it time to drain and finalize)
    // The writer thread should auto-complete when targetSamples is reached
    int waitMs = 0;
    static constexpr int MAX_WAIT_MS = 10000; // 10 second max wait
    while (recorder.getState() != DiagRecorderState::COMPLETED &&
           recorder.getState() != DiagRecorderState::ERROR &&
           waitMs < MAX_WAIT_MS) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        waitMs += 10;
    }

    // ─── Verification ────────────────────────────────────────────────────

    // Check 1: State must be COMPLETED
    DiagRecorderState finalState = recorder.getState();
    if (finalState != DiagRecorderState::COMPLETED) {
        std::cerr << "[P2] Iteration " << seed << ": Expected COMPLETED, got state="
                  << static_cast<int>(finalState) << " (fed " << totalFramesFed
                  << " frames in " << blockCount << " blocks)" << std::endl;
        std::remove(wavPath.c_str());
        return false;
    }

    // Check 2: Exactly 720,000 samples per channel written
    int64_t samplesWritten = recorder.getSamplesWritten();
    if (samplesWritten != TARGET_SAMPLES) {
        std::cerr << "[P2] Iteration " << seed << ": Expected " << TARGET_SAMPLES
                  << " samples, got " << samplesWritten << std::endl;
        std::remove(wavPath.c_str());
        return false;
    }

    // Check 3: WAV data section size == 2,880,000 bytes
    int64_t dataSectionSize = readWavDataSectionSize(wavPath);
    if (dataSectionSize != EXPECTED_DATA_SIZE) {
        std::cerr << "[P2] Iteration " << seed << ": Expected data section "
                  << EXPECTED_DATA_SIZE << " bytes, got " << dataSectionSize << std::endl;
        std::remove(wavPath.c_str());
        return false;
    }

    // Check 4: Verify total file size = header (44) + data (2,880,000)
    int64_t fileSize = getFileSize(wavPath);
    int64_t expectedFileSize = 44 + EXPECTED_DATA_SIZE;
    if (fileSize != expectedFileSize) {
        std::cerr << "[P2] Iteration " << seed << ": Expected file size "
                  << expectedFileSize << " bytes, got " << fileSize << std::endl;
        std::remove(wavPath.c_str());
        return false;
    }

    // Cleanup temp file
    std::remove(wavPath.c_str());
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Harness: Google Test or Standalone
// ─────────────────────────────────────────────────────────────────────────────

#ifdef HAS_GTEST
#include <gtest/gtest.h>

/// Property 2: Exact Sample Count Invariant (100 iterations)
/// For any sequence of random block sizes, the recorder captures exactly
/// 720,000 samples per channel and produces 2,880,000 bytes of data.
TEST(DiagnosticRecorderPBT, Property2_ExactSampleCount) {
    static constexpr int NUM_ITERATIONS = 100;

    for (int iter = 0; iter < NUM_ITERATIONS; ++iter) {
        SCOPED_TRACE("Iteration " + std::to_string(iter));
        bool passed = runProperty2Iteration(static_cast<unsigned int>(iter));
        ASSERT_TRUE(passed) << "Property 2 violated at iteration " << iter;
    }
}

#else
// ─── Standalone execution ────────────────────────────────────────────────────

int main(int argc, char* argv[]) {
    static constexpr int NUM_ITERATIONS = 100;
    int failures = 0;

    std::cout << "=== Property 2: Exact Sample Count Invariant ===" << std::endl;
    std::cout << "Running " << NUM_ITERATIONS << " iterations..." << std::endl;
    std::cout << "Target: 720,000 samples/channel, 2,880,000 bytes data section" << std::endl;
    std::cout << "Block sizes: random 64-512 frames per block" << std::endl;
    std::cout << std::endl;

    for (int iter = 0; iter < NUM_ITERATIONS; ++iter) {
        bool passed = runProperty2Iteration(static_cast<unsigned int>(iter));
        if (!passed) {
            ++failures;
            std::cerr << "  FAIL: Iteration " << iter << std::endl;
        } else {
            if (iter % 10 == 0) {
                std::cout << "  Passed iteration " << iter << "/100" << std::endl;
            }
        }
    }

    std::cout << std::endl;
    if (failures == 0) {
        std::cout << "=== ALL " << NUM_ITERATIONS << " ITERATIONS PASSED ===" << std::endl;
        return 0;
    } else {
        std::cerr << "=== FAILED: " << failures << "/" << NUM_ITERATIONS
                  << " iterations violated the property ===" << std::endl;
        return 1;
    }
}

#endif // HAS_GTEST

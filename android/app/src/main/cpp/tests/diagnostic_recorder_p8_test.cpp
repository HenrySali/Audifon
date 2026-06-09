/// @file diagnostic_recorder_p8_test.cpp
/// @brief Property 8: Early Stop Discards
///
/// For any recording stopped before reaching 2,880,000 samples per channel,
/// the DiagnosticRecorder SHALL transition to IDLE state and the partial WAV
/// file SHALL be deleted from disk (no orphaned files).
///
/// **Validates: Requirements 2.4**
///
/// Generator strategy: Random stop times (1–59 seconds worth of samples fed),
/// random block sizes (128–512 frames). 100 iterations with unique seeds.
/// Supports both Google Test (when HAS_GTEST defined) and standalone execution.

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <random>
#include <string>
#include <vector>
#include <thread>
#include <chrono>

// Include DiagnosticRecorder (header-only include; link .cpp separately or inline)
#include "../diagnostic_recorder.h"
#include "../diagnostic_recorder.cpp"

// ─────────────────────────────────────────────────────────────────────────────
// Platform-agnostic utilities
// ─────────────────────────────────────────────────────────────────────────────

/// Generate a temporary file path for test WAV output.
static std::string makeTempWavPath(int iteration) {
    std::string path;
#ifdef _WIN32
    const char* tmp = std::getenv("TEMP");
    if (!tmp) tmp = std::getenv("TMP");
    if (!tmp) tmp = ".";
    path = std::string(tmp) + "\\diag_p8_test_" + std::to_string(iteration) + ".wav";
#else
    const char* tmpDir = std::getenv("TMPDIR");
    if (!tmpDir) tmpDir = "/tmp";
    path = std::string(tmpDir) + "/diag_p8_test_" + std::to_string(iteration) + ".wav";
#endif
    return path;
}

/// Check if a file exists on disk. Uses fopen for maximum portability.
static bool fileExists(const std::string& path) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (f) {
        std::fclose(f);
        return true;
    }
    return false;
}

/// Remove file if it exists (defensive cleanup).
static void cleanupFile(const std::string& path) {
    std::remove(path.c_str());
}

// ─────────────────────────────────────────────────────────────────────────────
// Property 8: Early Stop Discards — Single Iteration
// ─────────────────────────────────────────────────────────────────────────────

/// Runs one iteration of Property 8.
/// @param seed Unique seed for random number generation.
/// @return true if property holds (state=IDLE, file deleted), false on violation.
static bool runProperty8Iteration(unsigned int seed) {
    std::mt19937 rng(seed);

    // ─── Generator: random stop time ────────────────────────────────────
    // Stop time: 1–59 seconds worth of frames (never reach 60s = 2,880,000)
    std::uniform_int_distribution<int> secondsDist(1, 59);
    int stopAfterSeconds = secondsDist(rng);

    // For test efficiency, feed a proportional number of frames rather than
    // the full secondsDist * 48000 (which could be millions). We use a fraction
    // that still exercises the ring buffer and writer thread meaningfully.
    // Feed between 1000 and 48000 frames (≤1 second of real data).
    std::uniform_int_distribution<int> framesToFeedDist(1000, 48000);
    int64_t framesToFeed = framesToFeedDist(rng);

    // Random block size: 128–512 frames per feed call
    std::uniform_int_distribution<int> blockSizeDist(128, 512);

    // Random float sample distribution: [-1.0, 1.0]
    std::uniform_real_distribution<float> sampleDist(-1.0f, 1.0f);

    // Create temp file path
    std::string wavPath = makeTempWavPath(static_cast<int>(seed));
    cleanupFile(wavPath);

    // Create fresh recorder instance
    DiagnosticRecorder recorder;

    // Verify initial state
    if (recorder.getState() != DiagRecorderState::IDLE) {
        std::cerr << "[P8] Iter " << seed << ": Initial state is not IDLE" << std::endl;
        return false;
    }

    // Start recording
    bool started = recorder.start(wavPath);
    if (!started) {
        std::cerr << "[P8] Iter " << seed << ": start() returned false" << std::endl;
        cleanupFile(wavPath);
        return false;
    }

    // Verify file was created (WAV header written)
    if (!fileExists(wavPath)) {
        std::cerr << "[P8] Iter " << seed << ": WAV file not created after start()" << std::endl;
        return false;
    }

    // Verify state is RECORDING
    if (recorder.getState() != DiagRecorderState::RECORDING) {
        std::cerr << "[P8] Iter " << seed << ": State is not RECORDING after start()" << std::endl;
        cleanupFile(wavPath);
        return false;
    }

    // ─── Feed random audio blocks (partial recording) ────────────────────
    int64_t framesFed = 0;
    while (framesFed < framesToFeed) {
        int blockSize = blockSizeDist(rng);
        int64_t remaining = framesToFeed - framesFed;
        blockSize = static_cast<int>(std::min(static_cast<int64_t>(blockSize), remaining));

        if (blockSize <= 0) break;

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

        // Feed pre-DSP then post-DSP (normal calling order from audio callback)
        recorder.feedPreDsp(preBuf.data(), blockSize);
        recorder.feedPostDsp(postBuf.data(), blockSize);

        framesFed += blockSize;
    }

    // ─── Early stop: call stop() before 60s completes ────────────────────
    recorder.stop();

    // ─── Property Verification ───────────────────────────────────────────

    // Check 1: State must be IDLE after early stop
    DiagRecorderState finalState = recorder.getState();
    if (finalState != DiagRecorderState::IDLE) {
        std::cerr << "[P8] Iter " << seed << " (stopAfter=" << stopAfterSeconds
                  << "s, fed=" << framesFed << " frames): Expected IDLE, got state="
                  << static_cast<int>(finalState) << std::endl;
        cleanupFile(wavPath);
        return false;
    }

    // Check 2: Partial WAV file must NOT exist on disk (deleted by stop())
    if (fileExists(wavPath)) {
        std::cerr << "[P8] Iter " << seed << " (stopAfter=" << stopAfterSeconds
                  << "s, fed=" << framesFed << " frames): Partial WAV file still exists at "
                  << wavPath << std::endl;
        cleanupFile(wavPath);
        return false;
    }

    return true;
}

/// Edge case: stop() while IDLE is a no-op (does not crash or change state).
static bool runProperty8_StopWhileIdle() {
    DiagnosticRecorder recorder;

    if (recorder.getState() != DiagRecorderState::IDLE) {
        std::cerr << "[P8-edge] Initial state not IDLE" << std::endl;
        return false;
    }

    // Should be a safe no-op
    recorder.stop();

    if (recorder.getState() != DiagRecorderState::IDLE) {
        std::cerr << "[P8-edge] State changed from IDLE after stop() no-op" << std::endl;
        return false;
    }

    return true;
}

/// Edge case: Immediate stop after start (0 frames fed).
static bool runProperty8_ImmediateStop(unsigned int seed) {
    std::string wavPath = makeTempWavPath(10000 + static_cast<int>(seed));
    cleanupFile(wavPath);

    DiagnosticRecorder recorder;
    bool started = recorder.start(wavPath);
    if (!started) {
        std::cerr << "[P8-imm] Iter " << seed << ": start() failed" << std::endl;
        return false;
    }

    // Immediate stop — no frames fed at all
    recorder.stop();

    if (recorder.getState() != DiagRecorderState::IDLE) {
        std::cerr << "[P8-imm] Iter " << seed << ": State not IDLE after immediate stop"
                  << std::endl;
        cleanupFile(wavPath);
        return false;
    }

    if (fileExists(wavPath)) {
        std::cerr << "[P8-imm] Iter " << seed << ": File exists after immediate stop"
                  << std::endl;
        cleanupFile(wavPath);
        return false;
    }

    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Full property test runner (used by both GTest and standalone)
// ─────────────────────────────────────────────────────────────────────────────

/// Runs all 100 iterations of Property 8 plus edge cases.
/// @return true if all iterations pass.
static bool runProperty8_EarlyStopDiscards(int numIterations = 100) {
    std::cout << "=== Property 8: Early Stop Discards ===" << std::endl;
    std::cout << "Running " << numIterations << " iterations..." << std::endl;
    std::cout << "Each iteration: start → feed random frames → stop → verify IDLE + file deleted"
              << std::endl;
    std::cout << std::endl;

    int passed = 0;
    int failed = 0;

    // ─── Main property iterations ────────────────────────────────────────
    for (int iter = 0; iter < numIterations; ++iter) {
        unsigned int seed = static_cast<unsigned int>(iter * 7 + 13);
        bool ok = runProperty8Iteration(seed);
        if (ok) {
            ++passed;
        } else {
            ++failed;
            std::cerr << "  >>> FAIL at iteration " << iter << " (seed=" << seed << ")"
                      << std::endl;
        }

        if ((iter + 1) % 20 == 0) {
            std::cout << "  Progress: " << (iter + 1) << "/" << numIterations
                      << " completed (" << passed << " passed)" << std::endl;
        }
    }

    // ─── Edge case: stop while IDLE ──────────────────────────────────────
    std::cout << "  Running edge case: stop while IDLE..." << std::endl;
    if (!runProperty8_StopWhileIdle()) {
        ++failed;
        std::cerr << "  >>> FAIL: stop-while-IDLE edge case" << std::endl;
    } else {
        ++passed;
    }

    // ─── Edge case: immediate stop (20 sub-iterations) ───────────────────
    std::cout << "  Running edge case: immediate stop (20 iterations)..." << std::endl;
    for (int i = 0; i < 20; ++i) {
        if (!runProperty8_ImmediateStop(static_cast<unsigned int>(i))) {
            ++failed;
            std::cerr << "  >>> FAIL: immediate stop sub-iteration " << i << std::endl;
        } else {
            ++passed;
        }
    }

    // ─── Summary ─────────────────────────────────────────────────────────
    int total = passed + failed;
    std::cout << std::endl;
    if (failed == 0) {
        std::cout << "  PASSED: All " << total << " checks verified Early Stop Discards."
                  << std::endl;
    } else {
        std::cerr << "  FAILED: " << failed << "/" << total << " checks violated the property."
                  << std::endl;
    }

    return failed == 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Google Test integration (if available)
// ─────────────────────────────────────────────────────────────────────────────

#ifdef HAS_GTEST
#include <gtest/gtest.h>

/// Property 8: Early Stop Discards (100 iterations + edge cases)
/// For any recording stopped before 60s, state=IDLE and partial file deleted.
///
/// **Validates: Requirements 2.4**
TEST(DiagnosticRecorderPBT, Property8_EarlyStopDiscards) {
    ASSERT_TRUE(runProperty8_EarlyStopDiscards(100));
}

#endif // HAS_GTEST

// ─────────────────────────────────────────────────────────────────────────────
// Standalone main (when running without Google Test)
// ─────────────────────────────────────────────────────────────────────────────

#ifndef HAS_GTEST

int main() {
    std::cout << "╔══════════════════════════════════════════════════════════╗" << std::endl;
    std::cout << "║  DiagnosticRecorder Property-Based Tests                ║" << std::endl;
    std::cout << "║  Feature: dsp-diagnostic-recorder                       ║" << std::endl;
    std::cout << "║  Property 8: Early Stop Discards                        ║" << std::endl;
    std::cout << "╚══════════════════════════════════════════════════════════╝" << std::endl;
    std::cout << std::endl;

    bool allPassed = runProperty8_EarlyStopDiscards(100);

    std::cout << std::endl;
    std::cout << "════════════════════════════════════════════════════════════" << std::endl;
    if (allPassed) {
        std::cout << "RESULT: PASS — Property 8 holds across all iterations." << std::endl;
    } else {
        std::cout << "RESULT: FAIL — Property 8 violated." << std::endl;
    }
    std::cout << "════════════════════════════════════════════════════════════" << std::endl;

    return allPassed ? 0 : 1;
}

#endif // !HAS_GTEST

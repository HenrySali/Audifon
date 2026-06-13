/// @file diagnostic_recorder_p4_test.cpp
/// @brief Property-Based Test: WAV Header Consistency (P4)
///
/// **Validates: Requirements 3.6, 8.2**
///
/// Property 4: For any completed recording, the WAV file's RIFF ChunkSize field
/// SHALL equal (file size - 8), and the data Subchunk2Size field SHALL equal
/// (samplesWritten × channels × bytesPerSample), both matching the actual bytes
/// written to disk.
///
/// Strategy: Complete recordings feeding random audio content (varying float32
/// values in [-1.0, 1.0]) with random block sizes. After each recording completes,
/// open the WAV file, read the header, and verify size consistency invariants.

#include <gtest/gtest.h>

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <random>
#include <string>
#include <vector>
#include <thread>
#include <chrono>
#include <filesystem>

#include "../diagnostic_recorder.h"

namespace {

/// Generates a temporary file path for test WAV output.
std::string getTempWavPath(int iteration) {
    std::string tempDir = std::filesystem::temp_directory_path().string();
    return tempDir + "/diag_p4_test_iter_" + std::to_string(iteration) + ".wav";
}

/// Reads a uint32 value from a file at the given byte offset (little-endian).
uint32_t readUint32At(const std::string& filePath, long offset) {
    FILE* f = std::fopen(filePath.c_str(), "rb");
    if (!f) return 0;
    std::fseek(f, offset, SEEK_SET);
    uint32_t value = 0;
    std::fread(&value, sizeof(uint32_t), 1, f);
    std::fclose(f);
    return value;
}

/// Gets the actual file size in bytes.
std::uintmax_t getFileSize(const std::string& filePath) {
    return std::filesystem::file_size(filePath);
}

/// Feeds random audio blocks to the recorder until the recording completes.
/// Uses random block sizes between minBlock and maxBlock frames, with random
/// float32 values in [-1.0, 1.0].
void feedUntilComplete(DiagnosticRecorder& recorder, std::mt19937& rng,
                       int minBlock, int maxBlock) {
    std::uniform_int_distribution<int> blockDist(minBlock, maxBlock);
    std::uniform_real_distribution<float> sampleDist(-1.0f, 1.0f);

    // Pre-allocate max-size buffers
    std::vector<float> preBuf(maxBlock);
    std::vector<float> postBuf(maxBlock);

    while (recorder.getState() == DiagRecorderState::RECORDING) {
        int blockSize = blockDist(rng);

        // Generate random pre-DSP samples
        for (int i = 0; i < blockSize; ++i) {
            preBuf[i] = sampleDist(rng);
        }

        // Generate random post-DSP samples (independent random content)
        for (int i = 0; i < blockSize; ++i) {
            postBuf[i] = sampleDist(rng);
        }

        recorder.feedPreDsp(preBuf.data(), blockSize);
        recorder.feedPostDsp(postBuf.data(), blockSize);

        // Brief yield to let writer thread drain the ring buffer
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    }

    // Wait for finalization to complete
    int maxWaitMs = 5000;
    int waited = 0;
    while (recorder.getState() == DiagRecorderState::FINALIZING && waited < maxWaitMs) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        waited += 10;
    }
}

} // anonymous namespace

/// Property 4: WAV Header Consistency
///
/// For any completed recording with random audio content:
/// 1. RIFF ChunkSize (offset 4) == (actual file size - 8)
/// 2. data Subchunk2Size (offset 40) == (720,000 × 2 channels × 2 bytes) == 2,880,000
/// 3. actual file size == 2,880,044 (2,880,000 data + 44 header bytes)
///
/// **Validates: Requirements 3.6, 8.2**
TEST(DiagnosticRecorderPBT, Property4_WavHeaderConsistency) {
    // Seed with fixed value for reproducibility; each iteration still gets
    // unique random content due to sequential draws from the same generator.
    std::mt19937 rng(42);

    // Distribution for random block sizes (256–1024 frames per callback)
    std::uniform_int_distribution<int> blockSizeDist(256, 1024);

    constexpr int NUM_ITERATIONS = 100;
    constexpr int64_t TARGET_SAMPLES = 720000;      // 15s × 48kHz
    constexpr int CHANNELS = 2;
    constexpr int BYTES_PER_SAMPLE = 2;             // 16-bit
    constexpr uint32_t EXPECTED_DATA_SIZE = TARGET_SAMPLES * CHANNELS * BYTES_PER_SAMPLE; // 2,880,000
    constexpr uint32_t EXPECTED_FILE_SIZE = EXPECTED_DATA_SIZE + 44;  // 2,880,044
    constexpr uint32_t EXPECTED_RIFF_SIZE = EXPECTED_FILE_SIZE - 8;   // 2,880,036

    for (int iter = 0; iter < NUM_ITERATIONS; ++iter) {
        // Generate random block size bounds for this iteration
        int minBlock = blockSizeDist(rng);
        int maxBlock = std::max(minBlock, static_cast<int>(blockSizeDist(rng)));
        // Ensure min <= max
        if (minBlock > maxBlock) std::swap(minBlock, maxBlock);

        std::string wavPath = getTempWavPath(iter);

        // Create a fresh recorder instance
        DiagnosticRecorder recorder;

        // Start recording
        ASSERT_TRUE(recorder.start(wavPath))
            << "Iteration " << iter << ": Failed to start recording at " << wavPath;

        ASSERT_EQ(recorder.getState(), DiagRecorderState::RECORDING)
            << "Iteration " << iter << ": State should be RECORDING after start()";

        // Feed random audio until recording completes
        feedUntilComplete(recorder, rng, minBlock, maxBlock);

        // Verify recording completed successfully
        ASSERT_EQ(recorder.getState(), DiagRecorderState::COMPLETED)
            << "Iteration " << iter << ": State should be COMPLETED after full recording"
            << " (actual state: " << static_cast<int>(recorder.getState()) << ")";

        // ─── Verify WAV header consistency ─────────────────────────────────

        // 1. Verify actual file size matches expected
        std::uintmax_t actualFileSize = getFileSize(wavPath);
        EXPECT_EQ(actualFileSize, EXPECTED_FILE_SIZE)
            << "Iteration " << iter << ": File size should be 2,880,044 bytes"
            << " (got " << actualFileSize << ")";

        // 2. Verify RIFF ChunkSize (offset 4) == (fileSize - 8)
        uint32_t riffChunkSize = readUint32At(wavPath, 4);
        EXPECT_EQ(riffChunkSize, static_cast<uint32_t>(actualFileSize - 8))
            << "Iteration " << iter << ": RIFF ChunkSize at offset 4 should equal (fileSize - 8)"
            << " (expected " << (actualFileSize - 8) << ", got " << riffChunkSize << ")";

        // Also verify against the computed expected value
        EXPECT_EQ(riffChunkSize, EXPECTED_RIFF_SIZE)
            << "Iteration " << iter << ": RIFF ChunkSize should be 2,880,036"
            << " (got " << riffChunkSize << ")";

        // 3. Verify data Subchunk2Size (offset 40) == (samplesWritten × channels × bytesPerSample)
        uint32_t dataSubchunk2Size = readUint32At(wavPath, 40);
        EXPECT_EQ(dataSubchunk2Size, EXPECTED_DATA_SIZE)
            << "Iteration " << iter << ": data Subchunk2Size at offset 40 should be 2,880,000"
            << " (got " << dataSubchunk2Size << ")";

        // 4. Cross-check: data Subchunk2Size should equal (actualFileSize - 44)
        EXPECT_EQ(dataSubchunk2Size, static_cast<uint32_t>(actualFileSize - 44))
            << "Iteration " << iter << ": data Subchunk2Size should equal (fileSize - 44 header)"
            << " (expected " << (actualFileSize - 44) << ", got " << dataSubchunk2Size << ")";

        // 5. Verify samplesWritten matches target
        EXPECT_EQ(recorder.getSamplesWritten(), TARGET_SAMPLES)
            << "Iteration " << iter << ": samplesWritten should be exactly 720,000"
            << " (got " << recorder.getSamplesWritten() << ")";

        // Clean up test file
        std::filesystem::remove(wavPath);
    }
}

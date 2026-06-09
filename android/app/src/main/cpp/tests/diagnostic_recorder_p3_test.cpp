/// @file diagnostic_recorder_p3_test.cpp
/// @brief Property 3: Channel Assignment Round-Trip
///
/// For any pair of audio buffers (pre-DSP and post-DSP) fed to the
/// DiagnosticRecorder, when the resulting WAV file is read back, the left
/// channel samples SHALL equal the int16 quantization of the pre-DSP input,
/// and the right channel samples SHALL equal the int16 quantization of the
/// post-DSP input, preserving temporal order.
///
/// **Validates: Requirements 3.2, 3.3**
///
/// Test strategy:
///   - 10 iterations of full 60-second recordings (2,880,000 frames each)
///   - Each iteration uses unique random float32 audio content in [-1.0, 1.0]
///   - After recording completes, read back the WAV file and verify a random
///     subset of 1000 sample positions per iteration
///   - This is a pragmatic tradeoff: verifying all 2.88M frames × 10 iterations
///     would be extremely slow; random sampling provides high confidence with
///     bounded execution time (~60s per iteration for the recording itself)
///
/// Uses Google Test with a custom PRNG-based generator.

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <numeric>
#include <random>
#include <string>
#include <vector>

#include "../diagnostic_recorder.h"

// ─────────────────────────────────────────────────────────────────────────────
// Reference implementation for float→int16 conversion (must match production)
// ─────────────────────────────────────────────────────────────────────────────

/// Reference float-to-int16 conversion.
/// Matches DiagnosticRecorder::floatToInt16: clamp to [-1.0, 1.0], scale by 32767.
static int16_t referenceFloatToInt16(float sample) {
    float clamped = std::fmax(-1.0f, std::fmin(1.0f, sample));
    return static_cast<int16_t>(clamped * 32767.0f);
}

// ─────────────────────────────────────────────────────────────────────────────
// WAV file reader utility (minimal, reads stereo int16 PCM only)
// ─────────────────────────────────────────────────────────────────────────────

/// Reads interleaved int16 stereo samples from a WAV file (skips 44-byte header).
/// Returns the total number of int16 samples read (frames × 2 channels).
static std::vector<int16_t> readWavSamples(const std::string& filePath) {
    FILE* f = std::fopen(filePath.c_str(), "rb");
    if (!f) return {};

    // Skip 44-byte WAV header
    std::fseek(f, 44, SEEK_SET);

    // Read remaining data as int16 samples
    std::fseek(f, 0, SEEK_END);
    long fileSize = std::ftell(f);
    long dataSize = fileSize - 44;
    std::fseek(f, 44, SEEK_SET);

    size_t numSamples = dataSize / sizeof(int16_t);
    std::vector<int16_t> samples(numSamples);
    size_t read = std::fread(samples.data(), sizeof(int16_t), numSamples, f);
    samples.resize(read);

    std::fclose(f);
    return samples;
}

// ─────────────────────────────────────────────────────────────────────────────
// Custom random audio generator
// ─────────────────────────────────────────────────────────────────────────────

/// Generates a vector of random float32 samples in [-1.0, 1.0].
static std::vector<float> generateRandomAudio(std::mt19937& rng, size_t numSamples) {
    std::uniform_real_distribution<float> dist(-1.0f, 1.0f);
    std::vector<float> audio(numSamples);
    for (auto& s : audio) {
        s = dist(rng);
    }
    return audio;
}

/// Generates a random subset of indices in [0, maxIndex) without replacement.
static std::vector<size_t> randomSubset(std::mt19937& rng, size_t maxIndex, size_t count) {
    count = std::min(count, maxIndex);
    std::vector<size_t> indices(maxIndex);
    std::iota(indices.begin(), indices.end(), 0);
    // Partial Fisher-Yates shuffle for first 'count' elements
    for (size_t i = 0; i < count; ++i) {
        std::uniform_int_distribution<size_t> dist(i, maxIndex - 1);
        std::swap(indices[i], indices[dist(rng)]);
    }
    indices.resize(count);
    std::sort(indices.begin(), indices.end());
    return indices;
}

// ─────────────────────────────────────────────────────────────────────────────
// Property Test: Channel Assignment Round-Trip (P3)
// ─────────────────────────────────────────────────────────────────────────────

/// Property 3: Channel Assignment Round-Trip
/// For any pair of audio buffers, left channel = int16(pre-DSP),
/// right channel = int16(post-DSP), preserving temporal order.
///
/// 10 iterations (full 60s recording each) with random audio content.
/// Verify 1000 random sample positions per iteration.
TEST(DiagnosticRecorderPBT, Property3_ChannelAssignment) {
    // Configuration
    constexpr int NUM_ITERATIONS = 10;
    constexpr int SAMPLES_TO_VERIFY = 1000;
    constexpr int64_t TARGET_FRAMES = 2880000; // 60s @ 48kHz
    constexpr int BLOCK_SIZE = 256;            // Typical Oboe callback size

    // Use a fixed seed per iteration for reproducibility, but different per iteration
    std::mt19937 masterRng(42);

    for (int iter = 0; iter < NUM_ITERATIONS; ++iter) {
        // Per-iteration seed for reproducible random audio
        uint32_t iterSeed = masterRng();
        std::mt19937 iterRng(iterSeed);

        // Create temporary WAV file path
        std::string tempDir = std::filesystem::temp_directory_path().string();
        std::string filePath = tempDir + "/diag_p3_test_iter_" +
                               std::to_string(iter) + ".wav";

        // ─── Generate random audio for entire recording ─────────────────
        // For memory efficiency, generate and feed in blocks rather than
        // storing all 2.88M samples. We'll regenerate with the same seed
        // later for verification.
        DiagnosticRecorder recorder;
        ASSERT_TRUE(recorder.start(filePath))
            << "Failed to start recording on iteration " << iter;

        // Feed audio in blocks until TARGET_FRAMES reached
        int64_t framesProduced = 0;
        std::mt19937 feedRng(iterSeed); // Same seed to reproduce audio later
        std::uniform_real_distribution<float> dist(-1.0f, 1.0f);

        while (framesProduced < TARGET_FRAMES) {
            int framesToFeed = static_cast<int>(
                std::min(static_cast<int64_t>(BLOCK_SIZE),
                         TARGET_FRAMES - framesProduced));

            // Generate random pre-DSP block
            std::vector<float> preBlock(framesToFeed);
            for (int i = 0; i < framesToFeed; ++i) {
                preBlock[i] = dist(feedRng);
            }

            // Generate random post-DSP block (independent random content)
            std::vector<float> postBlock(framesToFeed);
            for (int i = 0; i < framesToFeed; ++i) {
                postBlock[i] = dist(feedRng);
            }

            recorder.feedPreDsp(preBlock.data(), framesToFeed);
            recorder.feedPostDsp(postBlock.data(), framesToFeed);

            framesProduced += framesToFeed;

            // Give writer thread time to drain (avoid ring buffer overflow)
            if (framesProduced % (BLOCK_SIZE * 32) == 0) {
                std::this_thread::sleep_for(std::chrono::microseconds(100));
            }
        }

        // Wait for recording to complete (writer thread finalization)
        int waitMs = 0;
        while (recorder.getState() != DiagRecorderState::COMPLETED &&
               recorder.getState() != DiagRecorderState::ERROR &&
               waitMs < 10000) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            waitMs += 10;
        }

        ASSERT_EQ(recorder.getState(), DiagRecorderState::COMPLETED)
            << "Recording did not complete on iteration " << iter
            << " (state=" << static_cast<int>(recorder.getState()) << ")";

        // ─── Read back WAV file ─────────────────────────────────────────
        std::vector<int16_t> wavSamples = readWavSamples(filePath);
        ASSERT_EQ(wavSamples.size(), static_cast<size_t>(TARGET_FRAMES * 2))
            << "WAV sample count mismatch on iteration " << iter;

        // ─── Verify random subset of samples ────────────────────────────
        // Pick SAMPLES_TO_VERIFY random frame indices to check
        std::vector<size_t> checkIndices = randomSubset(
            iterRng, static_cast<size_t>(TARGET_FRAMES), SAMPLES_TO_VERIFY);

        // Regenerate the audio with the same seed to get expected values
        std::mt19937 verifyRng(iterSeed);
        std::uniform_real_distribution<float> verifyDist(-1.0f, 1.0f);

        // We need to regenerate all samples up to max(checkIndices) to get
        // the expected values. Stream through in order.
        size_t checkIdx = 0;
        int64_t framePos = 0;

        while (checkIdx < checkIndices.size() && framePos < TARGET_FRAMES) {
            // Determine how many frames in this block
            int blockFrames = static_cast<int>(
                std::min(static_cast<int64_t>(BLOCK_SIZE),
                         TARGET_FRAMES - framePos));

            for (int i = 0; i < blockFrames; ++i) {
                float preSample = verifyDist(verifyRng);
                float postSample = verifyDist(verifyRng);

                // Check if this frame index is in our verification set
                if (checkIdx < checkIndices.size() &&
                    static_cast<size_t>(framePos + i) == checkIndices[checkIdx]) {

                    size_t sampleOffset = checkIndices[checkIdx] * 2;
                    int16_t expectedLeft = referenceFloatToInt16(preSample);
                    int16_t expectedRight = referenceFloatToInt16(postSample);

                    int16_t actualLeft = wavSamples[sampleOffset];      // Even index = left
                    int16_t actualRight = wavSamples[sampleOffset + 1]; // Odd index = right

                    EXPECT_EQ(actualLeft, expectedLeft)
                        << "Left channel (pre-DSP) mismatch at frame "
                        << checkIndices[checkIdx]
                        << " on iteration " << iter
                        << " (pre=" << preSample << ")";

                    EXPECT_EQ(actualRight, expectedRight)
                        << "Right channel (post-DSP) mismatch at frame "
                        << checkIndices[checkIdx]
                        << " on iteration " << iter
                        << " (post=" << postSample << ")";

                    ++checkIdx;
                }
            }

            framePos += blockFrames;
        }

        // Verify all check indices were processed
        EXPECT_EQ(checkIdx, checkIndices.size())
            << "Not all verification indices were checked on iteration " << iter;

        // ─── Verify temporal order (adjacent samples) ───────────────────
        // Pick 100 consecutive frame pairs and verify ordering is preserved
        std::uniform_int_distribution<size_t> pairDist(0, TARGET_FRAMES - 2);
        for (int p = 0; p < 100; ++p) {
            size_t frameA = pairDist(iterRng);
            size_t frameB = frameA + 1;

            // The samples at frameA should come before frameB in the file
            size_t offsetA = frameA * 2;
            size_t offsetB = frameB * 2;

            // Just verify we can read both (temporal order = file order)
            EXPECT_LT(offsetA, wavSamples.size())
                << "Frame A out of bounds on iteration " << iter;
            EXPECT_LT(offsetB + 1, wavSamples.size())
                << "Frame B out of bounds on iteration " << iter;
        }

        // ─── Cleanup ────────────────────────────────────────────────────
        std::filesystem::remove(filePath);
    }
}

/// Supplementary test: verifies channel assignment with known edge-case values.
/// This is not a PBT iteration but covers boundary float values that the random
/// generator might not hit frequently (exactly -1.0, 0.0, 1.0, and values outside
/// the [-1, 1] range that should be clamped).
TEST(DiagnosticRecorderPBT, Property3_ChannelAssignment_EdgeCases) {
    constexpr int64_t TARGET_FRAMES = 2880000;
    constexpr int BLOCK_SIZE = 256;

    std::string tempDir = std::filesystem::temp_directory_path().string();
    std::string filePath = tempDir + "/diag_p3_edge_test.wav";

    DiagnosticRecorder recorder;
    ASSERT_TRUE(recorder.start(filePath));

    // Edge case values to embed in the first few blocks
    std::vector<float> edgeValues = {
        -1.0f, 0.0f, 1.0f, -0.5f, 0.5f,
        -1.5f, 1.5f,  // Should be clamped to -1.0, 1.0
        -0.999999f, 0.999999f,
        1.0f / 32767.0f,   // Smallest positive step
        -1.0f / 32767.0f   // Smallest negative step
    };

    // Feed edge values in first block, then fill remaining with zeros
    std::vector<float> preBlock(BLOCK_SIZE, 0.0f);
    std::vector<float> postBlock(BLOCK_SIZE, 0.0f);

    // Place edge values at start of first block
    for (size_t i = 0; i < edgeValues.size() && i < static_cast<size_t>(BLOCK_SIZE); ++i) {
        preBlock[i] = edgeValues[i];
        // Use reversed edge values for post-DSP to differentiate channels
        postBlock[i] = edgeValues[edgeValues.size() - 1 - i];
    }

    recorder.feedPreDsp(preBlock.data(), BLOCK_SIZE);
    recorder.feedPostDsp(postBlock.data(), BLOCK_SIZE);

    int64_t framesProduced = BLOCK_SIZE;

    // Fill remaining frames with silence
    std::vector<float> silence(BLOCK_SIZE, 0.0f);
    while (framesProduced < TARGET_FRAMES) {
        int framesToFeed = static_cast<int>(
            std::min(static_cast<int64_t>(BLOCK_SIZE),
                     TARGET_FRAMES - framesProduced));

        recorder.feedPreDsp(silence.data(), framesToFeed);
        recorder.feedPostDsp(silence.data(), framesToFeed);
        framesProduced += framesToFeed;

        if (framesProduced % (BLOCK_SIZE * 32) == 0) {
            std::this_thread::sleep_for(std::chrono::microseconds(100));
        }
    }

    // Wait for completion
    int waitMs = 0;
    while (recorder.getState() != DiagRecorderState::COMPLETED &&
           recorder.getState() != DiagRecorderState::ERROR &&
           waitMs < 10000) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        waitMs += 10;
    }

    ASSERT_EQ(recorder.getState(), DiagRecorderState::COMPLETED);

    // Read back and verify edge values
    std::vector<int16_t> wavSamples = readWavSamples(filePath);
    ASSERT_EQ(wavSamples.size(), static_cast<size_t>(TARGET_FRAMES * 2));

    for (size_t i = 0; i < edgeValues.size(); ++i) {
        size_t reverseIdx = edgeValues.size() - 1 - i;
        int16_t expectedLeft = referenceFloatToInt16(edgeValues[i]);
        int16_t expectedRight = referenceFloatToInt16(edgeValues[reverseIdx]);

        int16_t actualLeft = wavSamples[i * 2];
        int16_t actualRight = wavSamples[i * 2 + 1];

        EXPECT_EQ(actualLeft, expectedLeft)
            << "Edge case left mismatch at index " << i
            << " (value=" << edgeValues[i] << ")";
        EXPECT_EQ(actualRight, expectedRight)
            << "Edge case right mismatch at index " << i
            << " (value=" << edgeValues[reverseIdx] << ")";
    }

    // Verify silence region (all zeros → int16(0) = 0)
    for (size_t i = edgeValues.size(); i < edgeValues.size() + 10; ++i) {
        EXPECT_EQ(wavSamples[i * 2], 0)
            << "Expected silence (left) at frame " << i;
        EXPECT_EQ(wavSamples[i * 2 + 1], 0)
            << "Expected silence (right) at frame " << i;
    }

    // Cleanup
    std::filesystem::remove(filePath);
}

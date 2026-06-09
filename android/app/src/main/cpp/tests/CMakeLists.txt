# CMakeLists.txt — Property-Based Tests para DiagnosticRecorder
# Compila y ejecuta tests con Google Test en el host (no Android).

cmake_minimum_required(VERSION 3.14)
project("diagnostic_recorder_tests" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ─────────────────────────────────────────────────────────────────────────────
# Google Test via FetchContent (descarga automática si no está disponible)
# ─────────────────────────────────────────────────────────────────────────────
include(FetchContent)
FetchContent_Declare(
    googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG        v1.14.0
)
# Para Windows: Prevent overriding the parent project's compiler/linker settings
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

enable_testing()

# ─────────────────────────────────────────────────────────────────────────────
# Source bajo test (DiagnosticRecorder)
# ─────────────────────────────────────────────────────────────────────────────
set(SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/..")

# ─────────────────────────────────────────────────────────────────────────────
# Property Test P4: WAV Header Consistency
# ─────────────────────────────────────────────────────────────────────────────
add_executable(diagnostic_recorder_p4_test
    diagnostic_recorder_p4_test.cpp
    ${SRC_DIR}/diagnostic_recorder.cpp
)

target_include_directories(diagnostic_recorder_p4_test PRIVATE
    ${SRC_DIR}
)

target_link_libraries(diagnostic_recorder_p4_test
    GTest::gtest
    GTest::gtest_main
)

include(GoogleTest)
gtest_discover_tests(diagnostic_recorder_p4_test)

# ─────────────────────────────────────────────────────────────────────────────
# Property Test P3: Channel Assignment Round-Trip
# ─────────────────────────────────────────────────────────────────────────────
add_executable(diagnostic_recorder_p3_test
    diagnostic_recorder_p3_test.cpp
    ${SRC_DIR}/diagnostic_recorder.cpp
)

target_include_directories(diagnostic_recorder_p3_test PRIVATE
    ${SRC_DIR}
)

target_link_libraries(diagnostic_recorder_p3_test
    GTest::gtest
    GTest::gtest_main
)

gtest_discover_tests(diagnostic_recorder_p3_test)

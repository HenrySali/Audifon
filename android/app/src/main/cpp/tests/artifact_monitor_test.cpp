/// @file artifact_monitor_test.cpp
/// @brief Tests del detector de "matraca" (ArtifactMonitor) y del registro por
///        sistema de limpieza (DenoiserArtifactLog).
///
/// Header-only bajo test: no requiere sources extra. Compila en el host.

#include "artifact_monitor.h"
#include "denoiser_artifact_log.h"

#include <cmath>
#include <vector>

#include <gtest/gtest.h>

namespace {

constexpr int kSR = 48000;
constexpr int kN = 480;

/// Genera un bloque de tono senoidal limpio (sin artefactos).
void fillTone(std::vector<float>& buf, double& phase, float amp = 0.2f,
              double freq = 440.0) {
    const double w = 2.0 * M_PI * freq / kSR;
    for (auto& x : buf) {
        x = amp * static_cast<float>(std::sin(phase));
        phase += w;
    }
}

}  // namespace

// Una señal limpia no debe reportar clicks y su calidad debe ser máxima.
TEST(ArtifactMonitor, CleanSignalHasNoArtifacts) {
    ArtifactMonitor mon;
    mon.configure(kSR);
    std::vector<float> buf(kN);
    double phase = 0.0;
    for (int b = 0; b < 50; ++b) {
        fillTone(buf, phase);
        mon.feed(buf.data(), kN);
    }
    const auto s = mon.snapshot();
    EXPECT_EQ(s.clickCount, 0u);
    EXPECT_EQ(s.clipCount, 0u);
    EXPECT_EQ(s.nanInfCount, 0u);
    EXPECT_FLOAT_EQ(s.sessionQuality, 100.0f);
    EXPECT_TRUE(s.active);
}

// Los saltos impulsivos (matraca) deben detectarse como clicks y bajar la calidad.
TEST(ArtifactMonitor, DetectsImpulsiveClicks) {
    ArtifactMonitor mon;
    mon.configure(kSR);
    std::vector<float> buf(kN);
    double phase = 0.0;
    for (int b = 0; b < 50; ++b) {
        fillTone(buf, phase);
        buf[100] += 0.8f;  // discontinuidad impulsiva
        buf[300] -= 0.9f;
        mon.feed(buf.data(), kN);
    }
    const auto s = mon.snapshot();
    EXPECT_GT(s.clickCount, 0u);
    EXPECT_LT(s.sessionQuality, 100.0f);
    EXPECT_GT(s.maxAbsJump, 0.5f);
}

// NaN/Inf deben contarse como fallas numéricas graves.
TEST(ArtifactMonitor, DetectsNanInf) {
    ArtifactMonitor mon;
    mon.configure(kSR);
    std::vector<float> buf(kN, 0.1f);
    buf[10] = std::nanf("");
    buf[20] = std::numeric_limits<float>::infinity();
    mon.feed(buf.data(), kN);
    const auto s = mon.snapshot();
    EXPECT_GE(s.nanInfCount, 2u);
    EXPECT_LT(s.sessionQuality, 100.0f);
}

// reset() vuelve el estado a cero.
TEST(ArtifactMonitor, ResetClearsState) {
    ArtifactMonitor mon;
    mon.configure(kSR);
    std::vector<float> buf(kN, 0.5f);
    buf[5] = 0.99f;
    mon.feed(buf.data(), kN);
    mon.reset();
    const auto s = mon.snapshot();
    EXPECT_EQ(s.blocks, 0u);
    EXPECT_EQ(s.samples, 0u);
    EXPECT_EQ(s.clickCount, 0u);
    EXPECT_FALSE(s.active);
}

// El registro atribuye la matraca al sistema que la introduce, no a la fuente.
TEST(DenoiserArtifactLog, AttributesArtifactToIntroducingSystem) {
    DenoiserArtifactLog log;
    log.configure(kSR);
    std::vector<float> clean(kN), cracked(kN);
    double phase = 0.0;
    for (int b = 0; b < 100; ++b) {
        fillTone(clean, phase);
        cracked = clean;
        cracked[100] += 0.8f;
        cracked[300] -= 0.9f;
        log.feedDenoiserInput(clean.data(), kN);
        log.feedEngineOutput(0, cracked.data(), kN);  // sistema 0 = RNNoise
        log.feedOutput(cracked.data(), kN);
    }

    const auto in = log.inputSnapshot();
    const auto e0 = log.engineSnapshot(0);
    const auto e1 = log.engineSnapshot(1);

    // La entrada está limpia; el sistema 0 introduce la matraca.
    EXPECT_EQ(in.clickCount, 0u);
    EXPECT_GT(e0.clickCount, 0u);
    EXPECT_GT(e0.clicksPerSec, in.clicksPerSec);
    EXPECT_LT(e0.sessionQuality, in.sessionQuality);

    // El sistema 1 no se usó esta sesión.
    EXPECT_FALSE(e1.active);
    EXPECT_EQ(log.activeEngineIndex(), 0);

    // El reporte menciona que el sistema 1 (RNNoise) introduce matraca.
    const std::string report = log.renderReport();
    EXPECT_NE(report.find("INTRODUCE matraca"), std::string::npos);
    EXPECT_NE(report.find("RNNoise"), std::string::npos);
}

// Matraca presente ya en la entrada => diagnóstico de "fuente previa".
TEST(DenoiserArtifactLog, DetectsSourceArtifactPassingThrough) {
    DenoiserArtifactLog log;
    log.configure(kSR);
    std::vector<float> cracked(kN);
    double phase = 0.0;
    for (int b = 0; b < 100; ++b) {
        fillTone(cracked, phase);
        cracked[100] += 0.8f;   // la matraca ya viene en la entrada
        cracked[300] -= 0.9f;
        log.feedDenoiserInput(cracked.data(), kN);
        log.feedEngineOutput(0, cracked.data(), kN);  // el sistema no la agrega
        log.feedOutput(cracked.data(), kN);
    }
    const auto in = log.inputSnapshot();
    EXPECT_GT(in.clickCount, 0u);

    const std::string report = log.renderReport();
    // La entrada trae matraca => el diagnóstico apunta a etapa previa.
    EXPECT_NE(report.find("trae matraca"), std::string::npos);
}

// Ruido musical / aspereza ("ronco"): entrada estable pero salida con
// ganancia fluctuante bloque-a-bloque => envFlutterDb alto en la salida.
TEST(DenoiserArtifactLog, DetectsRoughnessMusicalNoise) {
    DenoiserArtifactLog log;
    log.configure(kSR);
    std::vector<float> steady(kN), rough(kN);
    double phase = 0.0;
    for (int b = 0; b < 200; ++b) {
        fillTone(steady, phase, 0.3f);
        // Ganancia que salta fuerte entre bloques (modulación ~ aspereza).
        const float g = (b % 2 == 0) ? 1.0f : 0.35f;
        for (int i = 0; i < kN; ++i) rough[i] = steady[i] * g;
        log.feedDenoiserInput(steady.data(), kN);
        log.feedEngineOutput(1, rough.data(), kN);  // sistema 1 = DFN3
        log.feedOutput(rough.data(), kN);
    }
    const auto in = log.inputSnapshot();
    const auto e1 = log.engineSnapshot(1);

    // La entrada es estable (poca modulación); la salida modula fuerte.
    EXPECT_LT(in.envFlutterDb, 1.0f);
    EXPECT_GT(e1.envFlutterDb, in.envFlutterDb + 1.5f);

    const std::string report = log.renderReport();
    EXPECT_NE(report.find("suena RONCO"), std::string::npos);
}

// Con mic crudo limpio pero matraca en la entrada => atribuye al realce.
TEST(DenoiserArtifactLog, AttributesArtifactToEnhancementStage) {
    DenoiserArtifactLog log;
    log.configure(kSR);
    std::vector<float> clean(kN), cracked(kN);
    double phase = 0.0;
    for (int b = 0; b < 100; ++b) {
        fillTone(clean, phase);
        cracked = clean;
        cracked[100] += 0.8f;   // matraca introducida DESPUES del mic crudo
        cracked[300] -= 0.9f;
        log.feedRawInput(clean.data(), kN);          // mic crudo limpio
        log.feedDenoiserInput(cracked.data(), kN);   // realce/headroom mete matraca
        log.feedEngineOutput(0, cracked.data(), kN);
        log.feedOutput(cracked.data(), kN);
    }
    const auto raw = log.rawMicSnapshot();
    const auto in = log.inputSnapshot();
    EXPECT_EQ(raw.clickCount, 0u);
    EXPECT_GT(in.clickCount, 0u);

    const std::string report = log.renderReport();
    EXPECT_NE(report.find("REALCE PREVIO"), std::string::npos);
    EXPECT_NE(report.find("MICROFONO CRUDO"), std::string::npos);
}

/// @file test_dnn_denoiser_dual.cpp
/// @brief Tests unitarios de las Correctness Properties del DnnDenoiser
///        dual-channel (spec gtcrn-dual-channel, tarea 2.7).
///
/// ─────────────────────────────────────────────────────────────────────────
/// POR QUÉ ESTE TEST ES "STANDALONE" Y NO LINKEA CONTRA dnn_denoiser.cpp
/// ─────────────────────────────────────────────────────────────────────────
/// `dnn_denoiser.cpp` incluye, de forma no opcional:
///   - onnxruntime/onnxruntime_cxx_api.h  (runtime GTCRN mono)
///   - android/asset_manager.h, android/log.h  (solo existen en el NDK)
///   - torch/script.h  (solo con HAVE_PYTORCH=1, LibTorch arm64)
/// y el constructor de `DnnDenoiser::Impl` instancia `Ort::Env`, con lo cual
/// NO se puede construir un `DnnDenoiser` real en un host x86 sin toda la
/// cadena ONNX + LibTorch + Android. Por eso NO se puede correr el objeto
/// real en un unit test de host.
///
/// Estrategia (honesta):
///   1. Las propiedades que dependen del MODELO ACTIVO (P3 dry/wet, P6 no
///      amplifica ruido) NO se pueden verificar sin cargar el `.pt`. Se
///      validan en el Simulation_Harness (tarea 6, `sim_harness.py`) y en
///      dispositivo (tarea 8.3). Acá quedan como tests SKIPPED documentados.
///   2. Las propiedades locales de SEGURIDAD viven todas en la ruta de
///      BYPASS de `processStereo`, que es lógica pura (sin ONNX/Torch):
///        - P1  salida acotada [-1,1]  (en bypass: output = ch0 ∈ rango)
///        - P2  bypass == ch0 bit-exact
///        - P4  fail-safe: modelo no cargado/activo → output == ch0, !isActive
///        - P5  modelo mono (no dual) → ch0 passthrough
///        - P7  processStereo produce exactamente blockSize muestras
///      Esas ramas se testean acá contra un ESPEJO FIEL de los predicados de
///      `processStereo` (ver `BypassMirror` abajo). El espejo transcribe las
///      condiciones EXACTAS de la implementación; si esos predicados cambian
///      en `dnn_denoiser.cpp`, este archivo debe actualizarse en el mismo
///      commit (queda anotado en cada sección con la línea de referencia).
///
/// ─────────────────────────────────────────────────────────────────────────
/// CÓMO COMPILAR Y CORRER EN HOST (Windows / Linux / Mac)
/// ─────────────────────────────────────────────────────────────────────────
///   g++ -std=c++17 -O2 test_dnn_denoiser_dual.cpp -o test_dnn_dual
///   ./test_dnn_dual        # exit 0 = OK, exit 1 = alguna propiedad falló
///
///   (o con clang++)  clang++ -std=c++17 -O2 test_dnn_denoiser_dual.cpp -o t
///
/// NO se agrega a la .so de la app (no está en CMakeLists.txt): es un target
/// de host separado y opcional. No afecta el build del APK.
///
/// ─────────────────────────────────────────────────────────────────────────
/// TESTS DE INTEGRACIÓN REAL (device target, futuro)
/// ─────────────────────────────────────────────────────────────────────────
/// Para ejercitar el `DnnDenoiser` real (P3/P6 incluidas) haría falta un
/// androidTest (JNI) que corra en el Moto G32 con el `.pt` cargado desde
/// assets vía AAssetManager. Los cuerpos de esos tests quedan esbozados al
/// final del archivo (ver sección DEVICE_INTEGRATION_SKETCH) listos para
/// portar a un instrumented test cuando exista ese target.
///
/// Spec: gtcrn-dual-channel — design.md, Correctness Properties P1–P7.

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

// ─────────────────────────────────────────────────────────────────────────
// Mini framework de asserts (sin dependencias externas)
// ─────────────────────────────────────────────────────────────────────────
namespace {

int g_checks = 0;
int g_failures = 0;

#define CHECK(cond, msg)                                                      \
    do {                                                                      \
        ++g_checks;                                                           \
        if (!(cond)) {                                                        \
            ++g_failures;                                                     \
            std::printf("  [FAIL] %s (línea %d): %s\n", __func__, __LINE__,   \
                        (msg));                                               \
        }                                                                     \
    } while (0)

#define CHECK_EQ_F(a, b, msg)                                                 \
    do {                                                                      \
        ++g_checks;                                                           \
        if ((a) != (b)) {                                                     \
            ++g_failures;                                                     \
            std::printf("  [FAIL] %s (línea %d): %s (%.9g != %.9g)\n",        \
                        __func__, __LINE__, (msg), (double)(a), (double)(b)); \
        }                                                                     \
    } while (0)

// ─────────────────────────────────────────────────────────────────────────
// ESPEJO FIEL de la ruta de bypass de DnnDenoiser::processStereo
// ─────────────────────────────────────────────────────────────────────────
// Transcripción 1:1 de las ramas de bypass de `processStereo`
// (dnn_denoiser.cpp, a partir de la línea de `void DnnDenoiser::processStereo`).
// Solo se modela la lógica de bypass (la única verificable sin ONNX/Torch).
// La rama "dual && activo" delega en el worker LibTorch y NO se modela acá.
//
// Constante real del wrapper (dnn_denoiser.h):
constexpr int   kDnnCrossfadeSamples = 800;
constexpr float kCrossfadeStep = 1.0f / static_cast<float>(kDnnCrossfadeSamples);

// Estado mínimo relevante para decidir bypass (subconjunto del estado real).
struct BypassMirror {
    bool  enabled = false;   // enabled_        (default false)
    bool  active  = false;   // active_         (default false)
    bool  dual    = false;   // inputChannelsMode_ == 2 (default 1 = mono)
    float crossfadeGain = 0.0f;

    // Resultado de intentar procesar. Devuelve true si TOMÓ una ruta de
    // bypass (y por tanto output quedó == ch0). Devuelve false si la entrada
    // caería en la ruta DNN activa (no modelada => el test que use eso lo
    // marca como fuera de alcance host).
    //
    // Réplica exacta de los guards y predicados de processStereo:
    //   guard nullptr/blockSize<=0 -> return (no escribe)
    //   passthroughCh0(): if(output!=ch0) memcpy(output, ch0, N)
    //   fast bypass: if(!dual || (!enabled && crossfadeGain<=0)) passthrough
    //   not active : if(!active) { crossfade out; passthrough }
    bool process(const float* ch0, const float* ch1, float* output,
                 int blockSize) {
        // Guard defensivo idéntico al de processStereo.
        if (ch0 == nullptr || ch1 == nullptr || output == nullptr ||
            blockSize <= 0) {
            return true;  // no-op: se considera "manejado" (no toca buffer)
        }

        auto passthroughCh0 = [&]() {
            if (output != ch0) {
                std::memcpy(output, ch0,
                            static_cast<size_t>(blockSize) * sizeof(float));
            }
        };

        // Fast path bypass (P5 mono→bypass; P4 no-enable).
        if (!dual || (!enabled && crossfadeGain <= 0.0f)) {
            passthroughCh0();
            return true;
        }

        // Modelo dual pero no activo (fail-safe P4): crossfade out + bypass.
        if (!active) {
            float target = 0.0f;
            if (crossfadeGain > 0.0f) {
                for (int i = 0; i < blockSize; ++i) {
                    crossfadeGain = std::max(0.0f, crossfadeGain - kCrossfadeStep);
                }
            }
            (void)target;
            passthroughCh0();
            return true;
        }

        // dual && active => ruta DNN (worker LibTorch). No modelada en host.
        return false;
    }
};

// Genera una señal de prueba acotada en [-1,1].
std::vector<float> makeBoundedSignal(int n, float phase) {
    std::vector<float> v(n);
    for (int i = 0; i < n; ++i) {
        v[i] = 0.9f * std::sin(0.1f * static_cast<float>(i) + phase);
    }
    return v;
}

// ─────────────────────────────────────────────────────────────────────────
// P2: Bypass es identidad sobre ch0 (bit-exact). Validates R2.4, R8.2.
// ─────────────────────────────────────────────────────────────────────────
void test_P2_bypass_identity_ch0() {
    std::printf("[P2] Bypass == ch0 bit-exact\n");
    const int N = 64;
    auto ch0 = makeBoundedSignal(N, 0.0f);
    auto ch1 = makeBoundedSignal(N, 1.7f);  // distinto de ch0 a propósito
    std::vector<float> out(N, -123.0f);

    // Estado por defecto (modelo nunca inicializado): dual=false => bypass.
    BypassMirror m;
    const bool bypassed = m.process(ch0.data(), ch1.data(), out.data(), N);
    CHECK(bypassed, "estado default debe ir a bypass");
    for (int i = 0; i < N; ++i) {
        CHECK_EQ_F(out[i], ch0[i], "output debe ser bit-exact ch0");
    }

    // Caso aliasing output == ch0 (contrato: puede aliasar). No debe corromper.
    std::vector<float> ali = ch0;
    BypassMirror m2;
    m2.process(ali.data(), ch1.data(), ali.data(), N);
    for (int i = 0; i < N; ++i) {
        CHECK_EQ_F(ali[i], ch0[i], "aliasing output==ch0 preserva ch0");
    }
}

// ─────────────────────────────────────────────────────────────────────────
// P1: Salida acotada [-1,1] en bypass (output = ch0 ∈ [-1,1]). Validates R6.5.
// ─────────────────────────────────────────────────────────────────────────
void test_P1_output_bounded_in_bypass() {
    std::printf("[P1] Salida acotada [-1,1] en bypass\n");
    const int N = 128;
    auto ch0 = makeBoundedSignal(N, 0.3f);  // |ch0| <= 0.9 < 1
    auto ch1 = makeBoundedSignal(N, 2.1f);
    std::vector<float> out(N, 0.0f);

    BypassMirror m;  // default => bypass
    m.process(ch0.data(), ch1.data(), out.data(), N);
    for (int i = 0; i < N; ++i) {
        CHECK(out[i] >= -1.0f && out[i] <= 1.0f, "muestra fuera de [-1,1]");
    }

    // Borde: ch0 saturado exactamente a ±1 sigue acotado tras bypass.
    std::vector<float> edge(N);
    for (int i = 0; i < N; ++i) edge[i] = (i % 2 == 0) ? 1.0f : -1.0f;
    BypassMirror m2;
    m2.process(edge.data(), ch1.data(), out.data(), N);
    for (int i = 0; i < N; ++i) {
        CHECK(out[i] >= -1.0f && out[i] <= 1.0f, "borde ±1 debe seguir acotado");
        CHECK_EQ_F(out[i], edge[i], "bypass no altera ±1");
    }
}

// ─────────────────────────────────────────────────────────────────────────
// P4: Fail-safe determinista. Si el modelo no cargó (initializeDual nunca
// llamado o falló => active=false), todo bloque hace output==ch0 e
// isActive()==false. Validates R4.1–R4.4.
// ─────────────────────────────────────────────────────────────────────────
void test_P4_failsafe_deterministic() {
    std::printf("[P4] Fail-safe: modelo no cargado/activo => ch0 passthrough\n");
    const int N = 96;
    auto ch0 = makeBoundedSignal(N, 0.0f);
    auto ch1 = makeBoundedSignal(N, 0.9f);
    std::vector<float> out(N, 0.0f);

    // Caso A: initializeDual nunca llamado. active=false, dual=false (mono
    // default). isActive()==false por construcción.
    BypassMirror never;
    CHECK(!never.active, "isActive() debe ser false sin initializeDual");
    for (int rep = 0; rep < 3; ++rep) {  // "todo bloque siguiente"
        const bool bp = never.process(ch0.data(), ch1.data(), out.data(), N);
        CHECK(bp, "sin modelo debe bypass");
        for (int i = 0; i < N; ++i)
            CHECK_EQ_F(out[i], ch0[i], "fail-safe: output==ch0");
    }

    // Caso B: modelo dual cargó el shape (dual=true) pero luego falló la
    // inferencia => active=false. Debe seguir haciendo ch0 passthrough y
    // NO quedar activo. Simula crossfade residual > 0 (venía de wet).
    BypassMirror failed;
    failed.dual = true;
    failed.active = false;
    failed.enabled = true;
    failed.crossfadeGain = 0.5f;  // había wet, debe rampar a 0
    for (int rep = 0; rep < 3; ++rep) {
        const bool bp = failed.process(ch0.data(), ch1.data(), out.data(), N);
        CHECK(bp, "dual pero !active => bypass");
        for (int i = 0; i < N; ++i)
            CHECK_EQ_F(out[i], ch0[i], "fail-safe dual-inactivo: output==ch0");
    }
    CHECK(!failed.active, "tras fallo isActive() sigue false");
    CHECK(failed.crossfadeGain < 0.5f, "crossfade debe ramp-out hacia 0");
}

// ─────────────────────────────────────────────────────────────────────────
// P5: Mono→bypass. Si el modelo es mono (o no dual) y el modo es
// DUAL_CHANNEL_DNN, processStereo hace ch0 passthrough. Validates R4.5.
// ─────────────────────────────────────────────────────────────────────────
void test_P5_mono_model_bypass() {
    std::printf("[P5] Modelo mono/no-dual => ch0 passthrough\n");
    const int N = 64;
    auto ch0 = makeBoundedSignal(N, 0.5f);
    auto ch1 = makeBoundedSignal(N, 3.3f);
    std::vector<float> out(N, 0.0f);

    // Modelo mono cargado y "enabled": aún así processStereo bypass a ch0
    // (el modo mono no puede procesar estéreo).
    BypassMirror mono;
    mono.dual = false;     // inputChannelsMode_ == 1
    mono.active = true;    // el mono podría estar activo, pero no aplica a dual
    mono.enabled = true;
    const bool bp = mono.process(ch0.data(), ch1.data(), out.data(), N);
    CHECK(bp, "modelo mono debe bypass en processStereo");
    for (int i = 0; i < N; ++i)
        CHECK_EQ_F(out[i], ch0[i], "mono→bypass: output==ch0");
}

// ─────────────────────────────────────────────────────────────────────────
// P7: Longitud preservada. processStereo produce exactamente blockSize
// muestras por cada blockSize de entrada. Validates R1.2.
// ─────────────────────────────────────────────────────────────────────────
void test_P7_length_preserved() {
    std::printf("[P7] processStereo produce exactamente blockSize muestras\n");
    // Varios blockSize típicos (Oboe callback) y bordes.
    const int sizes[] = {1, 16, 32, 48, 64, 128, 240, 256};
    for (int N : sizes) {
        auto ch0 = makeBoundedSignal(N, 0.0f);
        auto ch1 = makeBoundedSignal(N, 1.0f);
        // Sentinela para detectar under/over-write.
        std::vector<float> out(N + 2, 7777.0f);
        BypassMirror m;  // bypass path
        m.process(ch0.data(), ch1.data(), out.data() + 1, N);
        // Exactamente N muestras escritas: los guardias no se tocan.
        CHECK_EQ_F(out[0], 7777.0f, "no debe escribir antes del buffer");
        CHECK_EQ_F(out[N + 1], 7777.0f, "no debe escribir después de blockSize");
        for (int i = 0; i < N; ++i)
            CHECK_EQ_F(out[1 + i], ch0[i], "las N muestras == ch0");
    }

    // Guard: blockSize <= 0 no escribe nada (no crashea).
    float dummy = 42.0f;
    float chd = 0.0f;
    BypassMirror g;
    g.process(&chd, &chd, &dummy, 0);
    CHECK_EQ_F(dummy, 42.0f, "blockSize<=0 no debe escribir");
    g.process(&chd, &chd, &dummy, -5);
    CHECK_EQ_F(dummy, 42.0f, "blockSize negativo no debe escribir");
}

// ─────────────────────────────────────────────────────────────────────────
// P3 (dry/wet) y P6 (no amplifica ruido): REQUIEREN el modelo activo.
// No verificables sin cargar el `.pt` (LibTorch) + worker thread.
// Se documentan como SKIPPED y se delega a:
//   - P3: Simulation_Harness (tarea 6) + prueba dry/wet en dispositivo.
//   - P6: sim_harness.py mide RMS enhanced vs ch0 en tramos noise-only
//         (invariante "el DNN solo atenúa") + prueba subjetiva 8.3.
// ─────────────────────────────────────────────────────────────────────────
void test_P3_P6_documented_skips() {
    std::printf("[P3] dry/wet monótono  -> SKIP en host "
                "(requiere modelo activo; validado en Simulation_Harness + device)\n");
    std::printf("[P6] no amplifica ruido -> SKIP en host "
                "(requiere modelo activo; validado en sim_harness.py RMS + device)\n");
}

}  // namespace

// ─────────────────────────────────────────────────────────────────────────
// DEVICE_INTEGRATION_SKETCH — cuerpos de referencia para un instrumented
// test (JNI, Moto G32) que ejercite el DnnDenoiser real. NO compilan en host
// (necesitan dnn_denoiser.h + AAssetManager + el .pt). Se dejan como guía.
// ─────────────────────────────────────────────────────────────────────────
#if 0
#include "dnn_denoiser.h"
#include <android/asset_manager.h>
using dnn_denoiser::DnnDenoiser;

// P4 real: cargar un .pt inexistente => initializeDual false, isActive false,
// processStereo == ch0.
void device_P4(AAssetManager* mgr) {
    DnnDenoiser d;
    bool ok = d.initializeDual(mgr, "dnn_denoiser/NO_EXISTE.pt");
    assert(!ok);
    assert(!d.isActive());
    float ch0[64], ch1[64], out[64];
    /* ... llenar ch0/ch1 ... */
    d.setEnabled(true);
    d.processStereo(ch0, ch1, out, 64);
    for (int i = 0; i < 64; ++i) assert(out[i] == ch0[i]);  // bypass
}

// P3 real: con modelo activo, intensity=0 => salida ≈ dry(ch0 realineado);
// intensity=1 => 100% wet. Requiere .pt válido y drenar el worker.
void device_P3(AAssetManager* mgr) {
    DnnDenoiser d;
    assert(d.initializeDual(mgr, "dnn_denoiser/gtcrn_dual_core.onnx"));
    assert(d.inputChannels() == 2);
    d.setEnabled(true);
    d.setIntensity(0.0f);   // dry
    /* ... procesar N bloques, comparar contra ch0 realineado ... */
    d.setIntensity(1.0f);   // wet
    /* ... procesar, verificar mezcla lineal en valores intermedios ... */
}

// P6 real: en tramos noise-only, RMS(out) <= RMS(ch0) (DNN solo atenúa).
void device_P6(AAssetManager* mgr) {
    DnnDenoiser d;
    assert(d.initializeDual(mgr, "dnn_denoiser/gtcrn_dual_core.onnx"));
    d.setEnabled(true);
    d.setIntensity(1.0f);
    /* ... alimentar ruido sin voz, medir RMS ch0 y out, assert rmsOut<=rmsCh0 ... */
}
#endif  // DEVICE_INTEGRATION_SKETCH

int main() {
    std::printf("=== Tests DnnDenoiser dual-channel (spec gtcrn-dual-channel 2.7) ===\n");
    std::printf("Host-runnable: propiedades de bypass P1,P2,P4,P5,P7\n\n");

    test_P2_bypass_identity_ch0();
    test_P1_output_bounded_in_bypass();
    test_P4_failsafe_deterministic();
    test_P5_mono_model_bypass();
    test_P7_length_preserved();
    test_P3_P6_documented_skips();

    std::printf("\n---------------------------------------------------------\n");
    std::printf("Checks: %d   Fallos: %d\n", g_checks, g_failures);
    if (g_failures == 0) {
        std::printf("RESULT: PASS (propiedades de bypass verificadas)\n");
        return 0;
    }
    std::printf("RESULT: FAIL\n");
    return 1;
}

/// @file klatt_voice.h
/// @brief Sintetizador de voz Klatt simplificado para tests del VAD.
///
/// Genera muestras float [-1, +1] a 48 kHz que reproducen las
/// características espectrales esenciales de voz humana real:
///
///   - Pulsos glotales (excitación cuasi-periódica) a F0 = 80-300 Hz
///     con jitter ±2 % (variación natural del pitch).
///   - 5 formantes (F1..F5) implementados como resonadores IIR de
///     2 polos (biquads) en cascada. Frecuencias y anchos de banda
///     tomados de tablas estándar para vocales /a/, /e/, /i/, /o/, /u/.
///   - Aspiración (ruido blanco filtrado) modulada por la apertura
///     glotal — simula la "respiración" residual presente en voz real.
///   - Modulación lenta de F0 (vibrato 4-6 Hz, ±3 %) y de amplitud
///     (variación silábica 3-7 Hz) para evitar perfecta estacionariedad.
///
/// Referencias (parafraseadas):
///   - Klatt 1980, JASA — "Software for a cascade/parallel formant
///                         synthesizer"
///   - Carnegie Mellon AI Repository — implementación de referencia C
///   - ITU-T P.50 / P.501 — voz artificial estándar para tests
///
/// Esta NO es una implementación completa de Klatt — es la versión
/// mínima para tener una señal con la estructura espectral correcta
/// que el VAD analiza (pitch real, tilt negativo, flatness baja en
/// vocales, ZCR baja). Las constantes vienen de papers de fonética
/// publicados, parafraseadas para cumplir licencias.

#ifndef HEARING_AID_SMART_SCENE_TESTS_KLATT_VOICE_H
#define HEARING_AID_SMART_SCENE_TESTS_KLATT_VOICE_H

#include <cstddef>
#include <cstdint>

namespace smart_scene {
namespace klatt {

/// Identificadores de vocales con tablas de formantes pre-cargadas.
/// Valores tomados de Peterson & Barney 1952 (referencia clásica de
/// formantes en inglés americano), parafraseados.
enum class Vowel : int {
    A = 0,  ///< /a/ como en "father"  (F1=730, F2=1090, F3=2440)
    E = 1,  ///< /e/ como en "head"    (F1=530, F2=1840, F3=2480)
    I = 2,  ///< /i/ como en "see"     (F1=270, F2=2290, F3=3010)
    O = 3,  ///< /o/ como en "law"     (F1=570, F2=840,  F3=2410)
    U = 4,  ///< /u/ como en "boot"    (F1=300, F2=870,  F3=2240)
};

/// Sintetizador Klatt minimalista en estado interno.
class KlattVoice {
public:
    KlattVoice();

    /// Inicializa para un sampleRate dado y vocal inicial.
    /// @param sampleRate Frecuencia de muestreo en Hz (típico 48000).
    /// @param vowel       Vocal a sintetizar.
    /// @param f0Hz        Pitch fundamental en Hz (80-300 típico).
    /// @param dbSpl       Nivel objetivo en dB SPL (referenciado a
    ///                    splOffset = 120 → -94 dBFS = 26 dB SPL).
    void init(int sampleRate, Vowel vowel, float f0Hz, float dbSpl);

    /// Genera n samples y los escribe en out[]. La señal se actualiza
    /// internamente (jitter, vibrato, amplitud) para que dos llamadas
    /// consecutivas produzcan una señal continua, modulada como voz real.
    void generate(float* out, int n);

    /// Cambia la vocal sin reiniciar el estado glotal — simula la
    /// transición vocal-vocal de habla continua. Los formantes se
    /// interpolan suavemente en los próximos ~30 ms.
    void setVowel(Vowel vowel);

    /// Cambia el pitch objetivo. La transición es suave (~50 ms).
    void setF0(float f0Hz);

    /// Cambia el nivel objetivo en dB SPL.
    void setLevel(float dbSpl);

private:
    // Estado glotal (excitación)
    float sampleRate_   = 48000.0f;
    float f0_           = 120.0f;     // pitch actual (Hz)
    float f0Target_     = 120.0f;     // pitch objetivo (interpolado)
    float phase_        = 0.0f;       // fase glotal [0, 2π)
    float jitterRand_   = 0.0f;       // jitter actual (ruido lento)
    float vibratoPhase_ = 0.0f;
    float t_            = 0.0f;       // tiempo en segundos

    // Amplitud objetivo (linear, [-1, 1])
    float amp_       = 0.05f;
    float ampTarget_ = 0.05f;

    // Resonadores formantes (5 paralelo, BPF cookbook RBJ Direct Form I)
    struct Resonator {
        float fHz   = 1000.0f;
        float bwHz  = 100.0f;
        float fHzTarget = 1000.0f;
        float bwHzTarget = 100.0f;
        // Coeficientes (BPF: b1=0, b2=-b0)
        float b0 = 0.0f, a1 = 0.0f, a2 = 0.0f;
        // Estado IIR Direct Form I (entradas y salidas pasadas).
        float xz1 = 0.0f, xz2 = 0.0f;
        float yz1 = 0.0f, yz2 = 0.0f;
    };
    Resonator formants_[5];

    // Aspiración (ruido) mezclado con pulsos
    uint32_t noiseRng_   = 0xCAFEBABEu;
    float    aspirAmp_   = 0.0f;     // mezcla 0..1 (más en voz suave)

    // Helpers internos
    void recomputeFormantCoeffs(Resonator& r);
    void interpolateTowardsTargets();
    float frand();                   // ruido blanco [-1, 1]
    void  loadVowelFormants(Vowel v, float fOut[5], float bwOut[5]);
};

} // namespace klatt
} // namespace smart_scene

#endif // HEARING_AID_SMART_SCENE_TESTS_KLATT_VOICE_H

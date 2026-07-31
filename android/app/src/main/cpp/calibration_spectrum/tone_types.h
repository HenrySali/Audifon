/// @file tone_types.h
/// @brief Tipos compartidos del módulo Calibration Spectrum Validator.
///
/// Definiciones de enums y la struct ToneSnapshot que se serializa
/// desde C++ a Dart vía JNI ByteBuffer.
///
/// Este archivo NO depende de ningún otro módulo del proyecto.
/// Es la API pública del motor C++ del módulo.

#ifndef HEARING_AID_CALIBRATION_SPECTRUM_TONE_TYPES_H
#define HEARING_AID_CALIBRATION_SPECTRUM_TONE_TYPES_H

#include <cstdint>

namespace cal_spectrum {

/// Tipo de ventana aplicada antes de la FFT.
/// - Hann: default. Buen balance ENBW + sidelobes para tonos puros (Harris 1978).
/// - BlackmanHarris: low-leakage para análisis de armónicos a alta dinámica.
enum class WindowType : uint8_t {
    Hann = 0,
    BlackmanHarris = 1,
};

/// Veredicto del análisis de un tono.
enum class ToneVerdict : uint8_t {
    Unknown = 0,  ///< Aún no evaluado o sin datos.
    Pass = 1,     ///< Cumple todos los criterios de aceptación.
    Fail = 2,     ///< Al menos un criterio falló.
};

/// Bits que codifican qué criterio falló en `ToneSnapshot::failure_mask`.
/// Múltiples bits pueden estar activos simultáneamente.
enum FailureFlag : uint8_t {
    kFailureFreq    = 1 << 0,  ///< Frecuencia detectada fuera de tolerancia (±5%).
    kFailureThd     = 1 << 1,  ///< THD por encima del límite del preset.
    kFailureSnr     = 1 << 2,  ///< SNR por debajo del mínimo.
    kFailureLevel   = 1 << 3,  ///< Nivel de salida fuera de tolerancia (±3/±6 dB).
    kFailureNoSig   = 1 << 4,  ///< Pico no detectado (no supera floor + 20 dB).
    kFailureNanInf  = 1 << 5,  ///< Métricas con NaN/Inf (lectura anómala).
};

/// Snapshot del análisis de un tono en un instante temporal.
///
/// Se actualiza desde el thread de audio cada vez que el motor procesa una
/// ventana FFT completa. El thread de UI lo lee vía `ToneAnalyzer::getSnapshot()`.
///
/// Layout binario fijo: 96 bytes. Compatible con la deserialización en Dart.
/// NO agregar campos sin actualizar `tone_snapshot.dart`.
struct ToneSnapshot {
    // ─── Timing ─────────────────────────────────────────────────────────
    uint64_t timestamp_us;        ///< Microsegundos desde inicio de sesión.

    // ─── Configuración del análisis ─────────────────────────────────────
    float    sample_rate_hz;      ///< 16000.0 o 48000.0
    uint16_t fft_size;            ///< 1024, 4096 o 8192
    uint8_t  window_type;         ///< WindowType
    uint8_t  reserved0;           ///< Padding (0)

    // ─── Tono esperado / detectado ──────────────────────────────────────
    float    expected_freq_hz;        ///< Frecuencia objetivo (250, 500, 1k…).
    float    peak_freq_hz;            ///< Frecuencia detectada (Quinn 2nd estimator).
    float    peak_magnitude_dbfs;     ///< Magnitud del pico en dB FS.
    float    peak_magnitude_dbspl;    ///< Magnitud del pico en dB SPL (con offset).

    // ─── Niveles ────────────────────────────────────────────────────────
    float    noise_floor_dbfs;        ///< Piso de ruido medido pre-secuencia.
    float    snr_db;                  ///< SNR = 20·log10(|H1| / floor).

    // ─── Distorsión armónica ────────────────────────────────────────────
    float    thd_percent;             ///< %THD = sqrt(sum(Hk²))/|H1| × 100.
    float    harmonics_dbfs[8];       ///< H2..H9 (algunos pueden ser NaN si fuera de Nyquist).
    uint8_t  harmonics_count;         ///< 4 (clínico, H2-H5) o 7 (premium, H2-H8).
    uint8_t  reserved1[3];            ///< Padding.

    // ─── Estado / veredicto ─────────────────────────────────────────────
    uint8_t  verdict;                 ///< ToneVerdict.
    uint8_t  failure_mask;            ///< Bits FailureFlag activos.
    uint8_t  reserved2[2];            ///< Padding.
};

// Nota: el tamaño exacto del struct depende del padding del compilador.
// La serialización binaria a Dart se hace explícitamente en Fase 2 con
// un layout pack(1) o por campo, no via memcpy del struct. Por eso acá
// no hay static_assert sobre sizeof — el ABI binario es responsabilidad
// del módulo de serialización.

}  // namespace cal_spectrum

#endif  // HEARING_AID_CALIBRATION_SPECTRUM_TONE_TYPES_H

// Feature: in-app-diagnostic-analyzer
// Module: constants
//
// Centralized numeric constants used by every analyzer module. Values match
// the Octave golden reference (`analyze_dsp_diagnostic.m`) byte-for-byte
// where applicable, so any future tuning must be done here and propagated.

/// Sampling rate of every Recording_Package (Hz). Matches the recorder.
const int kSampleRate = 48000;

/// Default FFT length for Welch_PSD computations.
const int kNfftDefault = 8192;

/// FFT length for the spectrogram STFT.
const int kNfftSpectrogram = 1024;

/// Hop size for the spectrogram STFT (50% overlap).
const int kHopSpectrogram = 512;

/// Floor used in every dB conversion `10·log10(x + ε)` to avoid `log(0)`.
const double kPsdEpsilon = 1e-20;

/// Duration in seconds of every analysis segment used by SNR / WDRC / NR.
const int kSegmentDurationSec = 1;

/// Maximum cross-correlation lag for latency analysis (samples). ±50 ms at
/// 48 kHz.
const int kMaxLagSamples = 2400;

/// Magnitude floor for the THD fundamental. Below this the result is NaN.
const double kThdLowMagnitudeThreshold = 1e-9;

/// Threshold on |normalized cross-correlation peak| below which the
/// LatencyResult is flagged as low-confidence. Symmetric so strong
/// anti-correlations remain high-confidence (Req. 10.6).
const double kLatencyLowConfidenceThreshold = 0.1;

/// ANSI/ASA S3.22-2024 5% THD compliance limit.
const double kThdLimitPercent = 5.0;

/// Clipping detection threshold on normalized samples.
const double kClippingThreshold = 0.99;

/// 12 audiometric center frequencies index-aligned with `eqGainsDb` from
/// `DiagnosticMetadata` (Hz). Order is canonical for every analyzer.
const List<int> kAudiometricBandsHz = <int>[
  250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000,
];

/// Half-bandwidth (Hz) of the per-band averaging window around each
/// audiometric frequency.
const double kBandHalfBandwidthHz = 100.0;

/// 6 spectral noise-reduction bands, low-edge in Hz. Matches the Octave
/// reference verbatim.
const List<int> kSpectralNrBandsLowHz = <int>[100, 200, 500, 1000, 3000, 6000];

/// 6 spectral noise-reduction bands, high-edge in Hz.
const List<int> kSpectralNrBandsHighHz = <int>[
  200, 500, 1000, 3000, 6000, 10000,
];

/// Spanish display names of the 6 spectral NR bands.
const List<String> kSpectralNrBandNames = <String>[
  'Sub-graves 100–200 Hz',
  'Graves 200–500 Hz',
  'Medios-bajos 500–1000 Hz',
  'Medios 1000–3000 Hz',
  'Agudos 3000–6000 Hz',
  'HF 6000–10000 Hz',
];

/// ISO 389-7 free-field RETSPL offsets (dB) at the 12 audiometric
/// frequencies, used to convert between dB SPL and dB HL.
const Map<int, double> kRetsplDb = <int, double>{
  250: 11.0,
  500: 4.0,
  750: 2.0,
  1000: 2.0,
  1500: 2.0,
  2000: -1.5,
  2500: -1.5,
  3000: -6.0,
  3500: -6.0,
  4000: -6.5,
  6000: 4.0,
  8000: 12.5,
};

/// LTASS reference (Byrne et al. 1994, dB SPL @ 65 dB SPL overall) sampled
/// at the 12 audiometric bands. Used by the heuristic that flags non-speech
/// recordings (Req. 14.7).
const Map<int, double> kLtassDbSpl = <int, double>{
  250: 49.0,
  500: 50.0,
  750: 51.0,
  1000: 52.0,
  1500: 47.0,
  2000: 43.0,
  2500: 41.0,
  3000: 39.0,
  3500: 37.0,
  4000: 35.0,
  6000: 28.0,
  8000: 25.0,
};

/// LTASS deviation threshold (dB). Used by the heuristic (Req. 14.7).
const double kLtassDeviationDbLimit = 6.0;

/// LTASS check is restricted to this frequency range (Hz).
const int kLtassCheckLowHz = 250;
const int kLtassCheckHighHz = 4000;

// ─── Heuristic thresholds (Req. 14) ───────────────────────────────────────

/// Req. 14.1 — `snrImprovementDb < kSnrImprovementWarnDb` triggers warn.
const double kSnrImprovementWarnDb = -1.0;

/// Req. 14.3 — per-band absolute deviation above this triggers warn.
const double kBandDeviationWarnDb = 6.0;

/// Req. 14.4 — observed compression ratio exceeding configured by more than
/// this triggers warn.
const double kCompressionRatioWarnDelta = 1.0;

/// Req. 14.5 — clipping percent above this on the post channel triggers
/// error.
const double kClippingPostErrorPercent = 0.01;

/// Req. 14.6 — latency above this in ms triggers warn.
const double kLatencyWarnMs = 20.0;

// ─── Service_Code_Gate ────────────────────────────────────────────────────

/// Maximum failures before the gate locks input (Req. 17.7).
const int kServiceCodeMaxFailures = 5;

/// Lockout duration after `kServiceCodeMaxFailures` consecutive failures
/// (Req. 17.7).
const Duration kServiceCodeLockoutDuration = Duration(seconds: 60);

/// Allowed code lengths (Req. 17.3).
const int kServiceCodeMinDigits = 4;
const int kServiceCodeMaxDigits = 6;

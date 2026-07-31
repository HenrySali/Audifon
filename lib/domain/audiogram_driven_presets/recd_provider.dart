// Spec: audiogram-driven-presets · Wave 11, task 14.5.
//
// Real-Ear to 2cc Coupler Difference (RECD) provider.
//
// The RECD is the per-frequency offset (in dB) between the SPL measured
// in a 2cc coupler and the SPL produced at the patient's eardrum, given
// the same input. It is the standard correction used to translate
// coupler-domain prescription targets into real-ear targets and to
// translate audiometric thresholds (in dB HL, calibrated against a
// coupler) into real-ear SPL.
//
// Conversion chain (HL → real-ear SPL):
//
//   SPL_realear[f] = HL[f] + RETSPL[f] + RECD[f, age, coupling]
//
// where RETSPL[f] is the Reference Equivalent Threshold Sound Pressure
// Level for the audiometric transducer (ANSI S3.6 Table 7) and
// RECD[f, age, coupling] is the value provided by this module.
//
// References:
//   - Bagatto, M., Moodie, S., Scollie, S., Seewald, R., Moodie, K.,
//     Pumford, J., & Liu, K. P. R. (2005). "Clinical protocols for
//     hearing instrument fitting in the Desired Sensation Level
//     method". *Trends in Amplification*, 9(4), 199–226. — Tables 3
//     and 4 (predicted RECD by age, custom earmold + HA1/HA2 coupler
//     and eartip + HA1/HA2 coupler).
//   - University of Western Ontario, National Centre for Audiology,
//     Child Amplification Lab (2018). "DSL v5 by Hand", reproducing
//     Bagatto 2005 Tables 3 and 4 in PDF reference form. Local copy:
//     `.kiro_tmp/refs/dsl-v5-by-hand.pdf` (text in
//     `.kiro_tmp/refs/dsl-v5-by-hand.txt`, lines 175–340).
//   - DSL v5 — pediatric protocol justification for using predicted
//     RECDs by age when individual measurement is not feasible.
//
// Project doc:
//   `docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md`
//   §4 "RECD y conversión HL → SPL real-ear".

import 'dart:math' as math;

import '../entities/audiogram.dart';

/// Coupling configuration used to look up the predicted RECD.
///
/// The RECD depends on the *coupler* used during the prescription and
/// on the *coupling* used at the patient (foam tip vs custom earmold).
/// Bagatto 2005 publishes four predicted RECD tables, one per
/// `(coupling, coupler)` combination. The names below mirror the
/// table headings in the source.
enum RecdCoupling {
  /// Predicted RECD for **eartips** (foam tip / instant coupling) on
  /// an **HA1** coupler. Bagatto 2005 Table 4, top half.
  foamTipHa1,

  /// Predicted RECD for **eartips** on an **HA2** coupler.
  /// Bagatto 2005 Table 4, bottom half.
  foamTipHa2,

  /// Predicted RECD for **custom earmolds** on an **HA1** coupler.
  /// Bagatto 2005 Table 3, top half. This is the most common
  /// pediatric BTE configuration and the recommended default for
  /// children fitted with custom earmolds.
  earmoldHa1,

  /// Predicted RECD for **custom earmolds** on an **HA2** coupler.
  /// Bagatto 2005 Table 3, bottom half.
  earmoldHa2,
}

/// Provider of predicted Real-Ear to 2cc Coupler Difference (RECD)
/// values by age, frequency and coupling.
///
/// `getRecd(ageMonths, coupling)` returns a `Map<int, double>` keyed
/// by frequency in Hz, with the predicted RECD in dB. The frequency
/// keys are exactly the 9 frequencies tabulated by Bagatto 2005:
/// `{250, 500, 750, 1000, 1500, 2000, 3000, 4000, 6000}` Hz.
///
/// Implementations that do not have a measured RECD for a given
/// patient should return predicted values from the published tables.
/// The default implementation is [BagattoRecdProvider].
///
/// **Disclaimer.** Predicted RECDs are population averages and do
/// **not** replace an individual measurement on the patient's ear. For
/// clinically certified fittings — and for any pediatric fitting where
/// a real-ear measurement is feasible — the prescriber must obtain an
/// individual RECD and pass it to the rest of the pipeline instead of
/// relying on this provider.
abstract class RecdProvider {
  /// Returns the predicted RECD for a patient of [ageMonths] months
  /// with the given [coupling], expressed as `{frequency Hz: dB}`.
  ///
  /// ### Parameters
  ///
  /// - [ageMonths]: patient age in months. Must be `>= 0`. Values
  ///   `>= 84` (≥ 7 years) are treated as adult and resolve to the
  ///   "Adult >6y" row of the source tables.
  /// - [coupling]: coupling configuration (foam tip vs earmold,
  ///   HA1 vs HA2 coupler). See [RecdCoupling] for the four supported
  ///   variants.
  ///
  /// ### Returns
  ///
  /// A new `Map<int, double>` with one entry per frequency in
  /// `{250, 500, 750, 1000, 1500, 2000, 3000, 4000, 6000}` Hz.
  ///
  /// ### Errors
  ///
  /// Throws [ArgumentError] when [ageMonths] is negative.
  Map<int, double> getRecd(int ageMonths, RecdCoupling coupling);

  /// Returns a provider that always resolves to the adult RECD row,
  /// regardless of the [ageMonths] passed at lookup time.
  ///
  /// Use this in adult fittings where no measured RECD is available
  /// and the tabulated adult value is an acceptable approximation.
  factory RecdProvider.adultDefault() = _AdultDefaultRecdProvider;
}

/// Frequencies (Hz) tabulated in Bagatto 2005 Tables 3 and 4.
///
/// The order matches the column order in the source so the per-row
/// vectors can be indexed positionally.
const List<int> bagattoRecdFrequenciesHz = [
  250,
  500,
  750,
  1000,
  1500,
  2000,
  3000,
  4000,
  6000,
];

/// Anchor age in months for each row of the source tables.
///
/// The first 10 rows are spaced ~3 months apart in infancy/toddler
/// years and the last 4 rows are annual milestones up to "Adult >6y".
/// `_adultAgeMonths` is used as the upper anchor so any age ≥ that
/// value resolves to the adult row. The rows ">3y", "4 to 5y" and
/// "6y" are anchored at 36, 54 and 72 months respectively (lower
/// boundary of each range, except for "4 to 5y" where the midpoint is
/// used so interpolation degrades smoothly from "3y" → "4-5y" → "6y").
const int _adultAgeMonths = 84; // 7 years
const List<int> _bagattoAgesMonths = [
  1,
  4,
  7,
  10,
  13,
  16,
  19,
  22,
  25,
  34,
  36, // ">3y" row
  54, // "4 to 5y" row (midpoint)
  72, // "6y" row
  _adultAgeMonths, // "Adult >6y" row
];

/// Bagatto 2005 Table 3, top half — custom earmold + HA1 coupler.
///
/// Rows are indexed positionally against [_bagattoAgesMonths] and
/// columns positionally against [bagattoRecdFrequenciesHz]. Values
/// are in dB. Source: `.kiro_tmp/refs/dsl-v5-by-hand.txt` lines 178–195.
const List<List<double>> _earmoldHa1 = [
  // Age          250  500  750  1000 1500 2000 3000 4000 6000
  /* 1mo  */ [ 8,  12,  14,  17,  20,  20,  18,  19,  26],
  /* 4mo  */ [ 6,  10,  12,  15,  18,  18,  16,  16,  22],
  /* 7mo  */ [ 6,   9,  11,  14,  17,  18,  14,  15,  20],
  /* 10mo */ [ 5,   9,  11,  13,  16,  17,  14,  14,  19],
  /* 13mo */ [ 5,   9,  10,  13,  16,  17,  13,  13,  18],
  /* 16mo */ [ 4,   8,  10,  13,  16,  16,  13,  13,  17],
  /* 19mo */ [ 4,   8,  10,  13,  16,  16,  12,  12,  16],
  /* 22mo */ [ 4,   8,  10,  12,  15,  16,  12,  12,  16],
  /* 25mo */ [ 4,   8,  10,  12,  15,  16,  12,  12,  16],
  /* 34mo */ [ 3,   7,   9,  12,  15,  15,  11,  11,  15],
  /* >3y  */ [ 3,   7,   9,  11,  15,  15,  11,  11,  14],
  /* 4-5y */ [ 3,   7,   9,  11,  14,  15,  10,  10,  13],
  /* 6y   */ [ 3,   6,   8,  10,  14,  14,  10,   9,  13],
  /* >6y  */ [ 3,   5,   5,   7,  11,  10,   5,   5,  13],
];

/// Bagatto 2005 Table 3, bottom half — custom earmold + HA2 coupler.
/// Source: `.kiro_tmp/refs/dsl-v5-by-hand.txt` lines 198–215.
const List<List<double>> _earmoldHa2 = [
  // Age          250  500  750  1000 1500 2000 3000 4000 6000
  /* 1mo  */ [ 8,  12,  13,  16,  17,  17,  16,  17,  21],
  /* 4mo  */ [ 6,  10,  12,  14,  15,  15,  13,  14,  17],
  /* 7mo  */ [ 6,   9,  11,  13,  14,  14,  12,  12,  15],
  /* 10mo */ [ 5,   9,  10,  12,  14,  13,  11,  12,  13],
  /* 13mo */ [ 5,   9,  10,  12,  13,  13,  11,  11,  13],
  /* 16mo */ [ 4,   8,  10,  12,  13,  13,  10,  10,  12],
  /* 19mo */ [ 4,   8,  10,  12,  13,  12,  10,  10,  11],
  /* 22mo */ [ 4,   8,  10,  11,  13,  12,  10,  10,  11],
  /* 25mo */ [ 4,   8,   9,  11,  12,  12,   9,   9,  10],
  /* 34mo */ [ 3,   7,   9,  11,  12,  12,   9,   9,   9],
  /* >3y  */ [ 3,   7,   9,  10,  12,  11,   9,   9,   9],
  /* 4-5y */ [ 3,   7,   8,  10,  11,  11,   8,   8,   8],
  /* 6y   */ [ 3,   6,   8,   9,  11,  11,   7,   7,   8],
  /* >6y  */ [ 3,   5,   5,   6,   8,   6,   2,   3,   8],
];

/// Bagatto 2005 Table 4, top half — eartip + HA1 coupler.
/// Source: `.kiro_tmp/refs/dsl-v5-by-hand.txt` lines 222–239.
const List<List<double>> _foamTipHa1 = [
  // Age          250  500  750  1000 1500 2000 3000 4000 6000
  /* 1mo  */ [ 3,   8,  10,  13,  18,  19,  18,  23,  28],
  /* 4mo  */ [ 3,   7,   9,  12,  15,  16,  15,  20,  24],
  /* 7mo  */ [ 3,   6,   8,  11,  14,  15,  14,  19,  23],
  /* 10mo */ [ 3,   6,   8,  11,  13,  15,  14,  18,  22],
  /* 13mo */ [ 3,   6,   8,  11,  13,  14,  13,  17,  21],
  /* 16mo */ [ 3,   6,   8,  11,  13,  14,  13,  17,  21],
  /* 19mo */ [ 3,   6,   8,  11,  12,  14,  12,  17,  20],
  /* 22mo */ [ 3,   5,   8,  11,  12,  13,  12,  16,  20],
  /* 25mo */ [ 3,   5,   7,  10,  12,  13,  12,  16,  20],
  /* 34mo */ [ 3,   5,   7,  10,  11,  13,  11,  15,  19],
  /* >3y  */ [ 3,   5,   7,  10,  11,  13,  11,  15,  19],
  /* 4-5y */ [ 3,   5,   7,  10,  10,  12,  11,  15,  19],
  /* 6y   */ [ 3,   5,   7,  10,  10,  11,  11,  15,  19],
  /* >6y  */ [ 3,   4,   4,   6,  10,   9,  11,  15,  19],
];

/// Bagatto 2005 Table 4, bottom half — eartip + HA2 coupler.
/// Source: `.kiro_tmp/refs/dsl-v5-by-hand.txt` lines 242–259.
const List<List<double>> _foamTipHa2 = [
  // Age          250  500  750  1000 1500 2000 3000 4000 6000
  /* 1mo  */ [ 3,   8,   9,  12,  15,  15,  15,  20,  23],
  /* 4mo  */ [ 3,   7,   8,  11,  12,  13,  13,  18,  19],
  /* 7mo  */ [ 3,   6,   8,  10,  11,  12,  12,  16,  18],
  /* 10mo */ [ 3,   6,   8,  10,  11,  11,  11,  16,  17],
  /* 13mo */ [ 3,   6,   8,  10,  10,  11,  11,  15,  16],
  /* 16mo */ [ 3,   6,   7,  10,  10,  10,  10,  15,  16],
  /* 19mo */ [ 3,   6,   7,  10,   9,  10,  10,  14,  15],
  /* 22mo */ [ 3,   5,   7,  10,   9,  10,  10,  14,  15],
  /* 25mo */ [ 3,   5,   7,   9,   9,   9,   9,  14,  15],
  /* 34mo */ [ 3,   5,   7,   9,   8,   9,   9,  13,  14],
  /* >3y  */ [ 3,   5,   7,   9,   8,   9,   9,  13,  14],
  /* 4-5y */ [ 3,   5,   7,   9,   7,   8,   8,  13,  13],
  /* 6y   */ [ 3,   5,   7,   9,   7,   8,   8,  13,  13],
  /* >6y  */ [ 3,   4,   4,   5,   7,   5,   8,  13,  13],
];

/// Default [RecdProvider] implementation backed by the predicted
/// RECD tables published in Bagatto et al. (2005), reproduced in the
/// UWO "DSL v5 by Hand" pediatric protocol document.
///
/// **Tables.** Four `(age, frequency)` matrices — one per
/// [RecdCoupling] — covering 14 age anchors from 1 month through
/// "Adult >6y" and the 9 audiometric frequencies between 250 and
/// 6000 Hz.
///
/// **Interpolation.** For ages between two adjacent anchors (e.g. 5
/// months between the 4-month and 7-month rows) the provider returns
/// per-band **linear interpolation** over `ageMonths`:
///
/// ```text
///     RECD(age, f) = lower + (upper - lower) ×
///                            (age - age_lower) / (age_upper - age_lower)
/// ```
///
/// Linear interpolation is chosen because (a) the source tables are
/// already smoothed regressions of population data, (b) RECD changes
/// smoothly with ear-canal volume which itself grows monotonically
/// with age, and (c) it is exactly reproducible across implementations.
/// For ages below the first anchor (1 month) the 1-month row is used
/// verbatim. For ages at or above 84 months (7 years) the "Adult >6y"
/// row is used verbatim.
///
/// **Pure function.** `BagattoRecdProvider` holds no state and reads
/// no clock. Two calls with the same arguments produce the same map.
class BagattoRecdProvider implements RecdProvider {
  /// Builds a provider backed by the published Bagatto 2005 tables.
  const BagattoRecdProvider();

  /// Returns the predicted RECD for [ageMonths] and [coupling].
  ///
  /// ### Parameters
  ///
  /// - [ageMonths]: patient age in months. Must be `>= 0`. Values
  ///   below the 1-month anchor resolve to the 1-month row. Values
  ///   `>= 84` (≥ 7 years) resolve to the "Adult >6y" row. Values
  ///   between adjacent anchors are linearly interpolated per band.
  /// - [coupling]: coupler/coupling configuration. See [RecdCoupling].
  ///
  /// ### Returns
  ///
  /// A new `Map<int, double>` with 9 entries, one per frequency in
  /// [bagattoRecdFrequenciesHz]. Returned values are in dB.
  ///
  /// ### Errors
  ///
  /// Throws [ArgumentError] when [ageMonths] is negative.
  ///
  /// ### Example
  ///
  /// ```dart
  /// const provider = BagattoRecdProvider();
  ///
  /// // 1-month-old, custom earmold + HA1 coupler.
  /// final recd = provider.getRecd(1, RecdCoupling.earmoldHa1);
  /// assert(recd[1000] == 17.0); // Bagatto 2005 Table 3.
  ///
  /// // 5 months old → linear interp between 4mo (15.0) and 7mo (14.0)
  /// // at 1000 Hz: 15.0 + (14.0 - 15.0) × (5-4)/(7-4) ≈ 14.667 dB.
  /// final mid = provider.getRecd(5, RecdCoupling.earmoldHa1);
  /// // mid[1000] is ~14.667 dB.
  /// ```
  @override
  Map<int, double> getRecd(int ageMonths, RecdCoupling coupling) {
    if (ageMonths < 0) {
      throw ArgumentError.value(
        ageMonths,
        'ageMonths',
        'RECD lookup requires a non-negative age in months.',
      );
    }

    final table = _tableFor(coupling);

    // Adult fallback: ≥ 84 months → use the last row verbatim.
    if (ageMonths >= _adultAgeMonths) {
      return _rowToMap(table.last);
    }

    // Below or at the first anchor (1 month) → use the first row
    // verbatim. The Bagatto tables do not publish an in-utero row, so
    // newborns under 1 month inherit the 1-month estimate.
    if (ageMonths <= _bagattoAgesMonths.first) {
      return _rowToMap(table.first);
    }

    // Find the bracketing anchors `[lower, upper]` such that
    // `_bagattoAgesMonths[lowerIdx] < ageMonths <= _bagattoAgesMonths[upperIdx]`.
    int upperIdx = 0;
    for (int i = 1; i < _bagattoAgesMonths.length; i++) {
      if (_bagattoAgesMonths[i] >= ageMonths) {
        upperIdx = i;
        break;
      }
    }
    final lowerIdx = upperIdx - 1;

    // Exact hit on an anchor: skip interpolation.
    if (_bagattoAgesMonths[upperIdx] == ageMonths) {
      return _rowToMap(table[upperIdx]);
    }

    final ageLower = _bagattoAgesMonths[lowerIdx].toDouble();
    final ageUpper = _bagattoAgesMonths[upperIdx].toDouble();
    final t = (ageMonths - ageLower) / (ageUpper - ageLower);

    final lowerRow = table[lowerIdx];
    final upperRow = table[upperIdx];
    final out = <int, double>{};
    for (int j = 0; j < bagattoRecdFrequenciesHz.length; j++) {
      final lower = lowerRow[j].toDouble();
      final upper = upperRow[j].toDouble();
      out[bagattoRecdFrequenciesHz[j]] = lower + (upper - lower) * t;
    }
    return out;
  }

  /// Converts a single row of the source table into a frequency-keyed
  /// map. The list `row` must have the same length as
  /// [bagattoRecdFrequenciesHz].
  static Map<int, double> _rowToMap(List<double> row) {
    final out = <int, double>{};
    for (int j = 0; j < bagattoRecdFrequenciesHz.length; j++) {
      out[bagattoRecdFrequenciesHz[j]] = row[j].toDouble();
    }
    return out;
  }

  /// Selects the source table for the requested coupling.
  static List<List<double>> _tableFor(RecdCoupling coupling) {
    switch (coupling) {
      case RecdCoupling.foamTipHa1:
        return _foamTipHa1;
      case RecdCoupling.foamTipHa2:
        return _foamTipHa2;
      case RecdCoupling.earmoldHa1:
        return _earmoldHa1;
      case RecdCoupling.earmoldHa2:
        return _earmoldHa2;
    }
  }
}

/// Adult-only [RecdProvider] returned by [RecdProvider.adultDefault].
///
/// Always resolves to the "Adult >6y" row of the Bagatto tables,
/// regardless of [ageMonths]. Useful for adult fittings where no
/// measured RECD is available and the population-average adult value
/// is an acceptable approximation.
class _AdultDefaultRecdProvider implements RecdProvider {
  static const BagattoRecdProvider _delegate = BagattoRecdProvider();

  const _AdultDefaultRecdProvider();

  @override
  Map<int, double> getRecd(int ageMonths, RecdCoupling coupling) {
    if (ageMonths < 0) {
      throw ArgumentError.value(
        ageMonths,
        'ageMonths',
        'RECD lookup requires a non-negative age in months.',
      );
    }
    return _delegate.getRecd(_adultAgeMonths, coupling);
  }
}

/// Helper that converts an audiometric threshold in dB HL to a
/// real-ear SPL using the published RETSPL and a RECD lookup.
///
/// `SPL_realear[f] = HL[f] + RETSPL[f] + RECD[f, age, coupling]`
///
/// Frequencies present in the audiogram but absent from the RECD
/// table (Bagatto's grid skips 2500, 3500 and 8000 Hz) are resolved
/// by **log-frequency interpolation** between the two adjacent
/// tabulated frequencies. Frequencies below 250 Hz or above 6000 Hz
/// fall back to the nearest tabulated value (no extrapolation).
///
/// The class is a thin convenience around [RecdProvider.getRecd] and
/// a static RETSPL map; it is provided here so the integration tests
/// can express the conversion in a single call without re-implementing
/// the interpolation policy.
class HlToSplRealEarConverter {
  /// RETSPL values for ER-3A insert phones with HA-1 coupler /
  /// occluded ear simulator, from ANSI/ASA S3.6-2010 (R2020), Table 7.
  /// Values in dB SPL.
  ///
  /// Documented in `docs/03-investigacion/ANSI_S3.6_Reference.md`,
  /// section "Auriculares de Inserción ER-3A / EARTone 3A
  /// (Simulador de Oído Ocluido)".
  static const Map<int, double> retsplEr3aHa1 = {
    250: 14.0,
    500: 5.5,
    750: 2.0,
    1000: 0.0,
    1500: 2.0,
    2000: 3.0,
    3000: 3.5,
    4000: 5.5,
    6000: 2.0,
    8000: 0.0,
  };

  /// Audiogram bands tabulated in neither ANSI Table 7 nor Bagatto's
  /// 9-frequency grid, so they require log-frequency interpolation.
  ///
  /// 750 Hz and 1500 Hz are tabulated in both ANSI and Bagatto. 2500 Hz
  /// and 3500 Hz are tabulated in neither — they need log-frequency
  /// interpolation on both RETSPL and RECD. 8000 Hz is in ANSI but not
  /// in Bagatto, so RECD must be interpolated (capped at the 6000 Hz
  /// value per the policy below).
  static const Set<int> bandsRequiringInterpolation = {2500, 3500, 8000};

  /// Converts `HL[f]` (in dB HL) to `SPL_realear[f]` (in dB SPL) for
  /// every frequency in [audiogram] using the supplied [recdProvider]
  /// for the patient of age [ageMonths] and [coupling].
  ///
  /// ### Parameters
  ///
  /// - [audiogram]: patient audiogram with thresholds in dB HL.
  /// - [recdProvider]: provider used to resolve RECD by age and
  ///   coupling. Must agree with the transducer used at audiometry.
  /// - [ageMonths]: patient age in months.
  /// - [coupling]: coupling configuration. See [RecdCoupling].
  ///
  /// ### Returns
  ///
  /// A new `Map<int, double>` keyed by the same frequencies as
  /// `audiogram.thresholds`, with values in dB SPL.
  static Map<int, double> convert({
    required Audiogram audiogram,
    required RecdProvider recdProvider,
    required int ageMonths,
    required RecdCoupling coupling,
  }) {
    final recd = recdProvider.getRecd(ageMonths, coupling);
    final out = <int, double>{};
    for (final entry in audiogram.thresholds.entries) {
      final f = entry.key;
      final hl = entry.value;
      final retspl = lookupRetspl(f);
      final recdAtF = lookupRecd(recd, f);
      out[f] = hl + retspl + recdAtF;
    }
    return out;
  }

  /// RETSPL lookup for a frequency [f] (Hz). Falls back to log-frequency
  /// interpolation between the two adjacent ANSI-tabulated frequencies
  /// when [f] is not directly tabulated. For frequencies below the
  /// minimum or above the maximum tabulated value, returns the nearest
  /// tabulated value (no extrapolation).
  static double lookupRetspl(int f) {
    if (retsplEr3aHa1.containsKey(f)) {
      return retsplEr3aHa1[f]!;
    }
    return _logInterpolate(f, retsplEr3aHa1);
  }

  /// RECD lookup for a frequency [f] (Hz) within an already-resolved
  /// RECD map [recd]. Same interpolation policy as [lookupRetspl].
  static double lookupRecd(Map<int, double> recd, int f) {
    if (recd.containsKey(f)) {
      return recd[f]!;
    }
    return _logInterpolate(f, recd);
  }

  /// Log-frequency interpolation of [f] (Hz) on a sorted set of
  /// `(frequency → value)` anchors. Returns the nearest anchor when
  /// [f] is outside the anchor range.
  static double _logInterpolate(int f, Map<int, double> anchors) {
    final keys = anchors.keys.toList()..sort();
    if (f <= keys.first) return anchors[keys.first]!;
    if (f >= keys.last) return anchors[keys.last]!;
    int upper = keys.length - 1;
    for (int i = 1; i < keys.length; i++) {
      if (keys[i] >= f) {
        upper = i;
        break;
      }
    }
    final lower = upper - 1;
    final fLower = keys[lower];
    final fUpper = keys[upper];
    final logF = math.log(f.toDouble());
    final logL = math.log(fLower.toDouble());
    final logU = math.log(fUpper.toDouble());
    final t = (logF - logL) / (logU - logL);
    final vLower = anchors[fLower]!;
    final vUpper = anchors[fUpper]!;
    return vLower + (vUpper - vLower) * t;
  }
}

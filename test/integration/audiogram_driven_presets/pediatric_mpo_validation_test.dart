// Spec: audiogram-driven-presets · Wave 11, task 14.3.
//
// Tramo 2 — Pediatric MPO formula validation (end-to-end).
//
// Validates Requirement 15.7: for any patient with `age < 18`, the MPO
// profile produced by the full audiogram-driven derivation chain
// (`BundleBuilder.buildFromAudiogram`) satisfies, for every band:
//
//   1. `bundle.mpoProfileDbSpl[i] ≤ 110 dB SPL`     (pediatric ceiling)
//   2. `bundle.mpoProfileDbSpl[i] == clamp(min(UCL[i] - 10, 110), 80, 132)`
//      within ±0.1 dB SPL                             (formula match)
//
// where `UCL[i] = 100 + 0.15 × clamp(HL[i], 0, 120)` is the regression
// from `UclEstimator` (NAL-NL2). The final clamp `[80, 132]` is the
// operative range of the bundle's MPO field, so the test compares
// against the clamped expected value.
//
// ## Difference vs `mpo_deriver_test.dart`
//
// `mpo_deriver_test.dart` exercises `MpoDeriver.derive(...)` in
// isolation against a hand-built UCL list. This file is a Tramo 2
// **clinical end-to-end** validation: it drives a real audiogram into
// `BundleBuilder.buildFromAudiogram(...)` with a `PatientProfile` whose
// `ageYears < 18` and asserts the property on the bundle's
// `mpoProfileDbSpl` field. The chain exercised is therefore
// `Audiogram → UclEstimator → MpoDeriver → AudiogramDrivenBundle`,
// which is the actual production path used by the
// `AmplificationBloc`.
//
// ## Test inventory
//
//   1. Bisgaard N1–N7 + S1–S3 × ages {5, 10, 15, 17}     → 10 × 4 = 40 cases
//   2. 100+ pseudo-random audiograms × random age < 18   → 100 cases
//   3. Boundary ages: 0 (newborn) and 17 (last pediatric year)
//   4. Adult cutoff: age = 18 → MPO is **not** capped at 110, may reach
//      values up to 132 dB SPL when HL is very high
//
// PatientProfile.ageYears is typed as `int?`, so the "17.999" boundary
// from the task description is not representable in Dart and is
// covered by `age = 17` (closest integer below 18).
//
// Validates: Requirement 15.7
//
// References:
//  - Bisgaard, Vlaming & Dahlquist (2010), "Standard Audiograms for
//    the IEC 60118-15 Measurement Procedure", *Trends in Amplification*
//    14(2):113–120.
//  - DSL v5 — Bagatto et al. (2005), *Trends in Amplification*
//    9(4):199–226 (pediatric MPO ceiling at 110 dB SPL).
//  - AAA Pediatric Amplification Guidelines, Bagatto et al. (2016).
//  - Project doc:
//    `docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md`
//    §6.4 "De UCL a MPO" and §6.5 "Por qué un MPO fijo de 110 dB SPL
//    es inseguro para algunos pacientes".

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:hearing_aid_app/domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/bundle_builder.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/mpo_deriver.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/operating_mode.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/patient_profile.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';

// ─── Bisgaard audiogram fixtures (N1–N7 + S1–S3) ────────────────────────────
// Mirrored from `test/domain/audiogram_driven_presets/ucl_estimator_test.dart`
// to keep this file standalone and avoid coupling integration tests with
// unit-level fixtures.

const Map<int, double> _bisgaardN1 = {
  250: 20, 500: 20, 750: 20, 1000: 25, 1500: 25,
  2000: 25, 2500: 30, 3000: 30, 3500: 30, 4000: 35, 6000: 35, 8000: 35,
};

const Map<int, double> _bisgaardN2 = {
  250: 20, 500: 20, 750: 25, 1000: 30, 1500: 35,
  2000: 40, 2500: 45, 3000: 50, 3500: 50, 4000: 55, 6000: 55, 8000: 60,
};

const Map<int, double> _bisgaardN3 = {
  250: 35, 500: 35, 750: 35, 1000: 40, 1500: 45,
  2000: 50, 2500: 55, 3000: 55, 3500: 55, 4000: 60, 6000: 60, 8000: 65,
};

const Map<int, double> _bisgaardN4 = {
  250: 35, 500: 35, 750: 40, 1000: 45, 1500: 50,
  2000: 55, 2500: 60, 3000: 65, 3500: 65, 4000: 70, 6000: 75, 8000: 80,
};

const Map<int, double> _bisgaardN5 = {
  250: 55, 500: 55, 750: 55, 1000: 55, 1500: 55,
  2000: 60, 2500: 65, 3000: 70, 3500: 75, 4000: 80, 6000: 80, 8000: 80,
};

const Map<int, double> _bisgaardN6 = {
  250: 65, 500: 65, 750: 65, 1000: 70, 1500: 70,
  2000: 70, 2500: 75, 3000: 75, 3500: 80, 4000: 85, 6000: 85, 8000: 90,
};

const Map<int, double> _bisgaardN7 = {
  250: 75, 500: 80, 750: 80, 1000: 85, 1500: 85,
  2000: 90, 2500: 95, 3000: 100, 3500: 100, 4000: 105, 6000: 105, 8000: 110,
};

const Map<int, double> _bisgaardS1 = {
  250: 10, 500: 10, 750: 15, 1000: 20, 1500: 30,
  2000: 40, 2500: 50, 3000: 55, 3500: 55, 4000: 60, 6000: 65, 8000: 65,
};

const Map<int, double> _bisgaardS2 = {
  250: 10, 500: 10, 750: 10, 1000: 15, 1500: 30,
  2000: 50, 2500: 60, 3000: 70, 3500: 70, 4000: 75, 6000: 80, 8000: 80,
};

const Map<int, double> _bisgaardS3 = {
  250: 10, 500: 10, 750: 10, 1000: 10, 1500: 15,
  2000: 50, 2500: 65, 3000: 80, 3500: 90, 4000: 100, 6000: 110, 8000: 120,
};

const Map<String, Map<int, double>> _bisgaardFixtures = {
  'N1': _bisgaardN1,
  'N2': _bisgaardN2,
  'N3': _bisgaardN3,
  'N4': _bisgaardN4,
  'N5': _bisgaardN5,
  'N6': _bisgaardN6,
  'N7': _bisgaardN7,
  'S1': _bisgaardS1,
  'S2': _bisgaardS2,
  'S3': _bisgaardS3,
};

// ─── Constants ──────────────────────────────────────────────────────────────

/// Tolerance for the formula-match check (Requirement 15.7).
const double _toleranceDbSpl = 0.1;

/// Pediatric absolute MPO ceiling, in dB SPL. DSL v5 / AAA.
const double _pediatricCeilingDbSpl = 110.0;

/// Operative MPO floor of the bundle, in dB SPL.
const double _bundleMpoFloorDbSpl = AudiogramDrivenBundle.mpoMinDbSpl;

/// Operative MPO ceiling of the bundle, in dB SPL.
const double _bundleMpoCeilingDbSpl = AudiogramDrivenBundle.mpoMaxDbSpl;

// ─── Helpers ────────────────────────────────────────────────────────────────

/// Builds a real `Audiogram` entity from a `{frequency Hz → HL dB}` map.
Audiogram _audiogramFrom(Map<int, double> thresholds) =>
    Audiogram(thresholds: Map<int, double>.from(thresholds));

/// Computes the expected pediatric MPO per band end-to-end, mirroring
/// `UclEstimator.estimate` followed by `MpoDeriver.derive` with the
/// pediatric rule applied:
///
///   UCL[f]      = 100 + 0.15 × clamp(HL[f], 0, 120)
///   raw_MPO[f]  = min(UCL[f] - 10, 110)             (pediatric)
///   final[f]    = clamp(raw_MPO[f], 80, 132)        (bundle range)
///
/// The function reads thresholds via `Audiogram.standardFrequencies` so
/// the band order matches the bundle.
List<double> _expectedPediatricMpo(Audiogram audiogram) {
  return [
    for (final f in Audiogram.standardFrequencies)
      _expectedMpoForBand(audiogram.thresholds[f] ?? 0.0, isPediatric: true),
  ];
}

/// Same as `_expectedPediatricMpo` but for the adult rule
/// (`MPO[f] = min(UCL[f] - 5, 132)`). Used in the adult-cutoff test
/// to assert the cap is **not** lowered to 110 when `ageYears == 18`.
List<double> _expectedAdultMpo(Audiogram audiogram) {
  return [
    for (final f in Audiogram.standardFrequencies)
      _expectedMpoForBand(audiogram.thresholds[f] ?? 0.0, isPediatric: false),
  ];
}

double _expectedMpoForBand(double hl, {required bool isPediatric}) {
  // 1. UCL formula with HL clamped to [0, 120] dB HL.
  final clampedHl = hl.clamp(0.0, 120.0).toDouble();
  final ucl = 100.0 + 0.15 * clampedHl;

  // 2. Subtract safety margin and apply absolute ceiling.
  final safetyMargin = isPediatric
      ? MpoDeriver.pediatricSafetyMarginDb
      : MpoDeriver.adultSafetyMarginDb;
  final absoluteCeiling = isPediatric
      ? MpoDeriver.pediatricCeilingDbSpl
      : MpoDeriver.adultCeilingDbSpl;
  final raw = ucl - safetyMargin;
  final cappedByAbsolute = raw < absoluteCeiling ? raw : absoluteCeiling;

  // 3. Final clamp to the bundle's [80, 132] operative range.
  return cappedByAbsolute.clamp(_bundleMpoFloorDbSpl, _bundleMpoCeilingDbSpl);
}

/// Generates a pseudo-random valid audiogram with HL ∈ [-10, 120] dB HL
/// for every standard frequency, using the supplied [random] generator.
///
/// The full HL range is intentional: it exercises the boundary clamps
/// inside `UclEstimator` (HL clamped to `[0, 120]`) and inside
/// `BundleBuilder._validateAudiogram` (HL accepted in `[-10, 120]`).
Audiogram _randomAudiogram(math.Random random) {
  return Audiogram(thresholds: {
    for (final f in Audiogram.standardFrequencies)
      // Range: 0–130 → shift to [-10, 120] dB HL.
      f: (random.nextInt(131) - 10).toDouble(),
  });
}

/// Asserts the pediatric-MPO property on a freshly built bundle.
///
/// For every band:
///   - `bundle.mpoProfileDbSpl[i] ≤ 110.0`
///   - `|bundle.mpoProfileDbSpl[i] - expected[i]| ≤ 0.1 dB SPL`
/// where `expected[i]` is computed by `_expectedPediatricMpo`.
void _expectPediatricMpoMatches({
  required AudiogramDrivenBundle bundle,
  required Audiogram audiogram,
  required String label,
}) {
  expect(bundle.mpoProfileDbSpl.length, AudiogramDrivenBundle.bandCount,
      reason: '$label: MPO array must have ${AudiogramDrivenBundle.bandCount} bands');

  final expected = _expectedPediatricMpo(audiogram);

  for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
    final actual = bundle.mpoProfileDbSpl[i];
    final freq = Audiogram.standardFrequencies[i];

    // (1) Pediatric ceiling.
    expect(
      actual,
      lessThanOrEqualTo(_pediatricCeilingDbSpl),
      reason: '$label · band $i ($freq Hz): MPO=$actual must be ≤ '
          '$_pediatricCeilingDbSpl dB SPL (pediatric ceiling).',
    );

    // (2) Formula match within ±0.1 dB SPL.
    expect(
      actual,
      closeTo(expected[i], _toleranceDbSpl),
      reason: '$label · band $i ($freq Hz): MPO=$actual deviates from '
          'expected=${expected[i]} by more than $_toleranceDbSpl dB SPL '
          '(HL=${audiogram.thresholds[freq]}).',
    );
  }
}

void main() {
  late BundleBuilder builder;

  setUp(() {
    // Real BundleBuilder with default GainPrescriberNL3. The MPO chain
    // exercised here (Audiogram → UclEstimator → MpoDeriver) is a pure
    // computation independent from the gain/compression delegates.
    builder = BundleBuilder();
  });

  group('14.3 Pediatric MPO — Bisgaard N1–N7 + S1–S3 × ages {5,10,15,17}', () {
    const pediatricAges = <int>[5, 10, 15, 17];

    for (final entry in _bisgaardFixtures.entries) {
      final fixtureName = entry.key;
      final thresholds = entry.value;

      for (final age in pediatricAges) {
        test(
          'Bisgaard $fixtureName + age=$age years: '
          'MPO ≤ 110 and matches min(UCL-10, 110) within ±0.1 dB SPL',
          () {
            final audiogram = _audiogramFrom(thresholds);
            final bundle = builder.buildFromAudiogram(
              audiogram,
              profile: PatientProfile(experienceMonths: 24, ageYears: age),
              mode: PrescriptionMode.quiet,
              derivedAt: DateTime.utc(2026, 6, 3, 10, 0, 0),
            );

            _expectPediatricMpoMatches(
              bundle: bundle,
              audiogram: audiogram,
              label: 'Bisgaard $fixtureName + age=$age',
            );
          },
        );
      }
    }
  });

  group('14.3 Pediatric MPO — 100+ synthetic audiograms × random age < 18',
      () {
    /// Number of synthetic audiograms to validate. Covers the implicit
    /// "≥ 100 audiograms" requirement of Tramo 2.
    const int audiogramCount = 120;

    /// Fixed seed for deterministic, reproducible failures across CI
    /// runs.
    const int randomSeed = 0x14030001;

    test(
      'all $audiogramCount audiograms × age ∈ [0, 17]: '
      'every band ≤ 110 and within ±0.1 dB SPL of formula',
      () {
        final random = math.Random(randomSeed);

        for (var k = 0; k < audiogramCount; k++) {
          final audiogram = _randomAudiogram(random);
          // Random pediatric age in [0, 17] inclusive.
          final age = random.nextInt(18);

          final bundle = builder.buildFromAudiogram(
            audiogram,
            profile: PatientProfile(experienceMonths: 1, ageYears: age),
            mode: PrescriptionMode.quiet,
            derivedAt: DateTime.utc(2026, 6, 3, 10, 0, 0),
          );

          _expectPediatricMpoMatches(
            bundle: bundle,
            audiogram: audiogram,
            label: 'synthetic#$k (age=$age, seed=$randomSeed)',
          );
        }
      },
    );

    test(
      'synthetic audiograms with ageYears=null fall back to ADULT rule '
      '(no pediatric ceiling at 110)',
      () {
        // Sanity: the same generator + null age must not be silently
        // treated as pediatric. We only check that the bundle uses the
        // adult formula; the adult upper bound is asserted in the
        // dedicated "Adult cutoff" group below.
        final random = math.Random(0xADC0DE);
        for (var k = 0; k < 20; k++) {
          final audiogram = _randomAudiogram(random);
          final bundle = builder.buildFromAudiogram(
            audiogram,
            profile: const PatientProfile(experienceMonths: 24),
            mode: PrescriptionMode.quiet,
            derivedAt: DateTime.utc(2026, 6, 3, 10, 0, 0),
          );

          final expected = _expectedAdultMpo(audiogram);
          for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
            expect(bundle.mpoProfileDbSpl[i], closeTo(expected[i], 0.1),
                reason: 'null ageYears must use the adult rule, band $i.');
          }
        }
      },
    );
  });

  group('14.3 Pediatric MPO — boundary ages', () {
    test(
      'age=0 (newborn): MPO ≤ 110 and matches pediatric formula',
      () {
        // Use a moderate flat 50 dB HL audiogram so the formula clearly
        // distinguishes pediatric (cap at 110) from adult (cap at 132).
        final audiogram = Audiogram(thresholds: {
          for (final f in Audiogram.standardFrequencies) f: 50.0,
        });
        final bundle = builder.buildFromAudiogram(
          audiogram,
          profile: const PatientProfile(experienceMonths: 0, ageYears: 0),
          mode: PrescriptionMode.quiet,
          derivedAt: DateTime.utc(2026, 6, 3, 10, 0, 0),
        );

        _expectPediatricMpoMatches(
          bundle: bundle,
          audiogram: audiogram,
          label: 'age=0 newborn',
        );
      },
    );

    test(
      'age=17 (last pediatric year): MPO ≤ 110 and matches formula',
      () {
        // Use Bisgaard N7 (profound flat) — the case where the pediatric
        // ceiling is most likely to engage. UCL ranges from ~111 to 118,
        // so UCL-10 ranges from ~101 to 108, all under the 110 cap and
        // never reaching 132. Still, the property must hold.
        final audiogram = _audiogramFrom(_bisgaardN7);
        final bundle = builder.buildFromAudiogram(
          audiogram,
          profile: const PatientProfile(experienceMonths: 24, ageYears: 17),
          mode: PrescriptionMode.quiet,
          derivedAt: DateTime.utc(2026, 6, 3, 10, 0, 0),
        );

        _expectPediatricMpoMatches(
          bundle: bundle,
          audiogram: audiogram,
          label: 'age=17 (Bisgaard N7)',
        );
      },
    );

    test(
      'PatientProfile.ageYears is typed as int — fractional ages '
      'like 17.999 are not representable; documented in test header',
      () {
        // This assertion guards the documented limitation: if
        // PatientProfile ever exposes a fractional age (double), the
        // task description's "17.999" boundary must be added as a
        // dedicated test case at that moment.
        const profile = PatientProfile(experienceMonths: 24, ageYears: 17);
        expect(profile.ageYears, isA<int>());
      },
    );
  });

  group('14.3 Adult cutoff — age=18 → MPO is NOT capped at 110', () {
    test(
      'age=18 + severe HL audiogram: at least one MPO band exceeds 110',
      () {
        // Build a flat HL=120 dB audiogram. UCL = 100 + 0.15 × 120 = 118
        // → adult MPO = min(118-5, 132) = 113. Pediatric would be
        // min(118-10, 110) = 108. The 113 vs 108 gap proves the bundle
        // is using the adult formula.
        final audiogram = Audiogram(thresholds: {
          for (final f in Audiogram.standardFrequencies) f: 120.0,
        });
        final bundle = builder.buildFromAudiogram(
          audiogram,
          profile: const PatientProfile(experienceMonths: 24, ageYears: 18),
          mode: PrescriptionMode.quiet,
          derivedAt: DateTime.utc(2026, 6, 3, 10, 0, 0),
        );

        // Every band must match the adult formula within ±0.1 dB SPL.
        final expected = _expectedAdultMpo(audiogram);
        for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
          expect(
            bundle.mpoProfileDbSpl[i],
            closeTo(expected[i], _toleranceDbSpl),
            reason: 'age=18 must use adult rule, band $i.',
          );
        }

        // And at least one band must be strictly above the pediatric
        // ceiling, proving it is not silently capped at 110.
        expect(
          bundle.mpoProfileDbSpl.any((mpo) => mpo > _pediatricCeilingDbSpl),
          isTrue,
          reason:
              'With HL=120 across all bands, adult MPO = 113 dB SPL must '
              'exceed the pediatric ceiling of $_pediatricCeilingDbSpl dB SPL.',
        );

        // Sanity: no value should exceed the bundle's hard ceiling.
        for (final mpo in bundle.mpoProfileDbSpl) {
          expect(mpo, lessThanOrEqualTo(_bundleMpoCeilingDbSpl));
        }
      },
    );

    test(
      'age=18 (exactly adult boundary): pediatric formula does NOT apply',
      () {
        // Same N7 fixture used in the pediatric boundary test, but with
        // age=18 → adult rule. The MPO values must equal min(UCL-5,132)
        // not min(UCL-10,110).
        final audiogram = _audiogramFrom(_bisgaardN7);
        final bundle = builder.buildFromAudiogram(
          audiogram,
          profile: const PatientProfile(experienceMonths: 24, ageYears: 18),
          mode: PrescriptionMode.quiet,
          derivedAt: DateTime.utc(2026, 6, 3, 10, 0, 0),
        );

        final expectedAdult = _expectedAdultMpo(audiogram);
        final expectedPed = _expectedPediatricMpo(audiogram);

        for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
          expect(bundle.mpoProfileDbSpl[i], closeTo(expectedAdult[i], 0.1),
              reason: 'age=18 must produce adult MPO at band $i.');
        }

        // Adult and pediatric profiles produce different values on at
        // least one band for N7 (otherwise the test is vacuous).
        var diverged = false;
        for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
          if ((expectedAdult[i] - expectedPed[i]).abs() > 0.5) {
            diverged = true;
            break;
          }
        }
        expect(diverged, isTrue,
            reason: 'Bisgaard N7 must produce different adult vs '
                'pediatric MPO on at least one band.');
      },
    );
  });

  group('14.3 OperatingMode independence', () {
    test(
      'pediatric formula holds in BOTH diagnostic and amplifier mode',
      () {
        // The MPO chain must be invariant w.r.t. OperatingMode and
        // gainScale: per Req 13.4 the gainScale only affects gainsDb,
        // never MPO. This test covers the contract end-to-end.
        final audiogram = _audiogramFrom(_bisgaardN5);
        const child = PatientProfile(experienceMonths: 6, ageYears: 8);

        final diag = builder.buildFromAudiogram(
          audiogram,
          profile: child,
          mode: PrescriptionMode.quiet,
          operatingMode: OperatingMode.diagnostic,
          derivedAt: DateTime.utc(2026, 6, 3, 10, 0, 0),
        );

        final amp = builder.buildFromAudiogram(
          audiogram,
          profile: child,
          mode: PrescriptionMode.quiet,
          operatingMode: OperatingMode.amplifier,
          gainScale: 0.40,
          derivedAt: DateTime.utc(2026, 6, 3, 10, 0, 0),
        );

        _expectPediatricMpoMatches(
          bundle: diag,
          audiogram: audiogram,
          label: 'diagnostic mode (Bisgaard N5, age=8)',
        );
        _expectPediatricMpoMatches(
          bundle: amp,
          audiogram: audiogram,
          label: 'amplifier mode gainScale=0.40 (Bisgaard N5, age=8)',
        );

        // Cross-mode bit-equality of mpoProfileDbSpl: the MPO must be
        // identical regardless of OperatingMode / gainScale.
        for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
          expect(amp.mpoProfileDbSpl[i], equals(diag.mpoProfileDbSpl[i]),
              reason:
                  'MPO at band $i must be invariant w.r.t. OperatingMode.');
        }
      },
    );
  });
}

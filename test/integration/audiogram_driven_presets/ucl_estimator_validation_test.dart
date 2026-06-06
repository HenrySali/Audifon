// Spec: audiogram-driven-presets · Wave 14, task 14.4.
//
// UclEstimator validation at scale (≥ 100 audiogramas pseudoaleatorios).
//
// Purpose:
//   Tramo 2 (API → Prescription) requires that the regression
//   `UCL = 100 + 0.15 × HL` (with HL clamped to [0, 120] dB HL) be
//   reproduced bit-tight (±0.01 dB SPL) across a *broad* sample of
//   audiograms — not just the 10 Bisgaard fixtures already covered by
//   the unit tests in `test/domain/audiogram_driven_presets/
//   ucl_estimator_test.dart`.
//
// The unit test file validates the formula on hand-picked Bisgaard
// audiograms (N1–N7 + S1–S3) and explicit boundary values. This file
// adds *volume*: 100+ pseudo-random audiograms generated with a fixed
// seed (`Random(42)`), drawn from HL ∈ [-10, 130] dB HL per band so
// the clamp at 0 and 120 dB HL is exercised on both ends. Determinism
// is asserted by re-running the same generator twice and comparing
// outputs bit-exact.
//
// Requirements: 15.8.
//
// References:
//   - design.md §"Tramo 2: Audiogram → Prescription" (UCL/MPO derivation).
//   - lib/domain/audiogram_driven_presets/ucl_estimator.dart (impl).
//   - test/domain/audiogram_driven_presets/ucl_estimator_test.dart
//     (Bisgaard + boundary unit coverage; this file deliberately does
//     not duplicate it).
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/ucl_estimator.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';

/// Tolerance for the formula `UCL = 100 + 0.15 × HL_clamped`.
///
/// Acceptance criterion in tasks.md §14.4 is ±0.01 dB SPL. The
/// estimator is pure arithmetic on `double`s, so the actual deviation
/// from the analytical expectation is bounded by IEEE-754 rounding —
/// well under 1e-12 dB SPL — but we hold ourselves to the spec value
/// so a future refactor that adds e.g. a `toStringAsFixed` round-trip
/// would be flagged.
const double _uclToleranceDbSpl = 0.01;

/// Seed for the pseudo-random audiogram generator.
///
/// Fixed so the test is reproducible across runs and CI machines.
const int _seed = 42;

/// Number of audiograms in the main random sweep (must be ≥ 100).
const int _numAudiograms = 128;

/// Range of HL values fed to the generator, in dB HL.
///
/// Deliberately wider than the clinically useful range `[0, 120]` so
/// the clamp is exercised at both ends. Below 0 and above 120 the
/// estimator must clamp before applying the regression.
const double _hlMinDbHl = -10.0;
const double _hlMaxDbHl = 130.0;

/// Reference frequency at which `measuredUcl` overrides the formula
/// in §"measuredUcl partial" subgroup.
const int _measuredFrequencyHz = 1000;

/// Reference UCL value passed via `measuredUcl` for the partial
/// override scenario.
const double _measuredUclDbSpl = 95.0;

/// Generates a pseudo-random audiogram drawn uniformly from
/// `[_hlMinDbHl, _hlMaxDbHl]` per band.
///
/// Uses the supplied [random] so the caller controls determinism.
Audiogram _randomAudiogram(Random random) {
  const span = _hlMaxDbHl - _hlMinDbHl;
  return Audiogram(thresholds: {
    for (final f in Audiogram.standardFrequencies)
      f: _hlMinDbHl + random.nextDouble() * span,
  });
}

/// Analytical UCL the estimator should produce for a given raw HL.
///
/// Mirrors the public contract of [UclEstimator.estimate]:
/// `UCL = 100 + 0.15 × clamp(HL, 0, 120)`.
double _expectedUcl(double rawHl) {
  final clamped = rawHl.clamp(0.0, 120.0);
  return 100.0 + 0.15 * clamped;
}

void main() {
  group('UclEstimator — formula validation across ≥ 100 audiograms', () {
    test(
      'random sweep ($_numAudiograms audiograms, HL ∈ [$_hlMinDbHl, $_hlMaxDbHl] dB HL): '
      '|ucl[i] - (100 + 0.15 × clamp(HL[i], 0, 120))| ≤ $_uclToleranceDbSpl dB SPL',
      () {
        final random = Random(_seed);
        for (int n = 0; n < _numAudiograms; n++) {
          final audiogram = _randomAudiogram(random);
          final ucl = UclEstimator.estimate(audiogram);

          expect(
            ucl.length,
            equals(Audiogram.standardFrequencies.length),
            reason: 'Audiogram #$n: estimator must return one UCL per band',
          );

          int i = 0;
          for (final f in Audiogram.standardFrequencies) {
            final rawHl = audiogram.thresholds[f]!;
            final expected = _expectedUcl(rawHl);
            expect(
              ucl[i],
              closeTo(expected, _uclToleranceDbSpl),
              reason:
                  'Audiogram #$n, band $f Hz (index $i): HL=$rawHl, '
                  'expected UCL=$expected, got UCL=${ucl[i]}',
            );
            i++;
          }
        }
      },
    );

    test('extreme boundary clamp (HL = -100 dB HL → UCL = 100 dB SPL)', () {
      final audiogram = Audiogram(thresholds: {
        for (final f in Audiogram.standardFrequencies) f: -100.0,
      });
      final ucl = UclEstimator.estimate(audiogram);
      for (final value in ucl) {
        expect(value, closeTo(100.0, _uclToleranceDbSpl));
      }
    });

    test('extreme boundary clamp (HL = 200 dB HL → UCL = 118 dB SPL)', () {
      final audiogram = Audiogram(thresholds: {
        for (final f in Audiogram.standardFrequencies) f: 200.0,
      });
      final ucl = UclEstimator.estimate(audiogram);
      for (final value in ucl) {
        expect(value, closeTo(118.0, _uclToleranceDbSpl));
      }
    });

    test('mid-range value (HL = 60 dB HL → UCL = 109 dB SPL)', () {
      final audiogram = Audiogram(thresholds: {
        for (final f in Audiogram.standardFrequencies) f: 60.0,
      });
      final ucl = UclEstimator.estimate(audiogram);
      for (final value in ucl) {
        expect(value, closeTo(109.0, _uclToleranceDbSpl));
      }
    });

    test('typical mild loss (HL = 30 dB HL → UCL = 104.5 dB SPL)', () {
      final audiogram = Audiogram(thresholds: {
        for (final f in Audiogram.standardFrequencies) f: 30.0,
      });
      final ucl = UclEstimator.estimate(audiogram);
      for (final value in ucl) {
        expect(value, closeTo(104.5, _uclToleranceDbSpl));
      }
    });
  });

  group(
    'UclEstimator — measuredUcl partial override (random sweep, '
    '$_measuredFrequencyHz Hz pinned to $_measuredUclDbSpl dB SPL)',
    () {
      const numAudiograms = 64; // ≥ 50 per task spec
      // Index of `_measuredFrequencyHz` inside `standardFrequencies`.
      // `Audiogram.standardFrequencies` is a `const` list, so this is
      // computed once at startup.
      final measuredIndex =
          Audiogram.standardFrequencies.indexOf(_measuredFrequencyHz);

      test(
        '`measuredUcl` overrides the formula at $_measuredFrequencyHz Hz '
        'and leaves the rest of the bands on the regression '
        '(across $numAudiograms audiogramas)',
        () {
          // Use a different seed so the `measuredUcl` sweep does not
          // share state with the main sweep above. Determinism is
          // still preserved (asserted in the determinism group).
          final random = Random(_seed + 1);
          const measuredUcl = <int, double>{
            _measuredFrequencyHz: _measuredUclDbSpl,
          };

          for (int n = 0; n < numAudiograms; n++) {
            final audiogram = _randomAudiogram(random);
            final ucl = UclEstimator.estimate(
              audiogram,
              measuredUcl: measuredUcl,
            );

            expect(ucl.length, equals(Audiogram.standardFrequencies.length));

            // The pinned band must equal the measured value verbatim
            // (no clamp, no formula).
            expect(
              ucl[measuredIndex],
              equals(_measuredUclDbSpl),
              reason:
                  'Audiogram #$n: measured band $_measuredFrequencyHz Hz '
                  '(index $measuredIndex) must take the value supplied via '
                  '`measuredUcl`, not the regression.',
            );

            // Every other band must follow the regression with HL
            // clamped to [0, 120].
            for (int i = 0; i < Audiogram.standardFrequencies.length; i++) {
              if (i == measuredIndex) continue;
              final f = Audiogram.standardFrequencies[i];
              final rawHl = audiogram.thresholds[f]!;
              final expected = _expectedUcl(rawHl);
              expect(
                ucl[i],
                closeTo(expected, _uclToleranceDbSpl),
                reason:
                    'Audiogram #$n, band $f Hz (index $i): expected '
                    'regression UCL=$expected for HL=$rawHl, got ${ucl[i]}',
              );
            }
          }
        },
      );
    },
  );

  group('UclEstimator — determinism', () {
    test(
      'same seed ($_seed) → bit-exact UCLs across two independent runs '
      '($_numAudiograms audiograms)',
      () {
        List<List<double>> sweep() {
          final random = Random(_seed);
          final out = <List<double>>[];
          for (int n = 0; n < _numAudiograms; n++) {
            final audiogram = _randomAudiogram(random);
            out.add(UclEstimator.estimate(audiogram));
          }
          return out;
        }

        final runA = sweep();
        final runB = sweep();

        expect(runA.length, equals(_numAudiograms));
        expect(runB.length, equals(_numAudiograms));
        for (int n = 0; n < _numAudiograms; n++) {
          // `equals` on `List<double>` is bit-exact (no tolerance).
          // Any drift here would mean the estimator is not pure or
          // the generator picked up nondeterministic state.
          expect(
            runB[n],
            equals(runA[n]),
            reason:
                'Audiogram #$n: UCLs must be bit-exact across runs '
                'with the same seed.',
          );
        }
      },
    );

    test(
      'same seed (${_seed + 1}) → bit-exact UCLs in the measuredUcl '
      'partial-override scenario',
      () {
        const numAudiograms = 64;
        const measuredUcl = <int, double>{
          _measuredFrequencyHz: _measuredUclDbSpl,
        };

        List<List<double>> sweep() {
          final random = Random(_seed + 1);
          final out = <List<double>>[];
          for (int n = 0; n < numAudiograms; n++) {
            final audiogram = _randomAudiogram(random);
            out.add(UclEstimator.estimate(
              audiogram,
              measuredUcl: measuredUcl,
            ));
          }
          return out;
        }

        final runA = sweep();
        final runB = sweep();

        for (int n = 0; n < numAudiograms; n++) {
          expect(runB[n], equals(runA[n]));
        }
      },
    );
  });
}

// Spec: audiogram-driven-presets · Wave 10, task 13.2.
//
// AudiometryResult JSON round-trip (Tramo 1: Audiograma → API).
//
// Pure-JSON round-trip: AudiometryResult.toJson() → AudiometryResult.fromJson()
// without Hive, without DSP. Verifies that every field is preserved bit-exact
// through `jsonEncode`/`jsonDecode`, including:
//
//   * Top-level metadata: testedAt, calibrationMac, calibrationDate,
//     retest1000Diff (incl. > 5 dB edge), patientAlias.
//   * Per-frequency thresholds (`FrequencyThresholdHL`) including the
//     `outOfRange` and `normalLimit` flags, both true and false.
//   * The schema_version key emitted by `toJson()` matches the static
//     constant declared on the model.
//   * Timestamp precision: round-trip ISO-8601 strings are accurate to
//     the millisecond in UTC for both `testedAt` and `calibrationDate`.
//
// The 10 Bisgaard audiograms (N1–N7 + S1–S3) from
// Bisgaard, Vlaming & Dahlquist (2010), *Trends in Amplification*
// 14(2):113–120 are exercised end-to-end so any future format change is
// caught against the same fixture set used by the rest of the spec.
//
// Validates: Requirements 15.3.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:hearing_aid_app/audiometry/models/audiometry_result.dart';
import 'package:hearing_aid_app/audiometry/models/frequency_threshold_hl.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';

// ─── Bisgaard fixtures ──────────────────────────────────────────────────────
//
// Mirror of the values used by
//   * test/integration/audiogram_driven_presets/audiogram_persistence_bitexact_test.dart
//   * test/domain/audiogram_driven_presets/ucl_estimator_test.dart
//
// Keeping all three in sync is intentional — any correction to the
// reference values must propagate to every consumer.

/// N1: mild flat loss (~20 dB HL across all bands).
const Map<int, double> _bisgaardN1 = {
  250: 20, 500: 20, 750: 20, 1000: 25, 1500: 25,
  2000: 25, 2500: 30, 3000: 30, 3500: 30, 4000: 35,
  6000: 35, 8000: 35,
};

/// N2: mild sloping loss.
const Map<int, double> _bisgaardN2 = {
  250: 20, 500: 20, 750: 25, 1000: 30, 1500: 35,
  2000: 40, 2500: 45, 3000: 50, 3500: 50, 4000: 55,
  6000: 55, 8000: 60,
};

/// N3: moderate flat loss.
const Map<int, double> _bisgaardN3 = {
  250: 35, 500: 35, 750: 35, 1000: 40, 1500: 45,
  2000: 50, 2500: 55, 3000: 55, 3500: 55, 4000: 60,
  6000: 60, 8000: 65,
};

/// N4: moderate sloping loss.
const Map<int, double> _bisgaardN4 = {
  250: 35, 500: 35, 750: 40, 1000: 45, 1500: 50,
  2000: 55, 2500: 60, 3000: 65, 3500: 65, 4000: 70,
  6000: 75, 8000: 80,
};

/// N5: moderately-severe flat loss.
const Map<int, double> _bisgaardN5 = {
  250: 55, 500: 55, 750: 55, 1000: 55, 1500: 55,
  2000: 60, 2500: 65, 3000: 70, 3500: 75, 4000: 80,
  6000: 80, 8000: 80,
};

/// N6: severe flat loss.
const Map<int, double> _bisgaardN6 = {
  250: 65, 500: 65, 750: 65, 1000: 70, 1500: 70,
  2000: 70, 2500: 75, 3000: 75, 3500: 80, 4000: 85,
  6000: 85, 8000: 90,
};

/// N7: profound flat loss.
const Map<int, double> _bisgaardN7 = {
  250: 75, 500: 80, 750: 80, 1000: 85, 1500: 85,
  2000: 90, 2500: 95, 3000: 100, 3500: 100, 4000: 105,
  6000: 105, 8000: 110,
};

/// S1: shallow sloping (mild low, moderate high).
const Map<int, double> _bisgaardS1 = {
  250: 10, 500: 10, 750: 15, 1000: 20, 1500: 30,
  2000: 40, 2500: 50, 3000: 55, 3500: 55, 4000: 60,
  6000: 65, 8000: 65,
};

/// S2: steep sloping.
const Map<int, double> _bisgaardS2 = {
  250: 10, 500: 10, 750: 10, 1000: 15, 1500: 30,
  2000: 50, 2500: 60, 3000: 70, 3500: 70, 4000: 75,
  6000: 80, 8000: 80,
};

/// S3: very steep "ski-slope" loss.
const Map<int, double> _bisgaardS3 = {
  250: 10, 500: 10, 750: 10, 1000: 10, 1500: 15,
  2000: 50, 2500: 65, 3000: 80, 3500: 90, 4000: 100,
  6000: 110, 8000: 120,
};

const Map<String, Map<int, double>> _bisgaardAudiograms = {
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

/// Tolerance for double round-trip through JSON. Decimal HL values like
/// 35.0, 7.5, 100.0 are exact in IEEE-754 binary64, but the spec asks
/// for closeTo(..., 1e-9) and we keep that tighter-than-needed margin
/// to expose any future format change that loses precision.
const double _kFloatTolerance = 1e-9;

/// Reference UCT timestamps used across the test cases. Pinned so that
/// drift caused by toIso8601String/parse round-trips is caught
/// deterministically (no clock dependency).
final DateTime _refTestedAt =
    DateTime.utc(2025, 3, 15, 14, 30, 0, 123); // ms precision
final DateTime _refCalibrationDate =
    DateTime.utc(2025, 3, 1, 10, 0, 0, 456); // ms precision

/// Build a [FrequencyThresholdHL] map from a Bisgaard fixture, with all
/// thresholds marked as "in range, not at the normal floor".
Map<int, FrequencyThresholdHL> _thresholdsFromBisgaard(
  Map<int, double> hlByFreq,
) {
  return {
    for (final freq in Audiogram.standardFrequencies)
      freq: FrequencyThresholdHL(
        freqHz: freq,
        thresholdHL: hlByFreq[freq]!,
        outOfRange: false,
        normalLimit: false,
      ),
  };
}

/// Encode `result` to JSON via `jsonEncode`, then decode back through
/// `AudiometryResult.fromJson`. Mirrors how AudiometryStore persists the
/// blob, but stays Hive-free so this test exercises the JSON contract
/// in isolation.
AudiometryResult _roundTrip(AudiometryResult result) {
  final encoded = jsonEncode(result.toJson());
  final decoded = jsonDecode(encoded) as Map<String, dynamic>;
  return AudiometryResult.fromJson(decoded);
}

/// Field-by-field assertion that the round-trip preserves every value.
/// Doubles are compared with [_kFloatTolerance]; ints, bools, strings and
/// timestamps are compared for exact equality (UTC for timestamps).
void _expectEqualResult(
  AudiometryResult restored,
  AudiometryResult original, {
  String? reason,
}) {
  final ctx = reason == null ? '' : ' [$reason]';

  // ── Top-level scalar / metadata fields ──────────────────────────────────
  expect(restored.testedAt.toUtc(), original.testedAt.toUtc(),
      reason: 'testedAt$ctx');
  expect(restored.calibrationMac, original.calibrationMac,
      reason: 'calibrationMac$ctx');
  expect(restored.calibrationDate.toUtc(), original.calibrationDate.toUtc(),
      reason: 'calibrationDate$ctx');
  expect(restored.patientAlias, original.patientAlias,
      reason: 'patientAlias$ctx');

  // retest1000Diff may be null. closeTo cannot be applied to null, so
  // we branch here.
  if (original.retest1000Diff == null) {
    expect(restored.retest1000Diff, isNull, reason: 'retest1000Diff$ctx');
  } else {
    expect(
      restored.retest1000Diff,
      closeTo(original.retest1000Diff!, _kFloatTolerance),
      reason: 'retest1000Diff$ctx',
    );
  }

  // ── Threshold map: same keys, same values, same flags ──────────────────
  expect(restored.thresholds.keys.toSet(), original.thresholds.keys.toSet(),
      reason: 'thresholds.keys$ctx');

  original.thresholds.forEach((freq, t) {
    final r = restored.thresholds[freq]!;
    expect(r.freqHz, t.freqHz, reason: 'freqHz @${freq}Hz$ctx');
    expect(r.thresholdHL, closeTo(t.thresholdHL, _kFloatTolerance),
        reason: 'thresholdHL @${freq}Hz$ctx');
    expect(r.outOfRange, t.outOfRange, reason: 'outOfRange @${freq}Hz$ctx');
    expect(r.normalLimit, t.normalLimit, reason: 'normalLimit @${freq}Hz$ctx');
  });
}

void main() {
  group('AudiometryResult — JSON round-trip básico (Bisgaard N3)', () {
    test('toJson → fromJson preserves every field with N3 typical values', () {
      final original = AudiometryResult(
        testedAt: _refTestedAt,
        calibrationMac: 'AA:BB:CC:DD:EE:FF',
        calibrationDate: _refCalibrationDate,
        thresholds: _thresholdsFromBisgaard(_bisgaardN3),
        retest1000Diff: 2.5,
        patientAlias: 'Paciente Test',
      );

      final restored = _roundTrip(original);

      _expectEqualResult(restored, original, reason: 'N3 baseline');

      // Sanity: confirm no field was silently dropped or replaced.
      expect(restored.thresholds.length, 12,
          reason: 'every standard frequency must round-trip');
      for (final freq in Audiogram.standardFrequencies) {
        expect(restored.thresholds[freq], isNotNull,
            reason: 'frequency $freq Hz missing after round-trip');
      }
    });

    test('toJson exposes schema_version equal to the model constant', () {
      final original = AudiometryResult(
        testedAt: _refTestedAt,
        calibrationMac: 'AA:BB:CC:DD:EE:FF',
        calibrationDate: _refCalibrationDate,
        thresholds: _thresholdsFromBisgaard(_bisgaardN3),
        retest1000Diff: null,
        patientAlias: 'N3',
      );

      final json = original.toJson();
      expect(json.containsKey('schema_version'), isTrue,
          reason: 'JSON must declare schema_version for migrations');
      expect(json['schema_version'], AudiometryResult.schemaVersion);
      expect(AudiometryResult.schemaVersion, isNotEmpty);
    });
  });

  group('AudiometryResult — JSON round-trip with edge-case flags', () {
    test(
        'outOfRange=true, normalLimit=true and retest1000Diff > 5 dB '
        'all survive the round-trip with exact flag preservation', () {
      // Build a custom threshold map so each edge case targets a
      // specific frequency:
      //   * 250 Hz  → normalLimit=true at HL=-10 (audición normal mínima).
      //   * 1000 Hz → in-range, used to anchor retest1000Diff > 5 dB.
      //   * 8000 Hz → outOfRange=true at HL=120 (techo del transductor).
      final thresholds = <int, FrequencyThresholdHL>{
        250: const FrequencyThresholdHL(
          freqHz: 250,
          thresholdHL: -10.0,
          outOfRange: false,
          normalLimit: true,
        ),
        500: const FrequencyThresholdHL(
          freqHz: 500,
          thresholdHL: 5.0,
          outOfRange: false,
          normalLimit: false,
        ),
        1000: const FrequencyThresholdHL(
          freqHz: 1000,
          thresholdHL: 30.0,
          outOfRange: false,
          normalLimit: false,
        ),
        4000: const FrequencyThresholdHL(
          freqHz: 4000,
          thresholdHL: 75.0,
          outOfRange: false,
          normalLimit: false,
        ),
        8000: const FrequencyThresholdHL(
          freqHz: 8000,
          thresholdHL: 120.0,
          outOfRange: true,
          normalLimit: false,
        ),
      };

      final original = AudiometryResult(
        testedAt: _refTestedAt,
        calibrationMac: '11:22:33:44:55:66',
        calibrationDate: _refCalibrationDate,
        thresholds: thresholds,
        // 7.5 dB > 5 dB threshold the protocol flags as "ofrecer repetir".
        retest1000Diff: 7.5,
        patientAlias: 'Edge Cases',
      );

      final restored = _roundTrip(original);
      _expectEqualResult(restored, original, reason: 'edge flags');

      // Explicit flag-level assertions to guarantee the regression
      // failure message points at the right field if the contract
      // changes in the future.
      expect(restored.thresholds[250]!.normalLimit, isTrue,
          reason: '250 Hz normalLimit must round-trip as true');
      expect(restored.thresholds[250]!.outOfRange, isFalse,
          reason: '250 Hz outOfRange must round-trip as false');
      expect(restored.thresholds[250]!.thresholdHL,
          closeTo(-10.0, _kFloatTolerance));

      expect(restored.thresholds[8000]!.outOfRange, isTrue,
          reason: '8000 Hz outOfRange must round-trip as true');
      expect(restored.thresholds[8000]!.normalLimit, isFalse,
          reason: '8000 Hz normalLimit must round-trip as false');
      expect(restored.thresholds[8000]!.thresholdHL,
          closeTo(120.0, _kFloatTolerance));

      expect(restored.retest1000Diff, isNotNull);
      expect(restored.retest1000Diff!, closeTo(7.5, _kFloatTolerance),
          reason: 'retest1000Diff > 5 dB must round-trip exactly');
    });

    test('null retest1000Diff and empty patientAlias round-trip cleanly', () {
      final original = AudiometryResult(
        testedAt: _refTestedAt,
        calibrationMac: 'AA:BB:CC:DD:EE:FF',
        calibrationDate: _refCalibrationDate,
        thresholds: _thresholdsFromBisgaard(_bisgaardN1),
        retest1000Diff: null,
        patientAlias: '',
      );

      final restored = _roundTrip(original);
      _expectEqualResult(restored, original, reason: 'null retest, empty alias');

      expect(restored.retest1000Diff, isNull);
      expect(restored.patientAlias, '');
    });
  });

  group('AudiometryResult — 10 Bisgaard audiograms (N1–N7 + S1–S3)', () {
    for (final entry in _bisgaardAudiograms.entries) {
      final name = entry.key;
      final hlByFreq = entry.value;

      test('Bisgaard $name round-trips exactly through JSON', () {
        final original = AudiometryResult(
          testedAt: _refTestedAt,
          calibrationMac: 'AA:BB:CC:DD:EE:FF',
          calibrationDate: _refCalibrationDate,
          thresholds: _thresholdsFromBisgaard(hlByFreq),
          // Use a non-trivial value so retest1000Diff is exercised in
          // every audiogram, not only the explicit edge-case test.
          retest1000Diff: 3.25,
          patientAlias: 'Bisgaard $name',
        );

        final restored = _roundTrip(original);
        _expectEqualResult(restored, original, reason: 'Bisgaard $name');

        // Per-band closeTo assertion against the original Bisgaard
        // fixture, not just against `original.thresholds`. This catches
        // mistakes where _thresholdsFromBisgaard might lose precision
        // before the round-trip even starts.
        for (final freq in Audiogram.standardFrequencies) {
          expect(
            restored.thresholds[freq]!.thresholdHL,
            closeTo(hlByFreq[freq]!, _kFloatTolerance),
            reason: 'Bisgaard $name @${freq}Hz must equal the published '
                'reference within $_kFloatTolerance dB HL',
          );
        }
      });
    }
  });

  group('AudiometryResult — timestamp precision', () {
    test('testedAt and calibrationDate keep millisecond precision in UTC', () {
      // Timestamp with explicit millisecond component to verify the
      // ISO-8601 round-trip preserves ms (not just seconds).
      final tested = DateTime.utc(2025, 6, 17, 9, 8, 7, 321);
      final calib = DateTime.utc(2024, 12, 31, 23, 59, 58, 654);

      final original = AudiometryResult(
        testedAt: tested,
        calibrationMac: 'AA:BB:CC:DD:EE:FF',
        calibrationDate: calib,
        thresholds: _thresholdsFromBisgaard(_bisgaardN3),
        retest1000Diff: 1.0,
        patientAlias: 'Timestamps',
      );

      final restored = _roundTrip(original);

      // Compare in UTC explicitly: even if `parse` returned the value
      // in the local zone, `toUtc()` would normalise it before
      // comparison, so any drift > 0 ms will fail this assertion.
      expect(restored.testedAt.toUtc(), tested,
          reason: 'testedAt must round-trip with millisecond precision in UTC');
      expect(restored.testedAt.toUtc().millisecondsSinceEpoch,
          tested.millisecondsSinceEpoch,
          reason: 'testedAt epoch ms must match exactly');
      expect(restored.testedAt.isUtc, isTrue,
          reason: 'parse of an ISO-8601 string ending in Z must yield UTC');

      expect(restored.calibrationDate.toUtc(), calib,
          reason:
              'calibrationDate must round-trip with millisecond precision in UTC');
      expect(restored.calibrationDate.toUtc().millisecondsSinceEpoch,
          calib.millisecondsSinceEpoch,
          reason: 'calibrationDate epoch ms must match exactly');
      expect(restored.calibrationDate.isUtc, isTrue,
          reason: 'parse of an ISO-8601 string ending in Z must yield UTC');
    });
  });
}

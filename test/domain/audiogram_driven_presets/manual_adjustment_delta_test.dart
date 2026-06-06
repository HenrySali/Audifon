import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/manual_adjustment_delta.dart';

void main() {
  group('ManualAdjustmentDelta', () {
    // ─── zero() factory ───────────────────────────────────────────────────────

    group('zero() factory', () {
      test('all fields are 0 and eqDeltaDb is 12 zeros', () {
        final delta = ManualAdjustmentDelta.zero();

        expect(delta.eqDeltaDb, List<double>.filled(12, 0.0));
        expect(delta.eqDeltaDb.length, 12);
        expect(delta.volumeDeltaDb, 0.0);
        expect(delta.nrLevelDelta, 0);
        expect(delta.compressionRatioDelta, 0.0);
        expect(delta.compressionKneeDeltaDbSpl, 0.0);
      });

      test('isZero is true', () {
        final delta = ManualAdjustmentDelta.zero();
        expect(delta.isZero, isTrue);
      });
    });

    // ─── isZero getter ────────────────────────────────────────────────────────

    group('isZero', () {
      test('returns false for non-zero volumeDeltaDb', () {
        final delta = ManualAdjustmentDelta(
          eqDeltaDb: List<double>.filled(12, 0.0),
          volumeDeltaDb: 3.0,
          nrLevelDelta: 0,
          compressionRatioDelta: 0.0,
          compressionKneeDeltaDbSpl: 0.0,
          editedAt: DateTime.utc(2026, 6, 1),
        );
        expect(delta.isZero, isFalse);
      });

      test('returns false for non-zero eqDeltaDb band', () {
        final eq = List<double>.filled(12, 0.0);
        eq[5] = 2.5;
        final delta = ManualAdjustmentDelta(
          eqDeltaDb: eq,
          volumeDeltaDb: 0.0,
          nrLevelDelta: 0,
          compressionRatioDelta: 0.0,
          compressionKneeDeltaDbSpl: 0.0,
          editedAt: DateTime.utc(2026, 6, 1),
        );
        expect(delta.isZero, isFalse);
      });

      test('returns false for non-zero nrLevelDelta', () {
        final delta = ManualAdjustmentDelta(
          eqDeltaDb: List<double>.filled(12, 0.0),
          volumeDeltaDb: 0.0,
          nrLevelDelta: 1,
          compressionRatioDelta: 0.0,
          compressionKneeDeltaDbSpl: 0.0,
          editedAt: DateTime.utc(2026, 6, 1),
        );
        expect(delta.isZero, isFalse);
      });

      test('returns false for non-zero compressionRatioDelta', () {
        final delta = ManualAdjustmentDelta(
          eqDeltaDb: List<double>.filled(12, 0.0),
          volumeDeltaDb: 0.0,
          nrLevelDelta: 0,
          compressionRatioDelta: 0.5,
          compressionKneeDeltaDbSpl: 0.0,
          editedAt: DateTime.utc(2026, 6, 1),
        );
        expect(delta.isZero, isFalse);
      });

      test('returns false for non-zero compressionKneeDeltaDbSpl', () {
        final delta = ManualAdjustmentDelta(
          eqDeltaDb: List<double>.filled(12, 0.0),
          volumeDeltaDb: 0.0,
          nrLevelDelta: 0,
          compressionRatioDelta: 0.0,
          compressionKneeDeltaDbSpl: -5.0,
          editedAt: DateTime.utc(2026, 6, 1),
        );
        expect(delta.isZero, isFalse);
      });

      test('ignores editedAt — zero fields with different timestamps are both isZero', () {
        final delta1 = ManualAdjustmentDelta(
          eqDeltaDb: List<double>.filled(12, 0.0),
          volumeDeltaDb: 0.0,
          nrLevelDelta: 0,
          compressionRatioDelta: 0.0,
          compressionKneeDeltaDbSpl: 0.0,
          editedAt: DateTime.utc(2020, 1, 1),
        );
        final delta2 = ManualAdjustmentDelta(
          eqDeltaDb: List<double>.filled(12, 0.0),
          volumeDeltaDb: 0.0,
          nrLevelDelta: 0,
          compressionRatioDelta: 0.0,
          compressionKneeDeltaDbSpl: 0.0,
          editedAt: DateTime.utc(2026, 6, 15, 14, 30),
        );
        expect(delta1.isZero, isTrue);
        expect(delta2.isZero, isTrue);
      });
    });

    // ─── Serialization round-trip ─────────────────────────────────────────────

    group('serialization round-trip', () {
      test('fromJson(toJson(delta)) produces same values', () {
        final original = ManualAdjustmentDelta(
          eqDeltaDb: [1.0, -2.5, 3.0, -4.0, 5.5, -6.0, 7.0, -8.0, 9.0, -10.0, 4.5, -3.5],
          volumeDeltaDb: -7.5,
          nrLevelDelta: 2,
          compressionRatioDelta: 0.75,
          compressionKneeDeltaDbSpl: -5.5,
          editedAt: DateTime.utc(2026, 6, 3, 10, 30, 45, 123),
        );

        final json = original.toJson();
        final restored = ManualAdjustmentDelta.fromJson(json);

        for (var i = 0; i < 12; i++) {
          expect(restored.eqDeltaDb[i], closeTo(original.eqDeltaDb[i], 0.001));
        }
        expect(restored.volumeDeltaDb, closeTo(original.volumeDeltaDb, 0.001));
        expect(restored.nrLevelDelta, original.nrLevelDelta);
        expect(restored.compressionRatioDelta, closeTo(original.compressionRatioDelta, 0.001));
        expect(restored.compressionKneeDeltaDbSpl, closeTo(original.compressionKneeDeltaDbSpl, 0.001));
        expect(restored.editedAt, original.editedAt);
      });

      test('all 12 bands in eqDeltaDb preserved through round-trip', () {
        final eq = List<double>.generate(12, (i) => (i - 5.5), growable: false);
        // Values: [-5.5, -4.5, -3.5, -2.5, -1.5, -0.5, 0.5, 1.5, 2.5, 3.5, 4.5, 5.5]
        final original = ManualAdjustmentDelta(
          eqDeltaDb: eq,
          volumeDeltaDb: 0.0,
          nrLevelDelta: 0,
          compressionRatioDelta: 0.0,
          compressionKneeDeltaDbSpl: 0.0,
          editedAt: DateTime.utc(2026, 1, 1),
        );

        final restored = ManualAdjustmentDelta.fromJson(original.toJson());

        expect(restored.eqDeltaDb.length, 12);
        for (var i = 0; i < 12; i++) {
          expect(restored.eqDeltaDb[i], closeTo(original.eqDeltaDb[i], 0.001));
        }
      });

      test('editedAt preserved as UTC with millisecond resolution', () {
        final editedAt = DateTime.utc(2026, 3, 15, 9, 45, 30, 789);
        final original = ManualAdjustmentDelta(
          eqDeltaDb: List<double>.filled(12, 0.0),
          volumeDeltaDb: 0.0,
          nrLevelDelta: 0,
          compressionRatioDelta: 0.0,
          compressionKneeDeltaDbSpl: 0.0,
          editedAt: editedAt,
        );

        final restored = ManualAdjustmentDelta.fromJson(original.toJson());

        expect(restored.editedAt.isUtc, isTrue);
        expect(restored.editedAt.millisecondsSinceEpoch, editedAt.millisecondsSinceEpoch);
      });

      test('zero() round-trips correctly', () {
        final original = ManualAdjustmentDelta.zero();
        final restored = ManualAdjustmentDelta.fromJson(original.toJson());

        expect(restored.isZero, isTrue);
        expect(restored.eqDeltaDb.length, 12);
        expect(restored.editedAt.isUtc, isTrue);
      });
    });

    // ─── Clamping on load ─────────────────────────────────────────────────────

    group('clamping on load', () {
      test('eqDeltaDb value above 10 is clamped to 10', () {
        final json = _validJsonWithOverrides(eqDeltaDb0: 15.0);
        final delta = ManualAdjustmentDelta.fromJson(json);
        expect(delta.eqDeltaDb[0], 10.0);
      });

      test('eqDeltaDb value below -10 is clamped to -10', () {
        final json = _validJsonWithOverrides(eqDeltaDb0: -25.0);
        final delta = ManualAdjustmentDelta.fromJson(json);
        expect(delta.eqDeltaDb[0], -10.0);
      });

      test('volumeDeltaDb above 10 is clamped to 10', () {
        final json = _validJsonWithOverrides(volumeDeltaDb: 30.0);
        final delta = ManualAdjustmentDelta.fromJson(json);
        expect(delta.volumeDeltaDb, 10.0);
      });

      test('volumeDeltaDb below -10 is clamped to -10', () {
        final json = _validJsonWithOverrides(volumeDeltaDb: -30.0);
        final delta = ManualAdjustmentDelta.fromJson(json);
        expect(delta.volumeDeltaDb, -10.0);
      });

      test('nrLevelDelta above 3 is clamped to 3', () {
        final json = _validJsonWithOverrides(nrLevelDelta: 10);
        final delta = ManualAdjustmentDelta.fromJson(json);
        expect(delta.nrLevelDelta, 3);
      });

      test('nrLevelDelta below -3 is clamped to -3', () {
        final json = _validJsonWithOverrides(nrLevelDelta: -10);
        final delta = ManualAdjustmentDelta.fromJson(json);
        expect(delta.nrLevelDelta, -3);
      });

      test('compressionRatioDelta above 1 is clamped to 1', () {
        final json = _validJsonWithOverrides(compressionRatioDelta: 5.0);
        final delta = ManualAdjustmentDelta.fromJson(json);
        expect(delta.compressionRatioDelta, 1.0);
      });

      test('compressionRatioDelta below -1 is clamped to -1', () {
        final json = _validJsonWithOverrides(compressionRatioDelta: -5.0);
        final delta = ManualAdjustmentDelta.fromJson(json);
        expect(delta.compressionRatioDelta, -1.0);
      });

      test('compressionKneeDeltaDbSpl above 10 is clamped to 10', () {
        final json = _validJsonWithOverrides(compressionKneeDeltaDbSpl: 25.0);
        final delta = ManualAdjustmentDelta.fromJson(json);
        expect(delta.compressionKneeDeltaDbSpl, 10.0);
      });

      test('compressionKneeDeltaDbSpl below -10 is clamped to -10', () {
        final json = _validJsonWithOverrides(compressionKneeDeltaDbSpl: -25.0);
        final delta = ManualAdjustmentDelta.fromJson(json);
        expect(delta.compressionKneeDeltaDbSpl, -10.0);
      });

      test('clamping does NOT throw (graceful behavior)', () {
        final json = {
          'eqDeltaDb': [15.0, -20.0, 100.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -50.0],
          'volumeDeltaDb': 999.0,
          'nrLevelDelta': 100,
          'compressionRatioDelta': -50.0,
          'compressionKneeDeltaDbSpl': 200.0,
          'editedAt': '2026-06-03T10:00:00.000Z',
        };

        // Must not throw
        final delta = ManualAdjustmentDelta.fromJson(json);

        // All values should be within clamped range
        for (final v in delta.eqDeltaDb) {
          expect(v, inInclusiveRange(-10.0, 10.0));
        }
        expect(delta.volumeDeltaDb, inInclusiveRange(-10.0, 10.0));
        expect(delta.nrLevelDelta, inInclusiveRange(-3, 3));
        expect(delta.compressionRatioDelta, inInclusiveRange(-1.0, 1.0));
        expect(delta.compressionKneeDeltaDbSpl, inInclusiveRange(-10.0, 10.0));
      });
    });

    // ─── Equatable ────────────────────────────────────────────────────────────

    group('Equatable', () {
      test('two instances with same values are equal', () {
        final editedAt = DateTime.utc(2026, 6, 1, 12, 0);
        final delta1 = ManualAdjustmentDelta(
          eqDeltaDb: [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, -1.0, -2.0],
          volumeDeltaDb: 5.0,
          nrLevelDelta: -1,
          compressionRatioDelta: 0.5,
          compressionKneeDeltaDbSpl: -3.0,
          editedAt: editedAt,
        );
        final delta2 = ManualAdjustmentDelta(
          eqDeltaDb: [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, -1.0, -2.0],
          volumeDeltaDb: 5.0,
          nrLevelDelta: -1,
          compressionRatioDelta: 0.5,
          compressionKneeDeltaDbSpl: -3.0,
          editedAt: editedAt,
        );
        expect(delta1, equals(delta2));
        expect(delta1.hashCode, delta2.hashCode);
      });

      test('different editedAt means not equal', () {
        final delta1 = ManualAdjustmentDelta(
          eqDeltaDb: List<double>.filled(12, 0.0),
          volumeDeltaDb: 0.0,
          nrLevelDelta: 0,
          compressionRatioDelta: 0.0,
          compressionKneeDeltaDbSpl: 0.0,
          editedAt: DateTime.utc(2026, 1, 1),
        );
        final delta2 = ManualAdjustmentDelta(
          eqDeltaDb: List<double>.filled(12, 0.0),
          volumeDeltaDb: 0.0,
          nrLevelDelta: 0,
          compressionRatioDelta: 0.0,
          compressionKneeDeltaDbSpl: 0.0,
          editedAt: DateTime.utc(2026, 6, 1),
        );
        // editedAt IS in props, so they are NOT equal
        expect(delta1, isNot(equals(delta2)));
      });
    });
  });
}

// ─── Test helpers ─────────────────────────────────────────────────────────────

/// Returns a valid JSON map with all required fields at zero, allowing
/// specific overrides for testing clamping behavior.
Map<String, dynamic> _validJsonWithOverrides({
  double? eqDeltaDb0,
  double? volumeDeltaDb,
  int? nrLevelDelta,
  double? compressionRatioDelta,
  double? compressionKneeDeltaDbSpl,
}) {
  final eq = List<double>.filled(12, 0.0);
  if (eqDeltaDb0 != null) eq[0] = eqDeltaDb0;

  return {
    'eqDeltaDb': eq,
    'volumeDeltaDb': volumeDeltaDb ?? 0.0,
    'nrLevelDelta': nrLevelDelta ?? 0,
    'compressionRatioDelta': compressionRatioDelta ?? 0.0,
    'compressionKneeDeltaDbSpl': compressionKneeDeltaDbSpl ?? 0.0,
    'editedAt': '2026-06-03T10:00:00.000Z',
  };
}

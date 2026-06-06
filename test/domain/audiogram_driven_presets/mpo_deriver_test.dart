/// Tests unitarios para MpoDeriver.
///
/// Verifica la derivación de MPO (Maximum Power Output) por banda a partir
/// de un perfil UCL, diferenciando reglas adulto vs pediátrica, boundary
/// values, y el clamp final a [80, 132] dB SPL.
///
/// **Validates: Requirements 11.1, 12.x**
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/domain/entities/patient_profile.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/mpo_deriver.dart';

// ─── Test fixtures ───────────────────────────────────────────────────────────

/// Adult profile (age >= 18): uses adult rule.
const _adultProfile = PatientProfile(experienceMonths: 24, ageYears: 35);

/// Pediatric profile (age < 18): uses pediatric rule.
const _pediatricProfile = PatientProfile(experienceMonths: 6, ageYears: 8);

/// Boundary pediatric: age=17 (still pediatric).
const _pediatric17 = PatientProfile(experienceMonths: 12, ageYears: 17);

/// Boundary adult: age=18 (exactly adult).
const _adult18 = PatientProfile(experienceMonths: 12, ageYears: 18);

/// Profile with null age: treated as adult.
const _nullAgeProfile = PatientProfile(experienceMonths: 12);

/// Helper: create a uniform UCL list with a given value.
List<double> _uniformUcl(double value) => List<double>.filled(12, value);

void main() {
  group('MpoDeriver — output structure', () {
    test('always produces a 12-element list', () {
      final ucl = _uniformUcl(110);
      final mpo = MpoDeriver.derive(ucl);
      expect(mpo.length, equals(12));
    });

    test('produces non-growable list', () {
      final ucl = _uniformUcl(110);
      final mpo = MpoDeriver.derive(ucl);
      expect(() => mpo.add(0), throwsA(isA<UnsupportedError>()));
    });
  });

  group('MpoDeriver — adult rule (profile=null)', () {
    test('MPO = min(UCL-5, 132) for moderate UCL', () {
      // UCL = 115 → MPO = min(115-5, 132) = 110
      final mpo = MpoDeriver.derive(_uniformUcl(115));
      for (final value in mpo) {
        expect(value, equals(110.0));
      }
    });

    test('MPO = 132 ceiling when UCL is very high', () {
      // UCL = 140 → min(140-5, 132) = 132
      final mpo = MpoDeriver.derive(_uniformUcl(140));
      for (final value in mpo) {
        expect(value, equals(132.0));
      }
    });

    test('MPO = 80 floor when UCL is very low', () {
      // UCL = 80 → min(80-5, 132) = 75, but clamped to 80
      final mpo = MpoDeriver.derive(_uniformUcl(80));
      for (final value in mpo) {
        expect(value, equals(80.0));
      }
    });

    test('UCL = 85 → MPO = 80 (exactly at floor)', () {
      // min(85-5, 132) = 80 → exactly at floor
      final mpo = MpoDeriver.derive(_uniformUcl(85));
      for (final value in mpo) {
        expect(value, equals(80.0));
      }
    });

    test('UCL = 137 → MPO = 132 (exactly at adult ceiling)', () {
      // min(137-5, 132) = min(132, 132) = 132
      final mpo = MpoDeriver.derive(_uniformUcl(137));
      for (final value in mpo) {
        expect(value, equals(132.0));
      }
    });
  });

  group('MpoDeriver — adult rule (explicit adult profile)', () {
    test('explicit adult profile (age=35): same as null profile', () {
      final ucl = _uniformUcl(115);
      final mpoNull = MpoDeriver.derive(ucl);
      final mpoAdult = MpoDeriver.derive(ucl, profile: _adultProfile);
      expect(mpoAdult, equals(mpoNull));
    });

    test('age=18 (boundary): uses adult rule', () {
      // UCL = 110 → min(110-5, 132) = 105
      final mpo = MpoDeriver.derive(_uniformUcl(110), profile: _adult18);
      for (final value in mpo) {
        expect(value, equals(105.0));
      }
    });

    test('null ageYears: uses adult rule', () {
      final mpo = MpoDeriver.derive(_uniformUcl(110), profile: _nullAgeProfile);
      for (final value in mpo) {
        expect(value, equals(105.0));
      }
    });
  });

  group('MpoDeriver — pediatric rule (age < 18)', () {
    test('MPO = min(UCL-10, 110) for moderate UCL', () {
      // UCL = 115 → min(115-10, 110) = min(105, 110) = 105
      final mpo =
          MpoDeriver.derive(_uniformUcl(115), profile: _pediatricProfile);
      for (final value in mpo) {
        expect(value, equals(105.0));
      }
    });

    test('UCL = 125 → MPO = 110 (pediatric ceiling caps at 110)', () {
      // min(125-10, 110) = min(115, 110) = 110
      final mpo =
          MpoDeriver.derive(_uniformUcl(125), profile: _pediatricProfile);
      for (final value in mpo) {
        expect(value, equals(110.0));
      }
    });

    test('UCL = 80 → MPO = 80 (floor clamp at 80)', () {
      // min(80-10, 110) = min(70, 110) = 70 → clamped to 80
      final mpo =
          MpoDeriver.derive(_uniformUcl(80), profile: _pediatricProfile);
      for (final value in mpo) {
        expect(value, equals(80.0));
      }
    });

    test('age=17 (boundary pediatric): uses pediatric rule', () {
      // UCL = 115 → min(115-10, 110) = 105
      final mpo = MpoDeriver.derive(_uniformUcl(115), profile: _pediatric17);
      for (final value in mpo) {
        expect(value, equals(105.0));
      }
    });

    test('UCL = 90 → pediatric MPO = 80 (floor)', () {
      // min(90-10, 110) = min(80, 110) = 80 → exactly at floor
      final mpo =
          MpoDeriver.derive(_uniformUcl(90), profile: _pediatricProfile);
      for (final value in mpo) {
        expect(value, equals(80.0));
      }
    });

    test('pediatric ceiling is lower than adult ceiling', () {
      // UCL = 140: adult → 132, pediatric → 110
      final mpoAdult = MpoDeriver.derive(_uniformUcl(140));
      final mpoPed =
          MpoDeriver.derive(_uniformUcl(140), profile: _pediatricProfile);
      for (int i = 0; i < 12; i++) {
        expect(mpoPed[i], lessThan(mpoAdult[i]));
      }
    });
  });

  group('MpoDeriver — clamp to [80, 132]', () {
    test('all MPO values are >= 80 for very low UCL', () {
      // UCL = 50 → adult: min(50-5, 132) = 45 → clamped to 80
      final mpo = MpoDeriver.derive(_uniformUcl(50));
      for (final value in mpo) {
        expect(value, greaterThanOrEqualTo(80.0));
      }
    });

    test('all MPO values are <= 132 for very high UCL', () {
      final mpo = MpoDeriver.derive(_uniformUcl(200));
      for (final value in mpo) {
        expect(value, lessThanOrEqualTo(132.0));
      }
    });

    test('pediatric: all MPO values in [80, 132] regardless of UCL', () {
      for (final uclVal in [50.0, 80.0, 100.0, 120.0, 150.0, 200.0]) {
        final mpo = MpoDeriver.derive(
          _uniformUcl(uclVal),
          profile: _pediatricProfile,
        );
        for (final value in mpo) {
          expect(value, greaterThanOrEqualTo(80.0),
              reason: 'UCL=$uclVal should clamp MPO >= 80');
          expect(value, lessThanOrEqualTo(132.0),
              reason: 'UCL=$uclVal should clamp MPO <= 132');
        }
      }
    });
  });

  group('MpoDeriver — per-band variation with non-uniform UCL', () {
    test('varying UCL produces varying MPO (adult)', () {
      // Simulating a sloping UCL profile
      final ucl = <double>[
        101.5, 101.5, 102.25, 103.0, 104.5,
        106.0, 107.5, 109.0, 109.0, 110.5, 112.0, 113.5,
      ];
      final mpo = MpoDeriver.derive(ucl);
      expect(mpo.length, equals(12));
      // Each value should be UCL[i] - 5 clamped to [80, 132]
      for (int i = 0; i < 12; i++) {
        final expected = (ucl[i] - 5.0).clamp(80.0, 132.0);
        expect(mpo[i], closeTo(expected, 0.001),
            reason: 'Band $i: UCL=${ucl[i]}');
      }
    });

    test('varying UCL produces varying MPO (pediatric)', () {
      final ucl = <double>[
        101.5, 101.5, 102.25, 103.0, 104.5,
        106.0, 107.5, 109.0, 109.0, 110.5, 112.0, 113.5,
      ];
      final mpo = MpoDeriver.derive(ucl, profile: _pediatricProfile);
      expect(mpo.length, equals(12));
      for (int i = 0; i < 12; i++) {
        final raw = ucl[i] - 10.0;
        final cappedByCeiling = raw < 110.0 ? raw : 110.0;
        final expected = cappedByCeiling.clamp(80.0, 132.0);
        expect(mpo[i], closeTo(expected, 0.001),
            reason: 'Band $i: UCL=${ucl[i]}');
      }
    });
  });

  group('MpoDeriver — determinism', () {
    test('same inputs produce same outputs', () {
      final ucl = _uniformUcl(112);
      final mpo1 = MpoDeriver.derive(ucl, profile: _adultProfile);
      final mpo2 = MpoDeriver.derive(ucl, profile: _adultProfile);
      expect(mpo1, equals(mpo2));
    });
  });

  group('MpoDeriver — constants are consistent', () {
    test('safety margins are positive', () {
      expect(MpoDeriver.adultSafetyMarginDb, greaterThan(0));
      expect(MpoDeriver.pediatricSafetyMarginDb, greaterThan(0));
    });

    test('pediatric safety margin > adult safety margin', () {
      expect(
        MpoDeriver.pediatricSafetyMarginDb,
        greaterThan(MpoDeriver.adultSafetyMarginDb),
      );
    });

    test('pediatric ceiling < adult ceiling', () {
      expect(
        MpoDeriver.pediatricCeilingDbSpl,
        lessThan(MpoDeriver.adultCeilingDbSpl),
      );
    });

    test('floor < ceiling', () {
      expect(MpoDeriver.mpoFloorDbSpl, lessThan(MpoDeriver.mpoCeilingDbSpl));
    });
  });
}

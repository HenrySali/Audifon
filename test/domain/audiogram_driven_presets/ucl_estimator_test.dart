/// Tests unitarios para UclEstimator.
///
/// Verifica la estimación de UCL (Uncomfortable Loudness Level) por banda
/// usando audiogramas Bisgaard N1–N7 y S1–S3, boundary values (HL=0,
/// HL=120), y manejo de measuredUcl parcial y ausente.
///
/// **Validates: Requirements 11.1, 12.x**
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/ucl_estimator.dart';

// ─── Bisgaard audiogram fixtures ─────────────────────────────────────────────
// Reference: Bisgaard, Vlaming & Dahlquist (2010), "Standard Audiograms for
// the IEC 60118-15 Measurement Procedure", Trends in Amplification 14(2):113–120.
// N1–N7: flat-to-steeply-sloping losses (mild → profound).
// S1–S3: reverse slope / rising patterns.

/// N1: mild flat loss (~20 dB HL across all bands).
const _bisgaardN1 = <int, double>{
  250: 20, 500: 20, 750: 20, 1000: 25, 1500: 25,
  2000: 25, 2500: 30, 3000: 30, 3500: 30, 4000: 35, 6000: 35, 8000: 35,
};

/// N2: mild sloping loss.
const _bisgaardN2 = <int, double>{
  250: 20, 500: 20, 750: 25, 1000: 30, 1500: 35,
  2000: 40, 2500: 45, 3000: 50, 3500: 50, 4000: 55, 6000: 55, 8000: 60,
};

/// N3: moderate flat loss.
const _bisgaardN3 = <int, double>{
  250: 35, 500: 35, 750: 35, 1000: 40, 1500: 45,
  2000: 50, 2500: 55, 3000: 55, 3500: 55, 4000: 60, 6000: 60, 8000: 65,
};

/// N4: moderate sloping loss.
const _bisgaardN4 = <int, double>{
  250: 35, 500: 35, 750: 40, 1000: 45, 1500: 50,
  2000: 55, 2500: 60, 3000: 65, 3500: 65, 4000: 70, 6000: 75, 8000: 80,
};

/// N5: moderately-severe flat loss.
const _bisgaardN5 = <int, double>{
  250: 55, 500: 55, 750: 55, 1000: 55, 1500: 55,
  2000: 60, 2500: 65, 3000: 70, 3500: 75, 4000: 80, 6000: 80, 8000: 80,
};

/// N6: severe flat loss.
const _bisgaardN6 = <int, double>{
  250: 65, 500: 65, 750: 65, 1000: 70, 1500: 70,
  2000: 70, 2500: 75, 3000: 75, 3500: 80, 4000: 85, 6000: 85, 8000: 90,
};

/// N7: profound flat loss.
const _bisgaardN7 = <int, double>{
  250: 75, 500: 80, 750: 80, 1000: 85, 1500: 85,
  2000: 90, 2500: 95, 3000: 100, 3500: 100, 4000: 105, 6000: 105, 8000: 110,
};

/// S1: shallow sloping (mild low, moderate high).
const _bisgaardS1 = <int, double>{
  250: 10, 500: 10, 750: 15, 1000: 20, 1500: 30,
  2000: 40, 2500: 50, 3000: 55, 3500: 55, 4000: 60, 6000: 65, 8000: 65,
};

/// S2: steep sloping.
const _bisgaardS2 = <int, double>{
  250: 10, 500: 10, 750: 10, 1000: 15, 1500: 30,
  2000: 50, 2500: 60, 3000: 70, 3500: 70, 4000: 75, 6000: 80, 8000: 80,
};

/// S3: very steep "ski-slope" loss.
const _bisgaardS3 = <int, double>{
  250: 10, 500: 10, 750: 10, 1000: 10, 1500: 15,
  2000: 50, 2500: 65, 3000: 80, 3500: 90, 4000: 100, 6000: 110, 8000: 120,
};

/// Helper: creates an Audiogram from a threshold map.
Audiogram _makeAudiogram(Map<int, double> thresholds) =>
    Audiogram(thresholds: thresholds);

/// Helper: creates a flat audiogram with a given HL at all 12 bands.
Audiogram _flatAudiogram(double hl) => Audiogram(
      thresholds: {
        for (final f in Audiogram.standardFrequencies) f: hl,
      },
    );

void main() {
  group('UclEstimator — output structure', () {
    test('always produces a 12-element list', () {
      final audiogram = _flatAudiogram(30);
      final ucl = UclEstimator.estimate(audiogram);
      expect(ucl.length, equals(12));
    });

    test('produces 12 elements even with measuredUcl for some bands', () {
      final audiogram = _flatAudiogram(40);
      final ucl = UclEstimator.estimate(
        audiogram,
        measuredUcl: {1000: 95.0, 4000: 110.0},
      );
      expect(ucl.length, equals(12));
    });
  });

  group('UclEstimator — formula: UCL = 100 + 0.15 * HL', () {
    test('HL=0 → UCL=100 (boundary: normal hearing)', () {
      final audiogram = _flatAudiogram(0);
      final ucl = UclEstimator.estimate(audiogram);
      for (final value in ucl) {
        expect(value, equals(100.0));
      }
    });

    test('HL=120 → UCL=118 (boundary: maximum HL)', () {
      final audiogram = _flatAudiogram(120);
      final ucl = UclEstimator.estimate(audiogram);
      for (final value in ucl) {
        expect(value, equals(118.0));
      }
    });

    test('HL=30 → UCL=104.5 (typical mild loss)', () {
      final audiogram = _flatAudiogram(30);
      final ucl = UclEstimator.estimate(audiogram);
      for (final value in ucl) {
        expect(value, closeTo(104.5, 0.001));
      }
    });

    test('HL=60 → UCL=109 (moderate loss)', () {
      final audiogram = _flatAudiogram(60);
      final ucl = UclEstimator.estimate(audiogram);
      for (final value in ucl) {
        expect(value, closeTo(109.0, 0.001));
      }
    });

    test('HL below 0 is clamped to 0 → UCL=100', () {
      final audiogram = _flatAudiogram(-10);
      final ucl = UclEstimator.estimate(audiogram);
      for (final value in ucl) {
        expect(value, equals(100.0));
      }
    });

    test('HL above 120 is clamped to 120 → UCL=118', () {
      final audiogram = _flatAudiogram(150);
      final ucl = UclEstimator.estimate(audiogram);
      for (final value in ucl) {
        expect(value, equals(118.0));
      }
    });
  });

  group('UclEstimator — measuredUcl handling', () {
    test('no measuredUcl: all from formula', () {
      final audiogram = _flatAudiogram(50);
      final ucl = UclEstimator.estimate(audiogram);
      // UCL = 100 + 0.15 * 50 = 107.5
      for (final value in ucl) {
        expect(value, closeTo(107.5, 0.001));
      }
    });

    test('partial measuredUcl: specific bands use measured, rest use formula',
        () {
      final audiogram = _flatAudiogram(40); // formula UCL = 106
      final ucl = UclEstimator.estimate(
        audiogram,
        measuredUcl: {1000: 95.0, 4000: 112.0},
      );

      // Band at 1000 Hz (index 3): measured = 95.0
      expect(ucl[3], equals(95.0));
      // Band at 4000 Hz (index 9): measured = 112.0
      expect(ucl[9], equals(112.0));
      // All other bands: 100 + 0.15 * 40 = 106.0
      for (int i = 0; i < 12; i++) {
        if (i == 3 || i == 9) continue;
        expect(ucl[i], closeTo(106.0, 0.001));
      }
    });

    test('measuredUcl with all 12 bands: all values from map', () {
      final audiogram = _flatAudiogram(80); // formula would give 112
      final measured = <int, double>{
        for (final f in Audiogram.standardFrequencies) f: 99.0,
      };
      final ucl = UclEstimator.estimate(audiogram, measuredUcl: measured);
      for (final value in ucl) {
        expect(value, equals(99.0));
      }
    });

    test('measuredUcl with non-standard frequency is ignored gracefully', () {
      final audiogram = _flatAudiogram(20); // UCL = 103
      final ucl = UclEstimator.estimate(
        audiogram,
        measuredUcl: {7777: 80.0}, // not a standard frequency
      );
      for (final value in ucl) {
        expect(value, closeTo(103.0, 0.001));
      }
    });
  });

  group('UclEstimator — Bisgaard N1–N7 fixtures', () {
    final fixtures = <String, Map<int, double>>{
      'N1': _bisgaardN1,
      'N2': _bisgaardN2,
      'N3': _bisgaardN3,
      'N4': _bisgaardN4,
      'N5': _bisgaardN5,
      'N6': _bisgaardN6,
      'N7': _bisgaardN7,
    };

    for (final entry in fixtures.entries) {
      test('Bisgaard ${entry.key}: produces 12 values with correct formula', () {
        final audiogram = _makeAudiogram(entry.value);
        final ucl = UclEstimator.estimate(audiogram);
        expect(ucl.length, equals(12));

        // Verify each band matches formula
        int i = 0;
        for (final freq in Audiogram.standardFrequencies) {
          final hl = entry.value[freq]!.clamp(0.0, 120.0);
          final expected = 100.0 + 0.15 * hl;
          expect(ucl[i], closeTo(expected, 0.001),
              reason: 'Band $freq Hz (index $i) in ${entry.key}');
          i++;
        }
      });
    }
  });

  group('UclEstimator — Bisgaard S1–S3 fixtures (sloping)', () {
    final fixtures = <String, Map<int, double>>{
      'S1': _bisgaardS1,
      'S2': _bisgaardS2,
      'S3': _bisgaardS3,
    };

    for (final entry in fixtures.entries) {
      test('Bisgaard ${entry.key}: produces 12 values with correct formula', () {
        final audiogram = _makeAudiogram(entry.value);
        final ucl = UclEstimator.estimate(audiogram);
        expect(ucl.length, equals(12));

        int i = 0;
        for (final freq in Audiogram.standardFrequencies) {
          final hl = entry.value[freq]!.clamp(0.0, 120.0);
          final expected = 100.0 + 0.15 * hl;
          expect(ucl[i], closeTo(expected, 0.001),
              reason: 'Band $freq Hz (index $i) in ${entry.key}');
          i++;
        }
      });
    }

    test('Bisgaard S3: high-frequency bands (HL=120) give UCL=118', () {
      final audiogram = _makeAudiogram(_bisgaardS3);
      final ucl = UclEstimator.estimate(audiogram);
      // 8000 Hz has HL=120 → UCL = 100 + 0.15*120 = 118
      expect(ucl[11], closeTo(118.0, 0.001));
    });

    test('Bisgaard S3: low-frequency bands (HL=10) give UCL=101.5', () {
      final audiogram = _makeAudiogram(_bisgaardS3);
      final ucl = UclEstimator.estimate(audiogram);
      // 250 Hz has HL=10 → UCL = 100 + 0.15*10 = 101.5
      expect(ucl[0], closeTo(101.5, 0.001));
    });
  });

  group('UclEstimator — determinism', () {
    test('same inputs produce same outputs', () {
      final audiogram = _makeAudiogram(_bisgaardN4);
      final ucl1 = UclEstimator.estimate(audiogram);
      final ucl2 = UclEstimator.estimate(audiogram);
      expect(ucl1, equals(ucl2));
    });

    test('same inputs with measuredUcl produce same outputs', () {
      final audiogram = _flatAudiogram(50);
      final measured = {1000: 95.0, 2000: 98.0};
      final ucl1 = UclEstimator.estimate(audiogram, measuredUcl: measured);
      final ucl2 = UclEstimator.estimate(audiogram, measuredUcl: measured);
      expect(ucl1, equals(ucl2));
    });
  });
}

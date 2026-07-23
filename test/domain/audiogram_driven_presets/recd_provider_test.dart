// Spec: audiogram-driven-presets · Wave 11, task 14.5.
//
// Unit tests for the RECD provider implemented in
// `lib/domain/audiogram_driven_presets/recd_provider.dart`.
//
// These tests cover four concerns:
//
//   1. **Bit-exact lookup** at each tabulated age anchor (1, 4, 7, 10,
//      13, 16, 19, 22, 25, 34 mo + ">3y" / "4-5y" / "6y" / "Adult >6y")
//      for the four [RecdCoupling] variants. The expected values are
//      copied verbatim from the source PDF so any silent edit to the
//      tables would flip the test.
//   2. **Linear interpolation** between adjacent anchors. The example
//      called out in tasks.md §14.5 — `ageMonths=2` between `1` and
//      `4` for 250 Hz earmold + HA1 — is checked, and a second case
//      between `4` and `7` mo at 1000 Hz earmold + HA1 catches a sign
//      flip in the interpolation direction.
//   3. **Boundary policy**: `ageMonths == 0` falls back to the
//      1-month row; `ageMonths >= 84` falls back to the "Adult >6y"
//      row; negative ages throw [ArgumentError].
//   4. **HL → SPL real-ear conversion** via [HlToSplRealEarConverter]
//      against a hand-computed expected vector for a 4-month-old with
//      a flat 50 dB HL audiogram and earmold + HA1 coupling. The
//      formula exercised is `SPL_realear[f] = HL[f] + RETSPL[f] +
//      RECD[f, age]` (Req 15.9).
//
// References:
//   - Bagatto, M., Moodie, S., Scollie, S., Seewald, R., Moodie, K.,
//     Pumford, J., & Liu, K. P. R. (2005). "Clinical protocols for
//     hearing instrument fitting in the Desired Sensation Level
//     method". *Trends in Amplification*, 9(4), 199–226 — Tables 3
//     and 4.
//   - University of Western Ontario, Child Amplification Lab,
//     "DSL v5 by Hand" (PDF), reproducing the same tables
//     (https://www.uwo.ca/nca/dsl/assets/DSL-5-by-Hand.pdf).
//     Local copy: `.kiro_tmp/refs/dsl-v5-by-hand.txt`.
//   - ANSI/ASA S3.6-2010 (R2020), Table 7 — RETSPL for ER-3A insert
//     phones / HA-1 coupler.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:hearing_aid_app/domain/audiogram_driven_presets/recd_provider.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';

// ─── Expected values (copied verbatim from Bagatto 2005 / DSL v5) ───────────
//
// Each row maps `frequency Hz → RECD dB` for the corresponding age
// anchor. The order of rows mirrors `_bagattoAgesMonths` in the
// implementation: 1, 4, 7, 10, 13, 16, 19, 22, 25, 34 mo + ">3y"
// (anchored at 36 mo) + "4-5y" (at 54 mo) + "6y" (at 72 mo) +
// "Adult >6y" (at 84 mo).

const _earmoldHa1Expected = <List<num>>[
  /* 1mo  */ [8, 12, 14, 17, 20, 20, 18, 19, 26],
  /* 4mo  */ [6, 10, 12, 15, 18, 18, 16, 16, 22],
  /* 7mo  */ [6, 9, 11, 14, 17, 18, 14, 15, 20],
  /* 10mo */ [5, 9, 11, 13, 16, 17, 14, 14, 19],
  /* 13mo */ [5, 9, 10, 13, 16, 17, 13, 13, 18],
  /* 16mo */ [4, 8, 10, 13, 16, 16, 13, 13, 17],
  /* 19mo */ [4, 8, 10, 13, 16, 16, 12, 12, 16],
  /* 22mo */ [4, 8, 10, 12, 15, 16, 12, 12, 16],
  /* 25mo */ [4, 8, 10, 12, 15, 16, 12, 12, 16],
  /* 34mo */ [3, 7, 9, 12, 15, 15, 11, 11, 15],
  /* >3y  */ [3, 7, 9, 11, 15, 15, 11, 11, 14],
  /* 4-5y */ [3, 7, 9, 11, 14, 15, 10, 10, 13],
  /* 6y   */ [3, 6, 8, 10, 14, 14, 10, 9, 13],
  /* >6y  */ [3, 5, 5, 7, 11, 10, 5, 5, 13],
];

const _earmoldHa2Expected = <List<num>>[
  /* 1mo  */ [8, 12, 13, 16, 17, 17, 16, 17, 21],
  /* 4mo  */ [6, 10, 12, 14, 15, 15, 13, 14, 17],
  /* 7mo  */ [6, 9, 11, 13, 14, 14, 12, 12, 15],
  /* 10mo */ [5, 9, 10, 12, 14, 13, 11, 12, 13],
  /* 13mo */ [5, 9, 10, 12, 13, 13, 11, 11, 13],
  /* 16mo */ [4, 8, 10, 12, 13, 13, 10, 10, 12],
  /* 19mo */ [4, 8, 10, 12, 13, 12, 10, 10, 11],
  /* 22mo */ [4, 8, 10, 11, 13, 12, 10, 10, 11],
  /* 25mo */ [4, 8, 9, 11, 12, 12, 9, 9, 10],
  /* 34mo */ [3, 7, 9, 11, 12, 12, 9, 9, 9],
  /* >3y  */ [3, 7, 9, 10, 12, 11, 9, 9, 9],
  /* 4-5y */ [3, 7, 8, 10, 11, 11, 8, 8, 8],
  /* 6y   */ [3, 6, 8, 9, 11, 11, 7, 7, 8],
  /* >6y  */ [3, 5, 5, 6, 8, 6, 2, 3, 8],
];

const _foamTipHa1Expected = <List<num>>[
  /* 1mo  */ [3, 8, 10, 13, 18, 19, 18, 23, 28],
  /* 4mo  */ [3, 7, 9, 12, 15, 16, 15, 20, 24],
  /* 7mo  */ [3, 6, 8, 11, 14, 15, 14, 19, 23],
  /* 10mo */ [3, 6, 8, 11, 13, 15, 14, 18, 22],
  /* 13mo */ [3, 6, 8, 11, 13, 14, 13, 17, 21],
  /* 16mo */ [3, 6, 8, 11, 13, 14, 13, 17, 21],
  /* 19mo */ [3, 6, 8, 11, 12, 14, 12, 17, 20],
  /* 22mo */ [3, 5, 8, 11, 12, 13, 12, 16, 20],
  /* 25mo */ [3, 5, 7, 10, 12, 13, 12, 16, 20],
  /* 34mo */ [3, 5, 7, 10, 11, 13, 11, 15, 19],
  /* >3y  */ [3, 5, 7, 10, 11, 13, 11, 15, 19],
  /* 4-5y */ [3, 5, 7, 10, 10, 12, 11, 15, 19],
  /* 6y   */ [3, 5, 7, 10, 10, 11, 11, 15, 19],
  /* >6y  */ [3, 4, 4, 6, 10, 9, 11, 15, 19],
];

const _foamTipHa2Expected = <List<num>>[
  /* 1mo  */ [3, 8, 9, 12, 15, 15, 15, 20, 23],
  /* 4mo  */ [3, 7, 8, 11, 12, 13, 13, 18, 19],
  /* 7mo  */ [3, 6, 8, 10, 11, 12, 12, 16, 18],
  /* 10mo */ [3, 6, 8, 10, 11, 11, 11, 16, 17],
  /* 13mo */ [3, 6, 8, 10, 10, 11, 11, 15, 16],
  /* 16mo */ [3, 6, 7, 10, 10, 10, 10, 15, 16],
  /* 19mo */ [3, 6, 7, 10, 9, 10, 10, 14, 15],
  /* 22mo */ [3, 5, 7, 10, 9, 10, 10, 14, 15],
  /* 25mo */ [3, 5, 7, 9, 9, 9, 9, 14, 15],
  /* 34mo */ [3, 5, 7, 9, 8, 9, 9, 13, 14],
  /* >3y  */ [3, 5, 7, 9, 8, 9, 9, 13, 14],
  /* 4-5y */ [3, 5, 7, 9, 7, 8, 8, 13, 13],
  /* 6y   */ [3, 5, 7, 9, 7, 8, 8, 13, 13],
  /* >6y  */ [3, 4, 4, 5, 7, 5, 8, 13, 13],
];

/// Anchor ages (months) used by the implementation. Mirrored here so
/// these tests do not depend on the private constant inside the impl.
const _anchorAgesMonths = <int>[
  1, 4, 7, 10, 13, 16, 19, 22, 25, 34, 36, 54, 72, 84,
];

/// Hz keys exposed by the implementation.
const _frequenciesHz = <int>[
  250, 500, 750, 1000, 1500, 2000, 3000, 4000, 6000,
];

/// Convenience matcher: every value in [actual] equals the
/// corresponding [expected] entry within [tolerance] dB.
void _expectRecdEquals(
  Map<int, double> actual,
  List<num> expected, {
  double tolerance = 1e-9,
}) {
  expect(actual.length, equals(expected.length),
      reason: 'RECD map must have $expected.length entries.');
  for (var i = 0; i < expected.length; i++) {
    final f = _frequenciesHz[i];
    final got = actual[f];
    final want = expected[i].toDouble();
    expect(got, isNotNull, reason: 'missing key $f Hz');
    expect(got, closeTo(want, tolerance),
        reason: 'mismatch at $f Hz: got=$got want=$want');
  }
}

void main() {
  const provider = BagattoRecdProvider();

  // ─── 1. Bit-exact lookup ────────────────────────────────────────────────
  group('BagattoRecdProvider — bit-exact lookup at every anchor age', () {
    for (var i = 0; i < _anchorAgesMonths.length; i++) {
      final ageMonths = _anchorAgesMonths[i];
      test('earmold+HA1 row $i (age=$ageMonths mo) matches Bagatto Table 3',
          () {
        final recd = provider.getRecd(ageMonths, RecdCoupling.earmoldHa1);
        _expectRecdEquals(recd, _earmoldHa1Expected[i]);
      });
      test('earmold+HA2 row $i (age=$ageMonths mo) matches Bagatto Table 3',
          () {
        final recd = provider.getRecd(ageMonths, RecdCoupling.earmoldHa2);
        _expectRecdEquals(recd, _earmoldHa2Expected[i]);
      });
      test('foamtip+HA1 row $i (age=$ageMonths mo) matches Bagatto Table 4',
          () {
        final recd = provider.getRecd(ageMonths, RecdCoupling.foamTipHa1);
        _expectRecdEquals(recd, _foamTipHa1Expected[i]);
      });
      test('foamtip+HA2 row $i (age=$ageMonths mo) matches Bagatto Table 4',
          () {
        final recd = provider.getRecd(ageMonths, RecdCoupling.foamTipHa2);
        _expectRecdEquals(recd, _foamTipHa2Expected[i]);
      });
    }
  });

  // ─── 2. Linear interpolation between anchors ────────────────────────────
  group('BagattoRecdProvider — linear interpolation between anchors', () {
    test(
      'age=2 mo (between 1 and 4) at 250 Hz earmold+HA1 → 7.333… dB',
      () {
        // tasks.md §14.5 example. linear(8, 6, 1, 4, 2) =
        //   8 + (6 - 8) × (2 - 1) / (4 - 1) = 8 - 2/3 = 7.333333…
        final recd = provider.getRecd(2, RecdCoupling.earmoldHa1);
        expect(recd[250], closeTo(8.0 - 2.0 / 3.0, 1e-9));
      },
    );

    test(
      'age=2 mo at every band interpolates linearly between 1mo and 4mo',
      () {
        final recd = provider.getRecd(2, RecdCoupling.earmoldHa1);
        for (var i = 0; i < _frequenciesHz.length; i++) {
          final f = _frequenciesHz[i];
          final lower = _earmoldHa1Expected[0][i].toDouble(); // 1mo
          final upper = _earmoldHa1Expected[1][i].toDouble(); // 4mo
          // t = (2 - 1) / (4 - 1) = 1/3
          final expected = lower + (upper - lower) * (1.0 / 3.0);
          expect(recd[f], closeTo(expected, 1e-9),
              reason: 'interp at $f Hz mismatch');
        }
      },
    );

    test(
      'age=5 mo (between 4 and 7) at 1000 Hz earmold+HA1 → 14.666… dB',
      () {
        // linear(15, 14, 4, 7, 5) = 15 + (14 - 15) × (5 - 4) / (7 - 4)
        //                         = 15 - 1/3 = 14.6666…
        final recd = provider.getRecd(5, RecdCoupling.earmoldHa1);
        expect(recd[1000], closeTo(15.0 - 1.0 / 3.0, 1e-9));
      },
    );

    test(
      'age=45 mo (between >3y@36 and 4-5y@54) at 4000 Hz earmold+HA1 → '
      '10.5 dB',
      () {
        // >3y row at 4000 Hz = 11; 4-5y row at 4000 Hz = 10.
        // t = (45 - 36) / (54 - 36) = 9/18 = 0.5 → 11 + (10-11)*0.5 = 10.5.
        final recd = provider.getRecd(45, RecdCoupling.earmoldHa1);
        expect(recd[4000], closeTo(10.5, 1e-9));
      },
    );

    test('interpolation produces a fresh map (no aliasing)', () {
      final a = provider.getRecd(5, RecdCoupling.earmoldHa1);
      final b = provider.getRecd(5, RecdCoupling.earmoldHa1);
      expect(identical(a, b), isFalse, reason: 'each call must allocate');
      a[250] = 999.9;
      expect(b[250], isNot(equals(999.9)));
    });
  });

  // ─── 3. Boundary policy ─────────────────────────────────────────────────
  group('BagattoRecdProvider — boundary policy', () {
    test('age=0 mo resolves to the 1-month row (verbatim)', () {
      final recd = provider.getRecd(0, RecdCoupling.earmoldHa1);
      _expectRecdEquals(recd, _earmoldHa1Expected[0]);
    });

    test('age=84 mo (= 7y) resolves to the Adult >6y row', () {
      final recd = provider.getRecd(84, RecdCoupling.earmoldHa1);
      _expectRecdEquals(recd, _earmoldHa1Expected.last);
    });

    test('age=120 mo (= 10y) resolves to the Adult >6y row', () {
      final recd = provider.getRecd(120, RecdCoupling.foamTipHa2);
      _expectRecdEquals(recd, _foamTipHa2Expected.last);
    });

    test('negative ages throw ArgumentError', () {
      expect(
        () => provider.getRecd(-1, RecdCoupling.earmoldHa1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('RecdProvider.adultDefault always returns the Adult row', () {
      final adult = RecdProvider.adultDefault();
      _expectRecdEquals(
        adult.getRecd(1, RecdCoupling.earmoldHa1),
        _earmoldHa1Expected.last,
      );
      _expectRecdEquals(
        adult.getRecd(34, RecdCoupling.foamTipHa2),
        _foamTipHa2Expected.last,
      );
      _expectRecdEquals(
        adult.getRecd(500, RecdCoupling.earmoldHa2),
        _earmoldHa2Expected.last,
      );
    });
  });

  // ─── 4. HL → SPL real-ear conversion ────────────────────────────────────
  group('HlToSplRealEarConverter — SPL_realear = HL + RETSPL + RECD', () {
    test(
      '4-month-old, flat 50 dB HL audiogram, foam tip + HA1 → '
      'matches HL + RETSPL + RECD per band within 1e-9 dB SPL',
      () {
        // RETSPL for ER-3A / HA-1 (ANSI S3.6-2010 Table 7), in dB SPL:
        //   250: 14   500: 5.5   750: 2    1000: 0    1500: 2
        //   2000: 3   3000: 3.5  4000: 5.5 6000: 2    8000: 0
        const retspl = <int, double>{
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

        // Bagatto 2005 Table 4 row "4 mo" (foam tip + HA1):
        //   250:3, 500:7, 750:9, 1000:12, 1500:15, 2000:16, 3000:15,
        //   4000:20, 6000:24
        // Bands {2500, 3500} are not tabulated by Bagatto; the
        // implementation log-interpolates RECD between adjacent bands.
        // 8000 Hz is in ANSI but not Bagatto → caps at the 6000 Hz RECD.
        const recdAt4mo = <int, double>{
          250: 3,
          500: 7,
          750: 9,
          1000: 12,
          1500: 15,
          2000: 16,
          3000: 15,
          4000: 20,
          6000: 24,
        };

        // Build a flat 50 dB HL audiogram on the 12 standard bands.
        final audiogram = Audiogram(thresholds: {
          for (final f in Audiogram.standardFrequencies) f: 50.0,
        });

        final spl = HlToSplRealEarConverter.convert(
          audiogram: audiogram,
          recdProvider: const BagattoRecdProvider(),
          ageMonths: 4,
          coupling: RecdCoupling.foamTipHa1,
        );

        // For tabulated bands (no interpolation), the formula is
        // exact. For 2500, 3500 and 8000 Hz we re-derive the same
        // log-frequency interpolation inline so the test does not
        // depend on the implementation's private helper.
        for (final f in Audiogram.standardFrequencies) {
          final retsplF = retspl[f] ?? _logInterp(f, retspl);
          final recdF = recdAt4mo[f] ?? _logInterp(f, recdAt4mo);
          final expected = 50.0 + retsplF + recdF;
          expect(spl[f], closeTo(expected, 1e-9),
              reason: 'SPL_realear mismatch at $f Hz '
                  '(50 + $retsplF + $recdF = $expected)');
        }
      },
    );

    test(
      'adult HL=0, earmold+HA1 reduces to RETSPL + Adult RECD row',
      () {
        final audiogram = Audiogram(thresholds: {
          for (final f in Audiogram.standardFrequencies) f: 0.0,
        });

        final spl = HlToSplRealEarConverter.convert(
          audiogram: audiogram,
          recdProvider: const BagattoRecdProvider(),
          ageMonths: 84, // Adult anchor
          coupling: RecdCoupling.earmoldHa1,
        );

        // Adult earmold+HA1: [3, 5, 5, 7, 11, 10, 5, 5, 13] over
        // [250, 500, 750, 1000, 1500, 2000, 3000, 4000, 6000] Hz.
        // Spot-check 250 Hz: 0 + 14 + 3 = 17 dB SPL.
        expect(spl[250], closeTo(17.0, 1e-9));
        // 1000 Hz: 0 + 0 + 7 = 7 dB SPL.
        expect(spl[1000], closeTo(7.0, 1e-9));
        // 4000 Hz: 0 + 5.5 + 5 = 10.5 dB SPL.
        expect(spl[4000], closeTo(10.5, 1e-9));
      },
    );

    test('lookupRetspl returns the tabulated value verbatim for known bands',
        () {
      expect(HlToSplRealEarConverter.lookupRetspl(1000), equals(0.0));
      expect(HlToSplRealEarConverter.lookupRetspl(4000), equals(5.5));
      expect(HlToSplRealEarConverter.lookupRetspl(250), equals(14.0));
    });
  });
}

/// Log-frequency interpolation for tests, mirroring the implementation
/// policy used inside [HlToSplRealEarConverter] for non-tabulated bands.
/// Public mirror so the test does not reach into private helpers.
double _logInterp(int f, Map<int, double> anchors) {
  final keys = anchors.keys.toList()..sort();
  if (f <= keys.first) return anchors[keys.first]!;
  if (f >= keys.last) return anchors[keys.last]!;
  var upper = keys.length - 1;
  for (var i = 1; i < keys.length; i++) {
    if (keys[i] >= f) {
      upper = i;
      break;
    }
  }
  final lower = upper - 1;
  final fLower = keys[lower].toDouble();
  final fUpper = keys[upper].toDouble();
  final logF = _ln(f.toDouble());
  final logL = _ln(fLower);
  final logU = _ln(fUpper);
  final t = (logF - logL) / (logU - logL);
  final vLower = anchors[keys[lower]]!;
  final vUpper = anchors[keys[upper]]!;
  return vLower + (vUpper - vLower) * t;
}

double _ln(double x) {
  return math.log(x);
}

/// Unit tests for [BundleBuilder].
///
/// Verifies:
/// - All 12 fields and ranges (Req 1.5, 1.6)
/// - gainScale effects (only on gainsDb, not on MPO/CR/NR) (Req 13.4)
/// - Exception propagation from delegated modules (Req 1.5)
/// - nrLevel based on mode (Req 1.2)
/// - derivedAt stored in bundle
///
/// Validates: Requirements 1.5, 1.6, 13.4
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:hearing_aid_app/domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/bundle_builder.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/operating_mode.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/loss_type.dart';
import 'package:hearing_aid_app/domain/entities/nl3_prescription_result.dart';
import 'package:hearing_aid_app/domain/entities/patient_profile.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';
import 'package:hearing_aid_app/domain/gain_prescriber_nl3.dart';

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

class MockGainPrescriberNL3 extends Mock implements GainPrescriberNL3 {}

class FakeAudiogram extends Fake implements Audiogram {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Creates a flat audiogram with [hlDb] dB HL at all 12 standard frequencies.
Audiogram _flatAudiogram(double hlDb) {
  return Audiogram(
    thresholds: {
      for (final f in Audiogram.standardFrequencies) f: hlDb,
    },
  );
}

/// Creates a mock NL3PrescriptionResult for a flat audiogram with gains
/// at approximately half-gain rule level.
NL3PrescriptionResult _fakeNl3Result({
  List<double>? gains,
  List<double>? compressionRatios,
  DateTime? timestamp,
}) {
  return NL3PrescriptionResult(
    prescribedGains: gains ?? List<double>.filled(12, 10.0),
    finalGains: gains ?? List<double>.filled(12, 10.0),
    compressionRatios: compressionRatios ?? List<double>.filled(12, 1.5),
    lossType: LossType.flat,
    mode: PrescriptionMode.quiet,
    cinActive: false,
    wdrcOverrides: null,
    ptaWarning: false,
    timestamp: timestamp ?? DateTime.utc(2026, 6, 3),
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(FakeAudiogram());
    registerFallbackValue(PrescriptionMode.quiet);
  });

  group('BundleBuilder — field counts and ranges', () {
    late MockGainPrescriberNL3 mockNl3;
    late BundleBuilder builder;
    late Audiogram flat30;
    final fixedTime = DateTime.utc(2026, 6, 3, 10, 0, 0);

    setUp(() {
      mockNl3 = MockGainPrescriberNL3();
      builder = BundleBuilder(nl3Prescriber: mockNl3);
      flat30 = _flatAudiogram(30.0);

      when(() => mockNl3.prescribeFromAudiogram(
            any(),
            profile: any(named: 'profile'),
            mode: any(named: 'mode'),
            timestamp: any(named: 'timestamp'),
          )).thenReturn(_fakeNl3Result(
        gains: List<double>.filled(12, 12.0),
        compressionRatios: List<double>.filled(12, 1.375),
      ));
    });

    test('builds bundle with 12 elements in each array field', () {
      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
      );

      expect(bundle.gainsDb.length, 12);
      expect(bundle.compressionRatios.length, 12);
      expect(bundle.compressionKneesDbSpl.length, 12);
      expect(bundle.mpoProfileDbSpl.length, 12);
    });

    test('gainsDb values are in [0, 50]', () {
      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
      );

      for (int i = 0; i < 12; i++) {
        expect(
          bundle.gainsDb[i],
          inInclusiveRange(
            AudiogramDrivenBundle.gainMinDb,
            AudiogramDrivenBundle.gainMaxDb,
          ),
          reason: 'gainsDb[$i]=${bundle.gainsDb[i]}',
        );
      }
    });

    test('compressionRatios values are in [1.0, 3.0]', () {
      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
      );

      for (int i = 0; i < 12; i++) {
        expect(
          bundle.compressionRatios[i],
          inInclusiveRange(
            AudiogramDrivenBundle.compressionRatioMin,
            AudiogramDrivenBundle.compressionRatioMax,
          ),
          reason: 'compressionRatios[$i]=${bundle.compressionRatios[i]}',
        );
      }
    });

    test('compressionKneesDbSpl values are in [35, 65]', () {
      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
      );

      for (int i = 0; i < 12; i++) {
        expect(
          bundle.compressionKneesDbSpl[i],
          inInclusiveRange(
            AudiogramDrivenBundle.compressionKneeMinDbSpl,
            AudiogramDrivenBundle.compressionKneeMaxDbSpl,
          ),
          reason:
              'compressionKneesDbSpl[$i]=${bundle.compressionKneesDbSpl[i]}',
        );
      }
    });

    test('mpoProfileDbSpl values are in [80, 132]', () {
      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
      );

      for (int i = 0; i < 12; i++) {
        expect(
          bundle.mpoProfileDbSpl[i],
          inInclusiveRange(
            AudiogramDrivenBundle.mpoMinDbSpl,
            AudiogramDrivenBundle.mpoMaxDbSpl,
          ),
          reason: 'mpoProfileDbSpl[$i]=${bundle.mpoProfileDbSpl[i]}',
        );
      }
    });

    test('bundle passes full validation (all fields in range)', () {
      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
      );

      final errors = bundle.validate();
      expect(errors, isEmpty, reason: 'Validation errors: $errors');
    });
  });

  group('BundleBuilder — explicit field assertions (task 10.2)', () {
    // Per task 10.2: build from a flat 30 dB HL audiogram,
    // PrescriptionMode.quiet, derivedAt=DateTime.utc(2026,1,1) and assert
    // every documented invariant of the public API contract.
    late MockGainPrescriberNL3 mockNl3;
    late BundleBuilder builder;
    late Audiogram flat30;
    final taskTimestamp = DateTime.utc(2026, 1, 1);

    setUp(() {
      mockNl3 = MockGainPrescriberNL3();
      builder = BundleBuilder(nl3Prescriber: mockNl3);
      flat30 = _flatAudiogram(30.0);

      when(() => mockNl3.prescribeFromAudiogram(
            any(),
            profile: any(named: 'profile'),
            mode: any(named: 'mode'),
            timestamp: any(named: 'timestamp'),
          )).thenReturn(_fakeNl3Result(
        gains: List<double>.filled(12, 12.0),
        compressionRatios: List<double>.filled(12, 1.375),
      ));
    });

    test('all 12 array fields, scalars, and metadata populated correctly', () {
      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: taskTimestamp,
      );

      // Array lengths.
      expect(bundle.gainsDb.length, 12);
      expect(bundle.compressionRatios.length, 12);
      expect(bundle.compressionKneesDbSpl.length, 12);
      expect(bundle.mpoProfileDbSpl.length, 12);

      // Range invariants per band.
      for (var i = 0; i < 12; i++) {
        expect(bundle.gainsDb[i], inInclusiveRange(0.0, 50.0));
        expect(bundle.compressionRatios[i], inInclusiveRange(1.0, 4.0));
        expect(bundle.compressionKneesDbSpl[i], inInclusiveRange(35.0, 65.0));
        expect(bundle.mpoProfileDbSpl[i], inInclusiveRange(80.0, 132.0));
      }

      // Knee formula sanity for HL=30: 35 + (30/120)*30 = 42.5.
      for (var i = 0; i < 12; i++) {
        expect(
          bundle.compressionKneesDbSpl[i],
          closeTo(42.5, 1e-9),
          reason: 'Knee at band $i for HL=30 should be 42.5',
        );
      }

      // NR level for quiet mode.
      expect(bundle.nrLevel, 1);

      // WDRC times must be populated and positive (defaults are 5/100 ms).
      expect(bundle.wdrcAttackMs, greaterThan(0));
      expect(bundle.wdrcReleaseMs, greaterThan(0));

      // Expansion knee broadband fixed at 35.0 dB SPL.
      expect(bundle.expansionKneeDbSpl, 35.0);

      // Default operating mode == diagnostic; gainScale == 1.0 by contract.
      expect(bundle.mode, OperatingMode.diagnostic);
      expect(bundle.gainScale, 1.0);

      // derivedAt is preserved bit-exact.
      expect(bundle.derivedAt, taskTimestamp);
      expect(bundle.derivedAt.isUtc, isTrue);

      // PrescriptionMode echoed in the bundle.
      expect(bundle.prescriptionMode, PrescriptionMode.quiet);
    });
  });

  group('BundleBuilder — MhlModule path', () {
    // mode=mhl bypasses GainPrescriberNL3 and delegates to MhlModule.
    // The bundle's lossType is set to LossType.flat regardless of the
    // audiogram shape, per the documented behavior in BundleBuilder
    // (see decisions in memoria.md §1).
    late MockGainPrescriberNL3 mockNl3;
    late BundleBuilder builder;
    final fixedTime = DateTime.utc(2026, 6, 3, 10, 0, 0);

    setUp(() {
      mockNl3 = MockGainPrescriberNL3();
      builder = BundleBuilder(nl3Prescriber: mockNl3);
    });

    test('mode=mhl results in lossType == LossType.flat (flat audiogram)', () {
      final flat10 = _flatAudiogram(10.0);

      final bundle = builder.buildFromAudiogram(
        flat10,
        mode: PrescriptionMode.mhl,
        derivedAt: fixedTime,
      );

      expect(bundle.lossType, LossType.flat);
      expect(bundle.prescriptionMode, PrescriptionMode.mhl);
      expect(bundle.nrLevel, 3); // mhl → 3
      // The mock NL3 prescriber must NOT be called when mode == mhl.
      verifyNever(() => mockNl3.prescribeFromAudiogram(
            any(),
            profile: any(named: 'profile'),
            mode: any(named: 'mode'),
            timestamp: any(named: 'timestamp'),
          ));
    });

    test('mode=mhl with non-flat audiogram still classifies as flat', () {
      // Sloping audiogram: low HL at 250 Hz, high HL at 8000 Hz.
      final sloping = Audiogram(thresholds: {
        for (final f in Audiogram.standardFrequencies)
          f: 5.0 + (Audiogram.standardFrequencies.indexOf(f) * 1.0),
      });

      final bundle = builder.buildFromAudiogram(
        sloping,
        mode: PrescriptionMode.mhl,
        derivedAt: fixedTime,
      );

      // Per BundleBuilder MhlModule branch: lossType is forced to flat
      // because MHL applies to normal hearing / minimal loss.
      expect(bundle.lossType, LossType.flat);
    });
  });

  group('BundleBuilder — gainScale=0.05 explicit clamp (Req 1.5)', () {
    late MockGainPrescriberNL3 mockNl3;
    late BundleBuilder builder;
    late Audiogram flat30;
    final fixedTime = DateTime.utc(2026, 6, 3, 10, 0, 0);

    setUp(() {
      mockNl3 = MockGainPrescriberNL3();
      builder = BundleBuilder(nl3Prescriber: mockNl3);
      flat30 = _flatAudiogram(30.0);

      when(() => mockNl3.prescribeFromAudiogram(
            any(),
            profile: any(named: 'profile'),
            mode: any(named: 'mode'),
            timestamp: any(named: 'timestamp'),
          )).thenReturn(_fakeNl3Result(
        gains: List<double>.filled(12, 20.0),
        compressionRatios: List<double>.filled(12, 1.5),
      ));
    });

    test('gainScale=0.05 is clamped to 0.10 in amplifier mode (Req 1.5)', () {
      // 0.05 is below the [0.10, 1.00] valid range and must be clamped to
      // 0.10 with a warning, per BundleBuilder._sanitizeGainScale.
      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
        operatingMode: OperatingMode.amplifier,
        gainScale: 0.05,
      );

      expect(bundle.gainScale, 0.10);
      // Verify gainsDb scaled by 0.10, not 0.05.
      for (var i = 0; i < 12; i++) {
        expect(bundle.gainsDb[i], closeTo(20.0 * 0.10, 1e-9));
      }
    });
  });

  group('BundleBuilder — gainScale in amplifier mode', () {
    late MockGainPrescriberNL3 mockNl3;
    late BundleBuilder builder;
    late Audiogram flat30;
    final fixedTime = DateTime.utc(2026, 6, 3, 10, 0, 0);
    final prescribedGains = List<double>.filled(12, 20.0);

    setUp(() {
      mockNl3 = MockGainPrescriberNL3();
      builder = BundleBuilder(nl3Prescriber: mockNl3);
      flat30 = _flatAudiogram(30.0);

      when(() => mockNl3.prescribeFromAudiogram(
            any(),
            profile: any(named: 'profile'),
            mode: any(named: 'mode'),
            timestamp: any(named: 'timestamp'),
          )).thenReturn(_fakeNl3Result(
        gains: prescribedGains,
        compressionRatios: List<double>.filled(12, 1.5),
      ));
    });

    test('gainScale=0.5 halves gainsDb vs gainScale=1.0 in amplifier mode',
        () {
      final bundleFull = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
        operatingMode: OperatingMode.amplifier,
        gainScale: 1.0,
      );

      final bundleHalf = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
        operatingMode: OperatingMode.amplifier,
        gainScale: 0.5,
      );

      for (int i = 0; i < 12; i++) {
        expect(
          bundleHalf.gainsDb[i],
          closeTo(bundleFull.gainsDb[i] * 0.5, 0.01),
          reason:
              'Band $i: expected ${bundleFull.gainsDb[i] * 0.5}, '
              'got ${bundleHalf.gainsDb[i]}',
        );
      }
    });

    test('gainScale in diagnostic mode is forced to 1.0 (gainsDb unchanged)',
        () {
      final bundleNoScale = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
        operatingMode: OperatingMode.diagnostic,
        gainScale: 1.0,
      );

      final bundleWithScale = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
        operatingMode: OperatingMode.diagnostic,
        gainScale: 0.5,
      );

      // In diagnostic mode, gainScale is forced to 1.0 so gainsDb should be
      // identical regardless of the value passed.
      for (int i = 0; i < 12; i++) {
        expect(
          bundleWithScale.gainsDb[i],
          bundleNoScale.gainsDb[i],
          reason: 'Diagnostic mode should ignore gainScale. Band $i differs.',
        );
      }
      expect(bundleWithScale.gainScale, 1.0);
    });

    test('gainScale does NOT affect MPO, compressionRatios, or nrLevel', () {
      final bundleFull = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
        operatingMode: OperatingMode.amplifier,
        gainScale: 1.0,
      );

      final bundleHalf = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
        operatingMode: OperatingMode.amplifier,
        gainScale: 0.5,
      );

      // MPO unchanged
      expect(bundleHalf.mpoProfileDbSpl, bundleFull.mpoProfileDbSpl);
      // Compression ratios unchanged
      expect(bundleHalf.compressionRatios, bundleFull.compressionRatios);
      // Compression knees unchanged
      expect(
          bundleHalf.compressionKneesDbSpl, bundleFull.compressionKneesDbSpl);
      // NR level unchanged
      expect(bundleHalf.nrLevel, bundleFull.nrLevel);
    });
  });

  group('BundleBuilder — exception propagation', () {
    late MockGainPrescriberNL3 mockNl3;
    late BundleBuilder builder;
    late Audiogram flat30;
    final fixedTime = DateTime.utc(2026, 6, 3, 10, 0, 0);

    setUp(() {
      mockNl3 = MockGainPrescriberNL3();
      builder = BundleBuilder(nl3Prescriber: mockNl3);
      flat30 = _flatAudiogram(30.0);
    });

    test('propagates NL3 exception without wrapping', () {
      when(() => mockNl3.prescribeFromAudiogram(
            any(),
            profile: any(named: 'profile'),
            mode: any(named: 'mode'),
            timestamp: any(named: 'timestamp'),
          )).thenThrow(
        ArgumentError('Audiograma incompleto: se encontraron 6 de 12'),
      );

      expect(
        () => builder.buildFromAudiogram(
          flat30,
          mode: PrescriptionMode.quiet,
          derivedAt: fixedTime,
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('incompleto'),
        )),
      );
    });

    test('propagates StateError from NL3 without wrapping', () {
      when(() => mockNl3.prescribeFromAudiogram(
            any(),
            profile: any(named: 'profile'),
            mode: any(named: 'mode'),
            timestamp: any(named: 'timestamp'),
          )).thenThrow(
        StateError('Internal prescriber error'),
      );

      expect(
        () => builder.buildFromAudiogram(
          flat30,
          mode: PrescriptionMode.quiet,
          derivedAt: fixedTime,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('BundleBuilder — invalid audiogram validation', () {
    late BundleBuilder builder;
    final fixedTime = DateTime.utc(2026, 6, 3, 10, 0, 0);

    setUp(() {
      // Use real NL3 (won't be reached since validation happens first)
      builder = BundleBuilder();
    });

    test('throws ArgumentError for audiogram with missing frequencies', () {
      // Only 6 frequencies
      const incomplete = Audiogram(thresholds: {
        250: 30, 500: 30, 750: 30, 1000: 30, 1500: 30, 2000: 30,
      });

      expect(
        () => builder.buildFromAudiogram(
          incomplete,
          mode: PrescriptionMode.quiet,
          derivedAt: fixedTime,
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('incompleto'),
        )),
      );
    });

    test('throws ArgumentError for audiogram with threshold out of range', () {
      final outOfRange = Audiogram(thresholds: {
        for (final f in Audiogram.standardFrequencies)
          f: f == 4000 ? 130.0 : 30.0, // 130 > 120
      });

      expect(
        () => builder.buildFromAudiogram(
          outOfRange,
          mode: PrescriptionMode.quiet,
          derivedAt: fixedTime,
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('fuera de rango'),
        )),
      );
    });

    test('throws ArgumentError for audiogram with NaN threshold', () {
      final nanAudiogram = Audiogram(thresholds: {
        for (final f in Audiogram.standardFrequencies)
          f: f == 1000 ? double.nan : 30.0,
      });

      expect(
        () => builder.buildFromAudiogram(
          nanAudiogram,
          mode: PrescriptionMode.quiet,
          derivedAt: fixedTime,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws ArgumentError for audiogram with Infinity threshold', () {
      final infAudiogram = Audiogram(thresholds: {
        for (final f in Audiogram.standardFrequencies)
          f: f == 2000 ? double.infinity : 30.0,
      });

      expect(
        () => builder.buildFromAudiogram(
          infAudiogram,
          mode: PrescriptionMode.quiet,
          derivedAt: fixedTime,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('BundleBuilder — derivedAt timestamp', () {
    late MockGainPrescriberNL3 mockNl3;
    late BundleBuilder builder;
    late Audiogram flat30;

    setUp(() {
      mockNl3 = MockGainPrescriberNL3();
      builder = BundleBuilder(nl3Prescriber: mockNl3);
      flat30 = _flatAudiogram(30.0);

      when(() => mockNl3.prescribeFromAudiogram(
            any(),
            profile: any(named: 'profile'),
            mode: any(named: 'mode'),
            timestamp: any(named: 'timestamp'),
          )).thenReturn(_fakeNl3Result());
    });

    test('stores injected derivedAt in bundle', () {
      final timestamp = DateTime.utc(2026, 1, 15, 8, 30, 45, 123);

      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: timestamp,
      );

      expect(bundle.derivedAt, timestamp);
    });

    test('uses current time when derivedAt is null', () {
      final before = DateTime.now().toUtc();

      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        // derivedAt omitted → DateTime.now().toUtc()
      );

      final after = DateTime.now().toUtc();

      expect(bundle.derivedAt.isUtc, isTrue);
      expect(
        bundle.derivedAt.millisecondsSinceEpoch,
        greaterThanOrEqualTo(before.millisecondsSinceEpoch),
      );
      expect(
        bundle.derivedAt.millisecondsSinceEpoch,
        lessThanOrEqualTo(after.millisecondsSinceEpoch),
      );
    });
  });

  group('BundleBuilder — nrLevel based on mode', () {
    late MockGainPrescriberNL3 mockNl3;
    late BundleBuilder builder;
    late Audiogram flat30;
    final fixedTime = DateTime.utc(2026, 6, 3);

    setUp(() {
      mockNl3 = MockGainPrescriberNL3();
      builder = BundleBuilder(nl3Prescriber: mockNl3);
      flat30 = _flatAudiogram(30.0);

      when(() => mockNl3.prescribeFromAudiogram(
            any(),
            profile: any(named: 'profile'),
            mode: any(named: 'mode'),
            timestamp: any(named: 'timestamp'),
          )).thenReturn(_fakeNl3Result());
    });

    test('quiet mode → nrLevel = 1', () {
      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
      );
      expect(bundle.nrLevel, 1);
    });

    test('comfortInNoise mode → nrLevel = 2', () {
      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.comfortInNoise,
        derivedAt: fixedTime,
      );
      expect(bundle.nrLevel, 2);
    });

    test('mhl mode → nrLevel = 3', () {
      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.mhl,
        derivedAt: fixedTime,
      );
      expect(bundle.nrLevel, 3);
    });
  });

  group('BundleBuilder — gainScale clamping', () {
    late MockGainPrescriberNL3 mockNl3;
    late BundleBuilder builder;
    late Audiogram flat30;
    final fixedTime = DateTime.utc(2026, 6, 3, 10, 0, 0);
    final prescribedGains = List<double>.filled(12, 20.0);

    setUp(() {
      mockNl3 = MockGainPrescriberNL3();
      builder = BundleBuilder(nl3Prescriber: mockNl3);
      flat30 = _flatAudiogram(30.0);

      when(() => mockNl3.prescribeFromAudiogram(
            any(),
            profile: any(named: 'profile'),
            mode: any(named: 'mode'),
            timestamp: any(named: 'timestamp'),
          )).thenReturn(_fakeNl3Result(
        gains: prescribedGains,
        compressionRatios: List<double>.filled(12, 1.5),
      ));
    });

    test('gainScale > 1.0 is clamped to 1.0 in amplifier mode', () {
      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
        operatingMode: OperatingMode.amplifier,
        gainScale: 2.0,
      );

      // gainScale clamped to 1.0 (max)
      expect(bundle.gainScale, 1.0);
      // Gains should equal prescribedGains × 1.0
      for (int i = 0; i < 12; i++) {
        expect(bundle.gainsDb[i], closeTo(20.0, 0.01));
      }
    });

    test('gainScale < 0.10 is clamped to 0.10 in amplifier mode', () {
      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
        operatingMode: OperatingMode.amplifier,
        gainScale: 0.01,
      );

      // gainScale clamped to 0.10 (min)
      expect(bundle.gainScale, 0.10);
      // Gains should equal prescribedGains × 0.10
      for (int i = 0; i < 12; i++) {
        expect(bundle.gainsDb[i], closeTo(20.0 * 0.10, 0.01));
      }
    });

    test('gainScale=NaN is clamped to 0.10 in amplifier mode', () {
      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
        operatingMode: OperatingMode.amplifier,
        gainScale: double.nan,
      );

      expect(bundle.gainScale, 0.10);
    });

    test('gainScale=Infinity is clamped to 1.0 in amplifier mode', () {
      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
        operatingMode: OperatingMode.amplifier,
        gainScale: double.infinity,
      );

      expect(bundle.gainScale, 1.0);
    });

    test('gainScale=-Infinity is clamped to 0.10 in amplifier mode', () {
      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
        operatingMode: OperatingMode.amplifier,
        gainScale: double.negativeInfinity,
      );

      expect(bundle.gainScale, 0.10);
    });
  });

  group('BundleBuilder — real NL3 integration (no mock)', () {
    late BundleBuilder builder;
    late Audiogram flat30;
    final fixedTime = DateTime.utc(2026, 6, 3, 10, 0, 0);

    setUp(() {
      // Use real GainPrescriberNL3 to verify end-to-end behavior.
      builder = BundleBuilder();
      flat30 = _flatAudiogram(30.0);
    });

    test('real NL3: flat 30 dB HL → all fields valid and in range', () {
      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        profile: const PatientProfile(experienceMonths: 24, ageYears: 35),
        derivedAt: fixedTime,
      );

      // All arrays have 12 elements
      expect(bundle.gainsDb.length, 12);
      expect(bundle.compressionRatios.length, 12);
      expect(bundle.compressionKneesDbSpl.length, 12);
      expect(bundle.mpoProfileDbSpl.length, 12);

      // Full validation
      final errors = bundle.validate();
      expect(errors, isEmpty, reason: 'Validation errors: $errors');

      // Mode and metadata
      expect(bundle.mode, OperatingMode.diagnostic);
      expect(bundle.prescriptionMode, PrescriptionMode.quiet);
      expect(bundle.derivedAt, fixedTime);
      expect(bundle.gainScale, 1.0);
    });

    test('real NL3: compressionKnees for flat 30 dB HL all equal', () {
      // For flat 30 dB HL: knee = 35 + (30/120)*30 = 35 + 7.5 = 42.5
      final bundle = builder.buildFromAudiogram(
        flat30,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedTime,
      );

      for (int i = 0; i < 12; i++) {
        expect(
          bundle.compressionKneesDbSpl[i],
          closeTo(42.5, 0.01),
          reason: 'Knee at band $i should be 42.5 for flat 30 dB HL',
        );
      }
    });
  });
}

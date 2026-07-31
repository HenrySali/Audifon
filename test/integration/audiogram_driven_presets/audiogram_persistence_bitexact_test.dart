// Spec: audiogram-driven-presets · Wave 10, task 13.1.
//
// Bit-exact persistence test (Tramo 1: Audiograma → API).
//
// Walks the full persistence chain documented in design.md §"Persistencia"
// and tasks.md §13.1:
//
//   AudiometryResult (simulated capture) →
//   AudiometryStore.saveLast →
//   AudiometryStore.loadLast →
//   AudiometryResult.toAudiogram →
//   AudiogramRepository.saveAudiogram →
//   AudiogramRepository.getAudiogram
//
// For each of the 10 Bisgaard audiograms (N1–N7 + S1–S3) we assert
// that the threshold each frequency lands on at the *end* of the chain
// is within ≤ 0.001 dB HL of the threshold the simulated capture
// started with. Conversion to dB HL via [AudiometryResult.toAudiogram]
// is bit-exact (no DSP transform), so the only sources of drift this
// test guards against are:
//
//   - JSON encode/decode rounding inside [AudiometryStore].
//   - Hive-side typing changes (`Map<int, double>` → `Map<String, num>`
//     and back) inside [AudiogramRepositoryImpl].
//
// Implementation notes:
//
//   * Uses *real* implementations of [AudiometryStore] and
//     [AudiogramRepositoryImpl] (no mocks — the test exists to catch
//     bit-exactness regressions end-to-end, Req 15.1/15.2/15.4).
//
//   * The "capture" leg of the chain documented in tasks.md mentions
//     `AudiometryEngine`. The engine is a pure Hughson-Westlake state
//     machine that depends on a calibrated transducer: it does not
//     itself produce an [AudiometryResult]. The result is assembled by
//     `AudiometryController._finalize` from the engine's per-frequency
//     thresholds. For an integration test of *persistence*, building
//     the [AudiometryResult] directly with the Bisgaard thresholds is
//     equivalent to capturing them via the engine: from the moment the
//     [AudiometryResult] is built, every byte of the chain under test
//     is identical regardless of how the thresholds reached the result.
//     The ≤ 0.001 dB HL tolerance is therefore exercised end-to-end.
//
//   * Hive is initialised on a temporary directory in `setUpAll` and
//     fully torn down in `tearDownAll`.  The two boxes used by the
//     chain (`patient_audiometry_box` for [AudiometryStore],
//     `audiogram_box` for [AudiogramRepositoryImpl]) are opened
//     explicitly in `setUp` so each test starts from a clean state.
//
// Validates: Requirements 15.1, 15.2, 15.4.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:hearing_aid_app/audiometry/models/audiometry_result.dart';
import 'package:hearing_aid_app/audiometry/models/frequency_threshold_hl.dart';
import 'package:hearing_aid_app/audiometry/store/audiometry_store.dart';
import 'package:hearing_aid_app/data/repositories/audiogram_repository_impl.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';

// ─── Bisgaard fixtures ──────────────────────────────────────────────────────
//
// Bisgaard, Vlaming & Dahlquist (2010), "Standard Audiograms for the IEC
// 60118-15 Measurement Procedure", *Trends in Amplification* 14(2):113–120.
//
// Values mirror those in
// `test/domain/audiogram_driven_presets/ucl_estimator_test.dart` — keeping
// both files in sync intentionally so any future correction propagates.

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

/// All ten Bisgaard audiograms covered by this test, indexed by name so
/// failure messages identify the offending audiogram unambiguously.
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

/// Maximum allowed deviation per threshold across the full persistence
/// chain (Req 15.4: "Verify ≤ 0.001 dB HL deviation per threshold").
const double _kMaxDeviationDbHl = 0.001;

/// Builds a simulated [AudiometryResult] from a Bisgaard threshold map.
///
/// The result has all 12 standard audiometric frequencies populated and
/// is internally consistent (each [FrequencyThresholdHL] carries the
/// same `freqHz` as its key, all `outOfRange = false`, `normalLimit`
/// only true for HL = -10 — none of the Bisgaard fixtures reach that
/// value so it stays false in this test).
AudiometryResult _buildAudiometryResult(
  String label,
  Map<int, double> thresholds,
) {
  final frequencyThresholds = <int, FrequencyThresholdHL>{};
  for (final freq in Audiogram.standardFrequencies) {
    final hl = thresholds[freq];
    expect(hl, isNotNull,
        reason:
            'Bisgaard fixture $label is missing standard frequency $freq Hz');
    frequencyThresholds[freq] = FrequencyThresholdHL(
      freqHz: freq,
      thresholdHL: hl!,
    );
  }
  return AudiometryResult(
    // Use UTC + millisecond precision so JSON round-trips below preserve
    // the exact value; `DateTime.now()` would still round-trip but adds
    // microsecond noise on some platforms.
    testedAt: DateTime.utc(2026, 6, 4, 12, 0, 0),
    calibrationMac: 'AA:BB:CC:DD:EE:FF',
    calibrationDate: DateTime.utc(2026, 6, 1, 10, 0, 0),
    thresholds: frequencyThresholds,
    retest1000Diff: 0.0,
    patientAlias: 'Bisgaard $label',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempHiveDir;

  setUpAll(() async {
    tempHiveDir = await Directory.systemTemp.createTemp(
      'audiogram_persistence_bitexact_',
    );
    Hive.init(tempHiveDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempHiveDir.existsSync()) {
      try {
        await tempHiveDir.delete(recursive: true);
      } catch (_) {
        // Some Windows runs hold onto file handles briefly — non-fatal
        // for this test (the temp dir lives under %TEMP%).
      }
    }
  });

  setUp(() async {
    // Force a clean slate for both boxes so each iteration starts with
    // empty Hive state. We delete-from-disk because Hive may keep boxes
    // open across tests if `init` already happened in `setUpAll`.
    await Hive.deleteBoxFromDisk('patient_audiometry_box');
    await Hive.deleteBoxFromDisk(audiogramBoxName);
    // Initialise [AudiometryStore]'s box explicitly so the first call
    // to `saveLast`/`loadLast` does not race the open.
    await AudiometryStore.init();
  });

  tearDown(() async {
    if (Hive.isBoxOpen('patient_audiometry_box')) {
      await Hive.box<dynamic>('patient_audiometry_box').close();
    }
    if (Hive.isBoxOpen(audiogramBoxName)) {
      await Hive.box<dynamic>(audiogramBoxName).close();
    }
  });

  group('13.1 Bit-exact persistence — Bisgaard N1–N7 + S1–S3', () {
    for (final entry in _bisgaardAudiograms.entries) {
      final label = entry.key;
      final fixture = entry.value;

      test(
        'Bisgaard $label survives the full persistence chain '
        '(AudiometryResult → AudiometryStore → toAudiogram → '
        'AudiogramRepository) within ≤ $_kMaxDeviationDbHl dB HL '
        'per threshold',
        () async {
          // ── Step 1: simulated capture. ──
          final original = _buildAudiometryResult(label, fixture);

          // ── Step 2: persist via AudiometryStore.saveLast. ──
          await AudiometryStore.saveLast(original);

          // ── Step 3: load via AudiometryStore.loadLast. The reloaded
          //          result must match the original field-by-field
          //          (this is the Tramo-1 contract: persistence does
          //          not lose information). ──
          final reloaded = await AudiometryStore.loadLast();
          expect(reloaded, isNotNull,
              reason:
                  'AudiometryStore.loadLast returned null for Bisgaard '
                  '$label — the JSON round-trip lost the result');
          final reloadedNonNull = reloaded!;

          expect(
            reloadedNonNull.testedAt.toUtc(),
            original.testedAt.toUtc(),
            reason: 'testedAt drifted across saveLast/loadLast for $label',
          );
          expect(
            reloadedNonNull.calibrationMac,
            original.calibrationMac,
            reason:
                'calibrationMac drifted across saveLast/loadLast for $label',
          );
          expect(
            reloadedNonNull.calibrationDate.toUtc(),
            original.calibrationDate.toUtc(),
            reason:
                'calibrationDate drifted across saveLast/loadLast for $label',
          );
          expect(
            reloadedNonNull.patientAlias,
            original.patientAlias,
            reason:
                'patientAlias drifted across saveLast/loadLast for $label',
          );
          expect(
            reloadedNonNull.retest1000Diff,
            original.retest1000Diff,
            reason:
                'retest1000Diff drifted across saveLast/loadLast for $label',
          );
          expect(
            reloadedNonNull.thresholds.keys.toSet(),
            original.thresholds.keys.toSet(),
            reason:
                'threshold key set drifted across saveLast/loadLast for $label',
          );
          for (final freq in original.thresholds.keys) {
            final origT = original.thresholds[freq]!;
            final reT = reloadedNonNull.thresholds[freq]!;
            expect(reT.freqHz, origT.freqHz,
                reason:
                    'freqHz drifted at $freq Hz across saveLast/loadLast '
                    'for $label');
            expect(
              reT.thresholdHL,
              closeTo(origT.thresholdHL, _kMaxDeviationDbHl),
              reason:
                  'thresholdHL drifted > $_kMaxDeviationDbHl dB HL at '
                  '$freq Hz across saveLast/loadLast for $label '
                  '(orig=${origT.thresholdHL}, reloaded=${reT.thresholdHL})',
            );
            expect(reT.outOfRange, origT.outOfRange,
                reason: 'outOfRange flag drifted at $freq Hz for $label');
            expect(reT.normalLimit, origT.normalLimit,
                reason: 'normalLimit flag drifted at $freq Hz for $label');
          }

          // ── Step 4: convert reloaded result to [Audiogram] via
          //          [AudiometryResult.toAudiogram]. The conversion is
          //          a pure copy of `thresholdHL` per band (it skips
          //          `outOfRange` entries — none in Bisgaard fixtures
          //          — and fills with 0.0 dB HL when missing — which
          //          should not happen because we populate all 12
          //          standard frequencies). ──
          final audiogram = reloadedNonNull.toAudiogram();

          // Sanity check: 12 standard frequencies present.
          expect(
            audiogram.thresholds.keys.toSet(),
            Audiogram.standardFrequencies.toSet(),
            reason:
                'toAudiogram() did not produce the 12 standard '
                'frequencies for Bisgaard $label',
          );

          // ── Step 5: persist via AudiogramRepository.saveAudiogram. ──
          final box = await AudiogramRepositoryImpl.openBox();
          final repo = AudiogramRepositoryImpl(box);
          await repo.saveAudiogram(audiogram);

          // ── Step 6: recover via AudiogramRepository.getAudiogram. ──
          final recovered = await repo.getAudiogram();
          expect(recovered, isNotNull,
              reason:
                  'AudiogramRepository.getAudiogram returned null for '
                  'Bisgaard $label — Hive round-trip lost the audiogram');
          final recoveredNonNull = recovered!;

          // ── Step 7: assert per-frequency deviation. ──
          //
          // The chain end-to-end equality is:
          //
          //   recoveredNonNull.thresholds[f] ≈ fixture[f]
          //
          // because every step in between (build → JSON → JSON⁻¹ →
          // toAudiogram → Hive map → Hive map⁻¹) is value-preserving
          // for finite doubles. The tolerance is the spec-mandated
          // 0.001 dB HL.
          for (final freq in Audiogram.standardFrequencies) {
            final originalHl = fixture[freq]!;
            final recoveredHl = recoveredNonNull.thresholds[freq];
            expect(recoveredHl, isNotNull,
                reason:
                    'recovered audiogram is missing standard frequency '
                    '$freq Hz for Bisgaard $label');
            final delta = (recoveredHl! - originalHl).abs();
            expect(
              delta,
              lessThanOrEqualTo(_kMaxDeviationDbHl),
              reason:
                  '|recovered.thresholds[$freq] - original[$freq]| = '
                  '$delta dB HL > $_kMaxDeviationDbHl dB HL for '
                  'Bisgaard $label (original=$originalHl, '
                  'recovered=$recoveredHl)',
            );
          }
        },
      );
    }
  });
}

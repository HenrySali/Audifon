import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/bundle_builder.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';

import '../fixtures/nal_r_reference_table.dart';

/// Integration test for CIN end-to-end via [BundleBuilder].
///
/// Validates task 6.3 of `system-audit-fix`:
/// - Construir bundle quiet vs comfortInNoise para Bisgaard N3 sin mocks.
/// - bundle_cin.prescriptionMode == comfortInNoise y nrLevel == 2.
/// - Ganancias non-speech band (índices 0=250, 10=6000, 11=8000) en
///   modo CIN deben ser ≤ quiet - 1 dB (CinModule reduce 3-6 dB; ese
///   delta debe propagarse al bundle final si la task 6.1 está cableada).
/// - Speech band (índices 1-9: 500-4000 Hz) preservada dentro de 1 dB.
void main() {
  group('CIN end-to-end via BundleBuilder', () {
    test(
        'mode=comfortInNoise reduce ganancias non-speech band vs quiet '
        '(Bisgaard N3)', () {
      final n3 = nalRBisgaardAudiograms['N3']!;
      final audiogram = Audiogram(thresholds: n3);
      final builder = BundleBuilder();
      final fixedClock = DateTime.utc(2026, 6, 5, 12, 0, 0);

      final quiet = builder.buildFromAudiogram(
        audiogram,
        mode: PrescriptionMode.quiet,
        derivedAt: fixedClock,
      );
      final cin = builder.buildFromAudiogram(
        audiogram,
        mode: PrescriptionMode.comfortInNoise,
        derivedAt: fixedClock,
      );

      // Metadata del bundle CIN.
      expect(cin.prescriptionMode, equals(PrescriptionMode.comfortInNoise));
      expect(cin.nrLevel, equals(2));

      // Non-speech bands: 250, 6000, 8000 deben tener reducción ≥ 1 dB.
      // CinModule reduce 3-6 dB; el delta mínimo asegura que la
      // reducción se propaga al bundle final (task 6.1 cableada).
      for (final i in [0, 10, 11]) {
        expect(
          cin.gainsDb[i],
          lessThanOrEqualTo(quiet.gainsDb[i] - 1.0),
          reason: 'Band index $i should have CIN reduction '
              '(quiet=${quiet.gainsDb[i]}, cin=${cin.gainsDb[i]})',
        );
      }

      // Speech bands 500-4000 Hz (índices 1-9): preservar dentro de 1 dB.
      for (final i in [1, 2, 3, 4, 5, 6, 7, 8, 9]) {
        final delta = (cin.gainsDb[i] - quiet.gainsDb[i]).abs();
        expect(
          delta,
          lessThanOrEqualTo(1.0),
          reason: 'Speech band $i preserved within 1 dB '
              '(quiet=${quiet.gainsDb[i]}, cin=${cin.gainsDb[i]}, '
              'delta=$delta)',
        );
      }
    });
  });
}

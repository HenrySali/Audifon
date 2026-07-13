/// Tests unitarios para [AudiometryResult] y [FrequencyThresholdHL].
///
/// Verifica:
///   - Roundtrip JSON `toJson` → `fromJson` preserva todos los campos
///     (incluyendo `schema_version` y los flags `outOfRange`/`normalLimit`).
///   - El campo `schema_version` está presente en el JSON con el valor
///     declarado en la constante estática.
///   - `toAudiogram()` ignora frecuencias marcadas como `outOfRange` y las
///     completa con 0.0 dB HL (audición normal supuesta) en el audiograma
///     resultante; las frecuencias válidas se transfieren con su `thresholdHL`.
///
/// Estos tests no requieren plugins ni Flutter binding: solo `flutter_test`
/// y los modelos puros de `lib/audiometry/models/`.
///
/// Requisitos validados: 5, 7 (audiograma autopoblado y persistencia JSON).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:hearing_aid_app/audiometry/models/audiometry_result.dart';
import 'package:hearing_aid_app/audiometry/models/frequency_threshold_hl.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';

void main() {
  AudiometryResult buildSampleResult() {
    return AudiometryResult(
      testedAt: DateTime.utc(2025, 3, 15, 14, 30, 0),
      calibrationMac: 'AA:BB:CC:DD:EE:FF',
      calibrationDate: DateTime.utc(2025, 3, 1, 10, 0, 0),
      thresholds: const {
        250: FrequencyThresholdHL(
          freqHz: 250,
          thresholdHL: 10.0,
          outOfRange: false,
          normalLimit: false,
        ),
        1000: FrequencyThresholdHL(
          freqHz: 1000,
          thresholdHL: 25.0,
          outOfRange: false,
          normalLimit: false,
        ),
        4000: FrequencyThresholdHL(
          freqHz: 4000,
          thresholdHL: -10.0,
          outOfRange: false,
          normalLimit: true,
        ),
        8000: FrequencyThresholdHL(
          freqHz: 8000,
          thresholdHL: 80.0,
          outOfRange: true,
          normalLimit: false,
        ),
      },
      retest1000Diff: 5.0,
      patientAlias: 'Paciente Test',
    );
  }

  group('AudiometryResult — roundtrip JSON', () {
    test('toJson → fromJson preserva todos los campos', () {
      final original = buildSampleResult();

      final encoded = jsonEncode(original.toJson());
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      final restored = AudiometryResult.fromJson(decoded);

      expect(restored.testedAt.toUtc(), original.testedAt.toUtc());
      expect(restored.calibrationMac, original.calibrationMac);
      expect(restored.calibrationDate.toUtc(),
          original.calibrationDate.toUtc());
      expect(restored.retest1000Diff, original.retest1000Diff);
      expect(restored.patientAlias, original.patientAlias);

      expect(restored.thresholds.keys.toSet(),
          original.thresholds.keys.toSet());
      original.thresholds.forEach((freq, t) {
        final r = restored.thresholds[freq]!;
        expect(r.freqHz, t.freqHz);
        expect(r.thresholdHL, closeTo(t.thresholdHL, 1e-12));
        expect(r.outOfRange, t.outOfRange);
        expect(r.normalLimit, t.normalLimit);
      });
    });

    test('roundtrip funciona aunque retest1000Diff sea null', () {
      final original = AudiometryResult(
        testedAt: DateTime.utc(2025, 3, 15, 14, 30, 0),
        calibrationMac: 'AA:BB:CC:DD:EE:FF',
        calibrationDate: DateTime.utc(2025, 3, 1, 10, 0, 0),
        thresholds: const {
          1000: FrequencyThresholdHL(
            freqHz: 1000,
            thresholdHL: 20.0,
          ),
        },
        retest1000Diff: null,
        patientAlias: '',
      );

      final restored = AudiometryResult.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      expect(restored.retest1000Diff, isNull);
      expect(restored.patientAlias, '');
      expect(restored.thresholds[1000]!.thresholdHL, closeTo(20.0, 1e-12));
    });
  });

  group('AudiometryResult — schema_version', () {
    test('toJson incluye schema_version con el valor de la constante', () {
      final result = buildSampleResult();
      final json = result.toJson();

      expect(json.containsKey('schema_version'), isTrue,
          reason: 'El JSON debe exponer schema_version para futuras '
              'migraciones de formato.');
      expect(json['schema_version'], equals(AudiometryResult.schemaVersion));
      expect(AudiometryResult.schemaVersion, isNotEmpty);
    });
  });

  group('AudiometryResult — toAudiogram()', () {
    test('ignora outOfRange (8000Hz) y conserva los umbrales válidos', () {
      // Resultado con 1000 Hz medido (20 dB HL) y 8000 Hz fuera de rango.
      final result = AudiometryResult(
        testedAt: DateTime.utc(2025, 3, 15, 14, 30, 0),
        calibrationMac: 'AA:BB:CC:DD:EE:FF',
        calibrationDate: DateTime.utc(2025, 3, 1, 10, 0, 0),
        thresholds: const {
          1000: FrequencyThresholdHL(
            freqHz: 1000,
            thresholdHL: 20.0,
          ),
          8000: FrequencyThresholdHL(
            freqHz: 8000,
            thresholdHL: 80.0,
            outOfRange: true,
          ),
        },
        retest1000Diff: null,
        patientAlias: 'Test',
      );

      final audiogram = result.toAudiogram();

      // El audiograma resultante DEBE tener exactamente las 12 frecuencias
      // estándar para que la prescripción NAL-NL2 nunca encuentre faltantes.
      expect(
        audiogram.thresholds.keys.toSet(),
        equals(Audiogram.standardFrequencies.toSet()),
      );

      // 1000 Hz se conserva con 20 dB HL.
      expect(audiogram.thresholds[1000], closeTo(20.0, 1e-12));

      // 8000 Hz fue outOfRange → se reemplaza por 0.0 (audición normal).
      expect(audiogram.thresholds[8000], closeTo(0.0, 1e-12));

      // Las demás frecuencias (no medidas) también se completan con 0.0.
      for (final freq in Audiogram.standardFrequencies) {
        if (freq == 1000) continue;
        expect(audiogram.thresholds[freq], closeTo(0.0, 1e-12),
            reason: 'Frecuencia no medida $freq debe ser 0.0 dB HL');
      }
    });
  });
}

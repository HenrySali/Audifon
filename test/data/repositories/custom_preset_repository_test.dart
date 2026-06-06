import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:hearing_aid_app/data/repositories/profile_repository_impl.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/bundle_builder.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/custom_preset_record.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/manual_adjustment_delta.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/operating_mode.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/profile_repository_warning.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/style_applicator.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/loss_type.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';

/// Unit tests for the bundle-driven extensions on [ProfileRepositoryImpl]
/// covering tasks 7.1–7.5 of the audiogram-driven-presets spec.
void main() {
  late Box<dynamic> box;
  late ProfileRepositoryImpl repo;
  late BundleBuilder builder;

  /// Audiograma plano de 30 dB HL en las 12 frecuencias estándar.
  Audiogram flatAudiogram(double hl) => Audiogram(thresholds: {
        for (final f in Audiogram.standardFrequencies) f: hl,
      });

  setUp(() async {
    Hive.init('./test_hive_custom_preset_temp');
    box = await Hive.openBox('test_custom_preset_box');
    builder = BundleBuilder();
    repo = ProfileRepositoryImpl(box, bundleBuilder: builder);
  });

  tearDown(() async {
    await repo.dispose();
    await box.clear();
    await Hive.close();
  });

  group('saveCustomProfile (task 7.1)', () {
    test('persists full bundle blob and returns it via getCustomPresetByName',
        () async {
      final audiogram = flatAudiogram(30.0);
      final bundle = builder.buildFromAudiogram(
        audiogram,
        mode: PrescriptionMode.quiet,
        derivedAt: DateTime.utc(2026, 6, 3, 12, 0, 0),
      );

      await repo.saveCustomProfile(
        name: 'Mi Preset',
        audiogram: audiogram,
        bundle: bundle,
        appliedStyleName: 'Voice Clarity',
        nrOverride: 1,
        manualDelta: ManualAdjustmentDelta.zero(),
        createdAt: DateTime.utc(2026, 6, 3, 12, 0, 0),
      );

      final loaded = await repo.getCustomPresetByName('Mi Preset');
      expect(loaded, isNotNull);
      expect(loaded!.name, 'Mi Preset');
      expect(loaded.audiogram, equals(audiogram));
      expect(loaded.bundle, equals(bundle));
      expect(loaded.appliedStyleName, 'Voice Clarity');
      expect(loaded.nrOverride, 1);
      expect(loaded.stale, isFalse);
      expect(loaded.migrated, isFalse);
    });

    test('rejects predefined names (Silencioso/Conversación/Ruidoso)',
        () async {
      final audiogram = flatAudiogram(20.0);
      final bundle = builder.buildFromAudiogram(
        audiogram,
        mode: PrescriptionMode.quiet,
        derivedAt: DateTime.utc(2026, 1, 1),
      );
      expect(
        () => repo.saveCustomProfile(
          name: 'Silencioso',
          audiogram: audiogram,
          bundle: bundle,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects blob > 64 KB without overwriting previous preset',
        () async {
      final audiogram = flatAudiogram(30.0);
      final bundle = builder.buildFromAudiogram(
        audiogram,
        mode: PrescriptionMode.quiet,
        derivedAt: DateTime.utc(2026, 6, 3),
      );

      // Guardar un preset original.
      await repo.saveCustomProfile(
        name: 'Big',
        audiogram: audiogram,
        bundle: bundle,
        appliedStyleName: 'Normal',
        createdAt: DateTime.utc(2026, 6, 3),
      );
      final original = await repo.getCustomPresetByName('Big');
      expect(original, isNotNull);

      // Forzar tamaño >64 KB inflando el name (válido como String).
      final hugeName = 'X' * (CustomPresetRecord.maxBlobSizeBytes + 1);

      expect(
        () => repo.saveCustomProfile(
          name: hugeName,
          audiogram: audiogram,
          bundle: bundle,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('exceeds'),
          ),
        ),
      );

      // El preset previo "Big" sigue intacto.
      final still = await repo.getCustomPresetByName('Big');
      expect(still, equals(original));
    });

    test('preserves legacy fields in the persisted blob (read-back compat)',
        () async {
      final audiogram = flatAudiogram(40.0);
      final bundle = builder.buildFromAudiogram(
        audiogram,
        mode: PrescriptionMode.quiet,
        derivedAt: DateTime.utc(2026, 6, 3),
      );
      await repo.saveCustomProfile(
        name: 'Legacy View',
        audiogram: audiogram,
        bundle: bundle,
      );

      final raw = box.get('Legacy View') as String;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      expect(json['nrLevel'], isA<num>());
      expect(json['compressionRatio'], isA<num>());
      expect(json['expansionKnee'], isA<num>());
      expect(json['compressionKnee'], isA<num>());
      // El campo legacy debe coincidir con el bundle.
      expect(json['nrLevel'], equals(bundle.nrLevel));
      expect(json['expansionKnee'], equals(bundle.expansionKneeDbSpl));
    });
  });

  group('schema migration on load (task 7.2)', () {
    test('migrates legacy EnvironmentProfile-only blob and emits warning',
        () async {
      // Simular un blob legacy persistido como Map (versión muy vieja).
      await box.put('Old Preset', {
        'name': 'Old Preset',
        'nrLevel': 2,
        'compressionRatio': 2.0,
        'expansionKnee': 35.0,
        'compressionKnee': 50.0,
      });

      final warnings = <ProfileRepositoryWarning>[];
      final sub = repo.warnings.listen(warnings.add);

      final loaded = await repo.getCustomPresetByName('Old Preset');
      expect(loaded, isNotNull);
      expect(loaded!.name, 'Old Preset');
      expect(loaded.migrated, isTrue);
      expect(loaded.bundle.gainsDb.length, AudiogramDrivenBundle.bandCount);

      // La advertencia llega de forma asíncrona vía broadcast stream.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        warnings.any(
          (w) =>
              w.type == ProfileRepositoryWarningType.migrated &&
              w.presetName == 'Old Preset',
        ),
        isTrue,
      );

      // Tras la migración, el blob persistido tiene el nuevo schema.
      final raw = box.get('Old Preset') as String;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      expect(json['schemaVersion'], CustomPresetRecord.schemaVersion);
      expect(json['migrated'], isTrue);

      await sub.cancel();
    });
  });

  group('reject corrupt presets on load (task 7.5)', () {
    test('emits corrupt warning and excludes preset from listing', () async {
      // Blob con audiograma fuera de rango.
      final corruptThresholds = <String, double>{
        for (final f in Audiogram.standardFrequencies) f.toString(): 200.0,
      };
      final audiogram = flatAudiogram(30.0);
      final bundle = builder.buildFromAudiogram(
        audiogram,
        mode: PrescriptionMode.quiet,
        derivedAt: DateTime.utc(2026, 6, 3),
      );

      final corrupt = {
        'schemaVersion': CustomPresetRecord.schemaVersion,
        'name': 'Corrupt',
        'audiogram': {'thresholds': corruptThresholds},
        'bundle': bundle.toJson(),
        'appliedStyleName': '',
        'nrOverride': 0,
        'manualDelta': null,
        'createdAt': DateTime.utc(2026, 6, 3).toIso8601String(),
        'stale': false,
        'migrated': false,
        'nrLevel': 1,
        'compressionRatio': 1.5,
        'expansionKnee': 35.0,
        'compressionKnee': 50.0,
      };
      await box.put('Corrupt', jsonEncode(corrupt));

      final warnings = <ProfileRepositoryWarning>[];
      final sub = repo.warnings.listen(warnings.add);

      final list = await repo.getCustomPresets();
      expect(list, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        warnings.any(
          (w) =>
              w.type == ProfileRepositoryWarningType.corrupt &&
              w.presetName == 'Corrupt',
        ),
        isTrue,
      );

      await sub.cancel();
    });

    test('returns null for a single-preset corrupt fetch', () async {
      // Blob con bundle sin schemaVersion y sin campos válidos.
      await box.put('Bad Bundle', '{"schemaVersion":"9.9.9"}');

      final loaded = await repo.getCustomPresetByName('Bad Bundle');
      expect(loaded, isNull);
    });
  });

  group('markCustomPresetsAsStale (task 7.3)', () {
    test('marks only presets with MAD > thresholdDb', () async {
      final audiogramA = flatAudiogram(20.0);
      final audiogramB = flatAudiogram(30.0); // MAD=10 vs A.
      final bundleA = builder.buildFromAudiogram(
        audiogramA,
        mode: PrescriptionMode.quiet,
        derivedAt: DateTime.utc(2026, 6, 3),
      );
      final bundleB = builder.buildFromAudiogram(
        audiogramB,
        mode: PrescriptionMode.quiet,
        derivedAt: DateTime.utc(2026, 6, 3),
      );

      await repo.saveCustomProfile(
        name: 'NearAudiogram',
        audiogram: audiogramA,
        bundle: bundleA,
      );
      await repo.saveCustomProfile(
        name: 'FarAudiogram',
        audiogram: audiogramB,
        bundle: bundleB,
      );

      // Audiograma actual: igual a A. NearAudiogram queda fresh,
      // FarAudiogram debería marcarse stale.
      final failed = await repo.markCustomPresetsAsStale(audiogramA);
      expect(failed, isEmpty);

      final near = await repo.getCustomPresetByName('NearAudiogram');
      final far = await repo.getCustomPresetByName('FarAudiogram');
      expect(near?.stale, isFalse);
      expect(far?.stale, isTrue);
    });

    test('returns failed names for corrupt blobs', () async {
      // Insert corrupt blob directly.
      await box.put('Corrupt2', '{"schemaVersion":"9.9.9"}');

      final audiogram = flatAudiogram(30.0);
      final failed = await repo.markCustomPresetsAsStale(audiogram);
      expect(failed, contains('Corrupt2'));
    });
  });

  group('regenerateCustomPreset (task 7.4)', () {
    test('rebuilds bundle from current audiogram preserving style and clears '
        'stale', () async {
      final audiogramOld = flatAudiogram(20.0);
      final audiogramNew = flatAudiogram(45.0);

      final bundleOld = builder.buildFromAudiogram(
        audiogramOld,
        mode: PrescriptionMode.quiet,
        derivedAt: DateTime.utc(2026, 6, 3),
      );
      final styledOld = StyleApplicator.applyStyle(
        bundleOld,
        StyleApplicator.styleVoiceClarity,
        derivedAt: DateTime.utc(2026, 6, 3),
      );

      await repo.saveCustomProfile(
        name: 'Regen',
        audiogram: audiogramOld,
        bundle: styledOld,
        appliedStyleName: StyleApplicator.styleVoiceClarity,
      );
      // Marcar el preset como stale para verificar que se limpia.
      await repo.markCustomPresetsAsStale(audiogramNew);
      var loaded = await repo.getCustomPresetByName('Regen');
      expect(loaded?.stale, isTrue);

      await repo.regenerateCustomPreset(
        'Regen',
        audiogram: audiogramNew,
        mode: PrescriptionMode.quiet,
      );

      loaded = await repo.getCustomPresetByName('Regen');
      expect(loaded, isNotNull);
      expect(loaded!.audiogram, equals(audiogramNew));
      expect(loaded.appliedStyleName, StyleApplicator.styleVoiceClarity);
      expect(loaded.stale, isFalse);
      // El bundle se reconstruyó: las ganancias deberían diferir del
      // bundle original (porque el audiograma cambió).
      expect(loaded.bundle.gainsDb, isNot(equals(styledOld.gainsDb)));
    });

    test('rolls back on builder failure (preserves previous blob)', () async {
      final audiogram = flatAudiogram(30.0);
      final bundle = builder.buildFromAudiogram(
        audiogram,
        mode: PrescriptionMode.quiet,
        derivedAt: DateTime.utc(2026, 6, 3),
      );
      await repo.saveCustomProfile(
        name: 'Rollback',
        audiogram: audiogram,
        bundle: bundle,
        appliedStyleName: 'Normal',
      );

      // Audiograma incompleto: BundleBuilder lanza ArgumentError.
      final incomplete = Audiogram(thresholds: {250: 30.0});

      expect(
        () => repo.regenerateCustomPreset(
          'Rollback',
          audiogram: incomplete,
          mode: PrescriptionMode.quiet,
        ),
        throwsA(isA<ArgumentError>()),
      );

      // Preset original intacto.
      final after = await repo.getCustomPresetByName('Rollback');
      expect(after?.audiogram, equals(audiogram));
      expect(after?.bundle, equals(bundle));
    });

    test('rejects predefined names', () async {
      final audiogram = flatAudiogram(30.0);
      expect(
        () => repo.regenerateCustomPreset(
          'Conversación',
          audiogram: audiogram,
          mode: PrescriptionMode.quiet,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects regeneration of unknown preset', () async {
      final audiogram = flatAudiogram(30.0);
      expect(
        () => repo.regenerateCustomPreset(
          'Unknown',
          audiogram: audiogram,
          mode: PrescriptionMode.quiet,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('CustomPresetRecord JSON round-trip', () {
    test('serializes and deserializes losslessly', () {
      final audiogram = flatAudiogram(35.0);
      final bundle = AudiogramDrivenBundle(
        gainsDb: List<double>.filled(12, 12.0),
        compressionRatios: List<double>.filled(12, 1.5),
        compressionKneesDbSpl: List<double>.filled(12, 50.0),
        mpoProfileDbSpl: List<double>.filled(12, 100.0),
        nrLevel: 2,
        wdrcAttackMs: 5.0,
        wdrcReleaseMs: 100.0,
        expansionKneeDbSpl: 35.0,
        lossType: LossType.flat,
        prescriptionMode: PrescriptionMode.quiet,
        mode: OperatingMode.diagnostic,
        gainScale: 1.0,
        derivedAt: DateTime.utc(2026, 6, 3, 12, 0, 0),
      );

      final record = CustomPresetRecord(
        name: 'RT',
        audiogram: audiogram,
        bundle: bundle,
        appliedStyleName: 'Voice Clarity',
        nrOverride: 1,
        manualDelta: ManualAdjustmentDelta.zero(),
        createdAt: DateTime.utc(2026, 6, 3, 12, 0, 0),
      );

      final json = record.toJson();
      final hydrated = CustomPresetRecord.fromJson(json);

      expect(hydrated.name, record.name);
      expect(hydrated.audiogram, equals(record.audiogram));
      expect(hydrated.bundle, equals(record.bundle));
      expect(hydrated.appliedStyleName, record.appliedStyleName);
      expect(hydrated.nrOverride, record.nrOverride);
      expect(hydrated.manualDelta, equals(record.manualDelta));
      expect(hydrated.createdAt, record.createdAt);
    });
  });
}

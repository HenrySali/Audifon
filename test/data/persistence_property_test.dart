// Feature: psk-mobile-hearing-aid, Property 6: Persistence round-trip of configuration

/// Property-based test for persistence round-trip.
///
/// **Validates: Requirements 4.1, 8.4**
import 'dart:io';

import 'package:glados/glados.dart';
import 'package:hive/hive.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/environment_profile.dart';

/// Generate 12 threshold values from a seed.
Map<int, double> _seedToThresholds(double seed) {
  final freqs = Audiogram.standardFrequencies;
  final map = <int, double>{};
  for (int i = 0; i < 12; i++) {
    map[freqs[i]] = ((seed * (i + 1) * 7.3) % 120.0).abs();
  }
  return map;
}

void main() {
  late Directory tempDir;
  late Box<Map> audiogramBox;
  late Box<Map> settingsBox;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hive_test_');
    Hive.init(tempDir.path);
    audiogramBox = await Hive.openBox<Map>('test_audiogram');
    settingsBox = await Hive.openBox<Map>('test_settings');
  });

  tearDown(() async {
    await audiogramBox.close();
    await settingsBox.close();
    await Hive.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('Property 6: Persistence round-trip of configuration', () {
    Glados(any.doubleInRange(0, 120), ExploreConfig(numRuns: 100)).test(
      'audiogram round-trip: serialize/deserialize produces identical result',
      (seed) async {
        final thresholds = _seedToThresholds(seed);
        final original = Audiogram(thresholds: thresholds);

        // Serialize to Hive
        final serialized = <String, double>{};
        for (final entry in original.thresholds.entries) {
          serialized[entry.key.toString()] = entry.value;
        }
        await audiogramBox.put('audiogram', serialized);

        // Deserialize from Hive
        final stored = audiogramBox.get('audiogram')!;
        final deserialized = <int, double>{};
        for (final entry in stored.entries) {
          deserialized[int.parse(entry.key.toString())] =
              (entry.value as num).toDouble();
        }
        final restored = Audiogram(thresholds: deserialized);

        // Verify identity
        final freqs = Audiogram.standardFrequencies;
        expect(restored.thresholds.length, equals(original.thresholds.length));
        for (final freq in freqs) {
          expect(
            restored.thresholds[freq],
            closeTo(original.thresholds[freq]!, 0.0001),
            reason: 'Threshold at $freq Hz differs after round-trip',
          );
        }

        await audiogramBox.clear();
      },
    );

    Glados(any.doubleInRange(-20, 10), ExploreConfig(numRuns: 100)).test(
      'volume round-trip: serialize/deserialize produces identical result',
      (volume) async {
        await settingsBox.put('settings', {'lastVolume': volume});

        final stored = settingsBox.get('settings')!;
        final restored = (stored['lastVolume'] as num).toDouble();

        expect(restored, closeTo(volume, 0.0001));

        await settingsBox.clear();
      },
    );

    Glados(any.choose([
      EnvironmentProfile.quiet,
      EnvironmentProfile.conversation,
      EnvironmentProfile.noisy,
    ]), ExploreConfig(numRuns: 100)).test(
      'profile round-trip: serialize/deserialize produces identical result',
      (profile) async {
        final serialized = <String, dynamic>{
          'name': profile.name,
          'nrLevel': profile.nrLevel,
          'compressionRatio': profile.compressionRatio,
          'expansionKnee': profile.expansionKnee,
          'compressionKnee': profile.compressionKnee,
        };
        await settingsBox.put('profile', serialized);

        final stored = settingsBox.get('profile')!;
        final restored = EnvironmentProfile(
          name: stored['name'] as String,
          nrLevel: stored['nrLevel'] as int,
          compressionRatio: (stored['compressionRatio'] as num).toDouble(),
          expansionKnee: (stored['expansionKnee'] as num).toDouble(),
          compressionKnee: (stored['compressionKnee'] as num).toDouble(),
        );

        expect(restored, equals(profile));

        await settingsBox.clear();
      },
    );
  });
}

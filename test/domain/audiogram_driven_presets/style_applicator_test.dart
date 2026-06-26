/// Tests unitarios para StyleApplicator (sistema de 9 presets escalados).
///
/// Verifica la aplicación de cada uno de los 9 presets
/// (Suave/Medio/Alto × Plano/Voz/Agudos), la preservación de campos
/// no-gains, el clamp a [0, 50] dB y el manejo de presets desconocidos.
///
/// **Validates: Requirements 11.1, 12.x**
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/domain/entities/loss_type.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/operating_mode.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/style_applicator.dart';

// ─── Test fixtures ───────────────────────────────────────────────────────────

/// A "flat-gain" bundle with all gains at [gain] dB.
AudiogramDrivenBundle _flatGainBundle({double gain = 25.0}) {
  return AudiogramDrivenBundle(
    gainsDb: List<double>.filled(12, gain),
    compressionRatios: List<double>.filled(12, 1.5),
    compressionKneesDbSpl: List<double>.filled(12, 50.0),
    mpoProfileDbSpl: List<double>.filled(12, 110.0),
    prescribedTargetsDb: List<double>.filled(12, gain),
    nrLevel: 1,
    wdrcAttackMs: 5.0,
    wdrcReleaseMs: 100.0,
    expansionKneeDbSpl: 35.0,
    lossType: LossType.flat,
    prescriptionMode: PrescriptionMode.quiet,
    mode: OperatingMode.diagnostic,
    gainScale: 1.0,
    derivedAt: DateTime.utc(2026, 6, 3, 12, 0, 0),
  );
}

/// A bundle with gains near the upper bound to test clamping.
AudiogramDrivenBundle _nearMaxGainBundle() => _flatGainBundle(gain: 48.0);

/// A bundle with gains near the lower bound to test clamping.
AudiogramDrivenBundle _nearMinGainBundle() => _flatGainBundle(gain: 1.0);

void main() {
  group('StyleApplicator — unknown preset', () {
    test('unknown preset returns unchanged bundle (identical reference)', () {
      final bundle = _flatGainBundle();
      final result = StyleApplicator.applyStyle(bundle, 'NonExistentStyle');
      expect(identical(result, bundle), isTrue);
    });

    test('unknown preset does not throw', () {
      final bundle = _flatGainBundle();
      expect(
        () => StyleApplicator.applyStyle(bundle, 'InvalidStyleXYZ'),
        returnsNormally,
      );
    });

    test('empty string returns unchanged bundle', () {
      final bundle = _flatGainBundle();
      final result = StyleApplicator.applyStyle(bundle, '');
      expect(identical(result, bundle), isTrue);
    });

    test('legacy preset name (e.g. "Voice Clarity") returns unchanged bundle',
        () {
      // Legacy names from the previous 10-style system are no longer
      // recognized; they fall through to the unknown-style branch.
      final bundle = _flatGainBundle();
      final result = StyleApplicator.applyStyle(bundle, 'Voice Clarity');
      expect(identical(result, bundle), isTrue);
    });

    test('only intensity (without profile) is unknown', () {
      final bundle = _flatGainBundle();
      final result = StyleApplicator.applyStyle(bundle, 'Medio');
      expect(identical(result, bundle), isTrue);
    });

    test('only profile (without intensity) is unknown', () {
      final bundle = _flatGainBundle();
      final result = StyleApplicator.applyStyle(bundle, 'Voz');
      expect(identical(result, bundle), isTrue);
    });
  });

  group('StyleApplicator — all 9 presets produce gainsDb in [0, 50]', () {
    for (final styleName in StyleApplicator.supportedStyles) {
      test('preset "$styleName" keeps gainsDb in [0, 50] (mid-range bundle)',
          () {
        final bundle = _flatGainBundle();
        final result = StyleApplicator.applyStyle(bundle, styleName);
        for (int i = 0; i < 12; i++) {
          expect(result.gainsDb[i], greaterThanOrEqualTo(0.0),
              reason: 'Band $i below min');
          expect(result.gainsDb[i], lessThanOrEqualTo(50.0),
              reason: 'Band $i above max');
        }
      });
    }

    for (final styleName in StyleApplicator.supportedStyles) {
      test(
          'preset "$styleName" keeps gainsDb in [0, 50] (near-max-gain bundle)',
          () {
        final bundle = _nearMaxGainBundle();
        final result = StyleApplicator.applyStyle(bundle, styleName);
        for (int i = 0; i < 12; i++) {
          expect(result.gainsDb[i], greaterThanOrEqualTo(0.0),
              reason: 'Band $i below min');
          expect(result.gainsDb[i], lessThanOrEqualTo(50.0),
              reason: 'Band $i above max');
        }
      });
    }

    for (final styleName in StyleApplicator.supportedStyles) {
      test(
          'preset "$styleName" keeps gainsDb in [0, 50] (near-min-gain bundle)',
          () {
        final bundle = _nearMinGainBundle();
        final result = StyleApplicator.applyStyle(bundle, styleName);
        for (int i = 0; i < 12; i++) {
          expect(result.gainsDb[i], greaterThanOrEqualTo(0.0),
              reason: 'Band $i below min');
          expect(result.gainsDb[i], lessThanOrEqualTo(50.0),
              reason: 'Band $i above max');
        }
      });
    }
  });

  group('StyleApplicator — only gainsDb changes (other fields preserved)', () {
    for (final styleName in StyleApplicator.supportedStyles) {
      test('preset "$styleName" preserves non-gain fields', () {
        final bundle = _flatGainBundle();
        final result = StyleApplicator.applyStyle(bundle, styleName);

        expect(result.compressionRatios, equals(bundle.compressionRatios));
        expect(result.compressionKneesDbSpl,
            equals(bundle.compressionKneesDbSpl));
        expect(result.mpoProfileDbSpl, equals(bundle.mpoProfileDbSpl));
        expect(result.nrLevel, equals(bundle.nrLevel));
        expect(result.wdrcAttackMs, equals(bundle.wdrcAttackMs));
        expect(result.wdrcReleaseMs, equals(bundle.wdrcReleaseMs));
        expect(result.expansionKneeDbSpl, equals(bundle.expansionKneeDbSpl));
        expect(result.lossType, equals(bundle.lossType));
        expect(result.prescriptionMode, equals(bundle.prescriptionMode));
        expect(result.mode, equals(bundle.mode));
        expect(result.gainScale, equals(bundle.gainScale));
      });
    }
  });

  group('StyleApplicator — intensity multipliers on flat profile', () {
    test('Suave Plano scales base by 0.7', () {
      final bundle = _flatGainBundle(gain: 20.0);
      final result = StyleApplicator.applyStyle(bundle, 'Suave Plano');
      // 20 * 0.7 = 14.0 in every band.
      for (int i = 0; i < 12; i++) {
        expect(result.gainsDb[i], closeTo(14.0, 1e-9),
            reason: 'Band $i should scale by 0.7');
      }
    });

    test('Medio Plano leaves base unchanged (×1.0 + 0)', () {
      final bundle = _flatGainBundle(gain: 20.0);
      final result = StyleApplicator.applyStyle(bundle, 'Medio Plano');
      for (int i = 0; i < 12; i++) {
        expect(result.gainsDb[i], closeTo(20.0, 1e-9),
            reason: 'Band $i should equal base');
      }
    });

    test('Alto Plano scales base by 1.3', () {
      final bundle = _flatGainBundle(gain: 20.0);
      final result = StyleApplicator.applyStyle(bundle, 'Alto Plano');
      // 20 * 1.3 = 26.0 in every band.
      for (int i = 0; i < 12; i++) {
        expect(result.gainsDb[i], closeTo(26.0, 1e-9),
            reason: 'Band $i should scale by 1.3');
      }
    });
  });

  group('StyleApplicator — profile deltas at Medio intensity', () {
    test('Medio Voz: +3 dB in bands 1k–4k (indices 3..9)', () {
      final bundle = _flatGainBundle(gain: 20.0);
      final result = StyleApplicator.applyStyle(bundle, 'Medio Voz');
      // Profile Voz: [0,0,0,3,3,3,3,3,3,3,0,0]; mult=1.0.
      expect(result.gainsDb[0], closeTo(20.0, 1e-9));
      expect(result.gainsDb[1], closeTo(20.0, 1e-9));
      expect(result.gainsDb[2], closeTo(20.0, 1e-9));
      for (int i = 3; i <= 9; i++) {
        expect(result.gainsDb[i], closeTo(23.0, 1e-9),
            reason: 'Band $i should be base + 3');
      }
      expect(result.gainsDb[10], closeTo(20.0, 1e-9));
      expect(result.gainsDb[11], closeTo(20.0, 1e-9));
    });

    test('Medio Agudos: progressive boost above 3 kHz', () {
      final bundle = _flatGainBundle(gain: 20.0);
      final result = StyleApplicator.applyStyle(bundle, 'Medio Agudos');
      // Profile Agudos: [0,0,0,0,0,0,0,2,2,3,4,4]; mult=1.0.
      const expectedDeltas = <double>[0, 0, 0, 0, 0, 0, 0, 2, 2, 3, 4, 4];
      for (int i = 0; i < 12; i++) {
        expect(result.gainsDb[i], closeTo(20.0 + expectedDeltas[i], 1e-9),
            reason: 'Band $i should be base + ${expectedDeltas[i]}');
      }
    });
  });

  group('StyleApplicator — combined intensity × profile', () {
    test('Suave Voz: ×0.7 then +3 in mids', () {
      final bundle = _flatGainBundle(gain: 20.0);
      final result = StyleApplicator.applyStyle(bundle, 'Suave Voz');
      // 20 * 0.7 = 14, then +3 in indices 3..9 → 17.
      for (int i = 0; i < 3; i++) {
        expect(result.gainsDb[i], closeTo(14.0, 1e-9));
      }
      for (int i = 3; i <= 9; i++) {
        expect(result.gainsDb[i], closeTo(17.0, 1e-9));
      }
      expect(result.gainsDb[10], closeTo(14.0, 1e-9));
      expect(result.gainsDb[11], closeTo(14.0, 1e-9));
    });

    test('Alto Agudos: ×1.3 then progressive treble boost', () {
      final bundle = _flatGainBundle(gain: 20.0);
      final result = StyleApplicator.applyStyle(bundle, 'Alto Agudos');
      // 20 * 1.3 = 26, plus deltas [0,0,0,0,0,0,0,2,2,3,4,4].
      const expectedDeltas = <double>[0, 0, 0, 0, 0, 0, 0, 2, 2, 3, 4, 4];
      for (int i = 0; i < 12; i++) {
        expect(result.gainsDb[i], closeTo(26.0 + expectedDeltas[i], 1e-9),
            reason: 'Band $i: 26 + ${expectedDeltas[i]}');
      }
    });
  });

  group('StyleApplicator — clamping at boundaries', () {
    test('zero base remains zero with Suave Plano (×0.7 + 0 = 0)', () {
      final bundle = _flatGainBundle(gain: 0.0);
      final result = StyleApplicator.applyStyle(bundle, 'Suave Plano');
      for (int i = 0; i < 12; i++) {
        expect(result.gainsDb[i], equals(0.0));
      }
    });

    test('high base × Alto + treble delta is clamped to 50', () {
      // 45 * 1.3 = 58.5 → clamped to 50 in flat bands.
      final bundle = _flatGainBundle(gain: 45.0);
      final result = StyleApplicator.applyStyle(bundle, 'Alto Agudos');
      for (int i = 0; i < 12; i++) {
        expect(result.gainsDb[i], lessThanOrEqualTo(50.0),
            reason: 'Band $i must be clamped to 50');
      }
      // Bands 0..6 had no profile delta and computed 45*1.3 = 58.5 → 50.
      for (int i = 0; i < 7; i++) {
        expect(result.gainsDb[i], equals(50.0));
      }
    });

    test('zero base + voice profile boosts mids only', () {
      // 0 * mult = 0, plus delta 3 in mids → 3 in mids, 0 elsewhere.
      final bundle = _flatGainBundle(gain: 0.0);
      final result = StyleApplicator.applyStyle(bundle, 'Medio Voz');
      for (int i = 0; i < 3; i++) {
        expect(result.gainsDb[i], equals(0.0));
      }
      for (int i = 3; i <= 9; i++) {
        expect(result.gainsDb[i], equals(3.0));
      }
      expect(result.gainsDb[10], equals(0.0));
      expect(result.gainsDb[11], equals(0.0));
    });
  });

  group('StyleApplicator — supportedStyles', () {
    test('supportedStyles contains exactly 9 presets', () {
      expect(StyleApplicator.supportedStyles.length, equals(9));
    });

    test('supportedStyles contains all expected preset names in order', () {
      final expected = [
        'Suave Plano',
        'Suave Voz',
        'Suave Agudos',
        'Medio Plano',
        'Medio Voz',
        'Medio Agudos',
        'Alto Plano',
        'Alto Voz',
        'Alto Agudos',
      ];
      expect(StyleApplicator.supportedStyles, equals(expected));
    });

    test('supportedStyles is unmodifiable', () {
      final styles = StyleApplicator.supportedStyles;
      expect(() => styles.add('Custom'), throwsA(isA<UnsupportedError>()));
    });
  });

  group('StyleApplicator — derivedAt handling', () {
    test('derivedAt is preserved when not provided', () {
      final bundle = _flatGainBundle();
      final result = StyleApplicator.applyStyle(bundle, 'Medio Voz');
      expect(result.derivedAt, equals(bundle.derivedAt));
    });

    test('derivedAt is updated when provided', () {
      final bundle = _flatGainBundle();
      final newTime = DateTime.utc(2026, 8, 15, 9, 30, 0);
      final result =
          StyleApplicator.applyStyle(bundle, 'Medio Plano', derivedAt: newTime);
      expect(result.derivedAt, equals(newTime));
    });

    test('derivedAt is NOT updated when preset is unknown', () {
      final bundle = _flatGainBundle();
      final newTime = DateTime.utc(2026, 8, 15, 9, 30, 0);
      final result =
          StyleApplicator.applyStyle(bundle, 'Unknown', derivedAt: newTime);
      // Unknown returns the bundle unchanged (no derivedAt refresh).
      expect(identical(result, bundle), isTrue);
      expect(result.derivedAt, equals(bundle.derivedAt));
    });
  });

  group('StyleApplicator — determinism', () {
    for (final styleName in StyleApplicator.supportedStyles) {
      test('applying "$styleName" twice from base gives equal bundles', () {
        final bundle = _flatGainBundle();
        final a = StyleApplicator.applyStyle(bundle, styleName);
        final b = StyleApplicator.applyStyle(bundle, styleName);
        expect(a, equals(b));
        expect(a.gainsDb, equals(b.gainsDb));
      });
    }
  });
}

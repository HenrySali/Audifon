// Feature: audiogram-driven-presets, Properties 11.4 + 11.5
//
// Property-based tests para el [BundleBuilder] / [AudiogramDrivenBundle]:
//
// - **11.4 Determinism (Req 11.5)**: dos `buildFromAudiogram` con el mismo
//   audiograma + mismo `derivedAt` (timestamp inyectado, sin reloj) deben
//   producir bundles bit-idénticos en TODOS los campos del [Equatable.props],
//   incluyendo `derivedAt`. La prueba de "excluyendo derivedAt" del prompt se
//   subsume aquí porque el timestamp se fija desde afuera y no depende del
//   reloj (ver `BundleBuilder` - Req 1.3).
//
// - **11.5 JSON round-trip (Req 11.6)**: para cualquier bundle generado por
//   el builder, `AudiogramDrivenBundle.fromJson(b.toJson())` reproduce los
//   doubles dentro de ±0.001 (gainsDb, compressionRatios,
//   compressionKneesDbSpl, mpoProfileDbSpl), y los enteros, enums, strings y
//   timestamps de forma EXACTA (nrLevel, lossType, prescriptionMode, mode,
//   derivedAt al ms).
//
// Convención de generación seed-based (consistente con
// `test/domain/property/nl3_*_test.dart`): cada seed `double ∈ [0, 120]` se
// expande a 12 umbrales HL distribuidos pseudo-uniformemente con la misma
// fórmula que usa `nl3_determinism_test.dart`. Se garantiza HL ∈ [0, 120]
// dB HL por banda, lo que satisface la validación de [BundleBuilder].
//
// **Validates: Requirements 11.5, 11.6**
library;

// `glados/glados.dart` re-exporta `test`, `group`, `expect`, `closeTo`,
// `equals`, etc., desde `package:test_core` + `package:matcher`. Importar
// `flutter_test` adicionalmente provoca colisiones de identificadores
// (mismo patrón usado en `test/domain/property/*.dart`).
import 'package:glados/glados.dart';

import 'package:hearing_aid_app/domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/bundle_builder.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/operating_mode.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';

// ---------------------------------------------------------------------------
// Audiogram generator (seed-based)
// ---------------------------------------------------------------------------

/// Convierte un seed `double` a 12 umbrales HL ∈ [0, 120] dB HL en las 12
/// frecuencias estándar (Req 1.6, validado por `BundleBuilder`).
///
/// Usa la misma fórmula pseudo-hash que el resto de tests de propiedad del
/// repo (ver `nl3_determinism_test.dart`) para mantener cobertura
/// equivalente del espacio de audiogramas.
Audiogram _seedToAudiogram(double seed) {
  final freqs = Audiogram.standardFrequencies;
  final thresholds = <int, double>{};
  for (var i = 0; i < 12; i++) {
    thresholds[freqs[i]] = ((seed * (i + 1) * 7.3) % 120.0).abs();
  }
  return Audiogram(thresholds: thresholds);
}

/// Selecciona un [PrescriptionMode] de los 3 disponibles a partir del seed.
/// Cubre los tres modos (quiet, comfortInNoise, mhl) en muestras de 200 runs.
PrescriptionMode _seedToMode(double seed) {
  final modes = PrescriptionMode.values;
  final idx = (seed.abs() * 1000).floor() % modes.length;
  return modes[idx];
}

void main() {
  final builder = BundleBuilder();

  // Timestamp UTC fijo, con resolución de milisegundos. Igual al patrón usado
  // por `nl3_serialization_roundtrip_test.dart`. La precisión de ms es
  // necesaria para garantizar round-trip exacto con `toIso8601String`.
  final fixedTime = DateTime.utc(2026, 6, 1, 10, 0, 0);

  group('BundleBuilder property tests — serialization (11.4 + 11.5)', () {
    // -----------------------------------------------------------------------
    // 11.4 Determinism
    // -----------------------------------------------------------------------
    Glados2(
      any.doubleInRange(0, 120),
      any.doubleInRange(0, 100),
      ExploreConfig(numRuns: 200),
    ).test(
      '11.4 determinism — same audiogram + fixed derivedAt → equal bundles',
      (audiogramSeed, modeSeed) {
        final audiogram = _seedToAudiogram(audiogramSeed);
        final mode = _seedToMode(modeSeed);

        final b1 = builder.buildFromAudiogram(
          audiogram,
          mode: mode,
          derivedAt: fixedTime,
        );
        final b2 = builder.buildFromAudiogram(
          audiogram,
          mode: mode,
          derivedAt: fixedTime,
        );

        // Igualdad por banda (lista a lista) — más informativo que `equals`
        // a la hora de shrinking.
        expect(b1.gainsDb, equals(b2.gainsDb));
        expect(b1.compressionRatios, equals(b2.compressionRatios));
        expect(b1.compressionKneesDbSpl, equals(b2.compressionKneesDbSpl));
        expect(b1.mpoProfileDbSpl, equals(b2.mpoProfileDbSpl));

        // Escalares.
        expect(b1.nrLevel, equals(b2.nrLevel));
        expect(b1.wdrcAttackMs, equals(b2.wdrcAttackMs));
        expect(b1.wdrcReleaseMs, equals(b2.wdrcReleaseMs));
        expect(b1.expansionKneeDbSpl, equals(b2.expansionKneeDbSpl));
        expect(b1.gainScale, equals(b2.gainScale));

        // Metadata clínica.
        expect(b1.lossType, equals(b2.lossType));
        expect(b1.prescriptionMode, equals(b2.prescriptionMode));
        expect(b1.mode, equals(b2.mode));

        // Timestamp inyectado: igual por contrato.
        expect(b1.derivedAt, equals(b2.derivedAt));

        // Equatable.== completo (cubre cualquier campo no enumerado arriba).
        expect(b1, equals(b2));
      },
    );

    // -----------------------------------------------------------------------
    // 11.5 JSON round-trip
    // -----------------------------------------------------------------------
    Glados2(
      any.doubleInRange(0, 120),
      any.doubleInRange(0, 100),
      ExploreConfig(numRuns: 200),
    ).test(
      '11.5 JSON round-trip — fromJson(toJson(b)) ≈ b within 0.001 dB',
      (audiogramSeed, modeSeed) {
        final audiogram = _seedToAudiogram(audiogramSeed);
        final mode = _seedToMode(modeSeed);

        final original = builder.buildFromAudiogram(
          audiogram,
          mode: mode,
          derivedAt: fixedTime,
          // Cubre el branch del modo Amplificador (gainScale != 1.0) en una
          // fracción de los runs, para reforzar el round-trip de gainScale.
          operatingMode: (modeSeed.abs() * 100).floor() % 2 == 0
              ? OperatingMode.diagnostic
              : OperatingMode.amplifier,
          gainScale: 0.40,
        );

        final json = original.toJson();
        final restored = AudiogramDrivenBundle.fromJson(json);

        // Doubles por banda dentro de ±0.001 dB / dB SPL / adimensional.
        for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
          expect(
            restored.gainsDb[i],
            closeTo(original.gainsDb[i], 0.001),
            reason: 'gainsDb[$i] drift > 0.001 dB',
          );
          expect(
            restored.compressionRatios[i],
            closeTo(original.compressionRatios[i], 0.001),
            reason: 'compressionRatios[$i] drift > 0.001',
          );
          expect(
            restored.compressionKneesDbSpl[i],
            closeTo(original.compressionKneesDbSpl[i], 0.001),
            reason: 'compressionKneesDbSpl[$i] drift > 0.001 dB SPL',
          );
          expect(
            restored.mpoProfileDbSpl[i],
            closeTo(original.mpoProfileDbSpl[i], 0.001),
            reason: 'mpoProfileDbSpl[$i] drift > 0.001 dB SPL',
          );
        }

        // Doubles escalares dentro de ±0.001.
        expect(
          restored.wdrcAttackMs,
          closeTo(original.wdrcAttackMs, 0.001),
        );
        expect(
          restored.wdrcReleaseMs,
          closeTo(original.wdrcReleaseMs, 0.001),
        );
        expect(
          restored.expansionKneeDbSpl,
          closeTo(original.expansionKneeDbSpl, 0.001),
        );
        expect(
          restored.gainScale,
          closeTo(original.gainScale, 0.001),
        );

        // Ints / enums / strings exactos.
        expect(restored.nrLevel, equals(original.nrLevel));
        expect(restored.lossType, equals(original.lossType));
        expect(restored.prescriptionMode, equals(original.prescriptionMode));
        expect(restored.mode, equals(original.mode));

        // Timestamp exacto al ms (resolución que toIso8601String preserva).
        expect(
          restored.derivedAt.millisecondsSinceEpoch,
          equals(original.derivedAt.millisecondsSinceEpoch),
        );
      },
    );
  });
}

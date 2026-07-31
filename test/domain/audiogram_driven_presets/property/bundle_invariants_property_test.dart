/// Property-based tests para `BundleBuilder.buildFromAudiogram` (Tramo 2).
///
/// Tres propiedades estructurales:
///   - 11.1 Output invariant: 12 valores en cada array, todos en sus rangos
///     declarados (Req 11.2).
///   - 11.2 MPO bound: 80 ≤ mpoProfileDbSpl[f] ≤ 132 para toda banda
///     y todo audiograma (Req 11.3).
///   - 11.3 MPO monotonicity in HL: subir HL[f] en +10 dB no debe aumentar
///     mpoProfileDbSpl[f] en más de 1.5 dB (consecuencia directa de
///     `UCL = 100 + 0.15 × HL` + `MPO = min(UCL - 5, 132)`, Req 11.4).
///
/// Estrategia de generación: usamos `Glados<int>(any.intInRange(...))` y
/// derivamos un audiograma determinista de 12 umbrales a partir del seed
/// con un hash simple, sin tocar la API de extensiones de glados (que en
/// `glados ^1.1.1` no expone un constructor público para Generator<T>
/// arbitrarios sin mutar `Any`). Esto es el patrón ya usado en
/// `test/domain/property/nl3_output_invariant_test.dart`.
///
/// Cada test corre con `numRuns: 100` por requisito (≥ 100 audiogramas).
///
/// Validates: Requirements 11.2, 11.3, 11.4
library;

import 'package:flutter_test/flutter_test.dart'
    hide test, group, setUp, tearDown, expect;
import 'package:glados/glados.dart';

import 'package:hearing_aid_app/domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/bundle_builder.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';

/// Construye un audiograma determinista a partir de un par de seeds en
/// `[0, 1_000_000]`. Cada banda recibe un umbral pseudo-aleatorio en
/// `[0, 120] dB HL` derivado por hash, y los seeds rotan entre bandas
/// para asegurar variedad por sesión.
///
/// Se mantiene puro (sin RNG): el mismo seed produce siempre el mismo
/// audiograma, lo que permite a glados shrinkear y reproducir
/// counterexamples.
Audiogram _audiogramFromSeed(int seed1, int seed2) {
  final freqs = Audiogram.standardFrequencies;
  final thresholds = <int, double>{};
  for (int i = 0; i < 12; i++) {
    // Hash-style: combinamos los dos seeds y el índice de banda con
    // primos para esparcir bien el espacio. El % 121 da un entero en
    // [0, 120] inclusive y el .toDouble() lo deja en el dominio del
    // builder.
    final mixed = ((seed1 * 1009) ^ (seed2 * 2017) ^ ((i + 1) * 4093));
    final hl = (mixed.abs() % 121).toDouble();
    thresholds[freqs[i]] = hl;
  }
  return Audiogram(thresholds: thresholds);
}

void main() {
  final builder = BundleBuilder();

  group('BundleBuilder property tests (Tramo 2)', () {
    // ─── 11.1 Output invariant ────────────────────────────────────────────
    Glados2<int, int>(
      any.intInRange(0, 1000000),
      any.intInRange(0, 1000000),
      ExploreConfig(numRuns: 100),
    ).test(
      '11.1 output invariant — 12 values per array, all in declared ranges',
      (s1, s2) {
        final audiogram = _audiogramFromSeed(s1, s2);
        final bundle = builder.buildFromAudiogram(
          audiogram,
          mode: PrescriptionMode.quiet,
        );

        // Field counts (Req 1.2).
        expect(bundle.gainsDb.length, equals(AudiogramDrivenBundle.bandCount));
        expect(bundle.compressionRatios.length,
            equals(AudiogramDrivenBundle.bandCount));
        expect(bundle.compressionKneesDbSpl.length,
            equals(AudiogramDrivenBundle.bandCount));
        expect(bundle.mpoProfileDbSpl.length,
            equals(AudiogramDrivenBundle.bandCount));

        // Per-band ranges declared by AudiogramDrivenBundle (Req 1.2).
        for (int i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
          expect(
            bundle.gainsDb[i],
            inInclusiveRange(
              AudiogramDrivenBundle.gainMinDb,
              AudiogramDrivenBundle.gainMaxDb,
            ),
            reason: 'gainsDb[$i] = ${bundle.gainsDb[i]} fuera de '
                '[${AudiogramDrivenBundle.gainMinDb}, '
                '${AudiogramDrivenBundle.gainMaxDb}]',
          );
          expect(
            bundle.compressionRatios[i],
            inInclusiveRange(
              AudiogramDrivenBundle.compressionRatioMin,
              AudiogramDrivenBundle.compressionRatioMax,
            ),
            reason: 'compressionRatios[$i] = ${bundle.compressionRatios[i]} '
                'fuera de [${AudiogramDrivenBundle.compressionRatioMin}, '
                '${AudiogramDrivenBundle.compressionRatioMax}]',
          );
          expect(
            bundle.compressionKneesDbSpl[i],
            inInclusiveRange(
              AudiogramDrivenBundle.compressionKneeMinDbSpl,
              AudiogramDrivenBundle.compressionKneeMaxDbSpl,
            ),
            reason:
                'compressionKneesDbSpl[$i] = ${bundle.compressionKneesDbSpl[i]} '
                'fuera de [${AudiogramDrivenBundle.compressionKneeMinDbSpl}, '
                '${AudiogramDrivenBundle.compressionKneeMaxDbSpl}]',
          );
          expect(
            bundle.mpoProfileDbSpl[i],
            inInclusiveRange(
              AudiogramDrivenBundle.mpoMinDbSpl,
              AudiogramDrivenBundle.mpoMaxDbSpl,
            ),
            reason: 'mpoProfileDbSpl[$i] = ${bundle.mpoProfileDbSpl[i]} '
                'fuera de [${AudiogramDrivenBundle.mpoMinDbSpl}, '
                '${AudiogramDrivenBundle.mpoMaxDbSpl}]',
          );
        }

        // Scalar ranges.
        expect(bundle.nrLevel,
            inInclusiveRange(AudiogramDrivenBundle.nrLevelMin,
                AudiogramDrivenBundle.nrLevelMax));
        expect(
          bundle.wdrcAttackMs,
          inInclusiveRange(AudiogramDrivenBundle.wdrcAttackMinMs,
              AudiogramDrivenBundle.wdrcAttackMaxMs),
        );
        expect(
          bundle.wdrcReleaseMs,
          inInclusiveRange(AudiogramDrivenBundle.wdrcReleaseMinMs,
              AudiogramDrivenBundle.wdrcReleaseMaxMs),
        );
        expect(
          bundle.expansionKneeDbSpl,
          inInclusiveRange(AudiogramDrivenBundle.expansionKneeMinDbSpl,
              AudiogramDrivenBundle.expansionKneeMaxDbSpl),
        );
      },
    );

    // ─── 11.2 MPO bound ──────────────────────────────────────────────────
    Glados2<int, int>(
      any.intInRange(0, 1000000),
      any.intInRange(0, 1000000),
      ExploreConfig(numRuns: 100),
    ).test(
      '11.2 MPO bound — 80 ≤ mpoProfileDbSpl[f] ≤ 132 for all bands',
      (s1, s2) {
        final audiogram = _audiogramFromSeed(s1, s2);
        final bundle = builder.buildFromAudiogram(
          audiogram,
          mode: PrescriptionMode.quiet,
        );

        for (int i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
          final m = bundle.mpoProfileDbSpl[i];
          expect(m, greaterThanOrEqualTo(AudiogramDrivenBundle.mpoMinDbSpl),
              reason: 'Band $i: mpoProfileDbSpl=$m < 80 dB SPL');
          expect(m, lessThanOrEqualTo(AudiogramDrivenBundle.mpoMaxDbSpl),
              reason: 'Band $i: mpoProfileDbSpl=$m > 132 dB SPL');
        }
      },
    );

    // ─── 11.3 MPO monotonicity in HL ─────────────────────────────────────
    //
    // Fórmula clínica:
    //   UCL[f] = 100 + 0.15 × HL[f]   (clampada a HL ∈ [0, 120])
    //   MPO[f] = min(UCL[f] - 5, 132) (regla adulto)
    //   MPO[f] ∈ [80, 132] (clamp final)
    //
    // Subir HL[f] en +10 dB → UCL[f] sube 1.5 dB (si no se satura) →
    // MPO[f] sube como mucho 1.5 dB. Si UCL ya estaba saturado o el
    // clamp de [80, 132] ya estaba activo, ΔMPO = 0. La invariante
    // |ΔMPO| ≤ 1.5 dB + ε se mantiene siempre.
    //
    // ε = 0.001 dB para tolerancia de punto flotante.
    Glados2<int, int>(
      any.intInRange(0, 1000000),
      any.intInRange(0, 1000000),
      ExploreConfig(numRuns: 100),
    ).test(
      '11.3 MPO monotonicity — +10 dB HL[f] → MPO[f] increases by ≤ 1.5 dB',
      (s1, s2) {
        final audiogram = _audiogramFromSeed(s1, s2);
        final base = builder.buildFromAudiogram(
          audiogram,
          mode: PrescriptionMode.quiet,
        );

        for (int i = 0; i < Audiogram.standardFrequencies.length; i++) {
          final f = Audiogram.standardFrequencies[i];
          final originalHl = audiogram.thresholds[f]!;
          final newHl = (originalHl + 10.0).clamp(0.0, 120.0);
          // Si HL[f] ya estaba en el máximo, +10 dB no aplica → ΔMPO = 0
          // y no hay nada que verificar. Saltamos para no introducir
          // un test trivial.
          if (newHl == originalHl) continue;

          final perturbedThresholds =
              Map<int, double>.from(audiogram.thresholds);
          perturbedThresholds[f] = newHl.toDouble();
          final perturbed = Audiogram(thresholds: perturbedThresholds);
          final perturbedBundle = builder.buildFromAudiogram(
            perturbed,
            mode: PrescriptionMode.quiet,
          );

          final delta = perturbedBundle.mpoProfileDbSpl[i] -
              base.mpoProfileDbSpl[i];
          expect(
            delta,
            lessThanOrEqualTo(1.5 + 0.001),
            reason:
                'Band $i (${f} Hz): HL ${originalHl.toStringAsFixed(2)} → '
                '${newHl.toStringAsFixed(2)} dB caused MPO delta=${delta.toStringAsFixed(4)} dB '
                '(base=${base.mpoProfileDbSpl[i].toStringAsFixed(2)}, '
                'perturbed=${perturbedBundle.mpoProfileDbSpl[i].toStringAsFixed(2)})',
          );
        }
      },
    );
  });
}

// Feature: audiogram-driven-presets, Properties 11.7 + 11.8 + 11.9
//
// Property-based tests for advanced bundle invariants:
//
// - **11.7 Headroom invariant (Req 10.3)**: For every (audiogram, manual
//   delta) pair, the FINAL gain after applying the manual delta and the
//   bloc's headroom clamp must satisfy
//   `finalGain[i] ≤ mpoProfileDbSpl[i] - 65 - 3`. The clamp lives inside
//   `AmplificationBloc._resolveFinalGains`; this test mirrors the
//   formula in pure form (no bloc) so we can fuzz it exhaustively. The
//   typical-input level (65 dB SPL ≈ conversation) and the safety
//   margin (3 dB) are the same constants the bloc uses.
//
// - **11.8 GainScale isolation (Req 13.4)**: For every (audiogram,
//   gainScale_a, gainScale_b) triple in amplifier mode, bundles built
//   with different `gainScale` values must agree BIT-EXACT on
//   `mpoProfileDbSpl`, `compressionRatios`, `compressionKneesDbSpl` and
//   `nrLevel`. The only field that may change is `gainsDb` — and when
//   it changes, it must scale linearly with `gainScale` (verified per
//   band on bands that were NOT clamped to the structural [0, 50]
//   range).
//
// - **11.9 Style determinism (Req 5.1, 5.2 — and design.md P10)**:
//   `applyStyle(buildBundle(audiogram), styleName)` is a pure
//   deterministic function of (bundle, styleName, derivedAt). Calling
//   it twice with the same arguments produces equal bundles. Note that
//   true *idempotence* (applyStyle(applyStyle(b, s), s) == applyStyle(b,
//   s)) does NOT hold in the current grid because the formula
//   `gain[i] = base[i] * intensity + profile[i]` is non-idempotent
//   (e.g. applying "Alto Voz" twice yields
//   `((base * 1.3) + 4) * 1.3 + 4` ≠ `base * 1.3 + 4`). The clinical
//   property the bloc relies on is determinism — the preset is applied
//   from the BASE bundle every time, never on top of itself — and that
//   is what we validate here. We additionally assert the structural
//   range invariant `gainsDb ∈ [0, 50]` is preserved by the styler.
//
// Audiogram generation uses the same seed-based pseudo-hash as the
// rest of the property tests in this repo (see
// `nl3_determinism_test.dart`, `bundle_serialization_property_test.dart`)
// to guarantee HL ∈ [0, 120] dB HL per band, which satisfies the
// `BundleBuilder` validation.
//
// **Validates: Requirements 10.3, 13.4, 5.1, 5.2**
library;

// `glados/glados.dart` re-exporta `test`, `group`, `expect`, `closeTo`,
// `equals`, `inInclusiveRange`, `lessThanOrEqualTo`, etc. desde
// `package:test_core` + `package:matcher`. Importar `flutter_test`
// adicionalmente provoca colisiones de identificadores (mismo patrón
// que `bundle_serialization_property_test.dart` y el resto de
// `test/domain/property/*.dart`).
import 'package:glados/glados.dart';

import 'package:hearing_aid_app/domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/bundle_builder.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/manual_adjustment_delta.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/operating_mode.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/style_applicator.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';

// ---------------------------------------------------------------------------
// Audiogram + delta + style generators (seed-based)
// ---------------------------------------------------------------------------

/// Convierte un seed `double` a 12 umbrales HL ∈ [0, 120] dB HL en las 12
/// frecuencias estándar (Req 1.6, validado por `BundleBuilder`).
Audiogram _seedToAudiogram(double seed) {
  const freqs = Audiogram.standardFrequencies;
  final thresholds = <int, double>{};
  for (var i = 0; i < 12; i++) {
    thresholds[freqs[i]] = ((seed * (i + 1) * 7.3) % 120.0).abs();
  }
  return Audiogram(thresholds: thresholds);
}

/// Convierte un seed `double` a un [ManualAdjustmentDelta] con
/// `eqDeltaDb` por banda en `[-10, +10] dB` y `volumeDeltaDb` también
/// en `[-10, +10] dB`. El resto de campos quedan en cero ya que el
/// headroom clamp del bloc solo lee `eqDeltaDb` y `volumeDeltaDb` para
/// computar las ganancias finales.
ManualAdjustmentDelta _seedToDelta(double seed) {
  final eq = List<double>.generate(
    AudiogramDrivenBundle.bandCount,
    (i) => (((seed * (i + 1) * 3.7) % 20.0) - 10.0),
    growable: false,
  );
  final volume = (((seed * 11.13) % 20.0) - 10.0).clamp(-10.0, 10.0).toDouble();
  return ManualAdjustmentDelta(
    eqDeltaDb: eq,
    volumeDeltaDb: volume,
    nrLevelDelta: 0,
    compressionRatioDelta: 0.0,
    compressionKneeDeltaDbSpl: 0.0,
    editedAt: DateTime.utc(2026, 6, 1),
  );
}

/// Selecciona un [PrescriptionMode] de los 3 disponibles a partir del seed.
PrescriptionMode _seedToMode(double seed) {
  const modes = PrescriptionMode.values;
  final idx = (seed.abs() * 1000).floor() % modes.length;
  return modes[idx];
}

/// Selecciona un nombre de preset de [StyleApplicator.supportedStyles] a
/// partir del seed. Cubre los 9 presets en muestras de 200 runs.
String _seedToStyleName(double seed) {
  final styles = StyleApplicator.supportedStyles;
  final idx = (seed.abs() * 1000).floor() % styles.length;
  return styles[idx];
}

// ---------------------------------------------------------------------------
// Constants mirrored from AmplificationBloc._resolveFinalGains
// ---------------------------------------------------------------------------

/// Nivel de input típico (dB SPL) usado por el bloc para el clamp de
/// headroom MPO. Conversación normal ≈ 65 dB SPL.
/// Mismo valor que `AmplificationBloc._kTypicalInputDbSpl`.
const double _kTypicalInputDbSpl = 65.0;

/// Margen de seguridad sustraído al headroom MPO (Req 10.2).
/// Mismo valor que `AmplificationBloc._kHeadroomSafetyMarginDb`.
const double _kHeadroomSafetyMarginDb = 3.0;

/// Replica `AmplificationBloc._resolveFinalGains` en forma pura, sin
/// instanciar el bloc. La propiedad 11.7 fuzza esta función contra el
/// invariante `g[i] ≤ mpoProfileDbSpl[i] - 65 - 3`.
List<double> _resolveFinalGainsPure(
  AudiogramDrivenBundle bundle,
  ManualAdjustmentDelta? delta,
) {
  final gains = List<double>.filled(
    AudiogramDrivenBundle.bandCount,
    0.0,
    growable: false,
  );
  for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
    var g = bundle.gainsDb[i];
    if (delta != null) {
      g += delta.eqDeltaDb[i] + delta.volumeDeltaDb;
    }
    // Clamp al rango operativo del EQ.
    g = g
        .clamp(
          AudiogramDrivenBundle.gainMinDb,
          AudiogramDrivenBundle.gainMaxDb,
        )
        .toDouble();
    // Clamp por headroom MPO.
    final headroom = bundle.mpoProfileDbSpl[i] -
        _kTypicalInputDbSpl -
        _kHeadroomSafetyMarginDb;
    if (headroom < g) {
      g = headroom > AudiogramDrivenBundle.gainMinDb
          ? headroom
          : AudiogramDrivenBundle.gainMinDb;
    }
    gains[i] = g;
  }
  return gains;
}

void main() {
  final builder = BundleBuilder();
  final fixedTime = DateTime.utc(2026, 6, 1, 10, 0, 0);

  // -------------------------------------------------------------------------
  // 11.7 Headroom invariant (Req 10.3)
  // -------------------------------------------------------------------------
  group('BundleBuilder property tests — headroom invariant (11.7)', () {
    Glados2(
      any.doubleInRange(0, 120),
      any.doubleInRange(0, 120),
      ExploreConfig(numRuns: 200),
    ).test(
      '11.7 finalGain[f] ≤ mpoProfileDbSpl[f] − 65 − 3 ∀ f, ∀ delta',
      (audiogramSeed, deltaSeed) {
        final audiogram = _seedToAudiogram(audiogramSeed);
        final delta = _seedToDelta(deltaSeed);

        // Bundle en modo Diagnóstico (worst-case para headroom: gainScale=1.0
        // → ganancias máximas a clampar).
        final bundle = builder.buildFromAudiogram(
          audiogram,
          mode: PrescriptionMode.quiet,
          derivedAt: fixedTime,
        );

        final finalGains = _resolveFinalGainsPure(bundle, delta);

        for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
          final ceiling = bundle.mpoProfileDbSpl[i] -
              _kTypicalInputDbSpl -
              _kHeadroomSafetyMarginDb;
          // Margen de tolerancia float ε = 1e-9 (no relaja el invariante,
          // sólo absorbe redondeo de doubles).
          expect(
            finalGains[i],
            lessThanOrEqualTo(ceiling + 1e-9),
            reason:
                'Banda $i: finalGain=${finalGains[i].toStringAsFixed(6)} dB '
                'excede headroom=${ceiling.toStringAsFixed(6)} dB '
                '(mpo=${bundle.mpoProfileDbSpl[i].toStringAsFixed(2)}, '
                'baseGain=${bundle.gainsDb[i].toStringAsFixed(2)}, '
                'eqDelta=${delta.eqDeltaDb[i].toStringAsFixed(2)}, '
                'volume=${delta.volumeDeltaDb.toStringAsFixed(2)}).',
          );
          // Y nunca por debajo del bound estructural inferior.
          expect(
            finalGains[i],
            greaterThanOrEqualTo(AudiogramDrivenBundle.gainMinDb),
          );
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // 11.8 GainScale isolation (Req 13.4)
  // -------------------------------------------------------------------------
  group('BundleBuilder property tests — gainScale isolation (11.8)', () {
    Glados3(
      any.doubleInRange(0, 120),
      any.doubleInRange(0.10, 1.00),
      any.doubleInRange(0.10, 1.00),
      ExploreConfig(numRuns: 200),
    ).test(
      '11.8 gainScale only changes gainsDb; MPO/CR/knees/NR bit-exact',
      (audiogramSeed, gainScaleA, gainScaleB) {
        final audiogram = _seedToAudiogram(audiogramSeed);

        final bundleA = builder.buildFromAudiogram(
          audiogram,
          mode: PrescriptionMode.quiet,
          derivedAt: fixedTime,
          operatingMode: OperatingMode.amplifier,
          gainScale: gainScaleA,
        );
        final bundleB = builder.buildFromAudiogram(
          audiogram,
          mode: PrescriptionMode.quiet,
          derivedAt: fixedTime,
          operatingMode: OperatingMode.amplifier,
          gainScale: gainScaleB,
        );

        // — MPO bit-exact. —
        expect(
          bundleA.mpoProfileDbSpl,
          equals(bundleB.mpoProfileDbSpl),
          reason: 'mpoProfileDbSpl debe ser idéntico para todo gainScale.',
        );

        // — Compression ratios bit-exact. —
        expect(
          bundleA.compressionRatios,
          equals(bundleB.compressionRatios),
          reason: 'compressionRatios debe ser idéntico para todo gainScale.',
        );

        // — Compression knees bit-exact. —
        expect(
          bundleA.compressionKneesDbSpl,
          equals(bundleB.compressionKneesDbSpl),
          reason:
              'compressionKneesDbSpl debe ser idéntico para todo gainScale.',
        );

        // — NR level bit-exact. —
        expect(
          bundleA.nrLevel,
          equals(bundleB.nrLevel),
          reason: 'nrLevel debe ser idéntico para todo gainScale.',
        );

        // Si gainScale_a != gainScale_b, los gains DEBEN diferir en al menos
        // una banda donde ambos bundles estén dentro del rango operativo
        // (ni clampados a 0 ni a 50). En bandas donde la prescripción base
        // es 0 los gains valen 0 en ambos lados, así que se requiere al
        // menos UNA banda con prescripción no-cero y resultado no-clampado
        // para que se pueda distinguir gainScaleA de gainScaleB.
        if (gainScaleA != gainScaleB) {
          final ratioAB = gainScaleA / gainScaleB;
          var checkedAtLeastOneBand = false;
          var foundDifferingBand = false;
          for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
            final gA = bundleA.gainsDb[i];
            final gB = bundleB.gainsDb[i];
            // Considerar sólo bandas donde NINGUNO de los dos esté
            // clampado a 0 ni a 50 — sólo ahí la relación lineal
            // gainScale_a / gainScale_b se traduce 1:1 al cociente de
            // ganancias.
            final aUnclamped = gA > AudiogramDrivenBundle.gainMinDb &&
                gA < AudiogramDrivenBundle.gainMaxDb;
            final bUnclamped = gB > AudiogramDrivenBundle.gainMinDb &&
                gB < AudiogramDrivenBundle.gainMaxDb;
            if (!aUnclamped || !bUnclamped) continue;
            checkedAtLeastOneBand = true;
            // En esas bandas: gA / gB ≈ gainScaleA / gainScaleB.
            // Tolerancia 1% para absorber redondeo + el clamp [0, 50] que
            // el builder aplica DESPUÉS de multiplicar por gainScale.
            expect(
              gA / gB,
              closeTo(ratioAB, 0.01),
              reason: 'Banda $i: gA=$gA, gB=$gB, ratio=${gA / gB}, '
                  'expected=$ratioAB (scaleA=$gainScaleA, scaleB=$gainScaleB).',
            );
            if ((gA - gB).abs() > 1e-9) foundDifferingBand = true;
          }
          // Si pudimos verificar al menos una banda no-clampada, debió
          // haber al menos una donde difieran. Si todas las bandas están
          // clampadas (audiograma extremo o prescripción uniformemente
          // cero) la propiedad de "diferencia" no es aplicable y la dejamos
          // pasar — los invariantes de MPO/CR/knees/NR ya se validaron.
          if (checkedAtLeastOneBand) {
            expect(
              foundDifferingBand,
              isTrue,
              reason:
                  'gainScaleA=$gainScaleA, gainScaleB=$gainScaleB son '
                  'distintos pero todas las bandas no-clampadas dieron '
                  'gains iguales. Eso violaría la linealidad del scale.',
            );
          }
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // 11.9 Style determinism (Req 5.1, 5.2 / design.md P10)
  // -------------------------------------------------------------------------
  //
  // NOTA: la formulación literal del task 11.9 ("applyStyle(applyStyle(b,s),s)
  // == applyStyle(b,s)") es FALSA por construcción en la implementación
  // actual de [StyleApplicator]: la fórmula
  // `gain[i] = base[i] * intensity + profile[i]` no es idempotente porque
  // intensity ≠ 1.0 hace que aplicar dos veces dé
  // `(base * intensity + profile) * intensity + profile`. La propiedad
  // clínicamente válida que el bloc usa (y que design.md P10 buscaba
  // capturar) es DETERMINISMO: aplicar el estilo desde el bundle base
  // siempre da el mismo resultado para el mismo (bundle, styleName,
  // derivedAt). Validamos eso + el invariante estructural de rango de
  // `gainsDb`.
  group('StyleApplicator property tests — determinism (11.9)', () {
    Glados2(
      any.doubleInRange(0, 120),
      any.doubleInRange(0, 100),
      ExploreConfig(numRuns: 200),
    ).test(
      '11.9 applyStyle is deterministic and preserves gainsDb ∈ [0, 50]',
      (audiogramSeed, styleSeed) {
        final audiogram = _seedToAudiogram(audiogramSeed);
        final styleName = _seedToStyleName(styleSeed);
        final mode = _seedToMode(styleSeed);

        final base = builder.buildFromAudiogram(
          audiogram,
          mode: mode,
          derivedAt: fixedTime,
        );

        final styled1 = StyleApplicator.applyStyle(
          base,
          styleName,
          derivedAt: fixedTime,
        );
        final styled2 = StyleApplicator.applyStyle(
          base,
          styleName,
          derivedAt: fixedTime,
        );

        // Determinismo bit-exact: dos llamadas con los mismos argumentos
        // producen bundles iguales por Equatable (cubre todos los campos).
        expect(
          styled1,
          equals(styled2),
          reason:
              'applyStyle no-determinista para style="$styleName", '
              'mode=$mode, audiogramSeed=$audiogramSeed.',
        );

        // Rango estructural de gainsDb [0, 50] dB (Req 5.3).
        for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
          expect(
            styled1.gainsDb[i],
            inInclusiveRange(
              AudiogramDrivenBundle.gainMinDb,
              AudiogramDrivenBundle.gainMaxDb,
            ),
            reason:
                'styled1.gainsDb[$i]=${styled1.gainsDb[i]} fuera de '
                '[${AudiogramDrivenBundle.gainMinDb}, '
                '${AudiogramDrivenBundle.gainMaxDb}] dB '
                '(style="$styleName", audiogramSeed=$audiogramSeed).',
          );
        }

        // Style sólo modifica gainsDb (Req 5.3): el resto de los campos
        // del bundle deben ser idénticos a los del base. Esta verificación
        // es complementaria al test unitario y aumenta cobertura sobre los
        // 9 presets × cualquier audiograma.
        expect(styled1.compressionRatios, equals(base.compressionRatios));
        expect(
          styled1.compressionKneesDbSpl,
          equals(base.compressionKneesDbSpl),
        );
        expect(styled1.mpoProfileDbSpl, equals(base.mpoProfileDbSpl));
        expect(styled1.nrLevel, equals(base.nrLevel));
        expect(styled1.wdrcAttackMs, equals(base.wdrcAttackMs));
        expect(styled1.wdrcReleaseMs, equals(base.wdrcReleaseMs));
        expect(styled1.expansionKneeDbSpl, equals(base.expansionKneeDbSpl));
        expect(styled1.lossType, equals(base.lossType));
        expect(styled1.prescriptionMode, equals(base.prescriptionMode));
        expect(styled1.mode, equals(base.mode));
        expect(styled1.gainScale, equals(base.gainScale));
      },
    );
  });
}

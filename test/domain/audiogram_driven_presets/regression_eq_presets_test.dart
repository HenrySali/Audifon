@Tags(['legacy-skipped'])
library;

/// Regression test (task 10.4) — INVALIDATED by the migration to the
/// 9-preset scaled system (Suave/Medio/Alto × Plano/Voz/Agudos).
///
/// The previous model assumed a 1:1 mapping between [StyleApplicator]
/// names and [EqPreset.allPresets] (Normal · Mild High · Mild Flat ·
/// Moderate High · Moderate Flat · Moderate+ · Voice Clarity · Music ·
/// Outdoor · TV/Media), with each style adding small additive deltas to
/// the NL3-prescribed base. The new model:
///
/// - exposes 9 presets, none of which match a legacy [EqPreset] name;
/// - applies the intensity multiplier × base + profile delta formula
///   (`gain = clamp(base * mult + delta, 0, 50)`) instead of the
///   additive delta-only formula;
///
/// so the per-band ±3 dB tolerance vs `EqPreset.allPresets` is no
/// longer a meaningful invariant.
///
/// This file is kept as a documentation marker and is fully skipped.
/// New regression coverage for the 9-preset system lives in
/// `style_applicator_test.dart`.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'legacy 10-style ↔ EqPreset.allPresets regression — superseded by '
    '9-preset scaled system',
    () {
      // Intentionally empty — see file header for context.
    },
    skip: 'Superseded by the 9-preset scaled system (Suave/Medio/Alto × '
        'Plano/Voz/Agudos). The 1:1 mapping with EqPreset.allPresets no '
        'longer holds. New coverage in style_applicator_test.dart.',
  );
}

# Design Document

> Spec ID: `audiogram-driven-presets`
> Fecha: 3 de junio de 2026.
> Basado en: requirements.md v1 (15 requirements, 18 acceptance criteria sections).
> Dependencias: `nal-nl3-prescriptor` (implementado), `mic-calibration` (implementado).

## Overview

Este documento describe el diseño técnico para que el audiograma del paciente
derive un bundle completo de configuración DSP (ganancias + compresión + MPO +
NR + WDRC) y que ese bundle alimente atómicamente cada preset y flujo de
aplicación de la app.

### Objetivos de diseño

1. **Bundle como fuente única de verdad** — toda aplicación de parámetros al motor pasa por `AudiogramDrivenBundle`, eliminando parámetros clínicos sueltos.
2. **Funciones puras** — `BundleBuilder`, `UclEstimator`, `MpoDeriver`, `StyleApplicator` son deterministas y sin side-effects. `derivedAt` es inyectable.
3. **Aplicación atómica** — las 4 llamadas al bridge ocurren secuencialmente sin yields, con rollback completo ante fallo.
4. **Dos modos de operación** — Diagnóstico (audiograma medido, gainScale=1.0) y Amplificador (defaultAudiogram, gainScale configurable).
5. **Delta overlay** — ajustes manuales se suman al bundle sin reemplazarlo, auditables y persistidos por separado.
6. **Compatibilidad** — el AudioBridge solo gana un método nuevo (`setMpoThresholdDbSpl`). Código existente no se rompe.

### Decisiones clave

| Decisión | Justificación |
|----------|---------------|
| MPO broadband como `min(mpoProfile)` | Protege la banda más sensible. Extensión per-band reservada para futuro. |
| gainScale multiplicativo en dominio dB | Escala proporcionalmente: bandas con más ganancia reciben más reducción. |
| CR para bridge: PTA-weighted average | Las bandas de inteligibilidad (500–4k) pesan más. Los 12 ratios se preservan en el bundle para futuro. |
| Estilos como deltas relativos | Preserva prescripción audiograma como base; nunca reemplazan con hardcoded. |
| ManualAdjustmentDelta persistido por modo | Cada modo tiene su propio delta independiente. Cambio de audiograma marca stale solo el diagnostic. |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        AmplificationBloc                                 │
│  ┌─────────────────────┐    ┌───────────────────────────────────────┐   │
│  │ _onUpdateAudiogram  │───▸│ BundleBuilder.buildFromAudiogram()    │   │
│  │ _onChangeProfile    │    │   ├─ GainPrescriberNL3.prescribe…()   │   │
│  │ _onApplyStyle       │    │   ├─ UclEstimator.estimate()          │   │
│  │ _onApplyBundle      │    │   ├─ MpoDeriver.derive()              │   │
│  │ _onGainScaleChanged │    │   └─ NrLevelSuggester.suggest()       │   │
│  └─────────┬───────────┘    └────────────────┬──────────────────────┘   │
│            │                                  │                          │
│            │  ApplyAudiogramDrivenBundle       │  AudiogramDrivenBundle   │
│            ▼                                  ▼                          │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │ _applyBundleAtomic(bundle, delta?)                               │   │
│  │   1. setMpoThresholdDbSpl(min(bundle.mpoProfileDbSpl))          │   │
│  │   2. updateWdrcParams(...)                                       │   │
│  │   3. updateEqGains(finalGains)                                   │   │
│  │   4. updateNrLevel(bundle.nrLevel + delta.nrLevelDelta)          │   │
│  └──────────────────────────────────┬───────────────────────────────┘   │
│                                     │                                    │
└─────────────────────────────────────┼────────────────────────────────────┘
                                      │ AudioBridge
                                      ▼
                          ┌───────────────────────┐
                          │  Native DSP Pipeline   │
                          │  (mpo_limiter → wdrc   │
                          │   → eq_12band → gain)  │
                          └───────────────────────┘
```

### Dependency Graph

```
audiogram-driven-presets
├── nal-nl3-prescriptor (provides: GainPrescriberNL3, LossType, PrescriptionMode)
├── mic-calibration (provides: splOffset via applyCalibration at startup)
├── core-clinico-compartido [future] (will replace lookup tables)
└── AudioBridge.setMpoThresholdDbSpl (PATCH-3, already applied)
```

## Components and Interfaces

### BundleBuilder (función pura)

**Location:** `lib/domain/audiogram_driven_presets/bundle_builder.dart`

```dart
class BundleBuilder {
  final GainPrescriberNL3 _nl3;

  AudiogramDrivenBundle buildFromAudiogram(
    Audiogram audiogram, {
    PatientProfile? profile,
    required PrescriptionMode mode,
    Map<int, double>? measuredUcl,
    DateTime? derivedAt,
    OperatingMode operatingMode = OperatingMode.diagnostic,
    double gainScale = 1.0,
  });
}
```

**Flow interno:**
1. Validar audiograma (12 freqs, rango [-10, 120]).
2. Delegar a `_nl3.prescribeFromAudiogram(audiogram, profile: profile, mode: mode, timestamp: derivedAt)` para `gainsDb` y `compressionRatios`.
3. `UclEstimator.estimate(audiogram, measuredUcl: measuredUcl)` → 12 UCL.
4. `MpoDeriver.derive(ucl, profile: profile)` → 12 MPO.
5. Derivar `compressionKneesDbSpl`: `knee[f] = (35 + (HL[f] / 120) * 30).clamp(35, 65)`.
6. Si `operatingMode == amplifier`: `gainsDb[f] = (prescribedGains[f] * gainScale).clamp(0, 50)`.
7. Derivar `nrLevel` del modo + WDRC overrides.
8. Extraer `wdrcAttackMs`, `wdrcReleaseMs` del `NL3PrescriptionResult.wdrcOverrides` (defaults: 5/100 ms).
9. Construir `AudiogramDrivenBundle` inmutable.

### UclEstimator (función pura)

**Location:** `lib/domain/audiogram_driven_presets/ucl_estimator.dart`

```dart
class UclEstimator {
  /// UCL[f] = 100 + 0.15 × HL[f], clamp HL a [0, 120].
  /// Si measuredUcl[f] existe, usa ese valor directo.
  ///
  /// Fuente: NAL-NL2 UCL estimation (Dillon 2012, Ch 4.3)
  static List<double> estimate(Audiogram audiogram, {Map<int, double>? measuredUcl});
}
```

### MpoDeriver (función pura)

**Location:** `lib/domain/audiogram_driven_presets/mpo_deriver.dart`

```dart
class MpoDeriver {
  /// Adulto: MPO[f] = min(UCL[f] - 5, 132), clamp [80, 132].
  /// Pediátrico (age < 18): MPO[f] = min(UCL[f] - 10, 110), clamp [80, 132].
  ///
  /// Fuente: DSL v5 (Bagatto 2005), FDA OTC 21 CFR 800.30
  static List<double> derive(List<double> ucl, {PatientProfile? profile});
}
```

### StyleApplicator (función pura)

**Location:** `lib/domain/audiogram_driven_presets/style_applicator.dart`

```dart
class StyleApplicator {
  /// Aplica deltas de estilo al bundle sin reemplazar ganancias.
  static AudiogramDrivenBundle applyStyle(AudiogramDrivenBundle bundle, String styleName, {DateTime? derivedAt});
}
```

**Mapping de estilos → deltas:**

| Style Name    | EQ delta range | NR adj | Bands affected |
|---------------|---------------|--------|----------------|
| Normal        | [0, 0]        | 0      | none           |
| Mild High     | [0, +3]       | 0      | 4k–8k          |
| Mild Flat     | [+1, +2]      | 0      | all            |
| Moderate High | [0, +3]       | 0      | 2k–8k          |
| Moderate Flat | [+1, +3]      | 0      | all            |
| Moderate+     | [+1, +3]      | 0      | 2k–8k          |
| Voice Clarity | [−1, +4]      | +1     | 1k–4k boost    |
| Music         | [−2, +2]      | −1     | flat shape     |
| Outdoor       | [−4, +3]      | +1     | −LF, +MF       |
| TV/Media      | [−1, +4]      | +1     | 500–4k boost   |

### EnvironmentProfileMapper

**Location:** `lib/domain/audiogram_driven_presets/environment_profile_mapper.dart`

```dart
class EnvironmentProfileMapper {
  /// quiet → PrescriptionMode.quiet
  /// conversation → PrescriptionMode.quiet
  /// noisy → PrescriptionMode.comfortInNoise
  static PrescriptionMode modeFor(EnvironmentProfile profile);
  static int adjustNr(int bundleNrLevel, int nrDelta);
}
```

### AudioBridge extension

```dart
/// Método nuevo (PATCH-3, ya aplicado en audio_bridge.dart):
Future<void> setMpoThresholdDbSpl(double thresholdDbSpl);
```

Contrato nativo: `MethodChannel('setMpoThresholdDbSpl', {'thresholdDbSpl': value})`
→ motor C++ convierte a lineal y actualiza `mpo_limiter.cpp`.

### AmplificationBloc — nuevos eventos

```dart
class ApplyAudiogramDrivenBundle extends AmplificationEvent {
  final AudiogramDrivenBundle bundle;
  final ManualAdjustmentDelta? delta;
}

class GainScaleChanged extends AmplificationEvent {
  final double gainScale; // [0.10, 1.00]
}

class ManualEqAdjust extends AmplificationEvent {
  final int bandIndex;    // [0, 11]
  final double deltaDelta; // increment to apply
}
```

## Data Models

### AudiogramDrivenBundle

```dart
class AudiogramDrivenBundle extends Equatable {
  final List<double> gainsDb;               // 12, [0, 50] dB
  final List<double> compressionRatios;     // 12, [1.0, 3.0]
  final List<double> compressionKneesDbSpl; // 12, [35, 65] dB SPL
  final List<double> mpoProfileDbSpl;       // 12, [80, 132] dB SPL
  final int nrLevel;                        // [0, 3]
  final double wdrcAttackMs;                // [1, 50] ms
  final double wdrcReleaseMs;               // [20, 500] ms
  final double expansionKneeDbSpl;          // [20, 50] dB SPL
  final LossType lossType;
  final PrescriptionMode prescriptionMode;
  final OperatingMode mode;
  final double gainScale;
  final DateTime derivedAt;

  static const schemaVersion = '1.0.0';

  Map<String, dynamic> toJson();
  static AudiogramDrivenBundle fromJson(Map<String, dynamic> json);
}
```

### OperatingMode

```dart
enum OperatingMode { diagnostic, amplifier }
```

### ManualAdjustmentDelta

```dart
class ManualAdjustmentDelta extends Equatable {
  final List<double> eqDeltaDb;             // 12, [-10, +10]
  final double volumeDeltaDb;               // [-10, +10]
  final int nrLevelDelta;                   // [-3, +3]
  final double compressionRatioDelta;       // [-1.0, +1.0]
  final double compressionKneeDeltaDbSpl;   // [-10, +10]
  final DateTime editedAt;

  static ManualAdjustmentDelta zero();
  bool get isZero;
  Map<String, dynamic> toJson();
  static ManualAdjustmentDelta fromJson(Map<String, dynamic> json);
}
```

### Persistencia (Hive settings_box)

| Key | Type | Content |
|-----|------|---------|
| `amplifier_gain_scale` | double | gainScale [0.10, 1.00] |
| `manual_delta_diagnostic` | JSON string | ManualAdjustmentDelta |
| `manual_delta_amplifier` | JSON string | ManualAdjustmentDelta |
| `last_bundle` | JSON string | AudiogramDrivenBundle.toJson() |

## Correctness Properties

| # | Property | Assertion |
|---|----------|-----------|
| P1 | Output invariant | ∀ audiogram válido: bundle tiene 12 valores en cada array, todos en rango. |
| P2 | MPO bound | ∀ audiogram: 80 ≤ mpoProfileDbSpl[f] ≤ 132 |
| P3 | MPO monotonicity en HL | Subir HL[f] en 10 dB no aumenta mpoProfileDbSpl[f] en más de 1.5 dB |
| P4 | Determinism | buildFromAudiogram con mismos inputs + derivedAt fijo → mismos outputs |
| P5 | JSON round-trip | fromJson(b.toJson()) ≈ b (tolerancia ≤ 0.001 floats) |
| P6 | Atomic apply order | Bridge recibe exactamente setMpo → updateWdrc → updateEq → updateNr |
| P7 | Headroom invariant | ∀ f: finalGain[f] ≤ mpoProfileDbSpl[f] - input - 3 |
| P8 | GainScale isolation | gainScale NO modifica mpoProfileDbSpl, compressionRatios, nrLevel |
| P9 | Delta additivity | Aplicar delta dos veces es idempotente si el delta no cambia |
| P10 | Style idempotence | applyStyle(applyStyle(b, s), s) == applyStyle(b, s) |

## Error Handling

| Failure point | Action |
|---|---|
| `setMpoThresholdDbSpl` throws | No-op (MPO unchanged). Emit error identifying step 1. |
| `updateWdrcParams` throws | Rollback: re-apply previous MPO threshold. Emit error step 2. |
| `updateEqGains` throws | Rollback: re-apply previous MPO + WDRC. Emit error step 3. |
| `updateNrLevel` throws | Rollback: re-apply previous MPO + WDRC + EQ. Emit error step 4. |
| Bundle validation fails | Reject immediately, no bridge calls, emit validation error list. |
| Hive persistence fails | Apply bundle to motor anyway, emit warning (non-blocking). |
| GainScale out of range | Clamp to nearest bound + emit warning. Build bundle normally. |
| ManualAdjustmentDelta out of range on load | Clamp per-field + emit warning. |
| Audiogram missing/invalid | Fall to defaultAudiogram + Modo Amplificador. |

## Testing Strategy

### Unit tests
- BundleBuilder: audiogramas Bisgaard N1–N7, S1–S3 → bundle con tolerance checks.
- UclEstimator: edge cases (HL=0, HL=120, partial measuredUcl).
- MpoDeriver: adult vs pediatric, boundary values.
- StyleApplicator: cada estilo produce deltas dentro de rangos.
- ManualAdjustmentDelta: serialization, clamping, zero identity.

### Property-based tests (glados)
- P1 through P10 listed in Correctness Properties (100+ audiograms each).
- Regression: 10 EqPresets × audiograma 30 dB flat → ±3 dB vs hardcoded.

### Integration tests
- Mock AudioBridge: verify 4-call order with exact values.
- Full chain: simulated audiometry → saveAudiogram → bundle → bridge mock.
- Mode transition: Amplificador → Diagnóstico (on audiometry apply).
- Stale delta: change audiogram by MAD > 5 dB → delta marked stale.

### Tramo 3 (manual QC)
- Protocol in `docs/qc/loopback-validation.md`.
- 5 audiograms × 3 inputs × 3 frequencies = 45 measurements.
- Pass/fail: ±5 dB SPL (BAA REMS 2018 tolerance).

## Compression Ratio Strategy (hallazgo N2 resolution)

El bridge acepta un solo `compressionRatio` broadband. Estrategia:

```dart
/// PTA-weighted average de los 12 ratios.
/// Bandas PTA (500, 1000, 2000, 4000 Hz) pesan 2x; resto 1x.
double _bridgeCompressionRatio(AudiogramDrivenBundle bundle) {
  const ptaIndices = [1, 3, 5, 9]; // 500, 1000, 2000, 4000 Hz
  double sum = 0, weight = 0;
  for (int i = 0; i < 12; i++) {
    final w = ptaIndices.contains(i) ? 2.0 : 1.0;
    sum += bundle.compressionRatios[i] * w;
    weight += w;
  }
  return (sum / weight).clamp(1.0, 3.0);
}
```

## GainScale and MPO Interaction (Req 13 + 10)

```dart
// gainScale solo afecta gainsDb, nunca MPO:
for (int f = 0; f < 12; f++) {
  gainsDb[f] = (prescribedGains[f] * gainScale).clamp(0.0, 50.0);
  // mpoProfileDbSpl[f] se calcula SIN gainScale (protección al 100%)
}
```

## File Structure

```
hearing_aid_app/lib/domain/audiogram_driven_presets/
├── bundle_builder.dart             (Req 1)
├── audiogram_driven_bundle.dart    (Req 1.2)
├── ucl_estimator.dart              (Req 2)
├── mpo_deriver.dart                (Req 2)
├── style_applicator.dart           (Req 5)
├── environment_profile_mapper.dart (Req 6)
├── manual_adjustment_delta.dart    (Req 14)
└── operating_mode.dart             (Req 13)

hearing_aid_app/lib/presentation/bloc/
├── amplification_event.dart  (+ ApplyAudiogramDrivenBundle, GainScaleChanged, ManualEqAdjust)
├── amplification_bloc.dart   (+ _onApplyBundle, _onGainScaleChanged, _onManualEqAdjust)
└── amplification_state.dart  (+ mode, lossType, gainScale en AmplificationActive)

hearing_aid_app/lib/scene/
├── scene_personalized_generator.dart  (refactor: recibe bundle en vez de Audiogram)
└── scene_preset_generator.dart        (refactor: delega a bundle path)
```

## Open Questions (a resolver en tasks phase)

1. ¿El `compressionKnee` per-band se envía como promedio PTA-weighted igual que el ratio, o se usa un valor fijo (55 dB SPL)?
2. ¿El `expansionKnee` del bundle es siempre 35 dB SPL o se deriva del audiograma?
3. ¿La transición de `SceneGenericPresetGenerator` es refactor in-place o nuevo generador + deprecación?

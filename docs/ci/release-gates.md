# CI release gates — `audiogram-driven-presets`

This document maps each GitHub Actions workflow under
`hearing_aid_app/.github/workflows/` to the spec requirement it gates,
so reviewers can trace any red CI run back to the exact acceptance
criterion it is enforcing.

> The `hearing_aid_app/` directory is the git repo root, so workflows
> live at `hearing_aid_app/.github/workflows/`. All steps run from the
> repo root — no `working-directory:` is required.

## Spec → workflow → requirement matrix

| Spec / task | Workflow file | Job name | Requirement(s) | Gate behaviour |
|---|---|---|---|---|
| `audiogram-driven-presets` / 16.1 | `.github/workflows/property-tests.yml` | `pbt` | **11.10**, **15.10** | Blocks merge on any property-based test failure. The shrunken counterexample emitted by `glados` is printed in the failing step log (reporter `expanded`). Skipped automatically if `test/domain/audiogram_driven_presets/property/` is empty (wave-8 tasks 11.1 – 11.9 are flagged `*` so they may not be landed yet); the moment a PBT file lands the gate becomes strict. |
| `audiogram-driven-presets` / 16.2 | `.github/workflows/regression-tests.yml` | `regression` | **11.9** | Runs `test/domain/audiogram_driven_presets/regression_eq_presets_test.dart` (10 EqPresets × flat 30 dB HL audiogram). The Dart test asserts ±3 dB default plus a documented per-`(style, band)` ±5 dB softened map; any breach of the softened cap fails the test, which the workflow elevates to a merge block via `::error::` annotation per Requirement 11.9 ("deviation > 5 dB per band"). |
| `audiogram-driven-presets` / 16.3 | `.github/workflows/dartdoc-check.yml` | `dartdoc` | **12.2** | Runs `dart run tool/check_dartdoc.dart` on every PR that touches `lib/domain/audiogram_driven_presets/{bundle_builder,ucl_estimator,mpo_deriver}.dart`. The script verifies that each of those public clinical functions has the 4 mandatory Dartdoc sections (Parameters, Returns, References, Example). On any miss the script lists the offending function and exits 1, which the workflow surfaces as a merge block. |
| `audiogram-driven-presets` / 16.4 | `.github/workflows/release-gate.yml` | `qc-gate` | **15.14**, **15.15** | Triggered on `release: [created, published]` and on `workflow_dispatch`. Downloads the `*.pdf` asset attached to the release, then runs `dart run tool/release_gate.dart --audit-pdf=<pdf> --release-date=<release_at>`. The gate verifies (a) the PDF magic header `%PDF-`, (b) the four template markers written by `QcAuditRepositoryImpl.generatePdf` (`QC Loopback - Audit Trail`, `Spec: audiogram-driven-presets - Tramo 3`, `Resultado global: PASS`, `Firma del operador QC`) and (c) that the audit timestamp is at most 7 days before the release date. Any miss fails the gate with a clear operator action list ("Run QC, export PDF, attach as release asset, re-run workflow"). |

## Pre-existing gates (other specs)

| Workflow | Purpose |
|---|---|
| `dsp-quality.yml` | PESQ + STOI baseline check on the DNN denoiser pipeline (Mejora #5 of `docs/ruido-profundo.md`). |
| `build-apk.yml` | Release-APK builder triggered on push to `main`. Not a merge gate. |
| `deploy-simulator.yml` | Simulator-page deploy. Not a merge gate. |

## Triggers

Both new workflows are scoped to `pull_request` against `main` plus
`push` to `main`, with `paths:` filters so unrelated PRs don't pay the
runner cost. They also accept manual dispatch from the Actions tab for
ad-hoc re-runs.

## Tolerance contract for task 16.2

The Dart suite enforces the strictest tolerance the team can defend
clinically (±3 dB default, ±5 dB on documented bands). The CI gate
uses ±5 dB as the hard ceiling per Requirement 11.9. There is **no**
relaxation of the in-suite tolerance: if the `±5 dB` softened cap is
ever breached by future code, the test fails, the workflow fails, and
the PR is blocked. The softened bands are listed at the top of
`regression_eq_presets_test.dart` ("Documented deviations") and any
expansion of that list requires a code review trail.

## Operational notes

- These workflows are configuration-only and do not run from a local
  developer machine. Validation happens once the branch is pushed and
  GitHub schedules the runner.
- `glados` is already declared in `pubspec.yaml` (`dev_dependencies`),
  so no extra setup is required for task 16.1 once the property test
  files land.
- If a PBT failure is reproduced locally, run
  `flutter test test/domain/audiogram_driven_presets/property/ --reporter expanded`
  to see the same shrunken counterexample.

# Tramo 3 QC release gate — how-to

This document is the operator-facing guide for the **Tramo 3 release
gate** automated by `.github/workflows/release-gate.yml` and
`tool/release_gate.dart` (`audiogram-driven-presets` task 16.4,
Requirements 15.14 / 15.15).

## When the gate fires

The gate runs automatically when a GitHub release is created or
published, and can also be triggered manually from the Actions tab
with a `release_tag` input. Until the gate is green, the production
release artifact (APK) **must not** be promoted to end users.

## What the gate checks

`tool/release_gate.dart` consumes the QC audit PDF and verifies:

1. The file starts with the `%PDF-` magic header.
2. The PDF text contains the four template markers written by
   `QcAuditRepositoryImpl.generatePdf`:
   - `QC Loopback - Audit Trail`
   - `Spec: audiogram-driven-presets - Tramo 3`
   - `Resultado global: PASS` (overallPassed must be `true`)
   - `Firma del operador QC`
3. The audit `Fecha:` field (ISO-8601 UTC, written by
   `_buildPdfHeader`) is at most **7 days** before the release date.

If any check fails the workflow exits non-zero and the release is
blocked.

## Operator procedure (happy path)

1. Open the PSK app on the operator device.
2. Switch to **Modo Diagnóstico**.
3. Run the loopback QC routine for the 5 audiograms × 3 input levels
   suite (task 15.1 / 15.2).
4. Once `overallPassed = true`, export the PDF from
   `audit_trail_box`. The export entry point is the QC results screen
   ("Exportar PDF firmado"). The exported file is signed with the
   operator certification block.
5. Attach the PDF as a release asset on GitHub:
   - `Releases` → pick the release → `Edit` → drag-and-drop the PDF.
6. (Re-)run the `Release gate (Tramo 3 QC)` workflow from the Actions
   tab if it was already red.

## Manual fallback (when CI is not available)

If GitHub Actions is unreachable but the release must be approved,
the operator may run the gate locally on any developer machine that
has the Dart SDK installed:

```bash
cd hearing_aid_app
dart run tool/release_gate.dart \
  --audit-pdf="path/to/QC_<operator>_<timestamp>.pdf" \
  --release-date="2026-06-15T00:00:00Z"
```

A successful run prints `release_gate: PASS` and exits 0. The
operator must archive both the PDF and the terminal output as part
of the release record.

## Common failure modes

| Failure message | Likely cause | Action |
|---|---|---|
| `falta magic header "%PDF-"` | Asset is not a PDF (renamed binary, image, etc.) | Re-export from the app, do not rename. |
| `no contiene el marcador requerido: "Resultado global: PASS"` | The QC run had at least one FAIL | Re-run QC fixing the failing band(s) before releasing. |
| `no contiene el marcador requerido: "Firma del operador QC"` | PDF was generated outside the app | Use only `QcAuditRepositoryImpl.generatePdf`. |
| `Audit con antigüedad N días excede el máximo permitido (7)` | QC run too old | Run a fresh QC. |
| `No se pudo extraer la fecha del audit del PDF` | PDF stream is FlateDecode-compressed (rare with `package:pdf` 3.12) | Regenerate the PDF with the current app version; if the issue persists, file an issue against `qc-audit-pdf` and attach the PDF for analysis. |

## Limitations and TODOs

- The gate does **not** verify a cryptographic signature on the PDF
  itself. Adding a sealed-time / CMS signature is tracked under the
  separate `release-management` spec (out of scope for
  `audiogram-driven-presets`).
- The gate does **not** access the operator's `audit_trail_box` (Hive)
  directly because Hive lives on-device. The PDF asset workflow is
  the canonical handoff between operator and CI.
- The gate trusts the `Fecha:` field in the PDF header. A malicious
  operator could forge the date by editing the PDF, but that breaks
  the signature block and is detectable by the clinical owner during
  routine audits. Cryptographic enforcement is deferred to
  `release-management`.

## Related files

- `tool/release_gate.dart` — the gate logic and CLI.
- `.github/workflows/release-gate.yml` — the GitHub Actions workflow.
- `lib/data/repositories/qc_audit_repository_impl.dart` — generator
  of the PDF the gate consumes.
- `docs/ci/release-gates.md` — index of all CI gates for this spec.

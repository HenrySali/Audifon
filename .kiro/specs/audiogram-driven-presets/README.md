# audiogram-driven-presets

> **Status:** En desarrollo (Wave 3 — documentación y disclaimers).
> **Spec ID:** `audiogram-driven-presets`
> **Workflow:** Requirements-First (`requirements.md` → `design.md` → `tasks.md`).
> **Creado:** 2026-06-03.

## Overview

Spec que convierte el **audiograma del paciente** en la única fuente de verdad
para el bundle DSP de la app. Un solo objeto inmutable
([`AudiogramDrivenBundle`](../../../lib/domain/audiogram_driven_presets/audiogram_driven_bundle.dart))
agrupa ganancias por banda, ratios y knees de compresión, perfil MPO,
nivel de NR, parámetros WDRC y modo de operación; y se aplica
**atómicamente** al motor DSP a través de `AudioBridge`.

Cubre:

- Dos modos de operación: **Diagnóstico** (audiometría medida,
  `gainScale = 1.0`) y **Amplificador** (audiograma default,
  `gainScale ∈ [0.10, 1.00]`).
- Overlay aditivo `ManualAdjustmentDelta` para que los ajustes manuales
  no destruyan la prescripción base.
- Conexión con presets manuales, EnvironmentProfile, Smart Scene y
  custom presets persistidos.
- Validación clínica end-to-end en tres tramos:
  1. **Audiograma → API** (persistencia bit-exacta).
  2. **API → Prescripción** (gains, ratios, MPO vs literatura).
  3. **Prescripción → Audífono físico** (loopback QC con coupler IEC 60318-5).

Para detalle técnico ver [`design.md`](./design.md). Para los 15
requisitos con criterios de aceptación ver
[`requirements.md`](./requirements.md). Para la lista priorizada de
tareas ver [`tasks.md`](./tasks.md).

## Disclaimers clínicos

### Aproximación de UCL → MPO

> **El MPO derivado de UCL estimado (UCL ≈ 100 + 0.15 × HL) es una
> aproximación clínica. Para fitting clínico certificado, medir UCL con
> escala Cox Contour y reemplazar `measuredUcl` por los valores
> reales.**

Cuando el clínico no provee `measuredUcl` al
[`UclEstimator`](../../../lib/domain/audiogram_driven_presets/ucl_estimator.dart),
la app usa la regresión NAL-NL2 publicada por Dillon (2012, *Hearing
Aids* 2nd ed., Cap. 4.3) y Keidser et al. (2011). Esta regresión es
orientativa y suficiente para fitting de baja exigencia (autoajuste,
modo Amplificador, demos), pero **no reemplaza la medición clínica**:
puede sobre- o sub-estimar el UCL real del paciente en ±10–15 dB SPL en
casos con recruitment o canal auditivo pediátrico.

Consecuencia operativa: el perfil MPO devuelto por
[`MpoDeriver`](../../../lib/domain/audiogram_driven_presets/mpo_deriver.dart)
hereda esa aproximación. El módulo aplica los márgenes de seguridad
canónicos (DSL v5: 5 dB adulto / 10 dB pediátrico, techo absoluto 132
dB SPL adulto / 110 dB SPL pediátrico) precisamente para absorber el
error de la estimación, pero la mejor práctica para fitting clínico
sigue siendo medir UCL con escala Cox Contour.

Documento del proyecto:
[`docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md`](../../../../docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md)
§6.3 "Estimación de UCL cuando no hay medición" y §6.5 "Por qué un MPO
fijo de 110 dB SPL es inseguro para algunos pacientes".

### Modo Amplificador (sin audiometría medida)

El modo Amplificador usa un audiograma default genérico (no medido) y
aplica `gainScale` configurable por el usuario. **No es un sustituto
del fitting clínico**; el banner persistente "Modo Amplificador — sin
audiometría medida" se muestra mientras esté activo (Req 13.10 / 5.6).

### Validación HL → SPL real-ear

Sin RECD medido (espec hermana `mic-calibration` aún no provee RECD),
la conversión HL → SPL en oído real es aproximada. El bundle se
comporta correctamente con la calibración por defecto, pero la
validación Tramo 3 (loopback QC) es la única fuente de verdad para
producción.

## Dependencies

| Spec / módulo | Rol |
|---|---|
| [`nal-nl3-prescriptor`](../nal-nl3-prescriptor/) | Provee `GainPrescriberNL3`, `LossType`, `PrescriptionMode`, `NL3PrescriptionResult`. Genera `gainsDb` y `compressionRatios` por banda. |
| [`mic-calibration`](../mic-calibration/) | Provee `splOffset` aplicado al startup (vía `applyCalibration`). Pendiente: provisión de RECD para conversión HL → SPL real-ear. |
| `core-clinico-compartido` *(future)* | Reemplazará tablas de lookup hardcoded por la base clínica compartida del Sprint 3. |
| `AudioBridge.setMpoThresholdDbSpl` (PATCH-3) | Método ya patcheado en `lib/data/bridges/audio_bridge.dart`. Permite actualizar el MPO threshold del limitador en runtime sin reiniciar el motor. |

## Public API summary

Tres módulos puros principales (sin side-effects, deterministas con
`derivedAt` inyectable):

- [`UclEstimator`](../../../lib/domain/audiogram_driven_presets/ucl_estimator.dart)
  — `estimate(audiogram, {measuredUcl})` → `List<double>` (12 valores
  en dB SPL).
- [`MpoDeriver`](../../../lib/domain/audiogram_driven_presets/mpo_deriver.dart)
  — `derive(ucl, {profile})` → `List<double>` (12 valores en
  `[80, 132] dB SPL`).
- [`BundleBuilder`](../../../lib/domain/audiogram_driven_presets/bundle_builder.dart)
  — `buildFromAudiogram(audiogram, {profile, mode, measuredUcl, derivedAt, operatingMode, gainScale})` →
  `AudiogramDrivenBundle`.

Cada función pública del API expone Dartdoc completo con las cuatro
secciones obligatorias **Parameters**, **Returns**, **References**,
**Example** (Req 12.1, 12.2). Un check de CI bloquea el merge si
alguna falta (tarea 16.3).

## Files

- [`requirements.md`](./requirements.md) — 15 requirements + acceptance criteria.
- [`design.md`](./design.md) — arquitectura técnica y diagramas.
- [`tasks.md`](./tasks.md) — 16 grupos de tareas con dependency graph.
- [`native-coordination.md`](./native-coordination.md) — coordinación con el equipo native.

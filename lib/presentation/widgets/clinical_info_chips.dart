import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/audiogram_driven_presets/operating_mode.dart';
import '../../domain/entities/loss_type.dart';
import '../../domain/entities/prescription_mode.dart';
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_state.dart';

/// Chips informativos con LossType y PrescriptionMode visibles solo
/// en Modo Diagnóstico.
///
/// Comportamiento:
/// - Muestra dos `Chip` (tipo de pérdida + modo de prescripción)
///   cuando hay un bundle activo en Modo Diagnóstico.
/// - Si no hay preset activo (`bundle == null`) o el modo es
///   Amplificador: chip único "Sin perfil activo" en estilo muted.
/// - Si [isMigrated] es `true`: chip adicional "Migrado" con badge
///   indicando migración de schema (Req 8.7).
/// - Cada chip incluye tooltip de accesibilidad con explicación
///   funcional para screen readers.
///
/// Labels en español:
/// - LossType: flat→"Plana", sloping→"Descendente",
///   reverseSlope→"Ascendente", cookieBite→"Cookie-bite",
///   notch→"Muesca", mixed→"Mixta".
/// - PrescriptionMode: quiet→"Silencio", comfortInNoise→"Ruido",
///   mhl→"MHL".
///
/// Requisitos: 12.3, 12.4, 13.11, 8.7
class ClinicalInfoChips extends StatelessWidget {
  /// Si el preset custom activo fue migrado de un schema anterior.
  ///
  /// Cuando `true`, se muestra un chip adicional "Migrado" (Req 8.7).
  final bool isMigrated;

  const ClinicalInfoChips({super.key, this.isMigrated = false});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AmplificationBloc, AmplificationState>(
      buildWhen: (previous, current) {
        if (current is! AmplificationActive) return true;
        if (previous is! AmplificationActive) return true;
        return previous.operatingMode != current.operatingMode ||
            previous.bundle != current.bundle ||
            previous.lossType != current.lossType ||
            previous.prescriptionMode != current.prescriptionMode;
      },
      builder: (context, state) {
        if (state is! AmplificationActive) return const SizedBox.shrink();

        final bundle = state.bundle;
        final isDiagnostic =
            state.operatingMode == OperatingMode.diagnostic;

        // Sin bundle o en Modo Amplificador: chip "Sin perfil activo".
        if (bundle == null || !isDiagnostic) {
          return Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Wrap(
              spacing: 8,
              children: [
                Tooltip(
                  message: 'No hay audiograma medido aplicado. '
                      'Realizá una audiometría para activar el perfil.',
                  child: Chip(
                    avatar: Icon(
                      Icons.info_outline,
                      size: 18,
                      semanticLabel: 'Información',
                      color: Colors.grey.shade600,
                    ),
                    label: const Text('Sin perfil activo'),
                    backgroundColor: Colors.grey.shade200,
                  ),
                ),
              ],
            ),
          );
        }

        // Modo Diagnóstico con bundle activo: LossType + PrescriptionMode.
        final lossLabel = formatLossType(bundle.lossType);
        final lossTooltip = _lossTypeTooltip(bundle.lossType);
        final modeLabel = formatPrescriptionMode(bundle.prescriptionMode);
        final modeTooltip =
            _prescriptionModeTooltip(bundle.prescriptionMode);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              Tooltip(
                message: lossTooltip,
                child: Chip(
                  avatar: Icon(
                    _lossTypeIcon(bundle.lossType),
                    size: 18,
                    semanticLabel: lossTooltip,
                  ),
                  label: Text(lossLabel),
                  backgroundColor: Colors.blue.shade50,
                ),
              ),
              Tooltip(
                message: modeTooltip,
                child: Chip(
                  avatar: Icon(
                    _prescriptionModeIcon(bundle.prescriptionMode),
                    size: 18,
                    semanticLabel: modeTooltip,
                  ),
                  label: Text(modeLabel),
                  backgroundColor: Colors.teal.shade50,
                ),
              ),
              if (isMigrated)
                Tooltip(
                  message:
                      'Este preset fue migrado desde un schema anterior. '
                      'El bundle se recomputó con el audiograma original.',
                  child: Chip(
                    avatar: Icon(
                      Icons.upgrade,
                      size: 18,
                      color: Colors.orange.shade700,
                      semanticLabel: 'Preset migrado',
                    ),
                    label: const Text('Migrado'),
                    backgroundColor: Colors.orange.shade50,
                    side: BorderSide(color: Colors.orange.shade200),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // ─────────────────────────────────────────────────────────────────────
  // Labels en español
  // ─────────────────────────────────────────────────────────────────────

  /// Formatea el [LossType] para mostrar en la UI en español.
  static String formatLossType(LossType type) {
    switch (type) {
      case LossType.flat:
        return 'Plana';
      case LossType.sloping:
        return 'Descendente';
      case LossType.reverseSlope:
        return 'Ascendente';
      case LossType.cookieBite:
        return 'Cookie-bite';
      case LossType.notch:
        return 'Muesca';
      case LossType.mixed:
        return 'Mixta';
    }
  }

  /// Formatea el [PrescriptionMode] para mostrar en la UI en español.
  static String formatPrescriptionMode(PrescriptionMode mode) {
    switch (mode) {
      case PrescriptionMode.quiet:
        return 'Silencio';
      case PrescriptionMode.comfortInNoise:
        return 'Ruido';
      case PrescriptionMode.mhl:
        return 'MHL';
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // Tooltips de accesibilidad
  // ─────────────────────────────────────────────────────────────────────

  /// Tooltip descriptivo para cada tipo de pérdida.
  static String _lossTypeTooltip(LossType type) {
    switch (type) {
      case LossType.flat:
        return 'Pérdida plana: sin diferencias significativas entre bandas';
      case LossType.sloping:
        return 'Pérdida descendente: umbrales altos en agudos';
      case LossType.reverseSlope:
        return 'Pérdida ascendente: peor en graves que en agudos';
      case LossType.cookieBite:
        return 'Cookie-bite: peor en frecuencias medias';
      case LossType.notch:
        return 'Muesca: caída abrupta en una frecuencia (3k–6k Hz)';
      case LossType.mixed:
        return 'Mixta: componente conductivo con gap aire-hueso';
    }
  }

  /// Tooltip descriptivo para cada modo de prescripción.
  static String _prescriptionModeTooltip(PrescriptionMode mode) {
    switch (mode) {
      case PrescriptionMode.quiet:
        return 'Prescripción para ambiente silencioso o de habla';
      case PrescriptionMode.comfortInNoise:
        return 'Confort en ruido: reduce fatiga auditiva preservando habla';
      case PrescriptionMode.mhl:
        return 'MHL: ganancia mínima para pérdida auditiva mínima';
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // Íconos
  // ─────────────────────────────────────────────────────────────────────

  /// Ícono representativo para cada tipo de pérdida.
  static IconData _lossTypeIcon(LossType type) {
    switch (type) {
      case LossType.flat:
        return Icons.horizontal_rule;
      case LossType.sloping:
        return Icons.trending_down;
      case LossType.reverseSlope:
        return Icons.trending_up;
      case LossType.cookieBite:
        return Icons.filter_tilt_shift;
      case LossType.notch:
        return Icons.notifications_active;
      case LossType.mixed:
        return Icons.compare_arrows;
    }
  }

  /// Ícono representativo para cada modo de prescripción.
  static IconData _prescriptionModeIcon(PrescriptionMode mode) {
    switch (mode) {
      case PrescriptionMode.quiet:
        return Icons.volume_mute;
      case PrescriptionMode.comfortInNoise:
        return Icons.volume_up;
      case PrescriptionMode.mhl:
        return Icons.tune;
    }
  }
}

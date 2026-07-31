import 'package:flutter/material.dart';

/// Widget que renderiza los dos toggles independientes del técnico:
/// "MHL Prescripción" y "Modo Música".
///
/// Estos modos son mutuamente exclusivos a nivel de comportamiento del DSP,
/// pero la regla de mutex NO se enforce en este widget. El widget se limita
/// a invocar el callback correspondiente con el nuevo valor `bool`; el
/// `AmplificationBloc` recibe el evento (`ToggleMhlPrescription` o
/// `ToggleMusicMode`) y ejecuta la transición ordenada (apagar el otro
/// toggle, persistir, restaurar Smart, reaplicar parámetros, etc.).
///
/// Mantener el mutex fuera del widget evita estados intermedios visibles
/// y deja la UI como un simple presentador del estado emitido por el bloc.
///
/// Cada toggle es visualmente distinto:
/// - **MHL Prescripción**: acento cyan, icono `accessibility_new`,
///   subtítulo "Ganancia flat 8 dB · compresión 1.0:1".
/// - **Modo Música**: acento púrpura, icono `music_note`,
///   subtítulo "NR off · DNN off".
///
/// Ejemplo de uso:
/// ```dart
/// ModeToggles(
///   mhlPrescription: state.mhlPrescriptionEnabled,
///   musicMode: state.musicModeEnabled,
///   onMhlChanged: (v) => bloc.add(ToggleMhlPrescription(activate: v)),
///   onMusicChanged: (v) => bloc.add(ToggleMusicMode(activate: v)),
/// )
/// ```
///
/// El parámetro opcional `showMusic` permite ocultar el toggle de "Modo
/// Música" cuando se desea reusar el componente para mostrar solo MHL
/// Prescripción (lo usa el wrapper legacy `MhlModeToggle` para preservar
/// compatibilidad con screens viejas). Por defecto es `true`.
///
/// Requisitos: 1.3, 1.4
class ModeToggles extends StatelessWidget {
  /// Si "MHL Prescripción" está activo según el estado del bloc.
  final bool mhlPrescription;

  /// Si "Modo Música" está activo según el estado del bloc.
  final bool musicMode;

  /// Callback al togglear "MHL Prescripción". Recibe el nuevo valor `bool`
  /// (true = activar, false = desactivar). El bloc decide cómo aplicar la
  /// transición.
  final ValueChanged<bool> onMhlChanged;

  /// Callback al togglear "Modo Música". Recibe el nuevo valor `bool`.
  final ValueChanged<bool> onMusicChanged;

  /// Si los toggles están habilitados para interacción.
  final bool enabled;

  /// Si se debe renderizar el toggle de "Modo Música". Cuando es `false` el
  /// widget muestra únicamente el toggle de "MHL Prescripción"; los
  /// parámetros `musicMode` y `onMusicChanged` se ignoran visualmente y solo
  /// se conservan para preservar el contrato del constructor.
  final bool showMusic;

  const ModeToggles({
    super.key,
    required this.mhlPrescription,
    required this.musicMode,
    required this.onMhlChanged,
    required this.onMusicChanged,
    this.enabled = true,
    this.showMusic = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ModeToggleCard(
          title: 'MHL Prescripción',
          subtitle: mhlPrescription
              ? 'Ganancia flat 8 dB · compresión 1.0:1'
              : 'Pérdida mínima · prescripción simplificada',
          icon: Icons.accessibility_new,
          accentColor: Colors.cyanAccent,
          isActive: mhlPrescription,
          enabled: enabled,
          onChanged: onMhlChanged,
        ),
        if (showMusic) ...[
          const SizedBox(height: 8),
          _ModeToggleCard(
            title: 'Modo Música',
            subtitle: musicMode
                ? 'NR off · DNN off · cadena lineal'
                : 'Activar para escucha musical sin reducción de ruido',
            icon: Icons.music_note,
            accentColor: Colors.purpleAccent,
            isActive: musicMode,
            enabled: enabled,
            onChanged: onMusicChanged,
          ),
        ],
      ],
    );
  }
}

/// Tarjeta interna reutilizable para un toggle.
///
/// Diseño alineado con el resto de widgets del técnico (`MhlModeToggle`,
/// `PrescriberModeSelector`): `AnimatedContainer` con `BorderRadius.circular(12)`,
/// borde y fondo coloreados según `isActive`, fila con icono + título +
/// `Switch` compacto y subtítulo descriptivo.
class _ModeToggleCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accentColor;
  final bool isActive;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _ModeToggleCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accentColor,
    required this.isActive,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final Color resolvedAccent = isActive ? accentColor : Colors.white38;
    final Color borderColor = isActive ? accentColor : Colors.white24;
    final Color backgroundColor = isActive
        ? accentColor.withOpacity(0.12)
        : Colors.transparent;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: borderColor.withOpacity(0.5),
          width: isActive ? 1.5 : 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, color: resolvedAccent, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: isActive ? resolvedAccent : Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              SizedBox(
                height: 28,
                child: Switch(
                  value: isActive,
                  onChanged: enabled ? onChanged : null,
                  activeColor: resolvedAccent,
                  activeTrackColor: resolvedAccent.withOpacity(0.3),
                  inactiveThumbColor: Colors.white38,
                  inactiveTrackColor: Colors.white12,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              color: isActive
                  ? resolvedAccent.withOpacity(0.7)
                  : Colors.white38,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

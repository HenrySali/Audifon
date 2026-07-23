import 'package:flutter/material.dart';

/// Selector de experiencia previa del usuario con audífonos.
///
/// Presenta un grupo de chips con presets en español rioplatense:
/// "Primera vez", "Menos de 6 meses", "6 a 12 meses", "1 a 2 años" y
/// "Más de 2 años", mapeados respectivamente a 0, 3, 9, 18 y 36 meses.
///
/// El valor seleccionado se entrega al callback [onChanged]. Cuando
/// [currentMonths] es `null` ningún chip aparece resaltado, indicando
/// onboarding pendiente.
///
/// Ejemplo de uso:
/// ```dart
/// ExperienceMonthsPicker(
///   currentMonths: state.experienceMonths,
///   onChanged: (months) =>
///     bloc.add(SetExperienceMonths(months)),
/// )
/// ```
class ExperienceMonthsPicker extends StatelessWidget {
  /// Experiencia actualmente guardada en meses.
  ///
  /// `null` significa que el usuario todavía no eligió un valor: ningún
  /// chip se marca como activo, dando pie al onboarding.
  final int? currentMonths;

  /// Invocado cuando el usuario toca un chip distinto al activo.
  final ValueChanged<int> onChanged;

  /// Permite deshabilitar el control (por ejemplo durante la transición
  /// de modos del prescriptor).
  final bool enabled;

  const ExperienceMonthsPicker({
    super.key,
    required this.currentMonths,
    required this.onChanged,
    this.enabled = true,
  });

  /// Presets disponibles.
  ///
  /// Cada entrada se compone de la etiqueta visible y el valor en meses
  /// que se persiste y se inyecta en el [PatientProfile].
  static const List<({String label, int months})> _presets = [
    (label: 'Primera vez', months: 0),
    (label: 'Menos de 6 meses', months: 3),
    (label: '6 a 12 meses', months: 9),
    (label: '1 a 2 años', months: 18),
    (label: 'Más de 2 años', months: 36),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Encabezado de la sección
          const Row(
            children: [
              Icon(Icons.history_toggle_off, color: Colors.cyan, size: 18),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Tu experiencia con audífonos',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'NL3 ajusta -3 dB de aclimatización si recién empezás.',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 10),
          // Chips de presets
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in _presets)
                _ExperienceChip(
                  label: preset.label,
                  months: preset.months,
                  isActive: currentMonths == preset.months,
                  enabled: enabled,
                  onTap: () => _select(preset.months),
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _select(int months) {
    if (!enabled) return;
    if (currentMonths == months) return;
    onChanged(months);
  }
}

/// Chip individual para un preset de experiencia.
class _ExperienceChip extends StatelessWidget {
  final String label;
  final int months;
  final bool isActive;
  final bool enabled;
  final VoidCallback onTap;

  const _ExperienceChip({
    required this.label,
    required this.months,
    required this.isActive,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = isActive ? Colors.cyan : Colors.white24;
    final backgroundColor =
        isActive ? Colors.cyan.withOpacity(0.15) : Colors.transparent;
    final textColor = isActive ? Colors.cyan : Colors.white70;

    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor, width: isActive ? 2 : 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isActive)
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 6),
                decoration: const BoxDecoration(
                  color: Colors.greenAccent,
                  shape: BoxShape.circle,
                ),
              ),
            Text(
              label,
              style: TextStyle(
                color: textColor,
                fontSize: 12,
                fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

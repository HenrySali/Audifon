/// @file eligibility_questionnaire_widget.dart
/// @brief Widget de cuestionario de elegibilidad para sujetos normoyentes.
///
/// Presenta 4 preguntas con `SwitchListTile` (Material 3) que mapean
/// directamente a los campos de [EligibilityQuestionnaire]. El botón
/// "Continuar" solo se habilita cuando todas las respuestas son
/// `true`, es decir cuando `isEligible` del cuestionario es verdadero.
///
/// Compatibilidad Flutter 3.19.6: usa `withOpacity` (no `withValues`) y
/// no depende de APIs nuevas.

library;

import 'package:flutter/material.dart';

import '../../models/eligibility_questionnaire.dart';

/// Widget de cuestionario de elegibilidad.
///
/// Cuando el operador presiona "Continuar", se invoca [onSubmit] con un
/// [EligibilityQuestionnaire] que refleja las respuestas dadas. El botón
/// permanece deshabilitado hasta que el cuestionario sea elegible.
class EligibilityQuestionnaireWidget extends StatefulWidget {
  const EligibilityQuestionnaireWidget({
    super.key,
    required this.onSubmit,
  });

  /// Callback invocado al presionar "Continuar" con el cuestionario completo.
  final void Function(EligibilityQuestionnaire questionnaire) onSubmit;

  @override
  State<EligibilityQuestionnaireWidget> createState() =>
      _EligibilityQuestionnaireWidgetState();
}

class _EligibilityQuestionnaireWidgetState
    extends State<EligibilityQuestionnaireWidget> {
  bool _ageInRange = false;
  bool _normalHearing = false;
  bool _noTinnitus = false;
  bool _noCongestion = false;

  EligibilityQuestionnaire get _current => EligibilityQuestionnaire(
        ageInRange: _ageInRange,
        normalHearingSelfReported: _normalHearing,
        noActiveTinnitus: _noTinnitus,
        noCongestion: _noCongestion,
      );

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool eligible = _current.isEligible;

    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Encabezado.
            Row(
              children: <Widget>[
                Icon(Icons.assignment_ind_outlined,
                    color: colors.primary, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Cuestionario de elegibilidad',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Para participar en la calibración el sujeto debe cumplir los '
              'cuatro criterios. Marcá cada respuesta sinceramente.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurface.withOpacity(0.75),
                  ),
            ),
            const Divider(height: 24),

            // Preguntas.
            _buildQuestion(
              context: context,
              icon: Icons.cake_outlined,
              title: '¿Edad entre 18 y 35 años?',
              subtitle:
                  'Rango recomendado para garantizar audición no envejecida.',
              value: _ageInRange,
              onChanged: (bool v) => setState(() => _ageInRange = v),
            ),
            _buildQuestion(
              context: context,
              icon: Icons.hearing,
              title: '¿Audición normal sin pérdidas conocidas?',
              subtitle:
                  'Sin diagnóstico previo de hipoacusia ni uso de audífonos.',
              value: _normalHearing,
              onChanged: (bool v) => setState(() => _normalHearing = v),
            ),
            _buildQuestion(
              context: context,
              icon: Icons.volume_off_outlined,
              title: '¿Sin tinnitus activo (zumbidos)?',
              subtitle:
                  'No percibe zumbidos o pitidos en este momento.',
              value: _noTinnitus,
              onChanged: (bool v) => setState(() => _noTinnitus = v),
            ),
            _buildQuestion(
              context: context,
              icon: Icons.air_outlined,
              title: '¿Sin congestión nasal o de oído ahora?',
              subtitle:
                  'No tiene resfrío, alergia activa ni sensación de oído tapado.',
              value: _noCongestion,
              onChanged: (bool v) => setState(() => _noCongestion = v),
            ),

            const SizedBox(height: 16),

            // Botón continuar (habilitado solo si elegible).
            FilledButton.icon(
              onPressed: eligible ? () => widget.onSubmit(_current) : null,
              icon: const Icon(Icons.arrow_forward),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Continuar',
                  style: TextStyle(fontSize: 16),
                ),
              ),
            ),
            if (!eligible)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'El sujeto no es elegible. Marcá las cuatro casillas en '
                  'verdadero para continuar.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.error,
                      ),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildQuestion({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      secondary: Icon(icon, color: colors.primary),
      title: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          subtitle,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurface.withOpacity(0.65),
              ),
        ),
      ),
      value: value,
      onChanged: onChanged,
    );
  }
}

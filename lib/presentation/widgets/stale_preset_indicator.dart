import 'package:flutter/material.dart';

/// Indicador de preset personalizado obsoleto con acción de regeneración.
///
/// Muestra un badge "Obsoleto" (amber/orange [Chip]) cuando el preset
/// está marcado como stale (`isStale == true`). Expone un botón
/// "Regenerar con audiograma actual" que invoca [onRegenerate].
///
/// Diseñado para ser usado como overlay o wrapper de cada fila en la
/// lista de presets personalizados. Se muestra únicamente cuando
/// [isStale] es `true`; cuando es `false` retorna un [SizedBox.shrink].
///
/// Durante la regeneración ([isRegenerating] == true) el botón se
/// reemplaza por un indicador de progreso circular compacto.
///
/// Accessibility: el [Chip] de "Obsoleto" incluye [Semantics] con
/// label descriptivo para lectores de pantalla, indicando que el preset
/// está desfasado respecto al audiograma actual.
///
/// Requisitos: 9.4
class StalePresetIndicator extends StatelessWidget {
  /// Nombre del preset personalizado afectado.
  final String presetName;

  /// Si el preset está marcado como obsoleto (stale).
  ///
  /// Cuando `false`, el widget no renderiza nada ([SizedBox.shrink]).
  /// Cuando no se provee y se usa la variante legacy (con
  /// `customPresetsStale` global), usar el BlocSelector en el padre.
  final bool isStale;

  /// Si el preset está siendo regenerado actualmente.
  ///
  /// Muestra un [CircularProgressIndicator] en lugar del botón de
  /// regeneración.
  final bool isRegenerating;

  /// Callback invocado cuando el usuario pulsa "Regenerar con
  /// audiograma actual". El padre debe despachar la lógica de
  /// regeneración al repositorio.
  final VoidCallback? onRegenerate;

  const StalePresetIndicator({
    super.key,
    required this.presetName,
    this.isStale = false,
    this.isRegenerating = false,
    this.onRegenerate,
  });

  @override
  Widget build(BuildContext context) {
    if (!isStale) return const SizedBox.shrink();

    return Semantics(
      container: true,
      label: 'Preset "$presetName" obsoleto. '
          'El audiograma cambió significativamente desde que se creó.',
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.orange.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.orange.shade200),
        ),
        child: Row(
          children: [
            // Badge "Obsoleto" como Chip amber.
            Semantics(
              label: 'Estado: obsoleto',
              excludeSemantics: true,
              child: Chip(
                avatar: Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.orange.shade800,
                  size: 16,
                ),
                label: Text(
                  'Obsoleto',
                  style: TextStyle(
                    color: Colors.orange.shade900,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                backgroundColor: Colors.orange.shade100,
                side: BorderSide(color: Colors.orange.shade300),
                padding: EdgeInsets.zero,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 8),
            // Nombre del preset.
            Expanded(
              child: Text(
                presetName,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: Colors.orange.shade900,
                    ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            // Botón de regenerar o indicador de carga.
            if (isRegenerating)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.orange,
                ),
              )
            else
              Flexible(
                child: OutlinedButton.icon(
                  onPressed: onRegenerate,
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text(
                    'Regenerar con audiograma actual',
                    style: TextStyle(fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.orange.shade800,
                    side: BorderSide(color: Colors.orange.shade400),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

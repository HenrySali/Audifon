import 'package:flutter/material.dart';

/// Vista de detalle numérico de diferencias de ganancia banda por banda.
///
/// Muestra una tabla con 12 filas (una por banda del EQ) con las columnas:
/// frecuencia, ganancia NL2, ganancia NL3, diferencia (NL3 − NL2) con signo.
/// Las diferencias positivas (NL3 > NL2) se muestran en verde; las negativas
/// en rojo/naranja. Opcionalmente incluye una columna CIN si se proveen
/// ganancias CIN-modificadas.
///
/// Se usa como BottomSheet mostrado al tocar el [GainComparisonWidget].
///
/// Ejemplo de uso:
/// ```dart
/// showModalBottomSheet(
///   context: context,
///   builder: (_) => GainDetailView(
///     nl2Gains: nl2,
///     nl3Gains: nl3,
///     cinGains: cinActive ? cinGains : null,
///   ),
/// );
/// ```
///
/// Requisitos: 12.5
class GainDetailView extends StatelessWidget {
  /// Ganancias prescritas por NAL-NL2 (12 valores, dB).
  final List<double> nl2Gains;

  /// Ganancias prescritas por NAL-NL3 (12 valores, dB).
  final List<double> nl3Gains;

  /// Ganancias CIN-modificadas (12 valores, dB). Null si CIN no está activo.
  final List<double>? cinGains;

  /// Etiquetas de frecuencia para las 12 bandas del EQ.
  static const List<String> bandLabels = [
    '250 Hz',
    '500 Hz',
    '750 Hz',
    '1000 Hz',
    '1500 Hz',
    '2000 Hz',
    '2500 Hz',
    '3000 Hz',
    '3500 Hz',
    '4000 Hz',
    '6000 Hz',
    '8000 Hz',
  ];

  /// Color para diferencias positivas (NL3 prescribe más ganancia que NL2).
  static const Color _positiveColor = Color(0xFF4CAF50);

  /// Color para diferencias negativas (NL3 prescribe menos ganancia que NL2).
  static const Color _negativeColor = Color(0xFFFF7043);

  /// Color para diferencia cero.
  static const Color _zeroColor = Colors.white54;

  const GainDetailView({
    super.key,
    required this.nl2Gains,
    required this.nl3Gains,
    this.cinGains,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF16213e),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Indicador de arrastre (drag handle)
          _buildDragHandle(),
          // Título
          _buildTitle(),
          const SizedBox(height: 8),
          // Encabezado de columnas
          _buildHeader(),
          const Divider(color: Colors.white24, height: 1),
          // Lista de bandas con diferencias
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              itemCount: 12,
              separatorBuilder: (_, __) =>
                  const Divider(color: Colors.white10, height: 1),
              itemBuilder: (_, index) => _buildRow(index),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  /// Indicador visual de que el sheet es arrastrable.
  Widget _buildDragHandle() {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Center(
        child: Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }

  /// Título del detalle.
  Widget _buildTitle() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16),
      child: Text(
        'Diferencias de ganancia por banda',
        style: TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// Encabezado con los nombres de las columnas.
  Widget _buildHeader() {
    final hasCin = cinGains != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          const Expanded(
            flex: 3,
            child: Text(
              'Frecuencia',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Expanded(
            flex: 2,
            child: Text(
              'NL2',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.blue,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Expanded(
            flex: 2,
            child: Text(
              'NL3',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.cyan,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (hasCin)
            const Expanded(
              flex: 2,
              child: Text(
                'CIN',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.amber,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          const Expanded(
            flex: 2,
            child: Text(
              'Δ dB',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Fila con los datos de una banda individual.
  Widget _buildRow(int index) {
    final nl2 = nl2Gains[index];
    final nl3 = nl3Gains[index];
    final diff = nl3 - nl2;
    final hasCin = cinGains != null;

    // Color según signo de la diferencia.
    final diffColor = diff > 0
        ? _positiveColor
        : diff < 0
            ? _negativeColor
            : _zeroColor;

    // Formato con signo explícito.
    final diffText = _formatDifference(diff);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          // Frecuencia
          Expanded(
            flex: 3,
            child: Text(
              bandLabels[index],
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
              ),
            ),
          ),
          // Ganancia NL2
          Expanded(
            flex: 2,
            child: Text(
              nl2.toStringAsFixed(1),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.blue,
                fontSize: 12,
              ),
            ),
          ),
          // Ganancia NL3
          Expanded(
            flex: 2,
            child: Text(
              nl3.toStringAsFixed(1),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.cyan,
                fontSize: 12,
              ),
            ),
          ),
          // Ganancia CIN (si aplica)
          if (hasCin)
            Expanded(
              flex: 2,
              child: Text(
                cinGains![index].toStringAsFixed(1),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.amber,
                  fontSize: 12,
                ),
              ),
            ),
          // Diferencia NL3 - NL2
          Expanded(
            flex: 2,
            child: Text(
              diffText,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: diffColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Formatea la diferencia con signo explícito ("+2.0", "-1.5", "0.0").
  static String _formatDifference(double diff) {
    if (diff == 0) return '0.0';
    final sign = diff > 0 ? '+' : '';
    return '$sign${diff.toStringAsFixed(1)}';
  }
}

/// Muestra el [GainDetailView] como un BottomSheet modal.
///
/// Función utilitaria para invocar desde el callback [onTap] del
/// [GainComparisonWidget]. Encapsula la creación del bottom sheet
/// con la configuración visual apropiada.
///
/// Ejemplo:
/// ```dart
/// GainComparisonWidget(
///   nl2Gains: nl2,
///   nl3Gains: nl3,
///   lossType: lossType,
///   onTap: () => showGainDetailBottomSheet(
///     context: context,
///     nl2Gains: nl2,
///     nl3Gains: nl3,
///   ),
/// )
/// ```
void showGainDetailBottomSheet({
  required BuildContext context,
  required List<double> nl2Gains,
  required List<double> nl3Gains,
  List<double>? cinGains,
}) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      builder: (context, scrollController) => GainDetailView(
        nl2Gains: nl2Gains,
        nl3Gains: nl3Gains,
        cinGains: cinGains,
      ),
    ),
  );
}

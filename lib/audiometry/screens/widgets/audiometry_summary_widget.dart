/// @file audiometry_summary_widget.dart
/// @brief Resumen visual de un `AudiometryResult`: tabla de umbrales,
///        mini-audiograma y exportación a JSON.
///
/// Renderiza:
///   - Cabecera con fecha del test y referencia a la calibración usada.
///   - Tabla con: frecuencia (Hz), umbral en dB HL, estado clínico
///     (normal / leve / moderado / severo / profundo) y un indicador de
///     "fuera de rango del transductor" cuando aplica.
///   - Mini-gráfico tipo audiograma: barras verticales por frecuencia con
///     altura proporcional al umbral; eje Y invertido (0 dB HL arriba,
///     120 dB HL abajo) siguiendo la convención clínica.
///   - Botón "Copiar JSON al portapapeles".
///
/// Compatibilidad Flutter 3.19.6: usa `withOpacity` (no `withValues`) y no
/// depende de APIs nuevas.
///
/// Referencias:
///  - design.md §"Pantalla principal" / "Widgets UI"
///  - tasks.md §4 "Widgets UI"
///  - requirements.md §5 "Audiograma autopoblado"
///  - requirements.md §7 "Persistencia y reporte"
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/audiometry_result.dart';
import '../../models/frequency_threshold_hl.dart';

/// Categorías clínicas estándar de pérdida auditiva (WHO / ASHA).
///
/// Se usan para mostrar el estado en la tabla del resumen.
enum HearingLossCategory {
  normal,
  mild,
  moderate,
  severe,
  profound,
}

/// Helpers para mapear umbrales dB HL a [HearingLossCategory] y a su
/// representación visual (color + label en español).
class _HearingLossCategoryHelper {
  /// Clasificación clínica simplificada (ASHA-like):
  ///   ≤ 25 dB HL → normal
  ///   26 - 40    → leve
  ///   41 - 55    → moderado
  ///   56 - 70    → moderado-severo (lo agrupamos en "severo")
  ///   71 - 90    → severo
  ///   > 90       → profundo
  static HearingLossCategory categorize(double thresholdHL) {
    if (thresholdHL <= 25) return HearingLossCategory.normal;
    if (thresholdHL <= 40) return HearingLossCategory.mild;
    if (thresholdHL <= 55) return HearingLossCategory.moderate;
    if (thresholdHL <= 90) return HearingLossCategory.severe;
    return HearingLossCategory.profound;
  }

  static String label(HearingLossCategory c) {
    switch (c) {
      case HearingLossCategory.normal:
        return 'Normal';
      case HearingLossCategory.mild:
        return 'Leve';
      case HearingLossCategory.moderate:
        return 'Moderado';
      case HearingLossCategory.severe:
        return 'Severo';
      case HearingLossCategory.profound:
        return 'Profundo';
    }
  }

  static Color color(HearingLossCategory c, ColorScheme scheme) {
    switch (c) {
      case HearingLossCategory.normal:
        return Colors.green.shade600;
      case HearingLossCategory.mild:
        return Colors.lightGreen.shade700;
      case HearingLossCategory.moderate:
        return Colors.amber.shade800;
      case HearingLossCategory.severe:
        return Colors.deepOrange.shade700;
      case HearingLossCategory.profound:
        return scheme.error;
    }
  }
}

/// Widget que muestra el resultado de una audiometría completada.
class AudiometrySummaryWidget extends StatelessWidget {
  const AudiometrySummaryWidget({
    super.key,
    required this.result,
  });

  /// Resultado a mostrar.
  final AudiometryResult result;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Encabezado.
            Row(
              children: <Widget>[
                Icon(Icons.medical_information_outlined,
                    color: colors.primary, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Resumen de audiometría',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Realizada el ${_formatDateTime(result.testedAt)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurface.withOpacity(0.7),
                  ),
            ),
            Text(
              'Calibración: ${_shortMac(result.calibrationMac)} '
              '· ${_formatDateTime(result.calibrationDate)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurface.withOpacity(0.7),
                  ),
            ),
            if (result.retest1000Diff != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                'Retest 1000 Hz: '
                '${result.retest1000Diff!.abs().toStringAsFixed(1)} dB HL '
                '${result.retest1000Diff!.abs() <= 10 ? "✓ aceptable" : "⚠ excede 10 dB HL"}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: result.retest1000Diff!.abs() <= 10
                          ? Colors.green.shade700
                          : colors.error,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
            const Divider(height: 24),

            _buildThresholdsTable(context),

            const SizedBox(height: 20),
            Text(
              'Audiograma',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            _AudiogramMiniChart(result: result),

            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => _copyJsonToClipboard(context),
              icon: const Icon(Icons.copy_all),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  'Copiar JSON al portapapeles',
                  style: TextStyle(fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ───────────────────────────────────────────── Tabla de umbrales ─────

  Widget _buildThresholdsTable(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextStyle? headerStyle =
        Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colors.onPrimaryContainer,
              fontWeight: FontWeight.w700,
            );

    final List<int> orderedFreqs = result.thresholds.keys.toList()..sort();

    if (orderedFreqs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'No hay frecuencias medidas en este resultado.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.onSurface.withOpacity(0.7),
              ),
        ),
      );
    }

    const List<DataColumn> columns = <DataColumn>[
      DataColumn(label: Text('Hz')),
      DataColumn(label: Text('Umbral (dB HL)'), numeric: true),
      DataColumn(label: Text('Estado')),
      DataColumn(label: Text('Notas')),
    ];

    final List<DataRow> rows = orderedFreqs.map((int freq) {
      final FrequencyThresholdHL t = result.thresholds[freq]!;
      final HearingLossCategory cat =
          _HearingLossCategoryHelper.categorize(t.thresholdHL);

      // Formato del umbral: si es normalLimit mostramos "≤ -10".
      final String thresholdStr = t.normalLimit
          ? '≤ ${t.thresholdHL.toStringAsFixed(0)}'
          : t.thresholdHL.toStringAsFixed(0);

      // Texto de notas.
      final String notes = t.outOfRange
          ? 'Fuera de rango'
          : (t.normalLimit ? 'Audición normal' : '—');

      return DataRow(
        cells: <DataCell>[
          DataCell(Text(freq.toString())),
          DataCell(Text(thresholdStr)),
          DataCell(_categoryChip(context, cat, t.outOfRange)),
          DataCell(Text(
            notes,
            style: TextStyle(
              color: t.outOfRange
                  ? colors.error
                  : colors.onSurface.withOpacity(0.7),
              fontStyle: t.outOfRange ? FontStyle.italic : FontStyle.normal,
            ),
          )),
        ],
      );
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Umbrales por frecuencia',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: MaterialStateProperty.all(
              colors.primaryContainer.withOpacity(0.6),
            ),
            headingTextStyle: headerStyle,
            columnSpacing: 18,
            columns: columns,
            rows: rows,
          ),
        ),
      ],
    );
  }

  Widget _categoryChip(
    BuildContext context,
    HearingLossCategory cat,
    bool outOfRange,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (outOfRange) {
      // Para fuera de rango, mostramos la categoría con un asterisco visual
      // y color atenuado, dado que el umbral real podría ser peor.
      final Color base = scheme.error;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: base.withOpacity(0.18),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          '≥ ${_HearingLossCategoryHelper.label(cat)}',
          style: TextStyle(color: base, fontWeight: FontWeight.w600),
        ),
      );
    }

    final Color base = _HearingLossCategoryHelper.color(cat, scheme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: base.withOpacity(0.18),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        _HearingLossCategoryHelper.label(cat),
        style: TextStyle(color: base, fontWeight: FontWeight.w600),
      ),
    );
  }

  // ───────────────────────────────────────────── Acciones ──────────────

  Future<void> _copyJsonToClipboard(BuildContext context) async {
    final String jsonStr =
        const JsonEncoder.withIndent('  ').convert(result.toJson());
    await Clipboard.setData(ClipboardData(text: jsonStr));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Reporte de audiometría copiado al portapapeles'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  // ───────────────────────────────────────────── Helpers ───────────────

  String _formatDateTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    final DateTime local = dt.toLocal();
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  String _shortMac(String mac) {
    if (mac.length <= 8) return mac;
    return '${mac.substring(0, 8)}…';
  }
}

// ────────────────────────────────────────────── Mini audiograma ─────────

/// Mini-gráfico de audiograma (CustomPaint) que muestra una barra vertical
/// por frecuencia con altura proporcional al umbral.
///
/// Convenciones clínicas:
///   - Eje X: frecuencias ordenadas (250 → 8000 Hz típicamente).
///   - Eje Y: 0 dB HL arriba, 120 dB HL abajo (eje invertido).
///   - Barras color verde para Normal, amarillo para leve, naranja para
///     moderado, rojo para severo/profundo.
///   - Las frecuencias `outOfRange` se dibujan como una marca hasta el tope
///     (120 dB HL) con patrón rayado, indicando que el techo del transductor
///     se alcanzó sin respuesta.
class _AudiogramMiniChart extends StatelessWidget {
  const _AudiogramMiniChart({required this.result});

  final AudiometryResult result;

  /// Eje Y: 0 dB HL arriba, 120 dB HL abajo.
  static const double _yMaxDbHL = 120.0;
  static const double _yMinDbHL = -10.0;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<int> orderedFreqs = result.thresholds.keys.toList()..sort();

    if (orderedFreqs.isEmpty) {
      return Container(
        height: 160,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.surfaceVariant.withOpacity(0.3),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          'Sin datos para graficar',
          style: TextStyle(color: scheme.onSurface.withOpacity(0.6)),
        ),
      );
    }

    return Container(
      height: 200,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceVariant.withOpacity(0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withOpacity(0.6)),
      ),
      child: CustomPaint(
        painter: _AudiogramPainter(
          frequencies: orderedFreqs,
          thresholds: result.thresholds,
          axisColor: scheme.onSurface.withOpacity(0.6),
          gridColor: scheme.onSurface.withOpacity(0.12),
          textColor: scheme.onSurface.withOpacity(0.85),
          colorScheme: scheme,
          yMaxDbHL: _yMaxDbHL,
          yMinDbHL: _yMinDbHL,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Painter del mini audiograma de barras invertido.
class _AudiogramPainter extends CustomPainter {
  _AudiogramPainter({
    required this.frequencies,
    required this.thresholds,
    required this.axisColor,
    required this.gridColor,
    required this.textColor,
    required this.colorScheme,
    required this.yMaxDbHL,
    required this.yMinDbHL,
  });

  final List<int> frequencies;
  final Map<int, FrequencyThresholdHL> thresholds;
  final Color axisColor;
  final Color gridColor;
  final Color textColor;
  final ColorScheme colorScheme;
  final double yMaxDbHL;
  final double yMinDbHL;

  @override
  void paint(Canvas canvas, Size size) {
    // Margen para etiquetas: izquierda (dB HL) y abajo (Hz).
    const double leftMargin = 36.0;
    const double rightMargin = 8.0;
    const double topMargin = 8.0;
    const double bottomMargin = 22.0;

    final double plotW = size.width - leftMargin - rightMargin;
    final double plotH = size.height - topMargin - bottomMargin;
    if (plotW <= 0 || plotH <= 0) return;

    final Rect plotRect =
        Rect.fromLTWH(leftMargin, topMargin, plotW, plotH);

    // ─── Grid horizontal y etiquetas dB HL ─────────────────────────────
    final Paint gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1.0;

    // Líneas horizontales en 0, 25, 50, 75, 100, 120 dB HL.
    final List<double> yLabels = [0, 25, 50, 75, 100, 120];
    for (final dbHl in yLabels) {
      if (dbHl < yMinDbHL || dbHl > yMaxDbHL) continue;
      final double y = _yToPx(dbHl, plotRect);
      canvas.drawLine(
        Offset(plotRect.left, y),
        Offset(plotRect.right, y),
        gridPaint,
      );
      _drawText(
        canvas,
        '${dbHl.toInt()}',
        Offset(plotRect.left - 4, y),
        textColor,
        fontSize: 9,
        align: _TextAlign.right,
        vAlign: _VAlign.center,
      );
    }

    // ─── Eje X (línea inferior y eje Y vertical) ───────────────────────
    final Paint axisPaint = Paint()
      ..color = axisColor
      ..strokeWidth = 1.2;
    canvas.drawLine(
      Offset(plotRect.left, plotRect.bottom),
      Offset(plotRect.right, plotRect.bottom),
      axisPaint,
    );
    canvas.drawLine(
      Offset(plotRect.left, plotRect.top),
      Offset(plotRect.left, plotRect.bottom),
      axisPaint,
    );

    // ─── Barras por frecuencia ─────────────────────────────────────────
    final int n = frequencies.length;
    if (n == 0) return;
    final double bandW = plotW / n;
    final double barW = bandW * 0.55;

    for (int i = 0; i < n; i++) {
      final int freq = frequencies[i];
      final FrequencyThresholdHL t = thresholds[freq]!;

      final double cx = plotRect.left + bandW * (i + 0.5);
      final double yTop = _yToPx(
        t.thresholdHL.clamp(yMinDbHL, yMaxDbHL),
        plotRect,
      );
      final double yBottom = plotRect.bottom;

      final HearingLossCategory cat =
          _HearingLossCategoryHelper.categorize(t.thresholdHL);
      final Color barColor =
          _HearingLossCategoryHelper.color(cat, colorScheme);

      final Rect barRect = Rect.fromLTRB(
        cx - barW / 2,
        yTop,
        cx + barW / 2,
        yBottom,
      );

      if (t.outOfRange) {
        // Fuera de rango: barra hasta el tope (120) en color rojo + patrón.
        final double yTopOOR = _yToPx(yMaxDbHL, plotRect);
        final Rect oorRect = Rect.fromLTRB(
          cx - barW / 2,
          yTopOOR,
          cx + barW / 2,
          yBottom,
        );
        final Paint bgPaint = Paint()
          ..color = colorScheme.error.withOpacity(0.25);
        canvas.drawRRect(
          RRect.fromRectAndRadius(oorRect, const Radius.circular(3)),
          bgPaint,
        );
        // Borde marcado.
        final Paint borderPaint = Paint()
          ..color = colorScheme.error
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5;
        canvas.drawRRect(
          RRect.fromRectAndRadius(oorRect, const Radius.circular(3)),
          borderPaint,
        );
        // Marca "✕" en la parte superior.
        _drawText(
          canvas,
          '✕',
          Offset(cx, yTopOOR + 8),
          colorScheme.error,
          fontSize: 11,
          align: _TextAlign.center,
          vAlign: _VAlign.top,
          fontWeight: FontWeight.w700,
        );
      } else {
        final Paint barPaint = Paint()..color = barColor.withOpacity(0.85);
        canvas.drawRRect(
          RRect.fromRectAndRadius(barRect, const Radius.circular(3)),
          barPaint,
        );
        // Pequeña etiqueta numérica encima de cada barra (dB HL).
        _drawText(
          canvas,
          t.thresholdHL.toStringAsFixed(0),
          Offset(cx, yTop - 2),
          textColor,
          fontSize: 9,
          align: _TextAlign.center,
          vAlign: _VAlign.bottom,
          fontWeight: FontWeight.w600,
        );
      }

      // Etiqueta de frecuencia bajo la barra.
      _drawText(
        canvas,
        _freqLabel(freq),
        Offset(cx, plotRect.bottom + 4),
        textColor,
        fontSize: 9,
        align: _TextAlign.center,
        vAlign: _VAlign.top,
      );
    }
  }

  /// Convierte un valor en dB HL a coordenada Y en píxeles dentro de
  /// [plotRect]. El eje está invertido: 0 dB HL arriba, yMaxDbHL abajo.
  double _yToPx(double dbHl, Rect plotRect) {
    final double range = yMaxDbHL - yMinDbHL;
    if (range <= 0) return plotRect.top;
    final double t = (dbHl - yMinDbHL) / range;
    return plotRect.top + t * plotRect.height;
  }

  String _freqLabel(int hz) {
    if (hz >= 1000) {
      final double kHz = hz / 1000.0;
      final String s = kHz == kHz.toInt() ? kHz.toInt().toString() : kHz.toString();
      return '${s}k';
    }
    return hz.toString();
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset anchor,
    Color color, {
    double fontSize = 10,
    _TextAlign align = _TextAlign.left,
    _VAlign vAlign = _VAlign.top,
    FontWeight fontWeight = FontWeight.normal,
  }) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: fontWeight,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    double dx;
    switch (align) {
      case _TextAlign.left:
        dx = anchor.dx;
        break;
      case _TextAlign.center:
        dx = anchor.dx - tp.width / 2;
        break;
      case _TextAlign.right:
        dx = anchor.dx - tp.width;
        break;
    }

    double dy;
    switch (vAlign) {
      case _VAlign.top:
        dy = anchor.dy;
        break;
      case _VAlign.center:
        dy = anchor.dy - tp.height / 2;
        break;
      case _VAlign.bottom:
        dy = anchor.dy - tp.height;
        break;
    }

    tp.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(covariant _AudiogramPainter old) {
    return old.frequencies != frequencies ||
        old.thresholds != thresholds ||
        old.axisColor != axisColor ||
        old.gridColor != gridColor ||
        old.textColor != textColor;
  }
}

enum _TextAlign { left, center, right }

enum _VAlign { top, center, bottom }

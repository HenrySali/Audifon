import 'package:flutter/material.dart';
import '../../data/repositories/calibration_repository.dart';
import '../../data/serializers/calibration_serializer.dart';

/// Pantalla de historial y tendencias de calibración.
///
/// Muestra lista cronológica de mediciones con valores DI,
/// gráfico de tendencia del DI, y tendencias per-band.
///
/// Requirements: 7.3, 7.4
class CalibrationHistoryScreen extends StatefulWidget {
  final CalibrationRepository calibrationRepository;

  const CalibrationHistoryScreen({
    super.key,
    required this.calibrationRepository,
  });

  @override
  State<CalibrationHistoryScreen> createState() =>
      _CalibrationHistoryScreenState();
}

class _CalibrationHistoryScreenState extends State<CalibrationHistoryScreen> {
  List<CalibrationMeasurement> _measurements = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final allMeasurements = <CalibrationMeasurement>[];
      int page = 0;
      int totalCount = 0;

      do {
        final result = await widget.calibrationRepository.getHistory(page);
        allMeasurements.addAll(result.measurements);
        totalCount = result.totalCount;
        page++;
      } while (allMeasurements.length < totalCount && page < 7);

      setState(() {
        _measurements = allMeasurements;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Historial de Calibración'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadHistory),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Text('Error: $_error'));
    }
    if (_measurements.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, size: 48, color: Colors.grey),
            SizedBox(height: 16),
            Text('Sin mediciones registradas'),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildTrendChart(),
        const SizedBox(height: 16),
        Text('Mediciones (${_measurements.length})',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ..._measurements.reversed.map(_buildMeasurementTile),
      ],
    );
  }

  /// Simple DI trend visualization using bars (no external chart library needed)
  Widget _buildTrendChart() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tendencia del Índice de Degradación',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            SizedBox(
              height: 120,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: _measurements.map((m) {
                  final di = m.degradationIndex / 1000.0;
                  final color = di < 0.3
                      ? Colors.green
                      : di <= 0.7
                          ? Colors.orange
                          : Colors.red;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Tooltip(
                        message:
                            'DI: ${(di * 100).toStringAsFixed(1)}%\n${_formatTimestamp(m.timestamp)}',
                        child: Container(
                          height: 120 * di.clamp(0.02, 1.0),
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_formatTimestamp(_measurements.first.timestamp),
                    style: const TextStyle(fontSize: 10, color: Colors.grey)),
                Text(_formatTimestamp(_measurements.last.timestamp),
                    style: const TextStyle(fontSize: 10, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 8),
            // Legend
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _legendDot(Colors.green, '<30%'),
                const SizedBox(width: 12),
                _legendDot(Colors.orange, '30-70%'),
                const SizedBox(width: 12),
                _legendDot(Colors.red, '>70%'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      children: [
        Container(width: 10, height: 10, color: color),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }

  Widget _buildMeasurementTile(CalibrationMeasurement m) {
    final di = m.degradationIndexDouble;
    Color color;
    switch (m.severity) {
      case DegradationSeverity.none:
        color = Colors.green;
        break;
      case DegradationSeverity.moderate:
        color = Colors.orange;
        break;
      case DegradationSeverity.severe:
        color = Colors.red;
        break;
    }

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withOpacity(0.2),
          child: Text(
            '${(di * 100).toInt()}%',
            style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ),
        title: Text(_formatTimestamp(m.timestamp)),
        subtitle: Text(
          'HFA-FOG: ${(m.hfaFog / 10.0).toStringAsFixed(1)} dB  |  '
          'EIN: ${(m.ein / 10.0).toStringAsFixed(1)} dB',
        ),
        trailing: Icon(
          m.severity == DegradationSeverity.none
              ? Icons.check_circle_outline
              : Icons.warning_amber,
          color: color,
        ),
      ),
    );
  }

  String _formatTimestamp(int unixTimestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(unixTimestamp * 1000);
    return '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }
}

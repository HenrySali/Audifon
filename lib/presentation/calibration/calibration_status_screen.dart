import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/repositories/calibration_repository.dart';
import '../../data/serializers/calibration_serializer.dart';

/// Pantalla de estado de calibración y alertas.
///
/// Muestra el Índice de Degradación actual, severidad, timestamp de última
/// medición, y alertas persistentes para degradación severa o moderada.
///
/// Requirements: 5.1, 5.2, 5.3
class CalibrationStatusScreen extends StatefulWidget {
  final CalibrationRepository calibrationRepository;

  const CalibrationStatusScreen({
    super.key,
    required this.calibrationRepository,
  });

  @override
  State<CalibrationStatusScreen> createState() =>
      _CalibrationStatusScreenState();
}

class _CalibrationStatusScreenState extends State<CalibrationStatusScreen> {
  CalibrationStatus? _status;
  CalibrationMeasurement? _lastMeasurement;
  bool _loading = true;
  String? _error;
  StreamSubscription<CalibrationAlert>? _alertSubscription;

  @override
  void initState() {
    super.initState();
    _loadStatus();
    _alertSubscription =
        widget.calibrationRepository.alerts.listen(_handleAlert);
  }

  @override
  void dispose() {
    _alertSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final status = await widget.calibrationRepository.getCalibrationStatus();
      CalibrationMeasurement? lastMeas;
      try {
        lastMeas = await widget.calibrationRepository.getLastResult();
      } catch (_) {
        // No measurement available yet
      }

      setState(() {
        _status = status;
        _lastMeasurement = lastMeas;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _handleAlert(CalibrationAlert alert) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(alert.message),
        backgroundColor: alert.isSevere ? Colors.red : Colors.orange,
        duration: const Duration(seconds: 5),
      ),
    );
    _loadStatus(); // Refresh status
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Estado de Calibración'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadStatus,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text('Error: $_error'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadStatus,
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadStatus,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildDegradationCard(),
          const SizedBox(height: 16),
          if (_status != null) _buildStatusCard(),
          const SizedBox(height: 16),
          if (_lastMeasurement != null) _buildAlertCard(),
        ],
      ),
    );
  }

  Widget _buildDegradationCard() {
    final di = _status?.lastDegradationIndex ?? 0.0;
    final severity = _lastMeasurement?.severity ?? DegradationSeverity.none;

    Color severityColor;
    String severityText;
    IconData severityIcon;

    switch (severity) {
      case DegradationSeverity.none:
        severityColor = Colors.green;
        severityText = 'Sin degradación';
        severityIcon = Icons.check_circle;
        break;
      case DegradationSeverity.moderate:
        severityColor = Colors.orange;
        severityText = 'Degradación moderada';
        severityIcon = Icons.warning;
        break;
      case DegradationSeverity.severe:
        severityColor = Colors.red;
        severityText = 'Degradación severa';
        severityIcon = Icons.error;
        break;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(severityIcon, size: 48, color: severityColor),
            const SizedBox(height: 12),
            Text(
              severityText,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: severityColor,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Índice de Degradación: ${(di * 100).toStringAsFixed(1)}%',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: di,
              backgroundColor: Colors.grey[200],
              color: severityColor,
              minHeight: 8,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    final status = _status!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Información del Sistema',
                style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            _statusRow('Baseline válida', status.baselineValid ? 'Sí' : 'No'),
            _statusRow('Compensación activa',
                status.compensationActive ? 'Activa' : 'Inactiva'),
            _statusRow('Intervalo self-check', '${status.intervalHours} horas'),
            _statusRow(
              'Última medición',
              status.lastMeasurementTime != null
                  ? _formatDate(status.lastMeasurementTime!)
                  : 'Nunca',
            ),
            _statusRow('Estado engine',
                status.engineState == CalibrationEngineState.idle
                    ? 'Inactivo'
                    : 'Midiendo...'),
          ],
        ),
      ),
    );
  }

  Widget _buildAlertCard() {
    final meas = _lastMeasurement!;
    if (meas.severity == DegradationSeverity.none) return const SizedBox();

    return Card(
      color: meas.severity == DegradationSeverity.severe
          ? Colors.red[50]
          : Colors.orange[50],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  meas.severity == DegradationSeverity.severe
                      ? Icons.error
                      : Icons.info,
                  color: meas.severity == DegradationSeverity.severe
                      ? Colors.red
                      : Colors.orange,
                ),
                const SizedBox(width: 8),
                Text(
                  meas.severity == DegradationSeverity.severe
                      ? 'Acción Requerida'
                      : 'Compensación Aplicada',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              meas.severity == DegradationSeverity.severe
                  ? 'La degradación del hardware excede los límites seguros. '
                      'Se recomienda visitar a un audiólogo para servicio profesional.'
                  : 'Se detectó degradación moderada. El sistema ha aplicado '
                      'compensación automática para mantener la calidad de audio.',
            ),
            if (meas.underCompensatedBands != 0) ...[
              const SizedBox(height: 8),
              Text(
                '⚠️ Algunas bandas de frecuencia exceden el límite de '
                'compensación de 10 dB.',
                style: TextStyle(color: Colors.orange[800]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statusRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }
}

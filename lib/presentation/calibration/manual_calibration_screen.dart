import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hearing_aid_app/data/repositories/operator_pin_repository.dart';
import '../../data/repositories/calibration_repository.dart';
import '../../data/serializers/calibration_serializer.dart';

/// Pantalla de calibración manual con autenticación de audiólogo.
///
/// Permite disparar una calibración manual, muestra progreso en tiempo real,
/// y presenta los resultados completos con comparación vs baseline.
///
/// Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 6.6
class ManualCalibrationScreen extends StatefulWidget {
  final CalibrationRepository calibrationRepository;

  /// Repositorio del PIN del operador. Opcional: si se omite, se
  /// instancia uno nuevo. La inyección está pensada para tests
  /// (permite usar un repo apuntando a un Hive temporal).
  final OperatorPinRepository? operatorPinRepository;

  const ManualCalibrationScreen({
    super.key,
    required this.calibrationRepository,
    this.operatorPinRepository,
  });

  @override
  State<ManualCalibrationScreen> createState() =>
      _ManualCalibrationScreenState();
}

class _ManualCalibrationScreenState extends State<ManualCalibrationScreen> {
  bool _authenticated = false;
  bool _measuring = false;
  int _progress = 0;
  CalibrationMeasurement? _result;
  CalibrationMeasurement? _baseline;
  String? _error;
  String? _pinError;

  StreamSubscription<CalibrationProgress>? _progressSub;
  StreamSubscription<CalibrationMeasurement>? _completeSub;

  final _pinController = TextEditingController();
  late final OperatorPinRepository _pinRepo =
      widget.operatorPinRepository ?? OperatorPinRepository();

  @override
  void initState() {
    super.initState();
    _progressSub =
        widget.calibrationRepository.progress.listen(_handleProgress);
    _completeSub =
        widget.calibrationRepository.completedMeasurements.listen(_handleComplete);
    // Hallazgo C-1: si el operador todavía no configuró PIN, lo guiamos
    // a generar uno antes de permitir cualquier autenticación.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybePromptInitialPinSetup();
    });
  }

  /// Si no hay PIN configurado, muestra primero un diálogo invitando a
  /// generarlo y, al confirmar, persiste el hash y muestra el PIN una
  /// única vez para que el operador lo anote. Solo después se permite
  /// el flow de autenticación normal.
  Future<void> _maybePromptInitialPinSetup() async {
    if (!mounted) return;
    if (await _pinRepo.hasPin()) return;
    if (!mounted) return;

    final shouldGenerate = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Genere su PIN inicial'),
        content: const Text(
          'Aún no hay un PIN de operador configurado. '
          'Genérelo ahora para acceder a Calibración Manual y QC Loopback.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Generar'),
          ),
        ],
      ),
    );

    if (shouldGenerate != true || !mounted) return;

    final generated = await _pinRepo.generateAndStoreInitialPin();
    if (!mounted) return;
    await _showInitialPinDialog(generated);
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _completeSub?.cancel();
    _pinController.dispose();
    super.dispose();
  }

  void _handleProgress(CalibrationProgress progress) {
    if (!mounted) return;
    setState(() {
      _progress = progress.percentComplete;
    });
  }

  void _handleComplete(CalibrationMeasurement measurement) {
    if (!mounted) return;
    setState(() {
      _measuring = false;
      _result = measurement;
    });
  }

  Future<void> _verifyPin() async {
    final pin = _pinController.text.trim();

    if (!await _pinRepo.hasPin()) {
      // Primer arranque sin PIN: el operador debe pasar por el flujo de
      // generación inicial antes de poder autenticar.
      if (!mounted) return;
      await _maybePromptInitialPinSetup();
      return;
    }

    if (await _pinRepo.verifyPin(pin)) {
      if (!mounted) return;
      setState(() {
        _authenticated = true;
        _pinError = null;
      });
      await _loadBaseline();
    } else {
      if (!mounted) return;
      setState(() => _pinError = 'PIN incorrecto');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('PIN incorrecto. Acceso denegado.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _showInitialPinDialog(String pin) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('PIN de operador generado'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Anote este PIN — no se vuelve a mostrar. '
              'Servirá para acceder a Calibración Manual y a QC Loopback.',
            ),
            const SizedBox(height: 16),
            SelectableText(
              pin,
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                letterSpacing: 4,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Anotado'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadBaseline() async {
    try {
      _baseline = await widget.calibrationRepository.getBaseline();
    } catch (_) {
      // Baseline may not be available
    }
  }

  Future<void> _startCalibration() async {
    setState(() {
      _measuring = true;
      _progress = 0;
      _result = null;
      _error = null;
    });

    try {
      final success =
          await widget.calibrationRepository.triggerManualCalibration();
      if (!success) {
        setState(() {
          _measuring = false;
          _error = 'El dispositivo rechazó la solicitud de calibración. '
              'Puede haber una medición en progreso o batería baja.';
        });
      }
    } catch (e) {
      setState(() {
        _measuring = false;
        _error = 'Error de comunicación: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Calibración Manual')),
      body: _authenticated ? _buildCalibrationView() : _buildAuthView(),
    );
  }

  Widget _buildAuthView() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.lock, size: 64, color: Colors.grey),
          const SizedBox(height: 24),
          Text(
            'Acceso de Audiólogo',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            'La calibración manual requiere autenticación profesional.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _pinController,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: InputDecoration(
              labelText: 'PIN de Audiólogo',
              border: const OutlineInputBorder(),
              errorText: _pinError,
            ),
            onSubmitted: (_) => _verifyPin(),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _verifyPin,
            child: const Text('Autenticar'),
          ),
        ],
      ),
    );
  }

  Widget _buildCalibrationView() {
    if (_measuring) return _buildProgressView();
    if (_result != null) return _buildResultsView();
    if (_error != null) return _buildErrorView();
    return _buildStartView();
  }

  Widget _buildStartView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.tune, size: 64, color: Colors.blue),
            const SizedBox(height: 24),
            Text(
              'Calibración ANSI S3.22',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'Ejecuta una medición completa de parámetros electroacústicos '
              'y compara contra la línea base de fábrica.\n\n'
              'El audio se silenciará durante ~5 segundos.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _startCalibration,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Iniciar Calibración'),
              style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              'Midiendo... $_progress%',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress / 100.0),
            const SizedBox(height: 8),
            Text(
              'Tiempo estimado: ${((100 - _progress) * 0.05).toStringAsFixed(1)}s',
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            const Text(
              'Audio silenciado durante la medición.',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultsView() {
    final r = _result!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSeverityBanner(r),
        const SizedBox(height: 16),
        _buildMeasurementCard('Resultados de Medición', r),
        if (_baseline != null) ...[
          const SizedBox(height: 16),
          _buildComparisonCard(r, _baseline!),
        ],
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _startCalibration,
          child: const Text('Repetir Calibración'),
        ),
      ],
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => setState(() => _error = null),
              child: const Text('Volver'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSeverityBanner(CalibrationMeasurement m) {
    final di = m.degradationIndexDouble;
    Color color;
    String text;

    switch (m.severity) {
      case DegradationSeverity.none:
        color = Colors.green;
        text = 'Dispositivo en buen estado';
        break;
      case DegradationSeverity.moderate:
        color = Colors.orange;
        text = 'Degradación moderada — compensación aplicada';
        break;
      case DegradationSeverity.severe:
        color = Colors.red;
        text = 'Degradación severa — servicio profesional recomendado';
        break;
    }

    return Card(
      color: color.withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(text,
                style: TextStyle(
                    color: color, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            Text('DI: ${(di * 100).toStringAsFixed(1)}%'),
          ],
        ),
      ),
    );
  }

  Widget _buildMeasurementCard(String title, CalibrationMeasurement m) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            _row('HFA-OSPL90', '${(m.hfaOspl90 / 10.0).toStringAsFixed(1)} dB'),
            _row('HFA Full-On Gain', '${(m.hfaFog / 10.0).toStringAsFixed(1)} dB'),
            _row('EIN', '${(m.ein / 10.0).toStringAsFixed(1)} dB SPL'),
            _row('THD (500 Hz)', '${(m.thd[0] / 100.0).toStringAsFixed(2)}%'),
            _row('THD (800 Hz)', '${(m.thd[1] / 100.0).toStringAsFixed(2)}%'),
            _row('THD (1600 Hz)', '${(m.thd[2] / 100.0).toStringAsFixed(2)}%'),
            _row('Corriente batería', '${m.batteryDrainMa.toStringAsFixed(1)} mA'),
            _row('Índice Degradación',
                '${(m.degradationIndexDouble * 100).toStringAsFixed(1)}%'),
          ],
        ),
      ),
    );
  }

  Widget _buildComparisonCard(
      CalibrationMeasurement current, CalibrationMeasurement baseline) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Comparación vs Baseline',
                style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            const Text('Full-On Gain por banda (desviación):',
                style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            ...List.generate(numBands, (i) {
              final diff =
                  (current.fullOnGain[i] - baseline.fullOnGain[i]) / 10.0;
              final color = diff.abs() > 2.0
                  ? Colors.red
                  : diff.abs() > 1.0
                      ? Colors.orange
                      : Colors.green;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    SizedBox(
                        width: 60, child: Text('Banda ${i + 1}:')),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: (diff.abs() / 10.0).clamp(0.0, 1.0),
                        color: color,
                        backgroundColor: Colors.grey[200],
                      ),
                    ),
                    SizedBox(
                      width: 60,
                      child: Text(
                        '${diff >= 0 ? '+' : ''}${diff.toStringAsFixed(1)} dB',
                        textAlign: TextAlign.right,
                        style: TextStyle(color: color, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [Text(label), Text(value)],
      ),
    );
  }
}

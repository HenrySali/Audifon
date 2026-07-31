/// @file loopback_qc_screen.dart
/// @brief Pantalla de QC Loopback — tarea 15.2 del spec
/// `audiogram-driven-presets`.
///
/// Pantalla técnica oculta detrás de PIN para validar Tramo 3
/// (Prescription → Hearing aid) con la matriz 5 × 3 × 3 documentada en
/// [`docs/qc/loopback-validation.md`](../../../../docs/qc/loopback-validation.md).
///
/// Flujo:
///   1. El operador ingresa el PIN (4 dígitos). PIN incorrecto →
///      SnackBar y la pantalla queda en blanco.
///   2. PIN correcto → se renderiza la UI de QC con tres dropdowns
///      (audiograma test, input level, frecuencia), botones de
///      "Reproducir warble tone" e "Iniciar matriz completa", display
///      del SPL esperado y lista de resultados.
///   3. La matriz completa itera las 45 mediciones (5 audiogramas × 3
///      inputs × 3 frecuencias) preguntando al operador entre cada una
///      el SPL medido por el sonómetro de referencia.
///   4. Al exportar, los resultados se persisten en el Hive box
///      `audit_trail_box` (preparación para 15.3).
///
/// **Pendiente de integración:** la API de [AudioBridge] aún no expone
/// `playWarbleTone(freqHz, levelDbSpl, durationMs)`. Mientras tanto, el
/// botón "Reproducir warble tone" intenta usar [ToneEmitter] para emitir
/// un tono puro como fallback (IEC 60118-7 §5.4 acepta tono puro como
/// alternativa). El TODO está marcado en el handler `_playTone`.
///
/// Requisitos: 15.16
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';

import '../../calibration_spectrum/tone_emitter.dart';
import '../../data/repositories/operator_pin_repository.dart';
import '../../domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import '../../domain/audiogram_driven_presets/bundle_builder.dart';
import '../../domain/audiogram_driven_presets/operating_mode.dart';
import '../../domain/entities/audiogram.dart';
import '../../domain/entities/prescription_mode.dart';
import '../../domain/entities/qc_audit_record.dart' as audit;
import '../../domain/repositories/qc_audit_repository.dart';

// ─── PIN configuration ─────────────────────────────────────────────────────
//
// El PIN del operador se persiste como SHA-256 en Hive
// `service_settings_box` vía [OperatorPinRepository] (tarea 10.3 de
// `system-audit-fix`, hallazgo C-1). El parámetro `pinOverride` del
// widget se mantiene exclusivamente como path de testing — los widget
// tests existentes lo usan para no tocar Hive.

// ─── Bisgaard fixtures (espejo del mismo set en tests) ─────────────────────
const Map<int, double> _bisgaardN1 = {
  250: 20, 500: 20, 750: 20, 1000: 25, 1500: 25,
  2000: 25, 2500: 30, 3000: 30, 3500: 30, 4000: 35, 6000: 35, 8000: 35,
};
const Map<int, double> _bisgaardN3 = {
  250: 35, 500: 35, 750: 35, 1000: 40, 1500: 45,
  2000: 50, 2500: 55, 3000: 55, 3500: 55, 4000: 60, 6000: 60, 8000: 65,
};
const Map<int, double> _bisgaardN5 = {
  250: 55, 500: 55, 750: 55, 1000: 55, 1500: 55,
  2000: 60, 2500: 65, 3000: 70, 3500: 75, 4000: 80, 6000: 80, 8000: 80,
};
const Map<int, double> _bisgaardN7 = {
  250: 75, 500: 80, 750: 80, 1000: 85, 1500: 85,
  2000: 90, 2500: 95, 3000: 100, 3500: 100, 4000: 105, 6000: 105, 8000: 110,
};
const Map<int, double> _bisgaardS3 = {
  250: 10, 500: 10, 750: 10, 1000: 10, 1500: 15,
  2000: 50, 2500: 65, 3000: 80, 3500: 90, 4000: 100, 6000: 110, 8000: 120,
};

const Map<String, Map<int, double>> _audiogramFixtures = {
  'Bisgaard N1': _bisgaardN1,
  'Bisgaard N3': _bisgaardN3,
  'Bisgaard N5': _bisgaardN5,
  'Bisgaard N7': _bisgaardN7,
  'Bisgaard S3': _bisgaardS3,
};

const List<double> _inputLevels = [50.0, 65.0, 80.0];
const List<int> _testFrequencies = [250, 1000, 4000];

/// Tolerancia BAA REMS 2018, Cap. 6: ±5 dB SPL.
const double _kPassToleranceDbSpl = 5.0;

const String _kAuditTrailBoxName = 'audit_trail_box';

/// Una medición individual del QC.
class QcMeasurement {
  final String audiogramName;
  final int frequencyHz;
  final double inputDbSpl;
  final double expectedDbSpl;
  final double measuredDbSpl;
  final DateTime recordedAt;

  const QcMeasurement({
    required this.audiogramName,
    required this.frequencyHz,
    required this.inputDbSpl,
    required this.expectedDbSpl,
    required this.measuredDbSpl,
    required this.recordedAt,
  });

  double get deltaDbSpl => measuredDbSpl - expectedDbSpl;
  bool get pass => deltaDbSpl.abs() <= _kPassToleranceDbSpl;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': '1.0.0',
        'audiogram': audiogramName,
        'frequencyHz': frequencyHz,
        'inputDbSpl': inputDbSpl,
        'expectedDbSpl': expectedDbSpl,
        'measuredDbSpl': measuredDbSpl,
        'deltaDbSpl': deltaDbSpl,
        'pass': pass,
        'recordedAt': recordedAt.toUtc().toIso8601String(),
      };
}

/// Metadatos del operador y equipamiento usados al construir el
/// `QcAuditRecord` (tarea 15.3). En producción los puebla la pantalla
/// de Servicio Técnico desde `service_settings_box`; en tests se pueden
/// inyectar directamente.
class QcOperatorMetadata {
  final String operator;
  final String operatorCertification;
  final String appVersion;
  final String appCommitHash;
  final String hearingAidModel;
  final String hearingAidSerial;
  final String hearingAidFirmware;
  final String micModel;
  final String micSerial;
  final DateTime micCalibrationDate;
  final String couplerModel;
  final String splMeterModel;
  final String splMeterSerial;
  final String? notes;

  const QcOperatorMetadata({
    required this.operator,
    required this.operatorCertification,
    required this.appVersion,
    required this.appCommitHash,
    required this.hearingAidModel,
    required this.hearingAidSerial,
    required this.hearingAidFirmware,
    required this.micModel,
    required this.micSerial,
    required this.micCalibrationDate,
    required this.couplerModel,
    required this.splMeterModel,
    required this.splMeterSerial,
    this.notes,
  });

  /// Placeholder usado cuando el operador no inyectó metadata; mantiene
  /// la pantalla funcional pero el record se marca con valores "N/D" que
  /// el release gate (16.4) puede rechazar antes de firmar.
  factory QcOperatorMetadata.placeholder() => QcOperatorMetadata(
        operator: 'N/D',
        operatorCertification: 'N/D',
        appVersion: 'N/D',
        appCommitHash: 'N/D',
        hearingAidModel: 'N/D',
        hearingAidSerial: 'N/D',
        hearingAidFirmware: 'N/D',
        micModel: 'N/D',
        micSerial: 'N/D',
        micCalibrationDate: DateTime.utc(1970),
        couplerModel: 'N/D',
        splMeterModel: 'N/D',
        splMeterSerial: 'N/D',
      );
}

/// Pantalla de QC Loopback protegida por PIN.
class LoopbackQcScreen extends StatefulWidget {
  /// Permite inyectar un [BundleBuilder] mockeable en tests.
  final BundleBuilder? bundleBuilder;

  /// Permite inyectar un [ToneEmitter] mockeable en tests (evita abrir
  /// just_audio en widget tests).
  final ToneEmitter? toneEmitter;

  /// PIN override usado por tests. Producción ignora este parámetro
  /// y usa [OperatorPinRepository] (PIN aleatorio de 6 dígitos hashado
  /// en `service_settings_box`).
  final String? pinOverride;

  /// Repositorio de PIN inyectable (tests). En producción se crea un
  /// [OperatorPinRepository] por defecto.
  final OperatorPinRepository? pinRepository;

  /// Repositorio de audit trail QC (tarea 15.3). Cuando es `null`, el
  /// botón "Exportar resultados" persiste el blob legacy directamente
  /// en `audit_trail_box` para compatibilidad hacia atrás. Cuando se
  /// inyecta, se usa para llamar `append(record)` y opcionalmente
  /// `generatePdf(record)`.
  final QcAuditRepository? auditRepository;

  /// Metadatos del operador / equipamiento que se inyectan en el
  /// `QcAuditRecord` cuando el operador exporta. En producción serán
  /// leídos de Hive `service_settings_box`; en tests pueden inyectarse
  /// directamente. Si es `null`, se usan placeholders "N/D".
  final QcOperatorMetadata? operatorMetadata;

  const LoopbackQcScreen({
    super.key,
    this.bundleBuilder,
    this.toneEmitter,
    this.pinOverride,
    this.pinRepository,
    this.auditRepository,
    this.operatorMetadata,
  });

  @override
  State<LoopbackQcScreen> createState() => _LoopbackQcScreenState();
}

class _LoopbackQcScreenState extends State<LoopbackQcScreen> {
  final TextEditingController _pinController = TextEditingController();
  bool _unlocked = false;
  bool _verifyingPin = false;

  late final BundleBuilder _builder;
  late final OperatorPinRepository _pinRepo;
  ToneEmitter? _emitter;

  String _selectedAudiogram = _audiogramFixtures.keys.first;
  double _selectedInput = _inputLevels[1]; // 65 dB SPL por defecto
  int _selectedFrequency = _testFrequencies[1]; // 1000 Hz por defecto

  // Cache de bundles por audiograma para evitar recomputar en cada cambio.
  final Map<String, AudiogramDrivenBundle> _bundleCache = {};

  final List<QcMeasurement> _results = [];
  bool _matrixRunning = false;

  @override
  void initState() {
    super.initState();
    _builder = widget.bundleBuilder ?? BundleBuilder();
    _pinRepo = widget.pinRepository ?? OperatorPinRepository();
  }

  @override
  void dispose() {
    _pinController.dispose();
    // Sólo liberamos el emitter si lo creamos nosotros; los inyectados
    // los gestiona el caller (tests).
    if (widget.toneEmitter == null) {
      _emitter?.dispose();
    }
    super.dispose();
  }

  // ─── PIN gate ──────────────────────────────────────────────────────────

  Future<void> _onPinSubmit() async {
    if (_verifyingPin) return;
    final entered = _pinController.text.trim();

    // Testing path: comparación literal contra `pinOverride` para
    // mantener la compatibilidad con los widget tests existentes que
    // no inicializan el repo persistente.
    if (widget.pinOverride != null) {
      if (entered != widget.pinOverride) {
        _showPinError();
        return;
      }
      setState(() => _unlocked = true);
      return;
    }

    setState(() => _verifyingPin = true);
    try {
      // QC Loopback NO genera el PIN inicial: el operador debe llegar
      // acá luego de haber pasado por Calibración Manual, donde se
      // ejecuta el flujo de generación (tarea 10.2). Si el PIN aún no
      // está configurado, derivamos al operador a esa pantalla en lugar
      // de generar un PIN duplicado en este punto del flow.
      if (!await _pinRepo.hasPin()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'PIN no configurado. Acceder a Calibración Manual primero '
              'para generarlo.',
            ),
            backgroundColor: Colors.orangeAccent,
            duration: Duration(seconds: 5),
          ),
        );
        _pinController.clear();
        return;
      }
      final ok = await _pinRepo.verifyPin(entered);
      if (!mounted) return;
      if (!ok) {
        _showPinError();
        return;
      }
      setState(() => _unlocked = true);
    } finally {
      if (mounted) {
        setState(() => _verifyingPin = false);
      }
    }
  }

  void _showPinError() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('PIN incorrecto'),
        backgroundColor: Colors.redAccent,
      ),
    );
    _pinController.clear();
  }

  // ─── SPL esperado ──────────────────────────────────────────────────────

  AudiogramDrivenBundle _bundleFor(String audiogramName) {
    final cached = _bundleCache[audiogramName];
    if (cached != null) return cached;
    final thresholds = _audiogramFixtures[audiogramName]!;
    final audiogram = Audiogram(thresholds: thresholds);
    final bundle = _builder.buildFromAudiogram(
      audiogram,
      mode: PrescriptionMode.quiet,
      operatingMode: OperatingMode.diagnostic,
    );
    _bundleCache[audiogramName] = bundle;
    return bundle;
  }

  /// Devuelve el índice de banda (0..11) más cercano a [frequencyHz].
  static int _bandIndexFor(int frequencyHz) {
    const bands = Audiogram.standardFrequencies;
    int bestIndex = 0;
    int bestDelta = (bands.first - frequencyHz).abs();
    for (var i = 1; i < bands.length; ++i) {
      final delta = (bands[i] - frequencyHz).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        bestIndex = i;
      }
    }
    return bestIndex;
  }

  double _expectedSpl({
    required String audiogramName,
    required int frequencyHz,
    required double inputDbSpl,
  }) {
    final bundle = _bundleFor(audiogramName);
    final band = _bandIndexFor(frequencyHz);
    return inputDbSpl + bundle.gainsDb[band];
  }

  // ─── Tono ──────────────────────────────────────────────────────────────

  Future<void> _playTone({
    required int frequencyHz,
    required double levelDbSpl,
  }) async {
    // TODO(15.2): cuando AudioBridge exponga
    // `playWarbleTone(freqHz, levelDbSpl, durationMs)` (IEC 60118-7
    // §5.4 con FM ±5 %, fm 5 Hz), reemplazar este fallback por la
    // llamada al bridge.
    _emitter ??= widget.toneEmitter ?? ToneEmitter();
    try {
      await _emitter!.playTone(
        freqHz: frequencyHz.toDouble(),
        levelDbSpl: levelDbSpl,
        durationMs: 1500,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo reproducir el tono: $e')),
      );
    }
  }

  // ─── Diálogo de medición ───────────────────────────────────────────────

  Future<double?> _askMeasuredSpl({
    required String audiogramName,
    required int frequencyHz,
    required double inputDbSpl,
    required double expectedDbSpl,
  }) async {
    final controller = TextEditingController();
    final value = await showDialog<double>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Medición $audiogramName · $frequencyHz Hz'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Input: ${inputDbSpl.toStringAsFixed(1)} dB SPL'),
            Text('Esperado: ${expectedDbSpl.toStringAsFixed(1)} dB SPL'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
              ],
              decoration: const InputDecoration(
                labelText: 'SPL medido (dB SPL)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancelar'),
          ),
          TextButton(
            key: const Key('qc_measure_ok'),
            onPressed: () {
              final parsed = double.tryParse(controller.text.trim());
              Navigator.of(dialogContext).pop(parsed);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return value;
  }

  // ─── Acciones ──────────────────────────────────────────────────────────

  Future<void> _onPlayWarble() async {
    await _playTone(
      frequencyHz: _selectedFrequency,
      levelDbSpl: _selectedInput,
    );
  }

  Future<void> _onRunMatrix() async {
    if (_matrixRunning) return;
    setState(() => _matrixRunning = true);
    try {
      for (final audiogramName in _audiogramFixtures.keys) {
        for (final freq in _testFrequencies) {
          for (final input in _inputLevels) {
            final expected = _expectedSpl(
              audiogramName: audiogramName,
              frequencyHz: freq,
              inputDbSpl: input,
            );
            // Reproducir el tono para que el operador mida.
            await _playTone(frequencyHz: freq, levelDbSpl: input);
            if (!mounted) return;
            final measured = await _askMeasuredSpl(
              audiogramName: audiogramName,
              frequencyHz: freq,
              inputDbSpl: input,
              expectedDbSpl: expected,
            );
            if (measured == null) {
              // Operador canceló → abortar la corrida sin perder lo ya hecho.
              return;
            }
            final m = QcMeasurement(
              audiogramName: audiogramName,
              frequencyHz: freq,
              inputDbSpl: input,
              expectedDbSpl: expected,
              measuredDbSpl: measured,
              recordedAt: DateTime.now().toUtc(),
            );
            if (!mounted) return;
            setState(() => _results.add(m));
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() => _matrixRunning = false);
      }
    }
  }

  Future<void> _onExport() async {
    if (_results.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay mediciones para exportar')),
      );
      return;
    }
    try {
      final repo = widget.auditRepository;
      if (repo != null) {
        // Path 15.3: usa el repositorio inyectado, persiste un
        // QcAuditRecord estructurado y genera el PDF como side-effect.
        final metadata =
            widget.operatorMetadata ?? QcOperatorMetadata.placeholder();
        final auditMeasurements = _results
            .map<audit.QcMeasurement>((m) => audit.QcMeasurement.compute(
                  audiogramName: m.audiogramName,
                  frequencyHz: m.frequencyHz,
                  inputLevelDbSpl: m.inputDbSpl,
                  expectedDbSpl: m.expectedDbSpl,
                  measuredDbSpl: m.measuredDbSpl,
                ))
            .toList(growable: false);
        final record = audit.QcAuditRecord.compute(
          timestamp: DateTime.now().toUtc(),
          operator: metadata.operator,
          operatorCertification: metadata.operatorCertification,
          appVersion: metadata.appVersion,
          appCommitHash: metadata.appCommitHash,
          hearingAidModel: metadata.hearingAidModel,
          hearingAidSerial: metadata.hearingAidSerial,
          hearingAidFirmware: metadata.hearingAidFirmware,
          micModel: metadata.micModel,
          micSerial: metadata.micSerial,
          micCalibrationDate: metadata.micCalibrationDate,
          couplerModel: metadata.couplerModel,
          splMeterModel: metadata.splMeterModel,
          splMeterSerial: metadata.splMeterSerial,
          measurements: auditMeasurements,
          notes: metadata.notes,
        );
        await repo.append(record);
        // Best-effort PDF: si falla no abortamos la persistencia (el
        // record ya quedó en `audit_trail_box`).
        try {
          await repo.generatePdf(record);
        } catch (_) {/* ignore: PDF es opcional para el append */}
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Exportadas ${_results.length} mediciones '
              '(${record.overallPassed ? 'PASS' : 'FAIL'})',
            ),
          ),
        );
        return;
      }

      // Path legacy: blob simple en audit_trail_box. Compatible con la
      // implementación anterior a 15.3.
      final box = Hive.isBoxOpen(_kAuditTrailBoxName)
          ? Hive.box<dynamic>(_kAuditTrailBoxName)
          : await Hive.openBox<dynamic>(_kAuditTrailBoxName);
      final blob = <String, dynamic>{
        'schemaVersion': '1.0.0',
        'kind': 'loopback_qc_run',
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'measurements': _results.map((m) => m.toJson()).toList(),
      };
      await box.add(blob);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Exportadas ${_results.length} mediciones'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al exportar: $e')),
      );
    }
  }

  // ─── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('QC Loopback')),
      body: _unlocked ? _buildQcUi(context) : _buildPinGate(context),
    );
  }

  Widget _buildPinGate(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Acceso restringido a operadores QC',
            style: TextStyle(fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('qc_pin_field'),
            controller: _pinController,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 4,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
            ],
            decoration: const InputDecoration(
              labelText: 'PIN',
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            key: const Key('qc_pin_submit'),
            onPressed: _onPinSubmit,
            child: const Text('Ingresar'),
          ),
        ],
      ),
    );
  }

  Widget _buildQcUi(BuildContext context) {
    final expected = _expectedSpl(
      audiogramName: _selectedAudiogram,
      frequencyHz: _selectedFrequency,
      inputDbSpl: _selectedInput,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildAudiogramDropdown(),
          const SizedBox(height: 8),
          _buildInputDropdown(),
          const SizedBox(height: 8),
          _buildFrequencyDropdown(),
          const SizedBox(height: 12),
          Container(
            key: const Key('qc_expected_spl'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.cyan),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'SPL esperado: ${expected.toStringAsFixed(1)} dB SPL',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  key: const Key('qc_play_warble'),
                  onPressed: _matrixRunning ? null : _onPlayWarble,
                  child: const Text('Reproducir warble tone'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  key: const Key('qc_run_matrix'),
                  onPressed: _matrixRunning ? null : _onRunMatrix,
                  child: const Text('Iniciar matriz completa'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            key: const Key('qc_export'),
            onPressed: (_matrixRunning || _results.isEmpty) ? null : _onExport,
            child: const Text('Exportar resultados'),
          ),
          const SizedBox(height: 16),
          _buildResultsList(),
        ],
      ),
    );
  }

  Widget _buildAudiogramDropdown() {
    return DropdownButtonFormField<String>(
      key: const Key('qc_audiogram_dropdown'),
      value: _selectedAudiogram,
      decoration: const InputDecoration(labelText: 'Audiograma test'),
      items: _audiogramFixtures.keys
          .map((k) => DropdownMenuItem(value: k, child: Text(k)))
          .toList(),
      onChanged: (v) {
        if (v == null) return;
        setState(() => _selectedAudiogram = v);
      },
    );
  }

  Widget _buildInputDropdown() {
    return DropdownButtonFormField<double>(
      key: const Key('qc_input_dropdown'),
      value: _selectedInput,
      decoration: const InputDecoration(labelText: 'Input level (dB SPL)'),
      items: _inputLevels
          .map((v) => DropdownMenuItem(
                value: v,
                child: Text('${v.toStringAsFixed(0)} dB SPL'),
              ))
          .toList(),
      onChanged: (v) {
        if (v == null) return;
        setState(() => _selectedInput = v);
      },
    );
  }

  Widget _buildFrequencyDropdown() {
    return DropdownButtonFormField<int>(
      key: const Key('qc_freq_dropdown'),
      value: _selectedFrequency,
      decoration: const InputDecoration(labelText: 'Frecuencia (Hz)'),
      items: _testFrequencies
          .map((v) => DropdownMenuItem(value: v, child: Text('$v Hz')))
          .toList(),
      onChanged: (v) {
        if (v == null) return;
        setState(() => _selectedFrequency = v);
      },
    );
  }

  Widget _buildResultsList() {
    if (_results.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('Sin mediciones registradas todavía.'),
      );
    }
    return Column(
      key: const Key('qc_results_list'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Resultados',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        for (final m in _results)
          Container(
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: m.pass
                  ? Colors.green.withOpacity(0.15)
                  : Colors.red.withOpacity(0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${m.audiogramName} · ${m.frequencyHz} Hz · '
              'in ${m.inputDbSpl.toStringAsFixed(0)} → '
              'esp ${m.expectedDbSpl.toStringAsFixed(1)} '
              'med ${m.measuredDbSpl.toStringAsFixed(1)} '
              'Δ ${m.deltaDbSpl >= 0 ? '+' : ''}${m.deltaDbSpl.toStringAsFixed(1)} '
              '${m.pass ? 'PASS' : 'FAIL'}',
            ),
          ),
      ],
    );
  }
}

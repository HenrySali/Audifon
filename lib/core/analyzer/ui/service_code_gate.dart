// Feature: in-app-diagnostic-analyzer
// Module: ui/service_code_gate
//
// Numeric keypad screen that gates access to the AnalyzerScreen in the
// patient app variant. Code is read from
// `String.fromEnvironment('SERVICE_CODE')`. After 5 consecutive failures
// the gate locks input for 60 seconds.
//
// On success (code matches), navigates to the AnalyzerScreen, optionally
// pre-loaded with WAV+JSON paths from the recorder entry.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants.dart';
import 'analyzer_screen.dart';

class ServiceCodeGate extends StatefulWidget {
  /// Optional pre-loaded WAV path. When non-null the AnalyzerScreen
  /// skips the file picker (Req. 1.6, 17.1).
  final String? preloadedWavPath;

  /// Optional pre-loaded JSON path.
  final String? preloadedJsonPath;

  /// Override the configured code (used by widget tests). When `null`
  /// the gate reads `String.fromEnvironment('SERVICE_CODE')`.
  @visibleForTesting
  final String? configuredCodeOverride;

  /// Override the lock duration (used by widget tests).
  @visibleForTesting
  final Duration? lockoutDurationOverride;

  const ServiceCodeGate({
    super.key,
    this.preloadedWavPath,
    this.preloadedJsonPath,
    this.configuredCodeOverride,
    this.lockoutDurationOverride,
  });

  @override
  State<ServiceCodeGate> createState() => _ServiceCodeGateState();
}

class _ServiceCodeGateState extends State<ServiceCodeGate> {
  String _entered = '';
  int _failedAttempts = 0;
  DateTime? _lockedUntil;
  String _errorText = '';
  Timer? _ticker;

  static const String _kBuildSentinel =
      String.fromEnvironment('SERVICE_CODE');

  String get _configuredCode =>
      widget.configuredCodeOverride ?? _kBuildSentinel;

  Duration get _lockDuration =>
      widget.lockoutDurationOverride ?? kServiceCodeLockoutDuration;

  bool get _isLocked {
    final until = _lockedUntil;
    if (until == null) return false;
    return DateTime.now().isBefore(until);
  }

  int get _secondsLeft {
    final until = _lockedUntil;
    if (until == null) return 0;
    final s = until.difference(DateTime.now()).inSeconds;
    return s < 0 ? 0 : s;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _onDigit(String d) {
    if (_isLocked) return;
    if (_entered.length >= kServiceCodeMaxDigits) return;
    setState(() {
      _entered = _entered + d;
      _errorText = '';
    });
  }

  void _onBackspace() {
    if (_isLocked) return;
    if (_entered.isEmpty) return;
    setState(() {
      _entered = _entered.substring(0, _entered.length - 1);
      _errorText = '';
    });
  }

  void _onCancel() {
    Navigator.of(context).pop();
  }

  void _onConfirm() {
    if (_isLocked) return;

    final cfg = _configuredCode;
    if (cfg.isEmpty) {
      setState(() {
        _errorText = 'Código de servicio no configurado en esta build';
        _entered = '';
      });
      return;
    }
    if (_entered.length < kServiceCodeMinDigits ||
        _entered.length > kServiceCodeMaxDigits) {
      setState(() {
        _errorText = 'Ingrese entre $kServiceCodeMinDigits y '
            '$kServiceCodeMaxDigits dígitos';
      });
      return;
    }

    if (_entered == cfg) {
      // Success: reset state and navigate to AnalyzerScreen.
      setState(() {
        _failedAttempts = 0;
        _entered = '';
        _errorText = '';
      });
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => AnalyzerScreen(
            preloadedWavPath: widget.preloadedWavPath,
            preloadedJsonPath: widget.preloadedJsonPath,
          ),
        ),
      );
      return;
    }

    _failedAttempts++;
    if (_failedAttempts >= kServiceCodeMaxFailures) {
      _lockedUntil = DateTime.now().add(_lockDuration);
      _errorText = 'Demasiados intentos, espere '
          '${_lockDuration.inSeconds} segundos';
      _failedAttempts = 0;
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return;
        if (!_isLocked) {
          t.cancel();
          setState(() {
            _lockedUntil = null;
            _errorText = '';
          });
        } else {
          setState(() {});
        }
      });
    } else {
      _errorText = 'Código incorrecto';
    }
    setState(() => _entered = '');
  }

  // ─── Public API for widget tests ──────────────────────────────────────

  @visibleForTesting
  String get entered => _entered;

  @visibleForTesting
  int get failedAttempts => _failedAttempts;

  @visibleForTesting
  bool get isLocked => _isLocked;

  @visibleForTesting
  String get errorText => _errorText;

  @visibleForTesting
  void submit(String code) {
    setState(() {
      _entered = code;
      _errorText = '';
    });
    _onConfirm();
  }

  @override
  Widget build(BuildContext context) {
    final masked = '•' * _entered.length;
    final locked = _isLocked;
    return Scaffold(
      appBar: AppBar(title: const Text('Código de servicio')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              const Text(
                'Ingrese el código de servicio para acceder al analizador.',
                style: TextStyle(color: Colors.white70, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.25),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white24),
                ),
                child: Center(
                  child: Text(
                    masked.isEmpty ? '----' : masked,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      letterSpacing: 8,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_errorText.isNotEmpty)
                Text(
                  locked ? '$_errorText (${_secondsLeft}s)' : _errorText,
                  style: const TextStyle(
                      color: Colors.redAccent, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              const SizedBox(height: 24),
              _Keypad(
                onDigit: _onDigit,
                onBackspace: _onBackspace,
                disabled: locked,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _onCancel,
                      child: const Text('Cancelar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: locked ? null : _onConfirm,
                      child: const Text('Confirmar'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  final void Function(String) onDigit;
  final VoidCallback onBackspace;
  final bool disabled;
  const _Keypad({
    required this.onDigit,
    required this.onBackspace,
    required this.disabled,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
          ['', '0', '<'],
        ])
          Row(
            children: row.map((d) {
              if (d.isEmpty) return const Expanded(child: SizedBox.shrink());
              if (d == '<') {
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: ElevatedButton(
                      onPressed: disabled ? null : onBackspace,
                      child: const Icon(Icons.backspace),
                    ),
                  ),
                );
              }
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: ElevatedButton(
                    onPressed: disabled ? null : () => onDigit(d),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text(d, style: const TextStyle(fontSize: 22)),
                  ),
                ),
              );
            }).toList(),
          ),
      ],
    );
  }
}

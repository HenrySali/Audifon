/// Smart Scene Engine — UI mínima de Fase 1.
///
/// Muestra los números crudos del clasificador C++ actualizados a 10 Hz:
/// dB SPL, SNR, VAD score, tilt espectral, centroide, energía por banda.
/// No toma decisiones — la lógica de clasificación llega en Fase 2.
///
/// Validates: Requirements 1.1, 6.2

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../scene/scene_snapshot.dart';

class SmartSceneScreen extends StatefulWidget {
  const SmartSceneScreen({super.key});

  @override
  State<SmartSceneScreen> createState() => _SmartSceneScreenState();
}

class _SmartSceneScreenState extends State<SmartSceneScreen> {
  static const _channel = MethodChannel('com.psk.hearing_aid/audio');
  static const Duration _pollInterval = Duration(milliseconds: 100);

  Timer? _pollTimer;
  SceneSnapshot _snapshot = SceneSnapshot.empty();
  bool _enginePresent = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollSnapshot());
    // Hacer un poll inmediato para acelerar la primera lectura.
    _pollSnapshot();
  }

  Future<void> _pollSnapshot() async {
    try {
      final raw = await _channel.invokeMethod<Uint8List>('getSceneSnapshot');
      if (!mounted) return;
      if (raw == null || raw.isEmpty) {
        setState(() {
          _enginePresent = false;
        });
        return;
      }
      final snap = SceneSnapshot.fromBytes(raw);
      if (snap == null) {
        return;
      }
      setState(() {
        _snapshot = snap;
        _enginePresent = true;
        _errorMessage = null;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _enginePresent = false;
        _errorMessage = e.message ?? e.code;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a0e27),
      appBar: AppBar(
        title: const Text('Smart Scene · diagnóstico'),
        backgroundColor: const Color(0xFF0f3460),
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_enginePresent) _engineOffBanner(),
              if (_errorMessage != null) _errorBanner(_errorMessage!),
              const SizedBox(height: 8),
              _LevelsCard(snapshot: _snapshot),
              const SizedBox(height: 12),
              _VadCard(snapshot: _snapshot),
              const SizedBox(height: 12),
              _SpectralCard(snapshot: _snapshot),
              const SizedBox(height: 12),
              _BandsCard(snapshot: _snapshot),
              const SizedBox(height: 12),
              _MetaCard(snapshot: _snapshot),
            ],
          ),
        ),
      ),
    );
  }

  Widget _engineOffBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.withOpacity(0.4)),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline, color: Colors.orangeAccent, size: 20),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'El motor de audio no está activo. Activá el audífono para ver mediciones en vivo.',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner(String message) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.redAccent.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, color: Colors.redAccent, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tarjetas
// ─────────────────────────────────────────────────────────────────────────────

class _LevelsCard extends StatelessWidget {
  final SceneSnapshot snapshot;
  const _LevelsCard({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    return _SceneCard(
      icon: Icons.volume_up,
      title: 'Niveles',
      child: Column(
        children: [
          _MetricRow(
            label: 'Entrada',
            value: '${snapshot.inputDbSpl.toStringAsFixed(1)} dB SPL',
          ),
          _MetricRow(
            label: 'Piso de ruido',
            value: '${snapshot.noiseFloorDbSpl.toStringAsFixed(1)} dB SPL',
          ),
          _MetricRow(
            label: 'SNR',
            value: '${snapshot.snrDb.toStringAsFixed(1)} dB',
          ),
        ],
      ),
    );
  }
}

class _VadCard extends StatelessWidget {
  final SceneSnapshot snapshot;
  const _VadCard({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final voiceColor =
        snapshot.voiceActive ? Colors.greenAccent : Colors.white60;
    final hangoverColor =
        snapshot.vadHangoverActive ? Colors.amberAccent : Colors.white38;
    return _SceneCard(
      icon: Icons.record_voice_over,
      title: 'VAD híbrido (LRT + pitch + SNR + LTSD + estacionariedad)',
      child: Column(
        children: [
          _MetricRow(
            label: 'Score',
            value: snapshot.vadScore.toStringAsFixed(2),
          ),
          _MetricRow(
            label: 'Confianza',
            value: snapshot.vadConfidence.toStringAsFixed(2),
          ),
          _MetricRow(
            label: 'Voz activa',
            value: snapshot.voiceActive ? 'SÍ' : 'NO',
            valueColor: voiceColor,
          ),
          _MetricRow(
            label: 'Hangover activo',
            value: snapshot.vadHangoverActive ? 'SÍ' : 'NO',
            valueColor: hangoverColor,
          ),
          _MetricRow(
            label: 'Mid-SNR (1-5 kHz)',
            value: '${snapshot.vadMidSnrDb.toStringAsFixed(1)} dB',
          ),
          _MetricRow(
            label: 'Estacionariedad ruido',
            value: snapshot.vadStationarity.toStringAsFixed(2),
          ),
        ],
      ),
    );
  }
}

class _SpectralCard extends StatelessWidget {
  final SceneSnapshot snapshot;
  const _SpectralCard({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    return _SceneCard(
      icon: Icons.show_chart,
      title: 'Features espectrales',
      child: Column(
        children: [
          _MetricRow(
            label: 'Tilt',
            value: '${snapshot.spectralTiltDb.toStringAsFixed(2)} dB/oct',
          ),
          _MetricRow(
            label: 'Centroide',
            value: '${snapshot.spectralCentroidHz.toStringAsFixed(0)} Hz',
          ),
          _MetricRow(
            label: 'Flatness',
            value: snapshot.spectralFlatness.toStringAsFixed(3),
          ),
          _MetricRow(
            label: 'Flux',
            value: snapshot.spectralFlux.toStringAsFixed(3),
          ),
          const Divider(color: Colors.white12, height: 16),
          _MetricRow(
            label: 'Energía graves (250-750 Hz)',
            value: '${snapshot.lowBandEnergyDb.toStringAsFixed(1)} dB',
          ),
          _MetricRow(
            label: 'Energía medios (750 Hz-3 kHz)',
            value: '${snapshot.midBandEnergyDb.toStringAsFixed(1)} dB',
          ),
          _MetricRow(
            label: 'Energía agudos (3-8 kHz)',
            value: '${snapshot.highBandEnergyDb.toStringAsFixed(1)} dB',
          ),
        ],
      ),
    );
  }
}

class _BandsCard extends StatelessWidget {
  final SceneSnapshot snapshot;
  const _BandsCard({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final bands = snapshot.noisePerBandDb;
    // Normalizamos a [0, 1] para el barchart usando rango -90..-20 dB típico.
    const minDb = -90.0;
    const maxDb = -20.0;

    return _SceneCard(
      icon: Icons.equalizer,
      title: 'Piso de ruido por banda',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 96,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(bands.length, (i) {
                final value = bands[i];
                final norm = ((value - minDb) / (maxDb - minDb)).clamp(0.0, 1.0);
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Container(
                          height: 80 * norm,
                          decoration: BoxDecoration(
                            color: Colors.cyan.withOpacity(0.7),
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(2)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${i + 1}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Rango visual: $minDb a $maxDb dB',
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _MetaCard extends StatelessWidget {
  final SceneSnapshot snapshot;
  const _MetaCard({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    return _SceneCard(
      icon: Icons.info,
      title: 'Meta (Fase 1)',
      child: Column(
        children: [
          _MetricRow(
            label: 'Clase detectada',
            value: sceneClassLabel(snapshot.sceneClass),
          ),
          _MetricRow(
            label: 'Confianza',
            value: snapshot.sceneConfidence.toStringAsFixed(2),
          ),
          _MetricRow(
            label: 'Timestamp',
            value: '${(snapshot.timestampUs / 1000).toStringAsFixed(0)} ms',
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widgets compartidos
// ─────────────────────────────────────────────────────────────────────────────

class _SceneCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;

  const _SceneCard({
    required this.icon,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.cyan, size: 18),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _MetricRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? Colors.cyanAccent,
              fontSize: 13,
              fontFeatures: const [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

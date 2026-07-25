// Spec: diagnóstico de ronquera DPDFNet-4 (ventana de Testeo).
//
// Pantalla de Testeo / Diagnóstico. Graba en el móvil el audio REAL del
// pipeline DPDFNet-4 por etapas (A dry48 / B ds16 / C model16 / D out48)
// para aislar en qué etapa aparece la ronquera. Los WAV float32 mono se
// escriben en el external files dir de la app, subcarpeta `dpdf_captures/`,
// vía el canal nativo `com.psk.hearing_aid/audio`.
//
// Pensada para CRECER: es el punto de entrada de futuras herramientas de
// diagnóstico. Cada bloque está aislado para poder sumar tests nuevos.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/services/local_downloads_service.dart';
import '../../services/denoiser_service.dart';

/// Ventana de Testeo / Diagnóstico. Extensible.
class TestingScreen extends StatefulWidget {
  const TestingScreen({super.key});

  @override
  State<TestingScreen> createState() => _TestingScreenState();
}

class _TestingScreenState extends State<TestingScreen> {
  static const _channel = MethodChannel('com.psk.hearing_aid/audio');

  final DenoiserService _denoiserService = DenoiserService();
  final LocalDownloadsService _downloads = LocalDownloadsService();

  bool _capturing = false;
  int _seconds = 0;
  Timer? _timer;

  String _activeDenoiser = '—';
  bool _dpdfActive = false;

  String? _captureDir;
  List<Map<String, dynamic>> _captures = <Map<String, dynamic>>[];
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _refreshActiveDenoiser();
    _refreshCaptures();
    _syncCapturingState();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // ─── Estado del denoiser activo ──────────────────────────────────────
  Future<void> _refreshActiveDenoiser() async {
    try {
      final int idx = await _channel.invokeMethod('getActiveDenoiser') as int;
      if (!mounted) return;
      final type = (idx >= 0 && idx < DenoiserType.values.length)
          ? DenoiserType.values[idx]
          : null;
      setState(() {
        _dpdfActive = type == DenoiserType.dpdfnet;
        _activeDenoiser = _denoiserName(type);
      });
    } catch (_) {/* tolerante */}
  }

  String _denoiserName(DenoiserType? t) {
    switch (t) {
      case DenoiserType.rnnoise:
        return 'RNNoise (Estándar)';
      case DenoiserType.dfn3:
        return 'DeepFilterNet3 (Premium)';
      case DenoiserType.gtcrn:
        return 'GTCRN (Analítico)';
      case DenoiserType.dpdfnet:
        return 'DPDFNet-4 (Ultra)';
      default:
        return '—';
    }
  }

  /// Selecciona DPDFNet-4 como denoiser activo (lo que este test mide).
  Future<void> _selectDpdf() async {
    await _denoiserService.selectDenoiser(DenoiserType.dpdfnet);
    await _refreshActiveDenoiser();
  }

  // ─── Sincroniza el flag de captura con el nativo ─────────────────────
  Future<void> _syncCapturingState() async {
    try {
      final bool cap =
          await _channel.invokeMethod('isDpdfCapturing') as bool? ?? false;
      if (mounted && cap && !_capturing) {
        _startTimer();
        setState(() => _capturing = true);
      }
    } catch (_) {}
  }

  // ─── Grabación (toggle) ──────────────────────────────────────────────
  Future<void> _toggleCapture() async {
    if (_capturing) {
      await _stopCapture();
    } else {
      await _startCapture();
    }
  }

  Future<void> _startCapture() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final dir = await _channel.invokeMethod('startDpdfCapture') as String?;
      if (dir == null) {
        setState(() => _status = 'No se pudo iniciar (¿motor de audio activo?)');
      } else {
        _captureDir = dir;
        _startTimer();
        setState(() {
          _capturing = true;
          _status = 'Grabando… (auto-stop a los 10 s)';
        });
      }
    } on PlatformException catch (e) {
      setState(() => _status = 'Error: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopCapture() async {
    setState(() => _busy = true);
    _timer?.cancel();
    try {
      final list = await _channel.invokeMethod('stopDpdfCapture');
      _applyCaptureList(list);
      setState(() {
        _capturing = false;
        _status = 'Captura guardada (${_seconds}s).';
      });
    } on PlatformException catch (e) {
      setState(() {
        _capturing = false;
        _status = 'Error al detener: ${e.message}';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startTimer() {
    _seconds = 0;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted) return;
      setState(() => _seconds++);
      // Detectar el auto-stop nativo (buffer lleno a ~10 s).
      final bool stillCap =
          await _channel.invokeMethod('isDpdfCapturing') as bool? ?? false;
      if (!stillCap && _capturing) {
        _timer?.cancel();
        // Esperar a que el flush escriba los WAV y refrescar la lista.
        await _waitReadyAndRefresh();
        if (mounted) {
          setState(() {
            _capturing = false;
            _status = 'Captura completa (10 s, auto-stop). WAV guardados.';
          });
        }
      }
    });
  }

  Future<void> _waitReadyAndRefresh() async {
    for (var i = 0; i < 40; i++) {
      final bool ready =
          await _channel.invokeMethod('isDpdfCaptureReady') as bool? ?? false;
      if (ready) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await _refreshCaptures();
  }

  // ─── Lista de capturas ───────────────────────────────────────────────
  Future<void> _refreshCaptures() async {
    try {
      _captureDir ??=
          await _channel.invokeMethod('getDpdfCaptureDir') as String?;
      final list = await _channel.invokeMethod('listDpdfCaptures');
      _applyCaptureList(list);
    } catch (_) {}
  }

  void _applyCaptureList(dynamic list) {
    if (list is List) {
      _captures = list
          .whereType<Map>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    }
    if (mounted) setState(() {});
  }

  // ─── Exportar ────────────────────────────────────────────────────────
  Future<void> _exportAllToDownloads() async {
    if (_captures.isEmpty) return;
    setState(() {
      _busy = true;
      _status = 'Copiando a Descargas…';
    });
    var okCount = 0;
    for (final c in _captures) {
      final path = c['path'] as String?;
      final name = c['name'] as String?;
      if (path == null || name == null) continue;
      try {
        await _downloads.saveFileToDownloads(
          sourcePath: path,
          filename: name,
          mimeType: 'audio/wav',
        );
        okCount++;
      } catch (_) {/* seguir con el resto */}
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _status = 'Copiados $okCount/${_captures.length} a Descargas.';
      });
    }
  }

  Future<void> _shareAll() async {
    if (_captures.isEmpty) return;
    final files = _captures
        .map((c) => c['path'] as String?)
        .whereType<String>()
        .map((p) => XFile(p, mimeType: 'audio/wav'))
        .toList();
    if (files.isEmpty) return;
    try {
      await Share.shareXFiles(files, subject: 'Capturas DPDFNet-4');
    } catch (e) {
      if (mounted) setState(() => _status = 'Share no disponible: $e');
    }
  }

  Future<void> _shareOne(String path) async {
    try {
      await Share.shareXFiles([XFile(path, mimeType: 'audio/wav')]);
    } catch (e) {
      if (mounted) setState(() => _status = 'Share no disponible: $e');
    }
  }

  // ─── Borrar ──────────────────────────────────────────────────────────
  Future<void> _deleteAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text('Borrar todas las grabaciones',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'Se borrarán todas las grabaciones de forma permanente. '
          '¿Continuar?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Borrar todo',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = true;
      _status = 'Borrando…';
    });
    try {
      final n = await _channel.invokeMethod('deleteAllDpdfCaptures') as int? ?? 0;
      await _refreshCaptures();
      setState(() => _status = 'Borrados $n archivos.');
    } on PlatformException catch (e) {
      setState(() => _status = 'Error al borrar: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteOne(String name) async {
    setState(() => _busy = true);
    try {
      await _channel.invokeMethod('deleteDpdfCapture', {'name': name});
      await _refreshCaptures();
      setState(() => _status = 'Grabación borrada.');
    } on PlatformException catch (e) {
      setState(() => _status = 'Error al borrar: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ─── UI ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0f1621),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text('Testeo / Diagnóstico'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _denoiserCard(),
            const SizedBox(height: 16),
            _recorderCard(),
            const SizedBox(height: 16),
            _capturesCard(),
          ],
        ),
      ),
    );
  }

  Widget _denoiserCard() {
    return Card(
      color: const Color(0xFF1a2332),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Denoiser activo',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 4),
            Text(_activeDenoiser,
                style: TextStyle(
                    color: _dpdfActive ? Colors.cyanAccent : Colors.orangeAccent,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            if (!_dpdfActive) ...[
              const SizedBox(height: 8),
              const Text(
                'Este test mide el pipeline DPDFNet-4. Seleccionalo para '
                'capturar sus 4 etapas.',
                style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _selectDpdf,
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Activar DPDFNet-4'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _recorderCard() {
    return Card(
      color: const Color(0xFF1a2332),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(_capturing ? Icons.fiber_manual_record : Icons.mic,
                    color: _capturing ? Colors.redAccent : Colors.white70),
                const SizedBox(width: 8),
                Text(
                  _capturing
                      ? 'Grabando  ${_seconds}s'
                      : 'Detenido',
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 64,
              child: ElevatedButton.icon(
                onPressed: _busy ? null : _toggleCapture,
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _capturing ? Colors.redAccent : Colors.cyan,
                  foregroundColor: Colors.black,
                ),
                icon: Icon(_capturing ? Icons.stop : Icons.fiber_manual_record,
                    size: 28),
                label: Text(
                  _capturing ? 'Detener grabación' : 'Iniciar grabación',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // ─── BOTON BORRAR — SIEMPRE VISIBLE ───────────────────────
            SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                onPressed: (_busy || _capturing) ? null : _deleteAll,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade700,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.delete_forever, size: 24),
                label: Text(
                  _captures.isEmpty
                      ? 'Borrar grabaciones (no hay)'
                      : 'Borrar TODAS las grabaciones (${_captures.length})',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            if (_status != null) ...[
              const SizedBox(height: 10),
              Text(_status!,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
            const SizedBox(height: 6),
            const Text(
              'Etapas capturadas: A dry48 · B ds16 · C model16 · D out48. '
              'Máx 10 s por sesión (auto-stop).',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _capturesCard() {
    return Card(
      color: const Color(0xFF1a2332),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Capturas guardadas',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  tooltip: 'Refrescar',
                  onPressed: _busy ? null : _refreshCaptures,
                  icon: const Icon(Icons.refresh, color: Colors.white70),
                ),
                IconButton(
                  tooltip: 'Borrar todas',
                  onPressed: (_busy || _captures.isEmpty) ? null : _deleteAll,
                  icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
                ),
              ],
            ),
            if (_captureDir != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SelectableText(_captureDir!,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 10)),
              ),
            if (_captures.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No hay capturas todavía.',
                    style: TextStyle(color: Colors.white54)),
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _exportAllToDownloads,
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Copiar a Descargas'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _shareAll,
                      icon: const Icon(Icons.share, size: 18),
                      label: const Text('Compartir'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _deleteAll,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    side: const BorderSide(color: Colors.redAccent),
                  ),
                  icon: const Icon(Icons.delete_forever, size: 18),
                  label: const Text('Borrar todas las grabaciones'),
                ),
              ),
              const SizedBox(height: 8),
              ..._captures.map(_captureTile),
            ],
          ],
        ),
      ),
    );
  }

  Widget _captureTile(Map<String, dynamic> c) {
    final name = c['name'] as String? ?? '?';
    final stage = c['stage'] as String? ?? '?';
    final sizeBytes = (c['sizeBytes'] as num?)?.toInt() ?? 0;
    final kb = (sizeBytes / 1024).toStringAsFixed(0);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        radius: 14,
        backgroundColor: _stageColor(stage),
        child: Text(stage,
            style: const TextStyle(
                color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12)),
      ),
      title: Text(name,
          style: const TextStyle(color: Colors.white, fontSize: 12)),
      subtitle: Text('$kb KB',
          style: const TextStyle(color: Colors.white38, fontSize: 11)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.share, color: Colors.white54, size: 18),
            onPressed: _busy ? null : () => _shareOne(c['path'] as String),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline,
                color: Colors.redAccent, size: 18),
            onPressed: _busy ? null : () => _deleteOne(name),
          ),
        ],
      ),
    );
  }

  Color _stageColor(String stage) {
    switch (stage) {
      case 'A':
        return Colors.greenAccent;
      case 'B':
        return Colors.lightBlueAccent;
      case 'C':
        return Colors.amberAccent;
      case 'D':
        return Colors.pinkAccent;
      default:
        return Colors.white54;
    }
  }
}

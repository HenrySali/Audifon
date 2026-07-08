// Feature: in-app-diagnostic-analyzer
// Module: presentation/screens/diagnostic_analyzer_screen
//
// Technician variant of the AnalyzerScreen entry. Muestra los WAVs
// pendientes del diagnóstico (inbox) y permite seleccionar cuál analizar.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/analyzer/ui/analyzer_screen.dart';
import '../../data/services/analyzer_inbox_service.dart';

class DiagnosticAnalyzerScreen extends StatefulWidget {
  const DiagnosticAnalyzerScreen({super.key});

  @override
  State<DiagnosticAnalyzerScreen> createState() =>
      _DiagnosticAnalyzerScreenState();
}

class _DiagnosticAnalyzerScreenState extends State<DiagnosticAnalyzerScreen> {
  final _inbox = AnalyzerInboxService.instance;
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = _inbox.onChange.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _openAnalyzer(String wavPath) async {
    // El inbox ahora guarda la ruta completa
    final fullPath = wavPath;

    // Verificar que existe
    if (!File(fullPath).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Archivo no encontrado: ${fullPath.split('/').last}')),
        );
      }
      return;
    }

    // Abrir el analizador con el WAV pre-cargado
    if (mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AnalyzerScreen(preloadedWavPath: fullPath),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final wavs = _inbox.pendingWavs;

    return Scaffold(
      backgroundColor: const Color(0xFF0a0e27),
      appBar: AppBar(
        title: const Text('Analizador'),
        backgroundColor: const Color(0xFF0f3460),
        foregroundColor: Colors.white,
        actions: [
          if (wavs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Limpiar inbox',
              onPressed: () {
                _inbox.clear();
                setState(() {});
              },
            ),
          IconButton(
            icon: const Icon(Icons.file_open),
            tooltip: 'Abrir archivo manualmente',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const AnalyzerScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: wavs.isEmpty
          ? _buildEmptyState()
          : _buildWavList(wavs),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.analytics_outlined, color: Colors.white30, size: 64),
          SizedBox(height: 16),
          Text(
            'Sin archivos pendientes',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          SizedBox(height: 8),
          Text(
            'Los WAVs del diagnóstico aparecerán aquí\nautomáticamente al ejecutar los tests.',
            style: TextStyle(color: Colors.white38, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildWavList(List<String> wavs) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: wavs.length,
      itemBuilder: (ctx, i) {
        final wav = wavs[i];
        return Card(
          color: const Color(0xFF16213e),
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: const Icon(Icons.audio_file, color: Colors.cyanAccent),
            title: Text(
              wav.split('/').last,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: const Text(
              'Toca para analizar',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.play_circle, color: Colors.cyanAccent),
              onPressed: () => _openAnalyzer(wav),
            ),
            onTap: () => _openAnalyzer(wav),
          ),
        );
      },
    );
  }
}

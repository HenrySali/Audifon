import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../bloc/amplification_bloc.dart';

/// Widget selector de micrófono de entrada.
///
/// Muestra una lista de micrófonos disponibles (builtin, BT, USB)
/// y permite al usuario seleccionar cuál usar para la captura de audio.
///
/// La selección se persiste en Hive (`preferred_mic_id`) y se aplica
/// automáticamente en el próximo boot o en caliente si el motor está activo.
///
/// Diseño: dropdown compacto con íconos por tipo de dispositivo.
class MicrophoneSelectorWidget extends StatefulWidget {
  const MicrophoneSelectorWidget({super.key});

  @override
  State<MicrophoneSelectorWidget> createState() =>
      _MicrophoneSelectorWidgetState();
}

class _MicrophoneSelectorWidgetState extends State<MicrophoneSelectorWidget> {
  List<Map<String, dynamic>> _microphones = [];
  int _selectedId = -1; // -1 = default del sistema
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadMicrophones();
  }

  Future<void> _loadMicrophones() async {
    final bloc = context.read<AmplificationBloc>();
    try {
      final mics = await bloc.audioBridge.getAvailableMicrophones();
      final box = await Hive.openBox<dynamic>('settings_box');
      final savedId = box.get('preferred_mic_id');
      if (mounted) {
        setState(() {
          _microphones = mics;
          _selectedId = savedId is int ? savedId : -1;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _selectMicrophone(int deviceId) async {
    final bloc = context.read<AmplificationBloc>();
    setState(() => _selectedId = deviceId);

    // Persistir la selección.
    try {
      final box = await Hive.openBox<dynamic>('settings_box');
      await box.put('preferred_mic_id', deviceId);
    } catch (_) {}

    // Aplicar en caliente si el motor está corriendo.
    try {
      await bloc.audioBridge.setPreferredMicrophone(deviceId);
    } catch (_) {}
  }

  IconData _iconForType(String typeName) {
    switch (typeName) {
      case 'Builtin':
        return Icons.phone_android;
      case 'Bluetooth SCO':
      case 'Bluetooth A2DP':
      case 'BLE':
        return Icons.bluetooth_audio;
      case 'USB':
        return Icons.usb;
      default:
        return Icons.mic;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.cyan),
          ),
        ),
      );
    }

    if (_microphones.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        child: const Text(
          'No se detectaron micrófonos.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header.
          const Row(
            children: [
              Icon(Icons.mic, color: Colors.cyan, size: 20),
              SizedBox(width: 8),
              Text(
                'Micrófono de entrada',
                style: TextStyle(
                  color: Colors.cyan,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Seleccioná el micrófono que se va a usar para la captura.',
            style: TextStyle(color: Colors.white54, fontSize: 11),
          ),
          const SizedBox(height: 12),

          // Opción: Default del sistema.
          _MicOptionTile(
            icon: Icons.auto_mode,
            name: 'Automático (default del sistema)',
            typeName: '',
            isSelected: _selectedId == -1,
            onTap: () => _selectMicrophone(-1),
          ),

          // Micrófonos disponibles.
          ...List.generate(_microphones.length, (i) {
            final mic = _microphones[i];
            final id = mic['id'] as int? ?? -1;
            final name = mic['name'] as String? ?? 'Desconocido';
            final typeName = mic['typeName'] as String? ?? 'Externo';
            return _MicOptionTile(
              icon: _iconForType(typeName),
              name: name,
              typeName: typeName,
              isSelected: _selectedId == id,
              onTap: () => _selectMicrophone(id),
            );
          }),
        ],
      ),
    );
  }
}

/// Tile individual de opción de micrófono.
class _MicOptionTile extends StatelessWidget {
  final IconData icon;
  final String name;
  final String typeName;
  final bool isSelected;
  final VoidCallback onTap;

  const _MicOptionTile({
    required this.icon,
    required this.name,
    required this.typeName,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: isSelected ? Colors.cyan.withOpacity(0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? Colors.cyan.withOpacity(0.5) : Colors.white12,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isSelected ? Colors.cyan : Colors.white54,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      color: isSelected ? Colors.cyan : Colors.white,
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (typeName.isNotEmpty)
                    Text(
                      typeName,
                      style: TextStyle(
                        color: isSelected ? Colors.cyan.withOpacity(0.7) : Colors.white38,
                        fontSize: 10,
                      ),
                    ),
                ],
              ),
            ),
            if (isSelected)
              const Icon(Icons.check_circle, color: Colors.cyan, size: 18),
          ],
        ),
      ),
    );
  }
}

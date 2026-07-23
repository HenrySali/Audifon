import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Pantalla de solicitud de permisos al primer inicio.
///
/// Pide TODOS los permisos necesarios de una vez con explicación clara:
/// - RECORD_AUDIO (micrófono)
/// - BLUETOOTH_CONNECT (dispositivos cercanos / auriculares BT)
///
/// Se muestra solo la primera vez o si los permisos no están concedidos.
/// Una vez concedidos, navega automáticamente a la pantalla principal.
class PermissionsScreen extends StatefulWidget {
  final Widget child;

  const PermissionsScreen({super.key, required this.child});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  bool _checking = true;
  bool _micGranted = false;
  bool _btGranted = false;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    final mic = await Permission.microphone.status;
    final bt = await Permission.bluetoothConnect.status;

    setState(() {
      _micGranted = mic.isGranted;
      _btGranted = bt.isGranted;
      _checking = false;
    });

    // Si ya tiene todos los permisos, no mostrar esta pantalla
    if (_micGranted && _btGranted) {
      // No hacer nada, el build mostrará el child directamente
    }
  }

  Future<void> _requestAll() async {
    // Pedir micrófono
    if (!_micGranted) {
      final result = await Permission.microphone.request();
      setState(() => _micGranted = result.isGranted);
    }

    // Pedir Bluetooth (dispositivos cercanos en Android 12+)
    if (!_btGranted) {
      final result = await Permission.bluetoothConnect.request();
      setState(() => _btGranted = result.isGranted);
    }
  }

  Future<void> _openSettings() async {
    await openAppSettings();
    // Re-check after returning from settings
    await Future.delayed(const Duration(milliseconds: 500));
    await _checkPermissions();
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        backgroundColor: Color(0xFF1a1a2e),
        body: Center(child: CircularProgressIndicator(color: Colors.cyan)),
      );
    }

    // Si ya tiene todos los permisos, mostrar la app normal
    if (_micGranted && _btGranted) {
      return widget.child;
    }

    // Mostrar pantalla de permisos
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.hearing, size: 80, color: Colors.cyan),
              const SizedBox(height: 24),
              const Text(
                'PSK Hearing Aid',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'La app necesita los siguientes permisos para funcionar:',
                style: TextStyle(color: Colors.white70, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              // Permiso de micrófono
              _PermissionTile(
                icon: Icons.mic,
                title: 'Micrófono',
                description: 'Capturar el sonido del entorno para amplificarlo',
                granted: _micGranted,
              ),
              const SizedBox(height: 16),
              // Permiso de Bluetooth
              _PermissionTile(
                icon: Icons.bluetooth,
                title: 'Dispositivos cercanos',
                description: 'Conectar con auriculares Bluetooth',
                granted: _btGranted,
              ),
              const SizedBox(height: 40),
              // Botón principal
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _requestAll,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.cyan,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text(
                    'Conceder permisos',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Botón secundario para ir a ajustes
              TextButton(
                onPressed: _openSettings,
                child: const Text(
                  'Abrir ajustes de la app',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool granted;

  const _PermissionTile({
    required this.icon,
    required this.title,
    required this.description,
    required this.granted,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: granted ? Colors.green.withOpacity(0.5) : Colors.white24,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: granted ? Colors.green : Colors.cyan, size: 28),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
          Icon(
            granted ? Icons.check_circle : Icons.circle_outlined,
            color: granted ? Colors.green : Colors.white38,
            size: 24,
          ),
        ],
      ),
    );
  }
}

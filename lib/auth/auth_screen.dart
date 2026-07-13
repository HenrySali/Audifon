// Pantalla de ingreso de codigo de activacion (variante tecnico)
import 'package:flutter/material.dart';
import '../data/bridges/audio_bridge_impl.dart';
import '../data/hive_initializer.dart';
import '../domain/gain_prescriber.dart';
import '../main_with_code.dart';
import '../presentation/services/permission_service.dart';
import '../presentation/widgets/remote_config_gate.dart';
import '../security/biometric_gate.dart';
import 'auth_service.dart';

class AuthScreen extends StatefulWidget {
  final HiveRepositories repositories;
  final AudioBridgeImpl audioBridge;
  final GainPrescriber gainPrescriber;
  final PermissionService permissionService;

  const AuthScreen({
    super.key,
    required this.repositories,
    required this.audioBridge,
    required this.gainPrescriber,
    required this.permissionService,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _controller = TextEditingController();
  final _authService = AuthService();
  bool _loading = false;
  String? _error;

  Future<void> _validate() async {
    final code = _controller.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Ingresa un codigo');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final result = await _authService.validateCode(code);

    if (!mounted) return;

    if (result.mode == TechMode.locked) {
      setState(() {
        _loading = false;
        _error = result.error ?? 'Codigo invalido';
      });
    } else {
      // Codigo valido — navegar a la app con gates de seguridad
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => BiometricGate(
            child: RemoteConfigGate(
              child: HearingAidApp(
                repositories: widget.repositories,
                audioBridge: widget.audioBridge,
                gainPrescriber: widget.gainPrescriber,
                permissionService: widget.permissionService,
              ),
            ),
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Logo
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0f3460),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.cyan.withOpacity(0.3),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.hearing,
                    size: 60,
                    color: Colors.cyan,
                  ),
                ),
                const SizedBox(height: 40),
                const Text(
                  'Oir Pro',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Servicio Tecnico',
                  style: TextStyle(
                    color: Colors.cyan,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 48),
                // Campo de codigo
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF16213e),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _error != null
                          ? Colors.red.withOpacity(0.5)
                          : Colors.cyan.withOpacity(0.3),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Codigo de activacion',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _controller,
                        enabled: !_loading,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 2,
                        ),
                        textAlign: TextAlign.center,
                        textCapitalization: TextCapitalization.characters,
                        decoration: InputDecoration(
                          hintText: 'XXXX-XXXX-XXXX',
                          hintStyle: TextStyle(
                            color: Colors.white30,
                            letterSpacing: 2,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: Colors.black.withOpacity(0.2),
                        ),
                        onSubmitted: (_) => _validate(),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 13,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: _loading ? null : _validate,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.cyan,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: _loading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor:
                                      AlwaysStoppedAnimation(Colors.black),
                                ),
                              )
                            : const Text(
                                'Activar',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                // Ayuda
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.amber.withOpacity(0.3)),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Icon(Icons.info_outline,
                              color: Colors.amber[300], size: 18),
                          const SizedBox(width: 8),
                          Text(
                            'No tienes codigo?',
                            style: TextStyle(
                              color: Colors.amber[300],
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Contacta al administrador del sistema para obtener tu codigo de activacion.',
                        style: TextStyle(
                          color: Colors.grey[300],
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

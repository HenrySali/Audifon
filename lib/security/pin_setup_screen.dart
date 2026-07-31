import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'security_settings_repository.dart';

/// Pantalla de **creación** de PIN local (primer arranque sin biometría).
///
/// Spec: oir-pro-rebrand-harden-and-remote-config — Fase 3 (R3.2).
///
/// Reglas:
/// - PIN de 4 a 6 dígitos numéricos (sin letras).
/// - Dos campos: "Crear PIN" y "Confirmar PIN" → deben coincidir.
/// - Tema oscuro azul marino (#0F1B2D), texto cyan, sin Material default.
/// - Al guardar, persiste vía `SecuritySettingsRepository.setPin()` y
///   hace `Navigator.pop(true)` para que el caller (BiometricGate) sepa
///   que el setup terminó OK.
class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key});

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  static const Color _kBg = Color(0xFF0F1B2D);
  static const Color _kCyan = Color(0xFF00E5FF);

  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _onSave() async {
    final pin = _pinController.text.trim();
    final confirm = _confirmController.text.trim();

    // Validaciones simples — UI rioplatense, mensajes cortos.
    if (pin.length < 4 || pin.length > 6) {
      setState(() => _error = 'El PIN tiene que ser de 4 a 6 dígitos.');
      return;
    }
    if (!RegExp(r'^\d+$').hasMatch(pin)) {
      setState(() => _error = 'Solo números, sin letras ni símbolos.');
      return;
    }
    if (pin != confirm) {
      setState(() => _error = 'Los PIN no coinciden. Reintentá.');
      return;
    }

    setState(() {
      _error = null;
      _saving = true;
    });

    await SecuritySettingsRepository.instance.setPin(pin);

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              const Icon(Icons.lock_outline, color: _kCyan, size: 56),
              const SizedBox(height: 16),
              const Text(
                'Creá tu PIN',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _kCyan,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Tu dispositivo no tiene huella enrolada. Configurá un PIN '
                'de 4 a 6 dígitos para abrir Oír Pro.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 32),
              _buildPinField(
                controller: _pinController,
                label: 'Crear PIN',
                autofocus: true,
              ),
              const SizedBox(height: 16),
              _buildPinField(
                controller: _confirmController,
                label: 'Confirmar PIN',
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 13,
                  ),
                ),
              ],
              const SizedBox(height: 28),
              ElevatedButton(
                onPressed: _saving ? null : _onSave,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kCyan.withOpacity(0.15),
                  foregroundColor: _kCyan,
                  side: BorderSide(color: _kCyan.withOpacity(0.5)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: _saving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _kCyan,
                        ),
                      )
                    : const Text(
                        'Guardar',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPinField({
    required TextEditingController controller,
    required String label,
    bool autofocus = false,
  }) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      obscureText: true,
      keyboardType: TextInputType.number,
      maxLength: 6,
      style: const TextStyle(color: Colors.white, fontSize: 18, letterSpacing: 4),
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        counterText: '',
        filled: true,
        fillColor: Colors.white.withOpacity(0.04),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: _kCyan.withOpacity(0.3)),
          borderRadius: BorderRadius.circular(8),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: _kCyan),
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}

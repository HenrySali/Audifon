import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'security_settings_repository.dart';

/// Pantalla de **ingreso** de PIN local (cuando no hay biometría disponible).
///
/// Spec: oir-pro-rebrand-harden-and-remote-config — Fase 3 (R3.2, R3.3).
///
/// Comportamiento:
/// - Un único campo "Ingresá tu PIN" (4-6 dígitos numéricos).
/// - Botón "Verificar" llama a `verifyPin()`. Si OK → `Navigator.pop(true)`.
/// - Si NO → incrementa `failedAttempts`. Al llegar a 5 → cierra la app
///   con `exit(0)` (R3.3, sin lockout permanente).
/// - Tema oscuro azul marino (#0F1B2D), texto cyan, sin Material default.
class PinFallbackScreen extends StatefulWidget {
  const PinFallbackScreen({super.key});

  @override
  State<PinFallbackScreen> createState() => _PinFallbackScreenState();
}

class _PinFallbackScreenState extends State<PinFallbackScreen> {
  static const Color _kBg = Color(0xFF0F1B2D);
  static const Color _kCyan = Color(0xFF00E5FF);

  final _pinController = TextEditingController();
  String? _error;
  bool _verifying = false;
  int _remainingAttempts = SecuritySettingsRepository.maxFailedAttempts;

  @override
  void initState() {
    super.initState();
    _refreshRemaining();
  }

  Future<void> _refreshRemaining() async {
    final used =
        await SecuritySettingsRepository.instance.getFailedAttempts();
    if (!mounted) return;
    setState(() {
      _remainingAttempts =
          (SecuritySettingsRepository.maxFailedAttempts - used).clamp(0, 5);
    });
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _onVerify() async {
    final pin = _pinController.text.trim();
    if (pin.isEmpty) {
      setState(() => _error = 'Ingresá el PIN.');
      return;
    }

    setState(() {
      _verifying = true;
      _error = null;
    });

    final ok = await SecuritySettingsRepository.instance.verifyPin(pin);

    if (!mounted) return;

    if (ok) {
      await SecuritySettingsRepository.instance.resetFailedAttempts();
      if (!mounted) return;
      Navigator.of(context).pop(true);
      return;
    }

    // PIN incorrecto. Incrementar contador y, si llega al tope, cerrar app.
    await SecuritySettingsRepository.instance.incrementFailedAttempts();
    final used =
        await SecuritySettingsRepository.instance.getFailedAttempts();
    if (used >= SecuritySettingsRepository.maxFailedAttempts) {
      // Salir duro. R3.3 — sin lockout permanente, simplemente cierre.
      // exit(0) en Android equivale al usuario pulsando recents → swipe.
      exit(0);
    }

    if (!mounted) return;
    setState(() {
      _verifying = false;
      _pinController.clear();
      _remainingAttempts =
          (SecuritySettingsRepository.maxFailedAttempts - used).clamp(0, 5);
      _error =
          'PIN incorrecto. Te quedan $_remainingAttempts intentos.';
    });
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
              const SizedBox(height: 32),
              const Icon(Icons.lock, color: _kCyan, size: 56),
              const SizedBox(height: 16),
              const Text(
                'Oír Pro',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _kCyan,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Ingresá tu PIN para abrir la app.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _pinController,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  letterSpacing: 8,
                ),
                textAlign: TextAlign.center,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onSubmitted: (_) => _verifying ? null : _onVerify(),
                decoration: InputDecoration(
                  hintText: '••••',
                  hintStyle: TextStyle(
                    color: Colors.white.withOpacity(0.25),
                    letterSpacing: 8,
                  ),
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
                onPressed: _verifying ? null : _onVerify,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kCyan.withOpacity(0.15),
                  foregroundColor: _kCyan,
                  side: BorderSide(color: _kCyan.withOpacity(0.5)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: _verifying
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _kCyan,
                        ),
                      )
                    : const Text(
                        'Verificar',
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
}

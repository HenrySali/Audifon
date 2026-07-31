import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';

/// Repositorio del PIN del operador para acceso a pantallas técnicas
/// (calibración manual, QC loopback, audit trail).
///
/// Resuelve el hallazgo C-1 de la auditoría:
/// - Hasta junio 2026 el PIN era literal `'1234'`/`'0000'` en código.
///   Cualquiera con la app podía firmar PDFs de QC válidos para
///   release-gate. Riesgo regulatorio (ANMAT/INVIMA): cadena de
///   evidencia trivialmente forjable.
/// - Ahora se persiste solo el SHA-256 del PIN en Hive
///   `service_settings_box`. Al primer arranque sin PIN configurado,
///   la app debe llamar `generateAndStoreInitialPin()` y mostrar el
///   PIN una sola vez al operador con instrucción de anotarlo.
class OperatorPinRepository {
  static const String _boxName = 'service_settings_box';
  static const String _pinHashKey = 'operator_pin_hash';
  static const int _pinDigits = 6;

  Future<Box> _openBox() => Hive.openBox(_boxName);

  /// `true` si el repo ya tiene un PIN configurado.
  Future<bool> hasPin() async {
    final box = await _openBox();
    return box.containsKey(_pinHashKey);
  }

  /// Genera un PIN aleatorio de [_pinDigits] dígitos, persiste solo
  /// el SHA-256 y retorna el PIN en plain (debe mostrarse al
  /// operador una sola vez — no se vuelve a obtener).
  Future<String> generateAndStoreInitialPin() async {
    final rng = Random.secure();
    final pin = List.generate(_pinDigits, (_) => rng.nextInt(10)).join();
    final hash = _hash(pin);
    final box = await _openBox();
    await box.put(_pinHashKey, hash);
    return pin;
  }

  /// `true` si `input` coincide con el hash persistido.
  Future<bool> verifyPin(String input) async {
    final box = await _openBox();
    final stored = box.get(_pinHashKey);
    if (stored is! String) return false;
    return _hash(input) == stored;
  }

  /// Útil solo para tests: borra el PIN persistido.
  Future<void> resetForTests() async {
    final box = await _openBox();
    await box.delete(_pinHashKey);
  }

  static String _hash(String pin) {
    final bytes = utf8.encode(pin);
    return sha256.convert(bytes).toString();
  }
}

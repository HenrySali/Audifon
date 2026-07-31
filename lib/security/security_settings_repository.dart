import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Repositorio singleton para persistir el estado del gate de seguridad.
///
/// Spec: oir-pro-rebrand-harden-and-remote-config — Fase 3 (R3.1 a R3.5).
///
/// Box Hive: `security_settings`. Claves persistidas:
/// - `pinHash`     → string hex (SHA-256 del PIN + salt).
/// - `salt`        → string base64 con 16 bytes random.
/// - `bioRequired` → bool (default true).
/// - `failedAttempts` → int contador de intentos fallidos consecutivos.
///
/// Notas de seguridad:
/// - El PIN tiene solo 4-6 dígitos numéricos, así que el espacio de búsqueda
///   es chico (10^4 a 10^6). bcrypt sería técnicamente más adecuado pero
///   `package:crypto` ya viene como dependencia y SHA-256 con salt aleatorio
///   por dispositivo da una protección razonable contra alguien que extrae
///   el archivo Hive: necesita probar 1M combinaciones por dispositivo.
/// - La comparación de hashes se hace en tiempo constante (helper interno)
///   para evitar timing attacks.
/// - Después de 5 intentos fallidos consecutivos `BiometricGate` cierra la
///   app vía `exit(0)` / `SystemNavigator.pop()` (R3.3). El contador se
///   resetea en cada éxito.
class SecuritySettingsRepository {
  static const String boxName = 'security_settings';
  static const String _kPinHash = 'pinHash';
  static const String _kSalt = 'salt';
  static const String _kBioRequired = 'bioRequired';
  static const String _kFailedAttempts = 'failedAttempts';

  /// Tope de intentos fallidos antes de cerrar la app (R3.3).
  static const int maxFailedAttempts = 5;

  /// Singleton accedido desde `BiometricGate` y `TechnicalServiceScreen`.
  static final SecuritySettingsRepository instance =
      SecuritySettingsRepository._();

  SecuritySettingsRepository._();

  Box? _box;
  Box get _requireBox {
    final b = _box;
    if (b == null) {
      throw StateError(
        'SecuritySettingsRepository.init() no fue llamado todavía.',
      );
    }
    return b;
  }

  /// Abre el box Hive. Idempotente: llamadas posteriores son no-op.
  ///
  /// Asume que `Hive.initFlutter()` ya fue invocado por `HiveInitializer`.
  Future<void> init() async {
    if (_box != null && _box!.isOpen) return;
    if (!Hive.isBoxOpen(boxName)) {
      _box = await Hive.openBox(boxName);
    } else {
      _box = Hive.box(boxName);
    }
  }

  // -------------------------------------------------------------------------
  // PIN
  // -------------------------------------------------------------------------

  /// Persiste el PIN como SHA-256 del concat `salt || pin`. Genera un salt
  /// nuevo de 16 bytes en cada `setPin` (rotación implícita en re-set).
  Future<void> setPin(String pin) async {
    final salt = _randomSaltBase64();
    final hash = _hashPin(pin, salt);
    await _requireBox.put(_kPinHash, hash);
    await _requireBox.put(_kSalt, salt);
    // Re-setear el PIN limpia el contador de intentos fallidos.
    await _requireBox.put(_kFailedAttempts, 0);
  }

  /// Devuelve true si el PIN ingresado coincide con el hash persistido.
  /// Comparación constant-time para evitar timing attacks.
  Future<bool> verifyPin(String pin) async {
    final stored = _requireBox.get(_kPinHash) as String?;
    final salt = _requireBox.get(_kSalt) as String?;
    if (stored == null || salt == null) return false;
    final candidate = _hashPin(pin, salt);
    return _constantTimeEquals(stored, candidate);
  }

  /// True si hay un PIN seteado (ambos `pinHash` y `salt` presentes).
  Future<bool> hasPin() async {
    final stored = _requireBox.get(_kPinHash) as String?;
    final salt = _requireBox.get(_kSalt) as String?;
    return stored != null && salt != null && stored.isNotEmpty;
  }

  // -------------------------------------------------------------------------
  // Toggle "Pedir biometría al abrir" (R3.4)
  // -------------------------------------------------------------------------

  /// Default true. El técnico puede apagarlo desde Servicio Técnico para
  /// demos / ventas sin que la app pida biometría en cada arranque.
  Future<bool> isBiometricRequired() async {
    final v = _requireBox.get(_kBioRequired) as bool?;
    return v ?? true;
  }

  Future<void> setBiometricRequired(bool value) async {
    await _requireBox.put(_kBioRequired, value);
  }

  // -------------------------------------------------------------------------
  // Contador de intentos fallidos (R3.3)
  // -------------------------------------------------------------------------

  Future<int> getFailedAttempts() async {
    final v = _requireBox.get(_kFailedAttempts) as int?;
    return v ?? 0;
  }

  Future<void> incrementFailedAttempts() async {
    final current = await getFailedAttempts();
    await _requireBox.put(_kFailedAttempts, current + 1);
  }

  Future<void> resetFailedAttempts() async {
    await _requireBox.put(_kFailedAttempts, 0);
  }

  // -------------------------------------------------------------------------
  // Helpers internos
  // -------------------------------------------------------------------------

  static String _hashPin(String pin, String saltBase64) {
    final salt = base64Decode(saltBase64);
    final pinBytes = utf8.encode(pin);
    final combined = Uint8List(salt.length + pinBytes.length)
      ..setRange(0, salt.length, salt)
      ..setRange(salt.length, salt.length + pinBytes.length, pinBytes);
    return sha256.convert(combined).toString();
  }

  static String _randomSaltBase64() {
    final rng = Random.secure();
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return base64Encode(bytes);
  }

  /// Comparación constant-time de dos strings hex. Devuelve true solo si
  /// son idénticas y de la misma longitud. Evita early-exit que filtra
  /// timing.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

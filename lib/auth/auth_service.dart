// Servicio de autenticacion - valida codigo contra el servidor (variante tecnico)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Modos de acceso para la variante tecnico.
enum TechMode {
  technical, // Acceso completo (todas las pantallas)
  locked, // Sin acceso
}

/// Resultado de validacion con mensaje de error detallado.
class AuthResult {
  final TechMode mode;
  final String? error;

  const AuthResult(this.mode, [this.error]);
}

/// Resultado del endpoint check-status.
class CheckStatusResult {
  /// true si el codigo esta activo y valido.
  final bool ok;

  /// true si el codigo fue bloqueado por el administrador.
  final bool blocked;

  /// Motivo del bloqueo (solo presente si blocked == true).
  final String? blockedReason;

  /// Fecha de expiracion de la licencia (ISO 8601 string o null).
  final String? expiresAt;

  /// Version minima requerida por el administrador (e.g. "2.0.0") o null.
  final String? requiredVersion;

  /// Mensaje de error si la consulta fallo (red, timeout, etc.).
  final String? error;

  /// true si no se pudo contactar al servidor (offline).
  final bool noNetwork;

  const CheckStatusResult({
    this.ok = false,
    this.blocked = false,
    this.blockedReason,
    this.expiresAt,
    this.requiredVersion,
    this.error,
    this.noNetwork = false,
  });
}

class AuthService {
  static const String _baseUrl =
      'https://appsmarttemp.xn--diseosyefectos-tnb.com/oirpro/api';
  static const String _validateUrl = '$_baseUrl/validate-code-tech';
  static const String _checkStatusUrl = '$_baseUrl/check-status';

  static const String _keyMode = 'tech_mode';
  static const String _keyLastValidation = 'last_validation_ts';
  static const String _keyDeviceId = 'device_id';
  static const String _keyActivationCode = 'activation_code';
  static const String _keyExpiresAt = 'expires_at';

  /// Obtiene o genera un deviceId unico persistido en este dispositivo.
  Future<String> getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_keyDeviceId);
    if (id == null) {
      final rng = Random.secure();
      id = List.generate(
        32,
        (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await prefs.setString(_keyDeviceId, id);
    }
    return id;
  }

  /// Consulta el estado de un codigo en el servidor.
  /// POST /api/check-status con { code, deviceId, type: "tech" }.
  Future<CheckStatusResult> checkStatus(String code, String deviceId) async {
    try {
      debugPrint('[AuthService] checkStatus contra: $_checkStatusUrl');

      final response = await http.post(
        Uri.parse(_checkStatusUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'code': code,
          'deviceId': deviceId,
          'type': 'tech',
        }),
      ).timeout(const Duration(seconds: 10));

      debugPrint('[AuthService] checkStatus status: ${response.statusCode}');
      debugPrint('[AuthService] checkStatus body: ${response.body}');

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;

        if (json['blocked'] == true) {
          return CheckStatusResult(
            ok: false,
            blocked: true,
            blockedReason: json['blockedReason'] as String?,
          );
        }

        if (json['ok'] == true) {
          // Guardar expiresAt si viene del servidor
          final expiresAt = json['expiresAt'] as String?;
          if (expiresAt != null) {
            await saveExpiresAt(expiresAt);
          }

          return CheckStatusResult(
            ok: true,
            blocked: false,
            expiresAt: expiresAt,
            requiredVersion: json['requiredVersion'] as String?,
          );
        }

        // Caso: ok == false sin blocked (puede ser expirado u otro error)
        final errorMsg = json['error'] as String?;
        return CheckStatusResult(
          ok: false,
          error: errorMsg,
          expiresAt: json['expiresAt'] as String?,
        );
      } else {
        return CheckStatusResult(
          ok: false,
          error: 'Error del servidor (${response.statusCode})',
        );
      }
    } on TimeoutException {
      return const CheckStatusResult(
        ok: false,
        noNetwork: true,
        error: 'Sin conexion al servidor (timeout)',
      );
    } on SocketException {
      return const CheckStatusResult(
        ok: false,
        noNetwork: true,
        error: 'Sin conexion a internet',
      );
    } on HandshakeException {
      return const CheckStatusResult(
        ok: false,
        noNetwork: true,
        error: 'Error SSL',
      );
    } catch (e) {
      debugPrint('[AuthService] checkStatus error: $e');
      return CheckStatusResult(
        ok: false,
        noNetwork: true,
        error: 'Error inesperado: $e',
      );
    }
  }

  /// Valida un codigo contra el servidor enviando tambien el deviceId.
  /// Devuelve un [AuthResult] con el modo y un error descriptivo si falla.
  Future<AuthResult> validateCode(String code) async {
    try {
      final deviceId = await getDeviceId();
      debugPrint('[AuthService] Validando codigo contra: $_validateUrl');
      debugPrint('[AuthService] deviceId: $deviceId');

      final response = await http
          .post(
            Uri.parse(_validateUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'code': code, 'deviceId': deviceId}),
          )
          .timeout(const Duration(seconds: 10));

      debugPrint('[AuthService] Status: ${response.statusCode}');
      debugPrint('[AuthService] Body: ${response.body}');

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        if (json['ok'] == true) {
          await _saveMode(TechMode.technical);
          // Guardar el codigo de activacion para futuras consultas check-status
          await saveActivationCode(code);
          // Hacer check-status para obtener expiresAt
          final statusResult = await checkStatus(code, deviceId);
          if (statusResult.ok && statusResult.expiresAt != null) {
            await saveExpiresAt(statusResult.expiresAt!);
          }
          return const AuthResult(TechMode.technical);
        } else {
          // Error del servidor (codigo no encontrado, revocado, otro dispositivo)
          final serverError =
              json['error'] as String? ?? 'Codigo invalido';
          return AuthResult(TechMode.locked, serverError);
        }
      } else if (response.statusCode == 400) {
        return const AuthResult(
          TechMode.locked,
          'Formato de codigo invalido',
        );
      } else if (response.statusCode == 429) {
        return const AuthResult(
          TechMode.locked,
          'Demasiados intentos. Espera 1 minuto.',
        );
      } else {
        return AuthResult(
          TechMode.locked,
          'Error del servidor (${response.statusCode})',
        );
      }
    } on TimeoutException {
      return const AuthResult(
        TechMode.locked,
        'Sin conexion al servidor (timeout)',
      );
    } on SocketException catch (e) {
      return AuthResult(TechMode.locked, 'Error de red: ${e.message}');
    } on HandshakeException catch (e) {
      return AuthResult(TechMode.locked, 'Error SSL: ${e.message}');
    } catch (e) {
      debugPrint('[AuthService] Error inesperado: $e');
      return AuthResult(TechMode.locked, 'Error inesperado: $e');
    }
  }

  /// Lee el modo persistido.
  Future<TechMode?> getSavedMode() async {
    final prefs = await SharedPreferences.getInstance();
    final modeStr = prefs.getString(_keyMode);
    if (modeStr == null) return null;
    return TechMode.values.firstWhere(
      (m) => m.name == modeStr,
      orElse: () => TechMode.locked,
    );
  }

  Future<void> _saveMode(TechMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyMode, mode.name);
    await prefs.setInt(
      _keyLastValidation,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> clearMode() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyMode);
    await prefs.remove(_keyLastValidation);
  }

  // --- Activation Code persistence ---

  /// Guarda el codigo de activacion en SharedPreferences.
  Future<void> saveActivationCode(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyActivationCode, code);
  }

  /// Lee el codigo de activacion guardado.
  Future<String?> getActivationCode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyActivationCode);
  }

  // --- ExpiresAt persistence ---

  /// Guarda la fecha de expiracion (ISO 8601 string).
  Future<void> saveExpiresAt(String expiresAt) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyExpiresAt, expiresAt);
  }

  /// Lee la fecha de expiracion guardada.
  Future<String?> getExpiresAt() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyExpiresAt);
  }
}

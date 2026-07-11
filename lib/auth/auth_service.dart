// Servicio de autenticacion — valida codigo contra el servidor (variante tecnico)
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

class AuthService {
  static const String _validateUrl =
      'https://appsmarttemp.xn--diseosyefectos-tnb.com/oirpro/api/validate-code-tech';

  static const String _keyMode = 'tech_mode';
  static const String _keyLastValidation = 'last_validation_ts';
  static const String _keyDeviceId = 'device_id';

  /// Obtiene o genera un deviceId unico persistido en este dispositivo.
  Future<String> _getDeviceId() async {
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

  /// Valida un codigo contra el servidor enviando tambien el deviceId.
  /// Devuelve un [AuthResult] con el modo y un error descriptivo si falla.
  Future<AuthResult> validateCode(String code) async {
    try {
      final deviceId = await _getDeviceId();
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
}

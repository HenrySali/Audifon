// Spec: bundle-export-local-save (fix mínimo).
//
// Wrapper Dart sobre el `MethodChannel` `com.psk.hearing_aid/local_downloads`
// que expone el código Kotlin en `LocalDownloadsChannel.kt`. Permite
// guardar archivos directamente en `Download/` del celular sin pasar
// por el share sheet del sistema (que actualmente está roto en builds
// release por reglas ProGuard incompletas en `share_plus`).

import 'dart:developer' as developer;

import 'package:flutter/services.dart';

/// Excepción específica para fallos al guardar en Downloads.
class LocalDownloadsException implements Exception {
  final String message;
  final Object? cause;
  LocalDownloadsException(this.message, [this.cause]);
  @override
  String toString() => 'LocalDownloadsException: $message';
}

/// Servicio para escribir archivos al directorio público `Download/`
/// del dispositivo Android sin abrir el share sheet.
///
/// Solo Android. En otras plataformas el método lanza
/// [LocalDownloadsException].
class LocalDownloadsService {
  LocalDownloadsService({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('com.psk.hearing_aid/local_downloads');

  final MethodChannel _channel;

  /// Guarda [content] como un archivo `.json` en `Download/` con
  /// nombre [filename]. Devuelve la ruta o URI mostrable al usuario
  /// (ej. `"Descargas/oirpro_juan_20260612.oirpro.json"`).
  ///
  /// Comportamiento:
  /// - Android 10+ (API 29+): usa `MediaStore.Downloads` — sin permisos.
  /// - Android 9 y anteriores: escribe directo a Downloads. Requiere
  ///   `WRITE_EXTERNAL_STORAGE` ya concedido.
  ///
  /// Errores comunes:
  /// - [LocalDownloadsException] si el método nativo falla (disco
  ///   lleno, permiso denegado, plataforma distinta a Android).
  Future<String> saveJsonToDownloads({
    required String filename,
    required String content,
  }) async {
    try {
      final result = await _channel.invokeMethod<String>(
        'saveJsonToDownloads',
        <String, dynamic>{
          'filename': filename,
          'content': content,
        },
      );
      if (result == null || result.isEmpty) {
        throw LocalDownloadsException(
          'El canal nativo retornó null/empty.',
        );
      }
      return result;
    } on MissingPluginException catch (e) {
      // Pasa solo si la app no es Android o el canal no se registró.
      developer.log(
        'LocalDownloadsService: canal nativo no disponible: $e',
        name: 'LocalDownloadsService',
        level: 1000,
      );
      throw LocalDownloadsException(
        'El canal nativo no está disponible en esta plataforma.',
        e,
      );
    } on PlatformException catch (e) {
      developer.log(
        'LocalDownloadsService: PlatformException ${e.code}: ${e.message}',
        name: 'LocalDownloadsService',
        level: 1000,
        error: e,
      );
      throw LocalDownloadsException(
        e.message ?? e.code,
        e,
      );
    }
  }
}

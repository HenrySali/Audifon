import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

/// Snapshot inmutable de la configuración remota descargada del backend
/// Oír Pro (`POST /api/check`) o leída del cache local de Hive.
///
/// Spec: oir-pro-rebrand-harden-and-remote-config — Fase 5b / R6.1 a R6.6.
///
/// La app NUNCA depende del server para operar el audífono. Si el server
/// está caído o tarda más de 3 s, este snapshot viene de cache (≤7 días)
/// o de los defaults seguros embebidos. El flag [isFromCache] permite a
/// la UI distinguir el origen para logs / debug.
@immutable
class RemoteConfig {
  /// Código que destraba el Modo Servicio Técnico. Hoy se usa para
  /// validar entrada en pantallas técnicas (futuro: spec
  /// `oir-pro-patient-mode`).
  final String techCode;

  /// Última versión publicada en el backend (semver `x.y.z`).
  final String latestVersion;

  /// Versión mínima soportada. Si la app instalada está por debajo, el
  /// diálogo de actualización es modal bloqueante (R6.3).
  final String minVersion;

  /// URL pública del APK más reciente. Puede ser null si no se subió
  /// todavía. La app abre esta URL en el navegador externo (R6.3).
  final String? apkUrl;

  /// Kill switch (R6.3): si `true`, la app muestra `BlockedScreen` y solo
  /// se sale apagando.
  final bool blocked;

  /// Texto que la `BlockedScreen` muestra. Si null, se usa un mensaje
  /// genérico.
  final String? blockedReason;

  /// Cuándo se obtuvo este snapshot. Sirve para descartar cache vencido
  /// (>7 días, ver [RemoteConfigService.cacheTtl]).
  final DateTime fetchedAt;

  /// `true` si el snapshot vino del cache (no del server) o del fallback
  /// embebido. El `fetch()` sigue devolviendo `RemoteConfig` cuando hay
  /// falla de red, pero con esta marca puesta para que la UI no insista
  /// con notificaciones de update basadas en datos viejos.
  final bool isFromCache;

  const RemoteConfig({
    required this.techCode,
    required this.latestVersion,
    required this.minVersion,
    required this.apkUrl,
    required this.blocked,
    required this.blockedReason,
    required this.fetchedAt,
    required this.isFromCache,
  });

  /// Construye el config desde la respuesta JSON del backend o desde la
  /// entrada cacheada en Hive. Tolera campos faltantes / null y cae a los
  /// defaults seguros embebidos.
  factory RemoteConfig.fromJson(
    Map<String, dynamic> json, {
    required bool isFromCache,
  }) {
    DateTime parseFetched(dynamic raw) {
      if (raw is String) {
        return DateTime.tryParse(raw)?.toUtc() ?? DateTime.now().toUtc();
      }
      return DateTime.now().toUtc();
    }

    final apkUrlRaw = json['apkUrl'];
    return RemoteConfig(
      techCode: (json['techCode'] as String?) ??
          RemoteConfigService.fallbackTechCode,
      latestVersion: (json['latestVersion'] as String?) ??
          RemoteConfigService.fallbackVersion,
      minVersion: (json['minVersion'] as String?) ??
          RemoteConfigService.fallbackVersion,
      apkUrl: (apkUrlRaw is String && apkUrlRaw.isNotEmpty) ? apkUrlRaw : null,
      blocked: json['blocked'] == true,
      blockedReason: json['blockedReason'] as String?,
      // El backend puede mandar `serverTime`. Si no, usamos `fetchedAt`
      // que persistimos al cachear. Si tampoco está, ahora.
      fetchedAt: parseFetched(json['fetchedAt'] ?? json['serverTime']),
      isFromCache: isFromCache,
    );
  }

  /// Serialización para persistencia en Hive. El consumo es interno —
  /// el backend ignora campos extra como `fetchedAt` / `isFromCache`.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'techCode': techCode,
        'latestVersion': latestVersion,
        'minVersion': minVersion,
        'apkUrl': apkUrl,
        'blocked': blocked,
        'blockedReason': blockedReason,
        'fetchedAt': fetchedAt.toIso8601String(),
      };
}

/// Cliente del backend remoto Oír Pro (`/api/check`).
///
/// Spec: oir-pro-rebrand-harden-and-remote-config — Fase 5b / R6.1 a R6.6.
///
/// Garantías:
///
/// - **Nunca tira excepciones**: cualquier `SocketException`,
///   `TimeoutException`, `FormatException` o error genérico se atrapa,
///   se loguea con tag `[RemoteConfig]` y se cae a cache / defaults.
/// - **Timeout corto** (3 s) para no bloquear el arranque si el server
///   está caído. Un técnico puede estar en una zona sin cobertura.
/// - **Cache de 7 días** en Hive box `oirpro_remote_cache`. Si el server
///   no responde y el cache está fresco, se devuelve cache. Si el cache
///   está vencido o vacío, se devuelven los defaults seguros embebidos.
/// - **deviceId estable**: UUID v4 generado con `Random.secure()` la
///   primera vez y persistido en la misma box. Sin `device_info_plus`
///   para no agregar deps nuevas — alcanza con un identificador random
///   por instalación.
///
/// Uso típico (ver `RemoteConfigGate` en `main.dart`):
///
/// ```dart
/// await RemoteConfigService.instance.init();
/// final cfg = await RemoteConfigService.instance.fetch(
///   currentVersion: '1.0.0',
/// );
/// if (cfg.blocked) ...;
/// ```
class RemoteConfigService {
  // -------------------------------------------------------------------------
  // Constantes públicas (referenciadas también desde `RemoteConfig.fromJson`)
  // -------------------------------------------------------------------------

  /// URL pública del backend Oír Pro. Sirve el endpoint vía nginx detrás
  /// del dominio público de SmartTemp (mismo VPS, puerto 8060 interno
  /// reverse proxy desde 443 SSL). Sin TLS los celulares de algunas
  /// operadoras bloquean cleartext, así que vamos directo a HTTPS.
  static const String endpoint =
      'https://appsmarttemp.xn--diseosyefectos-tnb.com/oirpro/api/check';

  /// Timeout duro del POST (R6.2). Si el server se cuelga, el `fetch()`
  /// resuelve con cache / defaults dentro de este margen.
  static const Duration timeout = Duration(seconds: 3);

  /// Vida útil del cache. Pasados 7 días, el snapshot persistido se
  /// considera vencido y se cae a defaults (R6.4).
  static const Duration cacheTtl = Duration(days: 7);

  /// Tech code embebido como último recurso. Solo se usa cuando ni el
  /// server ni el cache están disponibles. NO es un secreto — la idea es
  /// que la app abra y el técnico pueda operar offline; el código real
  /// llega del backend en el primer fetch exitoso.
  static const String fallbackTechCode = 'OIRPRO_TECH_DEFAULT';

  /// Versión asumida cuando no hay cache. Coincide con la `version:` del
  /// `pubspec.yaml` para no disparar diálogos de update espurios al
  /// arrancar offline por primera vez.
  static const String fallbackVersion = '1.0.0';

  /// Box Hive donde persistimos el último config y el `deviceId`.
  static const String boxName = 'oirpro_remote_cache';

  static const String _kLastConfig = 'last';
  static const String _kDeviceId = 'deviceId';

  // -------------------------------------------------------------------------
  // Singleton
  // -------------------------------------------------------------------------

  static final RemoteConfigService instance = RemoteConfigService._();
  RemoteConfigService._();

  /// Inyectable para tests: si se pasa un `http.Client`, se usa en lugar
  /// del cliente por defecto. En producción se deja en null.
  http.Client? _httpClient;

  @visibleForTesting
  set httpClientForTest(http.Client? client) => _httpClient = client;

  Box? _box;

  Box get _requireBox {
    final b = _box;
    if (b == null) {
      throw StateError(
        'RemoteConfigService.init() no fue llamado todavía.',
      );
    }
    return b;
  }

  /// Abre el box Hive. Idempotente. Asume que `Hive.initFlutter()` ya fue
  /// invocado por `HiveInitializer`.
  Future<void> init() async {
    if (_box != null && _box!.isOpen) return;
    if (!Hive.isBoxOpen(boxName)) {
      _box = await Hive.openBox(boxName);
    } else {
      _box = Hive.box(boxName);
    }
  }

  // -------------------------------------------------------------------------
  // API pública
  // -------------------------------------------------------------------------

  /// Consulta el backend con timeout 3 s.
  ///
  /// Garantía: NUNCA tira excepciones. Devuelve siempre un `RemoteConfig`:
  /// fresco (server) → cache (≤7 días) → defaults seguros.
  ///
  /// `appId` por default es `oirpro-tech` (la APK del técnico). El spec
  /// `oir-pro-patient-mode` reusará este servicio con `oirpro-patient`.
  Future<RemoteConfig> fetch({
    required String currentVersion,
    String appId = 'oirpro-tech',
  }) async {
    final client = _httpClient ?? http.Client();
    final shouldClose = _httpClient == null;
    try {
      final body = jsonEncode(<String, dynamic>{
        'appId': appId,
        'deviceId': await _ensureDeviceId(),
        'currentVersion': currentVersion,
      });
      debugPrint('[RemoteConfig] POST $endpoint appId=$appId v=$currentVersion');
      final res = await client
          .post(
            Uri.parse(endpoint),
            headers: const <String, String>{
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: body,
          )
          .timeout(timeout);

      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) {
          // Inyectamos `fetchedAt` antes de cachear para que el TTL del
          // cache funcione independientemente del `serverTime` que mande
          // (o no mande) el backend.
          final withTimestamp = <String, dynamic>{
            ...decoded,
            'fetchedAt': DateTime.now().toUtc().toIso8601String(),
          };
          await _saveCache(withTimestamp);
          debugPrint(
            '[RemoteConfig] OK techCode=${decoded['techCode']} '
            'latest=${decoded['latestVersion']} blocked=${decoded['blocked']}',
          );
          return RemoteConfig.fromJson(withTimestamp, isFromCache: false);
        }
        debugPrint('[RemoteConfig] respuesta JSON inválida: ${res.body}');
      } else {
        debugPrint('[RemoteConfig] HTTP ${res.statusCode}: ${res.body}');
      }
    } on TimeoutException catch (e) {
      debugPrint('[RemoteConfig] timeout (${timeout.inSeconds}s): $e');
    } on SocketException catch (e) {
      debugPrint('[RemoteConfig] socket error: ${e.message}');
    } on FormatException catch (e) {
      debugPrint('[RemoteConfig] format error: ${e.message}');
    } catch (e) {
      debugPrint('[RemoteConfig] error: $e');
    } finally {
      if (shouldClose) {
        client.close();
      }
    }

    // No hubo respuesta válida — caer al cache o a los defaults.
    return _readCacheOrFallback();
  }

  /// Devuelve el último config persistido (sin pegar al server). Útil
  /// cuando una pantalla técnica necesita saber el `techCode` actual sin
  /// disparar un nuevo fetch.
  ///
  /// Devuelve null si nunca se cacheó nada todavía. NO valida el TTL —
  /// el caller decide qué hacer si el cache está viejo.
  Future<RemoteConfig?> getCachedConfig() async {
    try {
      final raw = _requireBox.get(_kLastConfig);
      if (raw is Map) {
        final json = Map<String, dynamic>.from(raw);
        return RemoteConfig.fromJson(json, isFromCache: true);
      }
    } catch (e) {
      debugPrint('[RemoteConfig] error leyendo cache: $e');
    }
    return null;
  }

  /// Limpia el cache (no toca el `deviceId` para que la identidad del
  /// dispositivo se mantenga estable entre reseteos). Lo usa el botón
  /// "Resetear cache remoto" en Servicio Técnico.
  Future<void> clearCache() async {
    try {
      await _requireBox.delete(_kLastConfig);
      debugPrint('[RemoteConfig] cache reseteado');
    } catch (e) {
      debugPrint('[RemoteConfig] error reseteando cache: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Internos
  // -------------------------------------------------------------------------

  /// Lee el último JSON cacheado. Si está fresco (≤[cacheTtl]), lo usa.
  /// Si está vencido o vacío, devuelve los defaults seguros embebidos.
  Future<RemoteConfig> _readCacheOrFallback() async {
    try {
      final raw = _requireBox.get(_kLastConfig);
      if (raw is Map) {
        final json = Map<String, dynamic>.from(raw);
        final fetchedAtRaw = json['fetchedAt'];
        final fetchedAt = fetchedAtRaw is String
            ? DateTime.tryParse(fetchedAtRaw)
            : null;
        if (fetchedAt != null) {
          final age = DateTime.now().toUtc().difference(fetchedAt.toUtc());
          if (age <= cacheTtl) {
            debugPrint(
              '[RemoteConfig] usando cache (edad=${age.inHours}h)',
            );
            return RemoteConfig.fromJson(json, isFromCache: true);
          }
          debugPrint(
            '[RemoteConfig] cache vencido (edad=${age.inDays}d) → defaults',
          );
        } else {
          debugPrint('[RemoteConfig] cache sin fetchedAt → defaults');
        }
      } else {
        debugPrint('[RemoteConfig] sin cache → defaults');
      }
    } catch (e) {
      debugPrint('[RemoteConfig] error leyendo cache: $e');
    }
    return _fallbackConfig();
  }

  /// Defaults seguros embebidos. La app abre normal, sin bloqueo y sin
  /// notificación de update.
  RemoteConfig _fallbackConfig() {
    return RemoteConfig(
      techCode: fallbackTechCode,
      latestVersion: fallbackVersion,
      minVersion: fallbackVersion,
      apkUrl: null,
      blocked: false,
      blockedReason: null,
      fetchedAt: DateTime.now().toUtc(),
      isFromCache: true,
    );
  }

  Future<void> _saveCache(Map<String, dynamic> json) async {
    try {
      await _requireBox.put(_kLastConfig, json);
    } catch (e) {
      debugPrint('[RemoteConfig] error persistiendo cache: $e');
    }
  }

  /// Devuelve el `deviceId` persistido o lo genera si no existe (UUID v4
  /// random con `Random.secure()`).
  Future<String> _ensureDeviceId() async {
    try {
      final existing = _requireBox.get(_kDeviceId);
      if (existing is String && existing.isNotEmpty) {
        return existing;
      }
      final fresh = _generateUuidV4();
      await _requireBox.put(_kDeviceId, fresh);
      debugPrint('[RemoteConfig] deviceId generado: $fresh');
      return fresh;
    } catch (e) {
      // Si Hive falla, devolvemos un id efímero. El backend no se rompe
      // porque solo lo usa para logging.
      debugPrint('[RemoteConfig] error con deviceId persistido: $e');
      return _generateUuidV4();
    }
  }

  /// Genera un UUID v4 random con `Random.secure()`. Sin `device_info_plus`
  /// (no agregamos deps por esto) — el espacio de 122 bits aleatorios es
  /// más que suficiente para identificar instalaciones únicamente para
  /// logging del backend.
  static String _generateUuidV4() {
    final rng = Random.secure();
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = rng.nextInt(256);
    }
    // Versión 4 (random): nibble alto del byte 6.
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    // Variante RFC 4122 (10xx): dos bits altos del byte 8.
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    String hex(int from, int to) {
      final sb = StringBuffer();
      for (var i = from; i < to; i++) {
        sb.write(bytes[i].toRadixString(16).padLeft(2, '0'));
      }
      return sb.toString();
    }

    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }
}

/// Compara dos versiones semver simples (`x.y.z`). Devuelve `true` si
/// `candidate` es estrictamente más nueva que `reference`.
///
/// Parser tolerante: cualquier componente no numérico se ignora (las
/// pre-releases tipo `1.0.0-beta.1` quedan como `[1, 0, 0]` para evitar
/// trampas en la comparación). Si el parse falla, devuelve `false`
/// (asume igual o menor — más conservador para no bloquear la app con un
/// diálogo de update espurio).
bool isVersionNewer(String candidate, String reference) {
  List<int>? parse(String raw) {
    try {
      final cleanedBuf = StringBuffer();
      for (var i = 0; i < raw.length; i++) {
        final c = raw.codeUnitAt(i);
        // Solo dígitos y puntos. El primer guion (pre-release) corta.
        if (c == 0x2D /* '-' */ || c == 0x2B /* '+' */) break;
        cleanedBuf.writeCharCode(c);
      }
      final parts = cleanedBuf
          .toString()
          .split('.')
          .where((p) => p.isNotEmpty)
          .map(int.parse)
          .toList();
      if (parts.isEmpty) return null;
      return parts;
    } catch (_) {
      return null;
    }
  }

  final a = parse(candidate);
  final b = parse(reference);
  if (a == null || b == null) return false;
  // Igualar largos rellenando con 0 (`1.0` == `1.0.0`).
  final len = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < len; i++) {
    final ai = i < a.length ? a[i] : 0;
    final bi = i < b.length ? b[i] : 0;
    if (ai > bi) return true;
    if (ai < bi) return false;
  }
  return false;
}

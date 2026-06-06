import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:hive/hive.dart';

import '../../domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import '../../domain/audiogram_driven_presets/bundle_builder.dart';
import '../../domain/audiogram_driven_presets/custom_preset_record.dart';
import '../../domain/audiogram_driven_presets/manual_adjustment_delta.dart';
import '../../domain/audiogram_driven_presets/profile_repository_warning.dart';
import '../../domain/audiogram_driven_presets/style_applicator.dart';
import '../../domain/entities/audiogram.dart';
import '../../domain/entities/environment_profile.dart';
import '../../domain/entities/patient_profile.dart';
import '../../domain/entities/prescription_mode.dart';
import '../../domain/repositories/profile_repository.dart';

/// Nombre del Hive box para perfiles de entorno y presets personalizados.
const String profilesBoxName = 'profiles_box';

/// Implementación del repositorio de perfiles usando Hive.
///
/// Persiste cada preset personalizado como un blob JSON unificado bajo
/// la clave del nombre del preset (ver [CustomPresetRecord.toJson]).
/// La capa de persistencia conserva además los campos legacy
/// (`nrLevel`, `compressionRatio`, `expansionKnee`, `compressionKnee`)
/// para retrocompatibilidad de lectura desde versiones anteriores del
/// repo (Req 8.2).
///
/// Las advertencias observables (preset migrado, blob corrupto, fallo
/// parcial al marcar presets como obsoletos) se publican vía
/// [warnings].
///
/// Requisitos: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 9.2, 9.3, 9.5
class ProfileRepositoryImpl implements ProfileRepository {
  final Box<dynamic> _box;
  final BundleBuilder _bundleBuilder;
  final StreamController<ProfileRepositoryWarning> _warningsController;

  /// Nombres de los perfiles predefinidos (no eliminables, no
  /// elegibles como preset personalizado).
  static const Set<String> _predefinedNames = {
    'Silencioso',
    'Conversación',
    'Ruidoso',
  };

  ProfileRepositoryImpl(
    this._box, {
    BundleBuilder? bundleBuilder,
  })  : _bundleBuilder = bundleBuilder ?? BundleBuilder(),
        _warningsController =
            StreamController<ProfileRepositoryWarning>.broadcast();

  /// Abre el box de Hive para perfiles.
  static Future<Box<dynamic>> openBox() async {
    return Hive.openBox(profilesBoxName);
  }

  @override
  Stream<ProfileRepositoryWarning> get warnings =>
      _warningsController.stream;

  @override
  List<EnvironmentProfile> getPredefinedProfiles() {
    return EnvironmentProfile.predefinedProfiles;
  }

  @override
  Future<List<EnvironmentProfile>> getAllProfiles() async {
    final predefined = getPredefinedProfiles();
    final customProfiles = <EnvironmentProfile>[];

    for (final key in _box.keys.toList()) {
      if (key is! String) continue;
      if (_predefinedNames.contains(key)) continue;
      try {
        final raw = _box.get(key);
        if (raw == null) continue;
        final profile = await _hydrateLegacyProfile(key, raw);
        if (profile != null) {
          customProfiles.add(profile);
        }
      } catch (e) {
        developer.log(
          'ProfileRepositoryImpl.getAllProfiles: error al cargar '
          '"$key": $e',
          name: 'ProfileRepositoryImpl',
          level: 900,
        );
      }
    }

    return [...predefined, ...customProfiles];
  }

  @override
  Future<EnvironmentProfile?> getProfileByName(String name) async {
    // Buscar primero en predefinidos.
    for (final profile in EnvironmentProfile.predefinedProfiles) {
      if (profile.name == name) return profile;
    }

    final raw = _box.get(name);
    if (raw == null) return null;
    return _hydrateLegacyProfile(name, raw);
  }

  @override
  Future<List<CustomPresetRecord>> getCustomPresets() async {
    final out = <CustomPresetRecord>[];
    for (final key in _box.keys.toList()) {
      if (key is! String) continue;
      if (_predefinedNames.contains(key)) continue;
      final record = await _loadCustomPresetRecord(key);
      if (record != null) {
        out.add(record);
      }
    }
    return out;
  }

  @override
  Future<CustomPresetRecord?> getCustomPresetByName(String name) async {
    if (_predefinedNames.contains(name)) return null;
    return _loadCustomPresetRecord(name);
  }

  @override
  Future<void> saveCustomProfile({
    required String name,
    required Audiogram audiogram,
    required AudiogramDrivenBundle bundle,
    String appliedStyleName = '',
    int nrOverride = 0,
    ManualAdjustmentDelta? manualDelta,
    DateTime? createdAt,
  }) async {
    if (_predefinedNames.contains(name)) {
      throw StateError(
        'No se puede guardar un preset personalizado con el nombre '
        'reservado "$name" (predefinido).',
      );
    }

    // Capturar el blob previo para no pisarlo si la validación falla.
    final previousRaw = _box.get(name);

    final record = CustomPresetRecord(
      name: name,
      audiogram: audiogram,
      bundle: bundle,
      appliedStyleName: appliedStyleName,
      nrOverride: nrOverride,
      manualDelta: manualDelta,
      createdAt: createdAt ?? DateTime.now().toUtc(),
    );

    // Validación estructural antes de tocar Hive (Req 8.5).
    final violations = record.validate();
    if (violations.isNotEmpty) {
      throw StateError(
        'CustomPresetRecord inválido: ${violations.join('; ')}',
      );
    }

    final encoded = jsonEncode(record.toJson());
    if (encoded.codeUnits.length > CustomPresetRecord.maxBlobSizeBytes) {
      throw StateError(
        'Custom preset blob exceeds ${CustomPresetRecord.maxBlobSizeBytes} '
        'bytes (got ${encoded.codeUnits.length}). Preset "$name" no '
        'guardado; el blob previo se preserva sin cambios.',
      );
    }

    try {
      await _box.put(name, encoded);
    } catch (e) {
      // Restaurar el blob previo si la escritura falla parcialmente.
      if (previousRaw != null) {
        try {
          await _box.put(name, previousRaw);
        } catch (_) {
          // Persistencia tolerante: si el rollback falla también,
          // mantenemos el log y propagamos la excepción original.
        }
      }
      rethrow;
    }
  }

  @override
  @Deprecated(
    'Usar saveCustomProfile(name:, audiogram:, bundle:, ...) con el '
    'contexto clínico completo. La API legacy se mantiene sólo para '
    'callers en transición y no preserva el bundle ni el audiograma.',
  )
  Future<void> saveLegacyCustomProfile(EnvironmentProfile profile) async {
    if (_predefinedNames.contains(profile.name)) {
      throw StateError(
        'No se puede guardar un preset personalizado con el nombre '
        'reservado "${profile.name}" (predefinido).',
      );
    }
    final data = _serializeLegacy(profile);
    await _box.put(profile.name, data);
  }

  @override
  Future<void> deleteCustomProfile(String name) async {
    if (isPredefined(name)) return; // No eliminar predefinidos (Req 8.6).
    await _box.delete(name);
  }

  @override
  Future<List<String>> markCustomPresetsAsStale(
    Audiogram newAudiogram, {
    double thresholdDb = 5.0,
  }) async {
    final failed = <String>[];

    for (final key in _box.keys.toList()) {
      if (key is! String) continue;
      if (_predefinedNames.contains(key)) continue;

      try {
        final record = await _loadCustomPresetRecord(key);
        if (record == null) {
          // Blob corrupto: ya se reportó como warning en
          // `_loadCustomPresetRecord`. Lo agregamos a la lista de
          // fallidos para que el bloc pueda informar al usuario.
          failed.add(key);
          _warningsController.add(
            ProfileRepositoryWarning(
              type: ProfileRepositoryWarningType.staleUpdateFailed,
              presetName: key,
              message:
                  'Preset "$key" corrupto: no se pudo marcar como obsoleto.',
            ),
          );
          continue;
        }

        final shouldMarkStale = _audiogramMadExceeds(
          record.audiogram,
          newAudiogram,
          thresholdDb,
        );
        if (!shouldMarkStale) continue;
        if (record.stale) continue; // Ya estaba marcado.

        final updated = record.copyWith(stale: true);
        await _box.put(key, jsonEncode(updated.toJson()));
      } catch (e, st) {
        developer.log(
          'ProfileRepositoryImpl.markCustomPresetsAsStale: error en '
          '"$key": $e',
          name: 'ProfileRepositoryImpl',
          level: 1000,
          error: e,
          stackTrace: st,
        );
        failed.add(key);
        _warningsController.add(
          ProfileRepositoryWarning(
            type: ProfileRepositoryWarningType.staleUpdateFailed,
            presetName: key,
            message: 'No se pudo marcar "$key" como obsoleto: $e',
          ),
        );
      }
    }

    return failed;
  }

  @override
  Future<void> regenerateCustomPreset(
    String name, {
    required Audiogram audiogram,
    required PrescriptionMode mode,
    PatientProfile? profile,
  }) async {
    if (_predefinedNames.contains(name)) {
      throw StateError(
        'No se puede regenerar el preset predefinido "$name".',
      );
    }

    // Capturar el blob previo. Si la regeneración falla, el rollback
    // restaura este valor exacto en Hive (Req 9.6).
    final previousRaw = _box.get(name);
    if (previousRaw == null) {
      throw StateError(
        'El preset "$name" no existe; no se puede regenerar.',
      );
    }

    // Cargar el record actual para preservar appliedStyleName,
    // nrOverride, createdAt y manualDelta originales.
    final current = await _loadCustomPresetRecord(name);
    if (current == null) {
      throw StateError(
        'El preset "$name" está corrupto; no se puede regenerar.',
      );
    }

    AudiogramDrivenBundle newBundle;
    try {
      // 1. Construir bundle base desde el audiograma actual.
      final base = _bundleBuilder.buildFromAudiogram(
        audiogram,
        profile: profile,
        mode: mode,
        operatingMode: current.bundle.mode,
        gainScale: current.bundle.gainScale,
      );

      // 2. Aplicar el estilo original (si existe).
      if (current.appliedStyleName.isNotEmpty &&
          current.appliedStyleName != StyleApplicator.styleNormal) {
        newBundle = StyleApplicator.applyStyle(
          base,
          current.appliedStyleName,
        );
      } else {
        newBundle = base;
      }
    } catch (e, st) {
      developer.log(
        'ProfileRepositoryImpl.regenerateCustomPreset("$name"): '
        'fallo en BundleBuilder/StyleApplicator: $e',
        name: 'ProfileRepositoryImpl',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      // Rollback implícito: nunca tocamos el blob.
      rethrow;
    }

    final regenerated = current.copyWith(
      audiogram: audiogram,
      bundle: newBundle,
      stale: false,
    );

    // Validar antes de persistir.
    final violations = regenerated.validate();
    if (violations.isNotEmpty) {
      throw StateError(
        'CustomPresetRecord regenerado inválido: ${violations.join('; ')}',
      );
    }

    final encoded = jsonEncode(regenerated.toJson());
    if (encoded.codeUnits.length > CustomPresetRecord.maxBlobSizeBytes) {
      throw StateError(
        'Regenerated custom preset blob excede '
        '${CustomPresetRecord.maxBlobSizeBytes} bytes; rollback aplicado.',
      );
    }

    try {
      await _box.put(name, encoded);
    } catch (e) {
      // Rollback explícito al blob previo si la escritura falla.
      try {
        await _box.put(name, previousRaw);
      } catch (_) {
        // Persistencia tolerante: si el rollback falla, propagamos la
        // excepción original.
      }
      rethrow;
    }
  }

  @override
  bool isPredefined(String name) {
    return _predefinedNames.contains(name);
  }

  @override
  Future<void> dispose() async {
    if (!_warningsController.isClosed) {
      await _warningsController.close();
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // Helpers privados
  // ─────────────────────────────────────────────────────────────────────

  /// Carga un blob de Hive como [CustomPresetRecord], aplicando:
  /// - migración de schema legacy → recomputa el bundle desde el
  ///   audiograma + estilo + override (Req 8.4);
  /// - validación estructural y de rango → presets corruptos se
  ///   reportan vía [warnings] y se excluyen retornando `null` (Req 8.5).
  Future<CustomPresetRecord?> _loadCustomPresetRecord(String name) async {
    final raw = _box.get(name);
    if (raw == null) return null;

    try {
      final json = _normalizeRawBlob(raw);
      if (json == null) return null;

      final version = json['schemaVersion'];
      CustomPresetRecord record;
      bool migrated = false;

      if (version is String && version == CustomPresetRecord.schemaVersion) {
        // Schema actual: deserializar tal cual.
        try {
          record = CustomPresetRecord.fromJson(json);
        } on FormatException catch (e) {
          _emitCorruptWarning(name, ['fromJson: ${e.message}']);
          return null;
        }
      } else {
        // Schema legacy o ausente: intentar migración (Req 8.4).
        final maybeMigrated = await _migrateLegacyBlob(name, json);
        if (maybeMigrated == null) return null;
        record = maybeMigrated;
        migrated = true;
      }

      // Validación final del record.
      final violations = record.validate();
      if (violations.isNotEmpty) {
        _emitCorruptWarning(name, violations);
        return null;
      }

      if (migrated) {
        // Persistir el blob migrado y emitir la advertencia.
        try {
          await _box.put(name, jsonEncode(record.toJson()));
        } catch (e) {
          developer.log(
            'ProfileRepositoryImpl: persistencia del preset migrado '
            '"$name" falló: $e',
            name: 'ProfileRepositoryImpl',
            level: 900,
          );
        }
        _warningsController.add(
          ProfileRepositoryWarning(
            type: ProfileRepositoryWarningType.migrated,
            presetName: name,
            message:
                'Preset "$name" migrado al schema actual '
                '(${CustomPresetRecord.schemaVersion}).',
          ),
        );
      }

      return record;
    } catch (e, st) {
      developer.log(
        'ProfileRepositoryImpl._loadCustomPresetRecord("$name"): $e',
        name: 'ProfileRepositoryImpl',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      _emitCorruptWarning(name, ['load failed: $e']);
      return null;
    }
  }

  /// Acepta tanto strings (blob nuevo) como Maps (blob legacy /
  /// versiones tempranas que escribían el `Map<String, dynamic>`
  /// directo) y retorna un `Map<String, dynamic>` listo para
  /// procesar. `null` cuando el shape es irreconocible.
  Map<String, dynamic>? _normalizeRawBlob(dynamic raw) {
    if (raw is String) {
      if (raw.isEmpty) return null;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } on FormatException {
        return null;
      }
    } else if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    return null;
  }

  /// Hidrata un blob legacy a un [CustomPresetRecord] reconstruyendo
  /// el bundle desde:
  /// - el audiograma persistido en el preset (si existe), o
  /// - el bundle "vacío" derivado del [Audiogram.defaultAudiogram]
  ///   cuando el blob legacy no incluye audiograma (preset
  ///   `EnvironmentProfile`-only de versiones muy viejas).
  ///
  /// Si la reconstrucción falla la advertencia de corrupción se emite
  /// y se retorna `null`.
  Future<CustomPresetRecord?> _migrateLegacyBlob(
    String name,
    Map<String, dynamic> json,
  ) async {
    try {
      // Guarda de validación: un blob "legacy" legítimo tiene al menos
      // un campo identificable de algún schema previo soportado
      // (audiograma, ganancias de EQ, perfil, nombre). Si solo trae
      // `schemaVersion` (o ningún campo conocido), no es legacy: es
      // un blob corrupto o de un schema futuro no soportado, y se
      // reporta como tal en lugar de inventar valores default.
      const legacyMarkers = {
        'audiogram',
        'thresholds',
        'eqGains',
        'gains',
        'gainsDb',
        'name',
        'profile',
        'environmentProfile',
        'preset',
        'bundle',
      };
      final hasLegacyMarker = json.keys.any(legacyMarkers.contains);
      if (!hasLegacyMarker) {
        _emitCorruptWarning(
          name,
          [
            'unknown schemaVersion '
                '"${json['schemaVersion']}" sin campos legacy reconocibles'
          ],
        );
        return null;
      }

      // Detectar audiograma persistido. Schemas legacy pueden tenerlo
      // como Map directo o como sub-mapa con clave `thresholds`.
      Audiogram audiogram;
      final audiogramRaw = json['audiogram'];
      if (audiogramRaw is Map) {
        try {
          audiogram = _parseAudiogramMap(
            Map<String, dynamic>.from(audiogramRaw),
          );
        } catch (_) {
          audiogram = Audiogram.defaultAudiogram();
        }
      } else {
        // Versión legacy `EnvironmentProfile`-only: usar el audiograma
        // default como base. La advertencia "Migrado" alerta al
        // usuario; el preset luego puede regenerarse contra el
        // audiograma actual del paciente.
        audiogram = Audiogram.defaultAudiogram();
      }

      final appliedStyleName = json['appliedStyleName'] is String
          ? json['appliedStyleName'] as String
          : '';
      final nrOverrideRaw = json['nrOverride'];
      final nrOverride =
          nrOverrideRaw is num ? nrOverrideRaw.toInt() : 0;
      final createdAtRaw = json['createdAt'];
      final createdAt = createdAtRaw is String
          ? DateTime.parse(createdAtRaw).toUtc()
          : DateTime.now().toUtc();

      // Reconstruir el bundle base. La PrescriptionMode default queda
      // en `quiet` (mismo default del bloc cuando no hay perfil
      // activo). El estilo se aplica después si está disponible.
      final base = _bundleBuilder.buildFromAudiogram(
        audiogram,
        mode: PrescriptionMode.quiet,
      );
      final bundle = appliedStyleName.isNotEmpty &&
              appliedStyleName != StyleApplicator.styleNormal
          ? StyleApplicator.applyStyle(base, appliedStyleName)
          : base;

      ManualAdjustmentDelta? manualDelta;
      final deltaRaw = json['manualDelta'];
      if (deltaRaw is Map) {
        try {
          manualDelta = ManualAdjustmentDelta.fromJson(
            Map<String, dynamic>.from(deltaRaw),
          );
        } catch (_) {
          manualDelta = null;
        }
      }

      return CustomPresetRecord(
        name: name,
        audiogram: audiogram,
        bundle: bundle,
        appliedStyleName: appliedStyleName,
        nrOverride: nrOverride,
        manualDelta: manualDelta,
        createdAt: createdAt,
        migrated: true,
      );
    } catch (e, st) {
      developer.log(
        'ProfileRepositoryImpl._migrateLegacyBlob("$name"): '
        'fallo en migración: $e',
        name: 'ProfileRepositoryImpl',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      _emitCorruptWarning(name, ['migration failed: $e']);
      return null;
    }
  }

  /// Hidrata un preset como [EnvironmentProfile] desde el blob nuevo
  /// (vista legacy) o desde el blob legacy (Map directo). Aplica el
  /// pipeline de migración + validación: presets corruptos retornan
  /// `null` y emiten advertencia.
  Future<EnvironmentProfile?> _hydrateLegacyProfile(
    String name,
    dynamic raw,
  ) async {
    final json = _normalizeRawBlob(raw);
    if (json == null) return null;

    // Si tiene schemaVersion actual, leer el record validado y
    // proyectar a EnvironmentProfile.
    final version = json['schemaVersion'];
    if (version is String && version == CustomPresetRecord.schemaVersion) {
      try {
        final record = CustomPresetRecord.fromJson(json);
        if (record.validate().isNotEmpty) return null;
        return _legacyProfileFromRecord(record);
      } catch (_) {
        return null;
      }
    }

    // Schema legacy: usar campos del blob directamente.
    return _legacyProfileFromRawMap(name, json);
  }

  /// Proyecta un [CustomPresetRecord] a un [EnvironmentProfile] usando
  /// la vista legacy del bundle (broadband averages).
  EnvironmentProfile _legacyProfileFromRecord(CustomPresetRecord record) {
    double sumCr = 0;
    for (final cr in record.bundle.compressionRatios) {
      sumCr += cr;
    }
    final avgCr = record.bundle.compressionRatios.isEmpty
        ? 1.0
        : sumCr / record.bundle.compressionRatios.length;
    double sumKnee = 0;
    for (final k in record.bundle.compressionKneesDbSpl) {
      sumKnee += k;
    }
    final avgKnee = record.bundle.compressionKneesDbSpl.isEmpty
        ? 50.0
        : sumKnee / record.bundle.compressionKneesDbSpl.length;
    return EnvironmentProfile(
      name: record.name,
      nrLevel: record.bundle.nrLevel,
      compressionRatio: avgCr,
      expansionKnee: record.bundle.expansionKneeDbSpl,
      compressionKnee: avgKnee,
    );
  }

  /// Hidrata un perfil legacy (Map de Hive viejo, o blob nuevo con
  /// vista legacy) a un [EnvironmentProfile]. Tolera campos faltantes
  /// con defaults sensatos.
  EnvironmentProfile _legacyProfileFromRawMap(
    String name,
    Map<String, dynamic> map,
  ) {
    return EnvironmentProfile(
      name: map['name'] is String ? map['name'] as String : name,
      nrLevel: map['nrLevel'] is num ? (map['nrLevel'] as num).toInt() : 1,
      compressionRatio: map['compressionRatio'] is num
          ? (map['compressionRatio'] as num).toDouble()
          : 1.5,
      expansionKnee: map['expansionKnee'] is num
          ? (map['expansionKnee'] as num).toDouble()
          : 35.0,
      compressionKnee: map['compressionKnee'] is num
          ? (map['compressionKnee'] as num).toDouble()
          : 50.0,
    );
  }

  /// Lee el sub-mapa `thresholds` de un audiograma persistido al estilo
  /// `AudiogramRepositoryImpl` (claves String → double).
  Audiogram _parseAudiogramMap(Map<String, dynamic> json) {
    final raw = json['thresholds'];
    if (raw is! Map) {
      throw const FormatException(
        'Audiogram persistido sin "thresholds".',
      );
    }
    final thresholds = <int, double>{};
    raw.forEach((key, value) {
      final freq = key is int ? key : int.parse(key.toString());
      final hl = (value as num).toDouble();
      thresholds[freq] = hl;
    });
    return Audiogram(thresholds: thresholds);
  }

  /// Calcula la MAD por banda entre dos audiogramas. Retorna `true` si
  /// alguna banda excede [thresholdDb] (Req 9.2).
  bool _audiogramMadExceeds(
    Audiogram a,
    Audiogram b,
    double thresholdDb,
  ) {
    for (final f in Audiogram.standardFrequencies) {
      final av = a.thresholds[f];
      final bv = b.thresholds[f];
      if (av == null || bv == null) return true;
      if ((av - bv).abs() > thresholdDb) return true;
    }
    return false;
  }

  /// Emite una advertencia de corrupción para el preset [name].
  void _emitCorruptWarning(String name, List<String> violations) {
    _warningsController.add(
      ProfileRepositoryWarning(
        type: ProfileRepositoryWarningType.corrupt,
        presetName: name,
        message:
            'Preset "$name" descartado por validación: '
            '${violations.join('; ')}',
        violations: List<String>.unmodifiable(violations),
      ),
    );
  }

  /// Serializa un [EnvironmentProfile] al shape legacy almacenable en
  /// Hive (mantenido sólo para `saveLegacyCustomProfile`).
  Map<String, dynamic> _serializeLegacy(EnvironmentProfile profile) {
    return {
      'name': profile.name,
      'nrLevel': profile.nrLevel,
      'compressionRatio': profile.compressionRatio,
      'expansionKnee': profile.expansionKnee,
      'compressionKnee': profile.compressionKnee,
    };
  }
}

import 'package:hive/hive.dart';

import '../../domain/entities/audiogram.dart';
import '../../domain/repositories/audiogram_repository.dart';

/// Nombre del Hive box para audiogramas.
const String audiogramBoxName = 'audiogram_box';

/// Clave para el audiograma del usuario en el box.
const String _audiogramKey = 'user_audiogram';

/// Implementación del repositorio de audiograma usando Hive.
///
/// Almacena el audiograma como un Map<String, dynamic> serializado
/// manualmente (sin code generation). Los umbrales se guardan como
/// un mapa de frecuencia (String) a umbral (double).
///
/// Requisitos: 4.1
class AudiogramRepositoryImpl implements AudiogramRepository {
  final Box<dynamic> _box;

  AudiogramRepositoryImpl(this._box);

  /// Abre el box de Hive para audiogramas.
  static Future<Box<dynamic>> openBox() async {
    return Hive.openBox(audiogramBoxName);
  }

  @override
  Future<Audiogram?> getAudiogram() async {
    final data = _box.get(_audiogramKey);
    if (data == null) return null;
    return _deserialize(data);
  }

  @override
  Future<void> saveAudiogram(Audiogram audiogram) async {
    final data = _serialize(audiogram);
    await _box.put(_audiogramKey, data);
  }

  @override
  Future<void> deleteAudiogram() async {
    await _box.delete(_audiogramKey);
  }

  @override
  Future<bool> hasAudiogram() async {
    return _box.containsKey(_audiogramKey);
  }

  /// Serializa un Audiogram a un Map almacenable en Hive.
  Map<String, dynamic> _serialize(Audiogram audiogram) {
    // Convertir Map<int, double> a Map<String, double> para Hive
    final thresholdsMap = <String, double>{};
    for (final entry in audiogram.thresholds.entries) {
      thresholdsMap[entry.key.toString()] = entry.value;
    }
    return {
      'thresholds': thresholdsMap,
    };
  }

  /// Deserializa un Map de Hive a un Audiogram.
  Audiogram _deserialize(dynamic data) {
    final map = Map<String, dynamic>.from(data as Map);
    final thresholdsRaw = Map<String, dynamic>.from(map['thresholds'] as Map);
    final thresholds = <int, double>{};
    for (final entry in thresholdsRaw.entries) {
      thresholds[int.parse(entry.key)] = (entry.value as num).toDouble();
    }
    return Audiogram(thresholds: thresholds);
  }
}

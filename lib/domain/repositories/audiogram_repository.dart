import '../entities/audiogram.dart';

/// Interfaz del repositorio de audiograma.
///
/// Define las operaciones CRUD para almacenar y recuperar
/// el audiograma del usuario.
///
/// Requisitos: 4.1
abstract class AudiogramRepository {
  /// Obtiene el audiograma almacenado del usuario.
  /// Retorna null si no hay audiograma guardado.
  Future<Audiogram?> getAudiogram();

  /// Guarda el audiograma del usuario.
  Future<void> saveAudiogram(Audiogram audiogram);

  /// Elimina el audiograma almacenado.
  Future<void> deleteAudiogram();

  /// Verifica si existe un audiograma almacenado.
  Future<bool> hasAudiogram();
}

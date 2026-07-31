import '../entities/qc_audit_record.dart';

/// Repositorio de auditoría QC (Tramo 3 — Prescription → Hearing aid).
///
/// Persiste los `QcAuditRecord` en `audit_trail_box` (Hive) bajo una clave
/// derivada del timestamp ISO-8601 (orden lexicográfico = orden cronológico)
/// y genera artefactos PDF para el release approval (Req 15.14, 15.15, 16.4).
///
/// Contrato:
/// - `append`: agrega un nuevo record sin sobreescribir los existentes.
///   La clave es `record.storageKey` (timestamp UTC ISO-8601).
/// - `getAll`: devuelve todos los records ordenados por fecha ascendente.
/// - `generatePdf`: produce los bytes de un PDF que documenta la sesión
///   (header con operador/equipamiento/fecha + tabla de mediciones +
///   summary pass/fail + bloque de firma).
abstract class QcAuditRepository {
  /// Persiste un nuevo record en el audit trail.
  ///
  /// Lanza `StateError` si ya existe un record con el mismo `storageKey`
  /// (timestamp duplicado al microsegundo).
  Future<void> append(QcAuditRecord record);

  /// Devuelve todos los records del audit trail ordenados por timestamp
  /// ascendente.
  Future<List<QcAuditRecord>> getAll();

  /// Genera un PDF firmable a partir del record.
  ///
  /// Devuelve los bytes del PDF (magic header `%PDF-`). Los bytes pueden
  /// ser persistidos al filesystem por el caller usando `path_provider`,
  /// o adjuntados a un email / firma digital.
  Future<List<int>> generatePdf(QcAuditRecord record);
}

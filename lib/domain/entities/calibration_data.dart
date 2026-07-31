import 'package:equatable/equatable.dart';

/// Resultado de la calibración del micrófono.
///
/// Almacena el offset calculado para convertir niveles digitales (dBFS)
/// a niveles de presión sonora reales (dB SPL).
///
/// Fórmula: dB SPL = dBFS + splOffset
class MicCalibrationResult extends Equatable {
  /// Offset dBFS → dB SPL calculado durante la calibración.
  /// Default sin calibración: 120 (micrófono MEMS típico).
  final double splOffset;

  /// Nivel de confianza de la medición (0.0 a 1.0).
  /// 1.0 = calibración con referencia externa verificada.
  /// 0.5 = estimación por modelo de teléfono.
  /// 0.3 = auto-test con tono interno.
  final double confidenceLevel;

  /// Método utilizado para la calibración.
  /// Valores: 'external_ref', 'phone_model', 'self_test'.
  final String method;

  /// Fecha y hora de la calibración.
  final DateTime calibratedAt;

  /// Modelo del teléfono calibrado.
  final String deviceModel;

  const MicCalibrationResult({
    required this.splOffset,
    required this.confidenceLevel,
    required this.method,
    required this.calibratedAt,
    required this.deviceModel,
  });

  @override
  List<Object?> get props => [
        splOffset,
        confidenceLevel,
        method,
        calibratedAt,
        deviceModel,
      ];
}

/// Resultado de la calibración de auriculares (BT o cable).
///
/// Almacena la respuesta en frecuencia medida del auricular y la
/// compensación calculada para aplanar dicha respuesta.
class HeadphoneCalibrationResult extends Equatable {
  /// Respuesta en frecuencia medida: freq Hz → dB relativo a 1 kHz.
  final Map<int, double> frequencyResponse;

  /// Compensación calculada: freq Hz → dB de ajuste para aplanar.
  /// compensation[f] = -frequencyResponse[f]
  final Map<int, double> compensation;

  /// Identificador del auricular (dirección MAC BT o "wired_default").
  final String headphoneId;

  /// Nombre del dispositivo Bluetooth (o "Wired" para cable).
  final String headphoneName;

  /// Fecha y hora de la calibración.
  final DateTime calibratedAt;

  /// Indica si el auricular es Bluetooth (true) o con cable (false).
  final bool isBluetooth;

  const HeadphoneCalibrationResult({
    required this.frequencyResponse,
    required this.compensation,
    required this.headphoneId,
    required this.headphoneName,
    required this.calibratedAt,
    required this.isBluetooth,
  });

  @override
  List<Object?> get props => [
        frequencyResponse,
        compensation,
        headphoneId,
        headphoneName,
        calibratedAt,
        isBluetooth,
      ];
}

/// Datos de calibración del sistema (micrófono + auriculares).
///
/// Almacena la calibración del micrófono y las calibraciones de
/// múltiples auriculares (identificados por MAC BT o "wired_default").
///
/// Requisitos: Calibración del Sistema
class CalibrationData extends Equatable {
  /// Resultado de calibración del micrófono (null si no calibrado).
  final MicCalibrationResult? micCalibration;

  /// Calibraciones de auriculares por identificador.
  /// Key: dirección MAC BT o "wired_default".
  final Map<String, HeadphoneCalibrationResult> headphoneCalibrations;

  const CalibrationData({
    this.micCalibration,
    this.headphoneCalibrations = const {},
  });

  /// Obtiene la compensación para el auricular actualmente conectado.
  ///
  /// [btMac] Dirección MAC del auricular BT conectado, o null para cable.
  HeadphoneCalibrationResult? getActiveHeadphoneCalibration(String? btMac) {
    if (btMac != null) return headphoneCalibrations[btMac];
    return headphoneCalibrations['wired_default'];
  }

  /// Offset SPL efectivo (calibrado o default de 120 dB).
  double get effectiveSplOffset => micCalibration?.splOffset ?? 120.0;

  @override
  List<Object?> get props => [micCalibration, headphoneCalibrations];
}

/// Smart Scene Engine — Fase 1
/// Modelo Dart espejo del struct C++ `smart_scene::SceneSnapshot`.
///
/// El layout binario está definido en
/// `android/app/src/main/cpp/smart_scene/scene_types.h` con `#pragma pack(1)`
/// y debe mantenerse sincronizado: cualquier cambio acá requiere actualizar
/// el header C++ y viceversa.
///
/// Validates: Requirements 1.1, 6.2

import 'dart:typed_data';

/// Cantidad de bandas EQ usadas para el perfil de ruido — coincide con
/// `kSceneNumBands` en `scene_types.h`.
const int kSceneNumBands = 12;

/// Tamaño total del snapshot en bytes — debe coincidir con
/// `sizeof(SceneSnapshot)` en C++.
///
/// 8  (timestamp_us)
/// + 4*3  (input/noise/snr)
/// + 4*2  (vad_score, vad_confidence)
/// + 4    (voice_active + hangover + stationarity_q8 + mid_snr_q8)
/// + 4*7  (tilt/centroid/flatness/flux + low/mid/high)
/// + 4*12 (noise_per_band_db)
/// + 4    (impulse_count + 2 bytes padding)
/// + 4    (scene_class + 3 bytes padding)
/// + 4    (scene_confidence)
/// = 120 bytes
const int kSceneSnapshotBytes = 120;

/// Clases de escena — refleja el enum C++ `SceneClass`.
/// El orden es contractual con C++.
enum SceneClass {
  unknown,
  silence,
  voiceOnly,
  voiceInNoiseLow,
  voiceInNoiseMid,
  noiseLowDominant,
  noiseHighDominant,
  music,
}

SceneClass _sceneClassFromByte(int raw) {
  if (raw < 0 || raw >= SceneClass.values.length) return SceneClass.unknown;
  return SceneClass.values[raw];
}

/// Etiqueta corta legible para una clase de escena (Español).
String sceneClassLabel(SceneClass c) {
  switch (c) {
    case SceneClass.unknown:
      return 'Indeterminado';
    case SceneClass.silence:
      return 'Silencio';
    case SceneClass.voiceOnly:
      return 'Voz';
    case SceneClass.voiceInNoiseLow:
      return 'Voz + ruido grave';
    case SceneClass.voiceInNoiseMid:
      return 'Voz + ruido medio';
    case SceneClass.noiseLowDominant:
      return 'Ruido grave';
    case SceneClass.noiseHighDominant:
      return 'Ruido agudo';
    case SceneClass.music:
      return 'Música';
  }
}

/// Snapshot inmutable de las métricas computadas por el SceneAnalyzer C++.
class SceneSnapshot {
  final int timestampUs;
  final double inputDbSpl;
  final double noiseFloorDbSpl;
  final double snrDb;

  // VAD
  final double vadScore;
  final double vadConfidence;
  final bool voiceActive;
  final bool vadHangoverActive;
  final double vadStationarity; // [0, 1]
  final double vadMidSnrDb;      // [0, 30] dB

  // Espectral
  final double spectralTiltDb;
  final double spectralCentroidHz;
  final double spectralFlatness;
  final double spectralFlux;
  final double lowBandEnergyDb;
  final double midBandEnergyDb;
  final double highBandEnergyDb;

  // Perfil de ruido por banda
  final List<double> noisePerBandDb;

  // Eventos
  final int impulseCount;

  // Clasificación (Fase 1: siempre unknown)
  final SceneClass sceneClass;
  final double sceneConfidence;

  const SceneSnapshot({
    required this.timestampUs,
    required this.inputDbSpl,
    required this.noiseFloorDbSpl,
    required this.snrDb,
    required this.vadScore,
    required this.vadConfidence,
    required this.voiceActive,
    required this.vadHangoverActive,
    required this.vadStationarity,
    required this.vadMidSnrDb,
    required this.spectralTiltDb,
    required this.spectralCentroidHz,
    required this.spectralFlatness,
    required this.spectralFlux,
    required this.lowBandEnergyDb,
    required this.midBandEnergyDb,
    required this.highBandEnergyDb,
    required this.noisePerBandDb,
    required this.impulseCount,
    required this.sceneClass,
    required this.sceneConfidence,
  });

  /// Snapshot vacío — usado cuando todavía no hay datos del engine.
  factory SceneSnapshot.empty() {
    return SceneSnapshot(
      timestampUs: 0,
      inputDbSpl: 0.0,
      noiseFloorDbSpl: -90.0,
      snrDb: 0.0,
      vadScore: 0.0,
      vadConfidence: 0.0,
      voiceActive: false,
      vadHangoverActive: false,
      vadStationarity: 0.0,
      vadMidSnrDb: 0.0,
      spectralTiltDb: 0.0,
      spectralCentroidHz: 0.0,
      spectralFlatness: 1.0,
      spectralFlux: 0.0,
      lowBandEnergyDb: -90.0,
      midBandEnergyDb: -90.0,
      highBandEnergyDb: -90.0,
      noisePerBandDb: List<double>.filled(kSceneNumBands, -90.0),
      impulseCount: 0,
      sceneClass: SceneClass.unknown,
      sceneConfidence: 0.0,
    );
  }

  /// Parsea bytes provenientes del JNI (`ByteArray`).
  ///
  /// El engine devuelve un array vacío cuando no está activo: en ese caso
  /// retornamos `null` y el llamador debe usar `SceneSnapshot.empty()`.
  static SceneSnapshot? fromBytes(List<int> raw) {
    if (raw.length < kSceneSnapshotBytes) {
      return null;
    }
    final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
    final data = ByteData.sublistView(bytes);
    // Layout (little endian, packed):
    int offset = 0;
    int readU64() {
      final v = data.getUint64(offset, Endian.little);
      offset += 8;
      return v;
    }

    double readF32() {
      final v = data.getFloat32(offset, Endian.little);
      offset += 4;
      return v;
    }

    int readU16() {
      final v = data.getUint16(offset, Endian.little);
      offset += 2;
      return v;
    }

    int readU8() {
      final v = data.getUint8(offset);
      offset += 1;
      return v;
    }

    void skip(int n) {
      offset += n;
    }

    final timestampUs = readU64();
    final inputDb = readF32();
    final noiseFloorDb = readF32();
    final snrDb = readF32();
    final vadScore = readF32();
    final vadConfidence = readF32();
    final voiceFlag = readU8();
    final hangoverFlag = readU8();
    final stationarityQ8 = readU8();
    final midSnrQ8 = readU8();
    final tilt = readF32();
    final centroid = readF32();
    final flatness = readF32();
    final flux = readF32();
    final lowDb = readF32();
    final midDb = readF32();
    final highDb = readF32();
    final bands = <double>[];
    for (int i = 0; i < kSceneNumBands; ++i) {
      bands.add(readF32());
    }
    final impulse = readU16();
    skip(2); // padding _pad1
    final classByte = readU8();
    skip(3); // padding _pad2
    final confidence = readF32();

    return SceneSnapshot(
      timestampUs: timestampUs,
      inputDbSpl: inputDb,
      noiseFloorDbSpl: noiseFloorDb,
      snrDb: snrDb,
      vadScore: vadScore,
      vadConfidence: vadConfidence,
      voiceActive: voiceFlag != 0,
      vadHangoverActive: hangoverFlag != 0,
      vadStationarity: stationarityQ8 / 255.0,
      vadMidSnrDb: (midSnrQ8 / 255.0) * 30.0,
      spectralTiltDb: tilt,
      spectralCentroidHz: centroid,
      spectralFlatness: flatness,
      spectralFlux: flux,
      lowBandEnergyDb: lowDb,
      midBandEnergyDb: midDb,
      highBandEnergyDb: highDb,
      noisePerBandDb: List<double>.unmodifiable(bands),
      impulseCount: impulse,
      sceneClass: _sceneClassFromByte(classByte),
      sceneConfidence: confidence,
    );
  }
}

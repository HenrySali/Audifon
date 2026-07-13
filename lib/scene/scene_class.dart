/// Smart Scene Engine — Fase 2.
///
/// Re-exporta `SceneClass` desde `scene_snapshot.dart` (para evitar romper
/// imports existentes) y agrega métodos auxiliares para la UI: label legible,
/// icono Material y descripción larga.
///
/// Validates: Requirements 1.1

import 'package:flutter/material.dart';

import 'scene_snapshot.dart' show SceneClass;

export 'scene_snapshot.dart' show SceneClass, sceneClassLabel;

/// Helpers para mostrar una clase de escena en la UI.
extension SceneClassUi on SceneClass {
  /// Etiqueta corta legible en español rioplatense.
  String get label {
    switch (this) {
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

  /// Descripción larga para tooltip o detalle.
  String get description {
    switch (this) {
      case SceneClass.unknown:
        return 'Aún no hay datos suficientes para clasificar.';
      case SceneClass.silence:
        return 'Ambiente muy tranquilo, sin voz ni ruido relevante.';
      case SceneClass.voiceOnly:
        return 'Voz limpia, ideal para conversación.';
      case SceneClass.voiceInNoiseLow:
        return 'Voz con ruido grave de fondo (subte, motores).';
      case SceneClass.voiceInNoiseMid:
        return 'Voz con ruido medio (oficina, bar, restaurante).';
      case SceneClass.noiseLowDominant:
        return 'Ruido grave dominante sin voz (calle, metro).';
      case SceneClass.noiseHighDominant:
        return 'Ruido agudo dominante (viento, lluvia, agua).';
      case SceneClass.music:
        return 'Música u otro contenido armónico estable.';
    }
  }

  /// Icono Material apropiado para cada clase.
  IconData get icon {
    switch (this) {
      case SceneClass.unknown:
        return Icons.help_outline;
      case SceneClass.silence:
        return Icons.volume_off;
      case SceneClass.voiceOnly:
        return Icons.record_voice_over;
      case SceneClass.voiceInNoiseLow:
        return Icons.directions_subway;
      case SceneClass.voiceInNoiseMid:
        return Icons.local_cafe;
      case SceneClass.noiseLowDominant:
        return Icons.traffic;
      case SceneClass.noiseHighDominant:
        return Icons.air;
      case SceneClass.music:
        return Icons.music_note;
    }
  }

  /// Color de acento para la UI.
  Color get color {
    switch (this) {
      case SceneClass.unknown:
        return Colors.grey;
      case SceneClass.silence:
        return Colors.blueGrey;
      case SceneClass.voiceOnly:
        return Colors.greenAccent;
      case SceneClass.voiceInNoiseLow:
        return Colors.amberAccent;
      case SceneClass.voiceInNoiseMid:
        return Colors.orangeAccent;
      case SceneClass.noiseLowDominant:
        return Colors.deepOrangeAccent;
      case SceneClass.noiseHighDominant:
        return Colors.purpleAccent;
      case SceneClass.music:
        return Colors.cyanAccent;
    }
  }
}

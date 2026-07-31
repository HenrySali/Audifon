import 'dart:async';

import 'package:flutter/material.dart';

import '../../scene/scene_engine.dart';

/// Hint persistente en la pantalla Smart Scene cuando el análisis
/// usa el audiograma genérico (default) en lugar de uno medido.
///
/// Se suscribe al [SceneEngine.usingDefaultAudiogramStream] y muestra
/// el hint cuando `isUsingDefaultAudiogram == true`. Se oculta
/// automáticamente cuando hay audiograma medido disponible.
///
/// Texto: "Audiograma no medido — los ajustes se basan en un perfil
/// genérico. Realice una audiometría para personalizar."
///
/// Requisitos: 7.8
class DefaultAudiogramHint extends StatefulWidget {
  /// Instancia del SceneEngine para suscribirse al stream.
  /// Si es `null`, el widget intenta obtenerlo del contexto.
  final SceneEngine? sceneEngine;

  const DefaultAudiogramHint({super.key, this.sceneEngine});

  /// Texto del hint expuesto para testing y accesibilidad.
  static const hintText =
      'Audiograma no medido — los ajustes se basan en un perfil genérico. '
      'Realice una audiometría para personalizar.';

  @override
  State<DefaultAudiogramHint> createState() => _DefaultAudiogramHintState();
}

class _DefaultAudiogramHintState extends State<DefaultAudiogramHint> {
  bool _isUsingDefault = false;
  StreamSubscription<bool>? _subscription;

  @override
  void initState() {
    super.initState();
    final engine = widget.sceneEngine;
    if (engine != null) {
      _isUsingDefault = engine.isUsingDefaultAudiogram;
      _subscription = engine.usingDefaultAudiogramStream.listen((value) {
        if (mounted && value != _isUsingDefault) {
          setState(() => _isUsingDefault = value);
        }
      });
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isUsingDefault) return const SizedBox.shrink();

    return Semantics(
      label: DefaultAudiogramHint.hintText,
      liveRegion: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.blue.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.blue.shade200),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline,
              color: Colors.blue.shade700,
              size: 20,
              semanticLabel: 'Información',
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                DefaultAudiogramHint.hintText,
                style: TextStyle(
                  color: Colors.blue.shade800,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

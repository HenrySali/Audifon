/// @file waterfall_view.dart
/// @brief Waterfall (espectrograma) acumulado de los últimos N segundos.
///
/// REQ-8: hop 50%, eje frecuencia logarítmico, colormap viridis por default,
/// permite alternar a grayscale o "rainbow legacy" detrás de toggle con warning.
///
/// Implementación práctica: como sólo recibimos snapshots con harmonics,
/// el waterfall pintará "perfiles" sintéticos por snapshot — barras de
/// magnitud sobre eje log, apiladas en el tiempo. Suficiente para detectar
/// inestabilidad temporal del tono.

import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../tone_snapshot.dart';

enum WaterfallColormap { viridis, grayscale, rainbow }

class WaterfallView extends StatefulWidget {
  final ToneSnapshot snapshot;
  final WaterfallColormap colormap;
  final int historySize;
  final double freqMinHz;
  final double freqMaxHz;

  const WaterfallView({
    super.key,
    required this.snapshot,
    this.colormap = WaterfallColormap.viridis,
    this.historySize = 60,    // ~6 s a 10 Hz
    this.freqMinHz = 100,
    this.freqMaxHz = 8000,
  });

  @override
  State<WaterfallView> createState() => _WaterfallViewState();
}

class _WaterfallViewState extends State<WaterfallView> {
  final Queue<ToneSnapshot> _history = Queue<ToneSnapshot>();
  int _lastTimestampUs = -1;

  @override
  void didUpdateWidget(covariant WaterfallView old) {
    super.didUpdateWidget(old);
    final ts = widget.snapshot.timestampUs;
    if (ts == _lastTimestampUs) return;
    _lastTimestampUs = ts;
    _history.addLast(widget.snapshot);
    while (_history.length > widget.historySize) {
      _history.removeFirst();
    }
  }

  void clear() {
    _history.clear();
    _lastTimestampUs = -1;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1a1a2e),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: AspectRatio(
        aspectRatio: 2.4,
        child: CustomPaint(
          painter: _WaterfallPainter(
            history: _history,
            colormap: widget.colormap,
            freqMinHz: widget.freqMinHz,
            freqMaxHz: widget.freqMaxHz,
          ),
          child: _history.isEmpty
              ? const Center(
                  child: Text(
                    'Sin historial',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

class _WaterfallPainter extends CustomPainter {
  final Queue<ToneSnapshot> history;
  final WaterfallColormap colormap;
  final double freqMinHz;
  final double freqMaxHz;

  _WaterfallPainter({
    required this.history,
    required this.colormap,
    required this.freqMinHz,
    required this.freqMaxHz,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (history.isEmpty) return;

    const dbMin = -100.0;
    const dbMax = 0.0;
    final logMin = math.log(freqMinHz) / math.ln10;
    final logMax = math.log(freqMaxHz) / math.ln10;

    final rowHeight = size.height / history.length;
    final list = history.toList();
    for (var rowIdx = 0; rowIdx < list.length; ++rowIdx) {
      final snap = list[rowIdx];
      final y = rowIdx * rowHeight;

      // Construir array de magnitudes vs frecuencia con fundamental + armónicos.
      final freqs = <double>[];
      final mags = <double>[];
      if (snap.peakFreqHz.isFinite) {
        freqs.add(snap.peakFreqHz);
        mags.add(snap.peakMagnitudeDbfs.isFinite ? snap.peakMagnitudeDbfs : dbMin);
        for (var i = 0; i < snap.harmonicsDbfs.length; ++i) {
          final K = i + 2;
          final hf = snap.peakFreqHz * K;
          if (hf < freqMinHz || hf > freqMaxHz) continue;
          final hdb = snap.harmonicsDbfs[i];
          if (!hdb.isFinite) continue;
          freqs.add(hf);
          mags.add(hdb);
        }
      }

      // Renderizado: dibujamos cada armónico como una banda corta de su color.
      // El resto queda en el color del piso de ruido.
      final floorIntensity = _normalize(snap.noiseFloorDbfs.isFinite ? snap.noiseFloorDbfs : dbMin, dbMin, dbMax);
      final floorColor = _mapColor(floorIntensity);
      canvas.drawRect(
        Rect.fromLTWH(0, y, size.width, rowHeight + 0.5),
        Paint()..color = floorColor,
      );

      const halfBand = 6.0; // ancho en píxeles de la banda
      for (var k = 0; k < freqs.length; ++k) {
        final f = freqs[k];
        final m = mags[k];
        final logF = math.log(f) / math.ln10;
        final x = (logF - logMin) / (logMax - logMin) * size.width;
        final intensity = _normalize(m, dbMin, dbMax);
        final color = _mapColor(intensity);
        canvas.drawRect(
          Rect.fromLTWH(x - halfBand, y, halfBand * 2, rowHeight + 0.5),
          Paint()..color = color,
        );
      }
    }
  }

  double _normalize(double db, double dbMin, double dbMax) {
    final clamped = db.clamp(dbMin, dbMax);
    return (clamped - dbMin) / (dbMax - dbMin);
  }

  /// Colormap intensidad [0,1] → Color.
  Color _mapColor(double t) {
    switch (colormap) {
      case WaterfallColormap.grayscale:
        final v = (t * 255).round();
        return Color.fromARGB(255, v, v, v);
      case WaterfallColormap.rainbow:
        // Rainbow simple HSV (legacy, no recomendado pero opt-in).
        return HSVColor.fromAHSV(1.0, (1.0 - t) * 240.0, 1.0, 1.0).toColor();
      case WaterfallColormap.viridis:
        // Aproximación de viridis con interpolación entre 5 anclas conocidas.
        return _viridisAt(t);
    }
  }

  // Anchors aproximados de viridis (matplotlib): t=0 → púrpura oscuro, t=1 → amarillo.
  static const _viridisStops = <_ViridisStop>[
    _ViridisStop(0.00, Color(0xFF440154)),
    _ViridisStop(0.25, Color(0xFF3B528B)),
    _ViridisStop(0.50, Color(0xFF21918C)),
    _ViridisStop(0.75, Color(0xFF5EC962)),
    _ViridisStop(1.00, Color(0xFFFDE725)),
  ];

  Color _viridisAt(double t) {
    if (t <= 0) return _viridisStops.first.color;
    if (t >= 1) return _viridisStops.last.color;
    for (var i = 0; i < _viridisStops.length - 1; ++i) {
      final a = _viridisStops[i];
      final b = _viridisStops[i + 1];
      if (t >= a.t && t <= b.t) {
        final localT = (t - a.t) / (b.t - a.t);
        return Color.lerp(a.color, b.color, localT) ?? a.color;
      }
    }
    return _viridisStops.last.color;
  }

  @override
  bool shouldRepaint(covariant _WaterfallPainter oldDelegate) =>
      oldDelegate.history.length != history.length ||
      oldDelegate.colormap != colormap;

  // Marca clase no abstracta para satisfacer al linter.
  // ignore: unused_element
  ui.Image? _unused;
}

class _ViridisStop {
  final double t;
  final Color color;
  const _ViridisStop(this.t, this.color);
}

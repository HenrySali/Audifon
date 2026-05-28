import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/entities/eq_preset.dart';
import '../../domain/entities/environment_profile.dart';
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_state.dart';

/// Pantalla de detalle completo de la configuración DSP activa.
///
/// Muestra todos los parámetros del pipeline en tiempo real:
/// - Preset EQ activo con ganancias por banda (gráfico de barras)
/// - Parámetros WDRC (knees, ratios, attack/release)
/// - MPO threshold
/// - Nivel de NR
/// - Volumen maestro
/// - Perfil de entorno activo
/// - Curva I/O del WDRC
class DspConfigDetailScreen extends StatelessWidget {
  const DspConfigDetailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a1628),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0f3460),
        title: const Text('Configuración DSP Activa'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copiar configuración',
            onPressed: () => _copyFullConfig(context),
          ),
        ],
      ),
      body: BlocBuilder<AmplificationBloc, AmplificationState>(
        builder: (context, state) {
          if (state is! AmplificationActive) {
            return const Center(
              child: Text(
                'Amplificación no activa',
                style: TextStyle(color: Colors.white54, fontSize: 16),
              ),
            );
          }
          return _ConfigDetailBody(state: state);
        },
      ),
    );
  }

  void _copyFullConfig(BuildContext context) {
    final state = context.read<AmplificationBloc>().state;
    if (state is! AmplificationActive) return;

    final config = _buildConfigReport(state);
    Clipboard.setData(ClipboardData(text: config));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Configuración completa copiada'),
        backgroundColor: Color(0xFF0f3460),
      ),
    );
  }

  String _buildConfigReport(AmplificationActive state) {
    final preset = EqPreset.findByName(state.activeEqPreset) ?? EqPreset.normal;
    final profile = _getProfile(state.activeProfile);

    final buffer = StringBuffer();
    buffer.writeln('═══════════════════════════════════════');
    buffer.writeln('   CONFIGURACIÓN DSP ACTIVA');
    buffer.writeln('═══════════════════════════════════════');
    buffer.writeln('');
    buffer.writeln('▸ Preset EQ: ${preset.name}');
    buffer.writeln('  ${preset.description}');
    buffer.writeln('');
    buffer.writeln('▸ Ganancias EQ por banda:');
    for (int i = 0; i < 12; i++) {
      final freq = EqPreset.bandLabels[i].padRight(5);
      final gain = preset.gains[i].toStringAsFixed(1).padLeft(5);
      final bar = '█' * (preset.gains[i] ~/ 2);
      buffer.writeln('  $freq Hz: $gain dB  $bar');
    }
    buffer.writeln('');
    buffer.writeln('▸ WDRC:');
    buffer.writeln('  Expansion Knee:   ${profile.expansionKnee} dB SPL');
    buffer.writeln('  Expansion Ratio:  2:1');
    buffer.writeln('  Compression Knee: ${profile.compressionKnee} dB SPL');
    buffer.writeln('  Compression Ratio: ${profile.compressionRatio}:1');
    buffer.writeln('  Attack:  5 ms');
    buffer.writeln('  Release: 100 ms');
    buffer.writeln('');
    buffer.writeln('▸ MPO: 100 dB SPL');
    buffer.writeln('▸ NR Level: ${state.activeNrLevel} (${_nrLabel(state.activeNrLevel)})');
    buffer.writeln('▸ Volumen: ${state.volumeDb.toStringAsFixed(0)} dB');
    buffer.writeln('▸ Perfil: ${state.activeProfile}');
    buffer.writeln('▸ Input Level: ${state.inputLevelDb.toStringAsFixed(1)} dB SPL');
    buffer.writeln('');
    buffer.writeln('═══════════════════════════════════════');
    return buffer.toString();
  }

  EnvironmentProfile _getProfile(String name) {
    switch (name) {
      case 'Silencioso':
        return EnvironmentProfile.quiet;
      case 'Ruidoso':
        return EnvironmentProfile.noisy;
      default:
        return EnvironmentProfile.conversation;
    }
  }

  String _nrLabel(int level) {
    const labels = ['Off', 'Bajo', 'Medio', 'Alto'];
    return labels[level.clamp(0, 3)];
  }
}

// =============================================================================
// BODY — Contenido principal con todas las secciones
// =============================================================================

class _ConfigDetailBody extends StatelessWidget {
  final AmplificationActive state;

  const _ConfigDetailBody({required this.state});

  @override
  Widget build(BuildContext context) {
    final preset = EqPreset.findByName(state.activeEqPreset) ?? EqPreset.normal;
    final profile = _getProfile(state.activeProfile);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sección 1: Resumen general
          _SummaryCard(state: state, preset: preset, profile: profile),
          const SizedBox(height: 16),
          // Sección 2: Ganancias EQ por banda (gráfico de barras)
          _EqGainsCard(preset: preset),
          const SizedBox(height: 16),
          // Sección 3: Parámetros WDRC
          _WdrcCard(profile: profile),
          const SizedBox(height: 16),
          // Sección 4: Curva I/O del WDRC
          _WdrcCurveCard(profile: profile),
          const SizedBox(height: 16),
          // Sección 5: MPO y seguridad
          _MpoCard(inputLevel: state.inputLevelDb),
          const SizedBox(height: 16),
          // Sección 6: Pipeline completo
          _PipelineCard(state: state, preset: preset, profile: profile),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  EnvironmentProfile _getProfile(String name) {
    switch (name) {
      case 'Silencioso':
        return EnvironmentProfile.quiet;
      case 'Ruidoso':
        return EnvironmentProfile.noisy;
      default:
        return EnvironmentProfile.conversation;
    }
  }
}

// =============================================================================
// SUMMARY CARD — Resumen rápido
// =============================================================================

class _SummaryCard extends StatelessWidget {
  final AmplificationActive state;
  final EqPreset preset;
  final EnvironmentProfile profile;

  const _SummaryCard({
    required this.state,
    required this.preset,
    required this.profile,
  });

  @override
  Widget build(BuildContext context) {
    return _CardContainer(
      title: 'Resumen',
      icon: Icons.dashboard,
      child: Column(
        children: [
          _InfoRow('Preset EQ', preset.name, Colors.cyan),
          _InfoRow('Descripción', preset.description, Colors.white70),
          _InfoRow('Perfil Entorno', state.activeProfile, Colors.green),
          _InfoRow('Volumen', '${state.volumeDb.toStringAsFixed(0)} dB', Colors.amber),
          _InfoRow('NR', _nrLabel(state.activeNrLevel), Colors.purple.shade200),
          _InfoRow('Input', '${state.inputLevelDb.toStringAsFixed(1)} dB SPL', Colors.orange),
          _InfoRow('Auriculares', state.headphonesConnected ? '✓ Conectados' : '✗ Desconectados',
              state.headphonesConnected ? Colors.green : Colors.red),
        ],
      ),
    );
  }

  String _nrLabel(int level) {
    const labels = ['Off', 'Bajo', 'Medio', 'Alto'];
    return labels[level.clamp(0, 3)];
  }
}

// =============================================================================
// EQ GAINS CARD — Gráfico de barras de ganancias por banda
// =============================================================================

class _EqGainsCard extends StatelessWidget {
  final EqPreset preset;

  const _EqGainsCard({required this.preset});

  @override
  Widget build(BuildContext context) {
    final maxGain = preset.gains.reduce((a, b) => a > b ? a : b);
    final displayMax = maxGain < 5 ? 10.0 : (maxGain + 5);

    return _CardContainer(
      title: 'Ecualización (${preset.name})',
      icon: Icons.equalizer,
      child: Column(
        children: [
          // Gráfico de barras
          SizedBox(
            height: 160,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(12, (i) {
                final gain = preset.gains[i];
                final height = displayMax > 0 ? (gain / displayMax) * 140 : 0.0;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          gain > 0 ? '+${gain.toInt()}' : '${gain.toInt()}',
                          style: TextStyle(
                            color: _gainColor(gain),
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Container(
                          height: height.clamp(2.0, 140.0),
                          decoration: BoxDecoration(
                            color: _gainColor(gain),
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(3),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 4),
          // Labels de frecuencia
          Row(
            children: List.generate(12, (i) {
              return Expanded(
                child: Text(
                  EqPreset.bandLabels[i],
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 8,
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 8),
          // Tabla detallada
          ...List.generate(12, (i) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                children: [
                  SizedBox(
                    width: 55,
                    child: Text(
                      '${EqPreset.bandFrequencies[i]} Hz',
                      style: const TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                  ),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: displayMax > 0 ? preset.gains[i] / displayMax : 0,
                      backgroundColor: Colors.grey.shade800,
                      color: _gainColor(preset.gains[i]),
                      minHeight: 6,
                    ),
                  ),
                  SizedBox(
                    width: 45,
                    child: Text(
                      '+${preset.gains[i].toStringAsFixed(1)} dB',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: _gainColor(preset.gains[i]),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Color _gainColor(double gain) {
    if (gain >= 20) return Colors.red.shade300;
    if (gain >= 12) return Colors.orange;
    if (gain >= 5) return Colors.cyan;
    return Colors.green;
  }
}

// =============================================================================
// WDRC CARD — Parámetros del compresor
// =============================================================================

class _WdrcCard extends StatelessWidget {
  final EnvironmentProfile profile;

  const _WdrcCard({required this.profile});

  @override
  Widget build(BuildContext context) {
    return _CardContainer(
      title: 'WDRC (Compresión Dinámica)',
      icon: Icons.compress,
      child: Column(
        children: [
          _ParamRow('Expansion Knee', '${profile.expansionKnee.toStringAsFixed(0)} dB SPL',
              'Señales debajo de este nivel se atenúan (ruido)'),
          _ParamRow('Expansion Ratio', '2:1',
              'Por cada 2 dB menos de input, 1 dB más de atenuación'),
          const Divider(color: Colors.white12, height: 16),
          _ParamRow('Compression Knee', '${profile.compressionKnee.toStringAsFixed(0)} dB SPL',
              'Señales arriba de este nivel se comprimen'),
          _ParamRow('Compression Ratio', '${profile.compressionRatio.toStringAsFixed(1)}:1',
              'Cuánto se reduce la ganancia para sonidos fuertes'),
          const Divider(color: Colors.white12, height: 16),
          _ParamRow('Attack', '5 ms', 'Velocidad de reacción a sonidos fuertes'),
          _ParamRow('Release', '100 ms', 'Velocidad de recuperación tras sonido fuerte'),
          const Divider(color: Colors.white12, height: 16),
          _ParamRow('Región Lineal',
              '${profile.expansionKnee.toStringAsFixed(0)} – ${profile.compressionKnee.toStringAsFixed(0)} dB SPL',
              'Rango donde se aplica ganancia completa sin modificar'),
        ],
      ),
    );
  }
}

// =============================================================================
// WDRC CURVE CARD — Visualización de la curva I/O
// =============================================================================

class _WdrcCurveCard extends StatelessWidget {
  final EnvironmentProfile profile;

  const _WdrcCurveCard({required this.profile});

  @override
  Widget build(BuildContext context) {
    return _CardContainer(
      title: 'Curva I/O del WDRC',
      icon: Icons.show_chart,
      child: SizedBox(
        height: 200,
        child: CustomPaint(
          size: const Size(double.infinity, 200),
          painter: _WdrcCurvePainter(
            expansionKnee: profile.expansionKnee,
            compressionKnee: profile.compressionKnee,
            compressionRatio: profile.compressionRatio,
          ),
        ),
      ),
    );
  }
}

/// Painter para la curva I/O del WDRC con 3 regiones.
class _WdrcCurvePainter extends CustomPainter {
  final double expansionKnee;
  final double compressionKnee;
  final double compressionRatio;

  _WdrcCurvePainter({
    required this.expansionKnee,
    required this.compressionKnee,
    required this.compressionRatio,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    const padding = 30.0;
    final plotW = w - padding * 2;
    final plotH = h - padding * 2;

    // Ejes
    final axisPaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    canvas.drawLine(Offset(padding, h - padding), Offset(w - padding, h - padding), axisPaint);
    canvas.drawLine(Offset(padding, h - padding), Offset(padding, padding), axisPaint);

    // Labels
    final textStyle = TextStyle(color: Colors.white38, fontSize: 9);
    _drawText(canvas, '20', Offset(padding - 5, h - padding + 12), textStyle);
    _drawText(canvas, '100', Offset(w - padding - 10, h - padding + 12), textStyle);
    _drawText(canvas, 'Input (dB SPL)', Offset(w / 2 - 30, h - 8), textStyle);
    _drawText(canvas, 'Gain Factor', Offset(2, padding - 12), textStyle);
    _drawText(canvas, '1.0', Offset(padding - 22, padding - 4), textStyle);
    _drawText(canvas, '0.0', Offset(padding - 22, h - padding - 4), textStyle);

    // Curva I/O (gain factor vs input level)
    final curvePaint = Paint()
      ..color = Colors.cyan
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    final path = Path();
    const minInput = 20.0;
    const maxInput = 100.0;
    const expansionRatio = 2.0;

    for (int px = 0; px <= plotW.toInt(); px++) {
      final inputDb = minInput + (px / plotW) * (maxInput - minInput);
      double gainFactor;

      if (inputDb < expansionKnee) {
        final belowKnee = expansionKnee - inputDb;
        final reductionDb = belowKnee * (1.0 - 1.0 / expansionRatio);
        gainFactor = _dbToLinear(-reductionDb);
      } else if (inputDb > compressionKnee) {
        final aboveKnee = inputDb - compressionKnee;
        final reductionDb = aboveKnee * (1.0 - 1.0 / compressionRatio);
        gainFactor = _dbToLinear(-reductionDb);
      } else {
        gainFactor = 1.0;
      }

      final x = padding + px;
      final y = h - padding - (gainFactor.clamp(0.0, 1.0) * plotH);

      if (px == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, curvePaint);

    // Líneas de knee
    final kneePaint = Paint()
      ..color = Colors.orange.withOpacity(0.5)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    final expKneeX = padding + ((expansionKnee - minInput) / (maxInput - minInput)) * plotW;
    final compKneeX = padding + ((compressionKnee - minInput) / (maxInput - minInput)) * plotW;

    canvas.drawLine(Offset(expKneeX, padding), Offset(expKneeX, h - padding), kneePaint);
    canvas.drawLine(Offset(compKneeX, padding), Offset(compKneeX, h - padding), kneePaint);

    // Labels de regiones
    final regionStyle = TextStyle(color: Colors.white54, fontSize: 8);
    _drawText(canvas, 'EXP', Offset(expKneeX - 20, padding + 5), regionStyle);
    _drawText(canvas, 'LINEAL', Offset((expKneeX + compKneeX) / 2 - 12, padding + 5), regionStyle);
    _drawText(canvas, 'COMP', Offset(compKneeX + 5, padding + 5), regionStyle);
  }

  double _dbToLinear(double db) => db >= 0 ? 1.0 : (db < -60 ? 0.0 : math.pow(10.0, db / 20.0).toDouble());

  void _drawText(Canvas canvas, String text, Offset offset, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _WdrcCurvePainter old) =>
      old.expansionKnee != expansionKnee ||
      old.compressionKnee != compressionKnee ||
      old.compressionRatio != compressionRatio;
}

// =============================================================================
// MPO CARD — Limitador de salida máxima
// =============================================================================

class _MpoCard extends StatelessWidget {
  final double inputLevel;

  const _MpoCard({required this.inputLevel});

  @override
  Widget build(BuildContext context) {
    const mpoThreshold = 100.0;
    final headroom = mpoThreshold - inputLevel;
    final mpoActive = headroom < 10;

    return _CardContainer(
      title: 'MPO (Limitador de Salida)',
      icon: Icons.shield,
      iconColor: mpoActive ? Colors.red : Colors.green,
      child: Column(
        children: [
          _ParamRow('Threshold', '$mpoThreshold dB SPL',
              'Nivel máximo de salida permitido'),
          _ParamRow('Attack', '0.5 ms',
              'Reacción instantánea a picos'),
          _ParamRow('Release', '10 ms',
              'Recuperación tras limitación'),
          _ParamRow('Headroom actual', '${headroom.toStringAsFixed(1)} dB',
              headroom < 10 ? '⚠️ Cercano al límite' : '✓ Margen seguro'),
          _ParamRow('Estado', mpoActive ? '⚠️ CERCANO A LIMITAR' : '✓ Inactivo',
              'El MPO protege de daño auditivo'),
          const Divider(color: Colors.white12, height: 16),
          _ParamRow('Safety Ceiling', '-1 dBFS',
              'Máximo digital absoluto (nunca clipping)'),
          _ParamRow('Tipo', 'Peak Limiter Sample-by-Sample',
              'Opera en cada muestra individual'),
        ],
      ),
    );
  }
}

// =============================================================================
// PIPELINE CARD — Diagrama del pipeline completo
// =============================================================================

class _PipelineCard extends StatelessWidget {
  final AmplificationActive state;
  final EqPreset preset;
  final EnvironmentProfile profile;

  const _PipelineCard({
    required this.state,
    required this.preset,
    required this.profile,
  });

  @override
  Widget build(BuildContext context) {
    final maxEqGain = preset.gains.reduce((a, b) => a > b ? a : b);

    return _CardContainer(
      title: 'Pipeline DSP (Orden de Procesamiento)',
      icon: Icons.linear_scale,
      child: Column(
        children: [
          _PipelineStage('1. Input', 'int16 → float32', '0 dB', Colors.grey),
          _PipelineStage('2. NR', 'Reducción de ruido (${_nrLabel(state.activeNrLevel)})',
              '≤ 0 dB', Colors.purple.shade200),
          _PipelineStage('3. EQ', '12 bandas (max +${maxEqGain.toStringAsFixed(0)} dB)',
              '+${maxEqGain.toStringAsFixed(0)} dB', Colors.cyan),
          _PipelineStage('4. WDRC', '3 regiones (CR ${profile.compressionRatio}:1)',
              '≤ 0 dB', Colors.orange),
          _PipelineStage('5. Volume', 'Master ${state.volumeDb.toStringAsFixed(0)} dB',
              '${state.volumeDb >= 0 ? '+' : ''}${state.volumeDb.toStringAsFixed(0)} dB', Colors.amber),
          _PipelineStage('6. MPO', 'Peak Limiter @ 100 dB SPL',
              '≤ 0 dB', Colors.red.shade300),
          _PipelineStage('7. Output', 'float32 → int16', '0 dB', Colors.grey),
          const Divider(color: Colors.white12, height: 16),
          _InfoRow('Ganancia máx teórica',
              '+${(maxEqGain + (state.volumeDb > 0 ? state.volumeDb : 0)).toStringAsFixed(0)} dB',
              Colors.red.shade200),
          _InfoRow('Sample Rate', '48000 Hz', Colors.white54),
          _InfoRow('Buffer Size', '256 samples (~5.3 ms)', Colors.white54),
          _InfoRow('Latencia total', '~5.8 ms', Colors.white54),
        ],
      ),
    );
  }

  String _nrLabel(int level) {
    const labels = ['Off', 'Bajo', 'Medio', 'Alto'];
    return labels[level.clamp(0, 3)];
  }
}

// =============================================================================
// SHARED WIDGETS
// =============================================================================

/// Contenedor de tarjeta con título e icono.
class _CardContainer extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color? iconColor;
  final Widget child;

  const _CardContainer({
    required this.title,
    required this.icon,
    this.iconColor,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2a3a4a)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor ?? Colors.cyan, size: 18),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// Fila de información clave-valor.
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color valueColor;

  const _InfoRow(this.label, this.value, this.valueColor);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          Text(value, style: TextStyle(color: valueColor, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Fila de parámetro con descripción.
class _ParamRow extends StatelessWidget {
  final String label;
  final String value;
  final String description;

  const _ParamRow(this.label, this.value, this.description);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w500)),
              Text(value, style: const TextStyle(color: Colors.cyan, fontSize: 12, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 2),
          Text(description, style: const TextStyle(color: Colors.white30, fontSize: 10, fontStyle: FontStyle.italic)),
        ],
      ),
    );
  }
}

/// Etapa del pipeline con indicador visual.
class _PipelineStage extends StatelessWidget {
  final String name;
  final String description;
  final String gain;
  final Color color;

  const _PipelineStage(this.name, this.description, this.gain, this.color);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              children: [
                Text(name, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(description, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                ),
              ],
            ),
          ),
          Text(gain, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

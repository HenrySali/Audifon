import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_state.dart';

/// Overlay de advertencia de seguridad auditiva.
///
/// Monitorea el nivel de entrada desde el BLoC y muestra un banner
/// de advertencia cuando el nivel promedio supera 85 dB SPL durante
/// más de 5 segundos consecutivos.
///
/// Características:
/// - Muestra advertencia prominente sin bloquear controles
/// - Tiene botón de dismiss, pero reaparece si la condición persiste
/// - Se oculta automáticamente cuando el nivel cae por debajo de 85 dB SPL
///   durante más de 2 segundos
///
/// Se usa como overlay (dentro de un Stack) sobre el contenido principal.
///
/// Requisitos: 9.3
class SafetyWarningWidget extends StatefulWidget {
  /// Widget hijo sobre el cual se muestra el overlay de advertencia.
  final Widget child;

  /// Umbral de nivel en dB SPL para activar la advertencia.
  /// Default: 85 dB SPL según Req 9.3.
  final double thresholdDbSpl;

  /// Duración por encima del umbral para mostrar la advertencia.
  /// Default: 5 segundos según Req 9.3.
  final Duration showAfter;

  /// Duración por debajo del umbral para ocultar la advertencia.
  /// Default: 2 segundos.
  final Duration hideAfter;

  /// Proveedor de tiempo actual. Inyectable para tests.
  /// Default: `DateTime.now` (reloj real del sistema).
  final DateTime Function() nowProvider;

  const SafetyWarningWidget({
    super.key,
    required this.child,
    this.thresholdDbSpl = 85.0,
    this.showAfter = const Duration(seconds: 5),
    this.hideAfter = const Duration(seconds: 2),
    this.nowProvider = DateTime.now,
  });

  @override
  State<SafetyWarningWidget> createState() => _SafetyWarningWidgetState();
}

class _SafetyWarningWidgetState extends State<SafetyWarningWidget>
    with SingleTickerProviderStateMixin {
  /// Indica si la advertencia está visible.
  bool _showWarning = false;

  /// Indica si el usuario descartó manualmente la advertencia.
  /// Se resetea cuando el nivel cae por debajo del umbral.
  bool _dismissed = false;

  /// Timestamp de cuando el nivel superó el umbral por primera vez
  /// en la secuencia actual.
  DateTime? _aboveThresholdSince;

  /// Timestamp de cuando el nivel cayó por debajo del umbral.
  DateTime? _belowThresholdSince;

  /// Controlador de animación para fade in/out del banner.
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  /// Timer periódico para evaluar la condición de tiempo.
  Timer? _evaluationTimer;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );

    // Evaluar cada 500 ms si se cumplen las condiciones de tiempo.
    _evaluationTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _evaluateWarningState(),
    );
  }

  @override
  void dispose() {
    _evaluationTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  /// Procesa una nueva lectura de nivel del BLoC.
  void _onLevelUpdate(double inputLevelDb) {
    final now = widget.nowProvider();

    if (inputLevelDb > widget.thresholdDbSpl) {
      // Nivel por encima del umbral.
      _belowThresholdSince = null;
      _aboveThresholdSince ??= now;
    } else {
      // Nivel por debajo del umbral.
      _aboveThresholdSince = null;
      if (_showWarning || _dismissed) {
        _belowThresholdSince ??= now;
      } else {
        _belowThresholdSince = null;
      }
    }
  }

  /// Evalúa si se debe mostrar u ocultar la advertencia basándose
  /// en la duración acumulada por encima/debajo del umbral.
  void _evaluateWarningState() {
    final now = widget.nowProvider();

    if (!_showWarning && !_dismissed && _aboveThresholdSince != null) {
      // Verificar si llevamos > 5 segundos por encima del umbral.
      final elapsed = now.difference(_aboveThresholdSince!);
      if (elapsed >= widget.showAfter) {
        _showWarningBanner();
      }
    } else if (_dismissed && _aboveThresholdSince != null) {
      // Si fue descartado pero la condición persiste, re-mostrar
      // después de que pase el tiempo de showAfter desde el dismiss.
      final elapsed = now.difference(_aboveThresholdSince!);
      if (elapsed >= widget.showAfter) {
        _dismissed = false;
        _showWarningBanner();
      }
    } else if (_showWarning && _belowThresholdSince != null) {
      // Verificar si llevamos > 2 segundos por debajo del umbral.
      final elapsed = now.difference(_belowThresholdSince!);
      if (elapsed >= widget.hideAfter) {
        _hideWarningBanner();
      }
    } else if (_dismissed && _belowThresholdSince != null) {
      // Si fue descartado y el nivel bajó, resetear el estado dismissed.
      final elapsed = now.difference(_belowThresholdSince!);
      if (elapsed >= widget.hideAfter) {
        _dismissed = false;
        _belowThresholdSince = null;
      }
    }
  }

  void _showWarningBanner() {
    if (!_showWarning) {
      setState(() => _showWarning = true);
      _animationController.forward();
    }
  }

  void _hideWarningBanner() {
    if (_showWarning) {
      _animationController.reverse().then((_) {
        if (mounted) {
          setState(() => _showWarning = false);
        }
      });
      _belowThresholdSince = null;
    }
  }

  /// Descarta la advertencia manualmente. Reaparece si la condición persiste.
  void _dismissWarning() {
    _dismissed = true;
    _aboveThresholdSince = widget.nowProvider(); // Reset timer for reappearance
    _hideWarningBanner();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<AmplificationBloc, AmplificationState>(
      listenWhen: (previous, current) {
        // Escuchar solo cuando estamos en estado activo o salimos de él.
        return current is AmplificationActive ||
            (previous is AmplificationActive && current is! AmplificationActive);
      },
      listener: (context, state) {
        if (state is AmplificationActive) {
          _onLevelUpdate(state.inputLevelDb);
        } else {
          // Si salimos del estado activo, ocultar advertencia y resetear.
          _aboveThresholdSince = null;
          _belowThresholdSince = null;
          _dismissed = false;
          if (_showWarning) {
            _hideWarningBanner();
          }
        }
      },
      child: Stack(
        children: [
          // Contenido principal — nunca bloqueado.
          widget.child,

          // Banner de advertencia posicionado en la parte superior.
          if (_showWarning)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: SafeArea(
                  bottom: false,
                  child: _buildWarningBanner(context),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildWarningBanner(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.orange.shade800,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.orange.shade900.withOpacity(0.4),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Colors.white,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '⚠️ Nivel de salida alto — Considere reducir el volumen',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
            ),
          ),
          const SizedBox(width: 8),
          // Botón de dismiss — no bloquea controles (Req 9.3)
          GestureDetector(
            onTap: _dismissWarning,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.close,
                color: Colors.white,
                size: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

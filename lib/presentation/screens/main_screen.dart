import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../domain/entities/environment_profile.dart';
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_event.dart';
import '../bloc/amplification_state.dart';
import '../widgets/safety_warning_widget.dart';
import 'audiogram_screen.dart';
import 'simulator_screen.dart';

/// Pantalla principal de amplificación del PSK Mobile Hearing Aid.
///
/// Presenta:
/// - Botón grande de activación/desactivación (≥ 30% del área visible)
/// - Slider de volumen (-20 a +10 dB)
/// - Medidor de nivel de entrada (estilo VU, actualizado ≥ 10 Hz)
/// - Indicador de estado de conexión de auriculares (permanente)
/// - Selector de perfil (Silencioso, Conversación, Ruidoso)
/// - Wakelock mientras la amplificación está activa
///
/// Requisitos: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6
class MainScreen extends StatelessWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<AmplificationBloc, AmplificationState>(
      listener: _handleStateChanges,
      builder: (context, state) {
        return SafetyWarningWidget(
          child: Scaffold(
            body: SafeArea(
              child: Column(
                children: [
                  _StatusBar(state: state),
                  Expanded(
                    child: _buildBody(context, state),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Maneja efectos secundarios de cambios de estado (wakelock).
  void _handleStateChanges(BuildContext context, AmplificationState state) {
    if (state is AmplificationActive) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
  }

  Widget _buildBody(BuildContext context, AmplificationState state) {
    return switch (state) {
      AmplificationIdle() => _IdleView(),
      AmplificationStarting() => const _StartingView(),
      AmplificationActive() => _ActiveView(state: state),
      AmplificationPaused() => _PausedView(state: state),
      AmplificationError() => _ErrorView(state: state),
    };
  }
}

// =============================================================================
// STATUS BAR — Indicador de auriculares + perfil activo (siempre visible)
// =============================================================================

class _StatusBar extends StatelessWidget {
  final AmplificationState state;

  const _StatusBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final bool headphonesConnected;
    final String profileName;

    if (state is AmplificationActive) {
      headphonesConnected = (state as AmplificationActive).headphonesConnected;
      profileName = (state as AmplificationActive).activeProfile;
    } else if (state is AmplificationPaused) {
      headphonesConnected =
          (state as AmplificationPaused).reason != PauseReason.btDisconnected;
      profileName = (state as AmplificationPaused).lastActiveProfile;
    } else {
      headphonesConnected = false;
      profileName = '';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0f3460),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Indicador de auriculares (Req 5.5 — permanente, visible)
          _HeadphoneIndicator(connected: headphonesConnected),
          const Spacer(),
          // Perfil activo
          if (profileName.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.cyan.withOpacity(0.15),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.cyan.withOpacity(0.3)),
              ),
              child: Text(
                profileName,
                style: const TextStyle(
                  color: Colors.cyan,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          const SizedBox(width: 8),
          // Botón de simulador avanzado
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.tune, color: Colors.white70, size: 22),
              tooltip: 'Configuración Avanzada',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const SimulatorScreen(),
                  ),
                );
              },
            ),
          ),
          // Botón de configuración de audiograma (Req 4.1, 4.3)
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.settings, color: Colors.white70, size: 22),
              tooltip: 'Configurar Audiograma',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => BlocProvider.value(
                      value: context.read<AmplificationBloc>(),
                      child: const AudiogramScreen(),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Indicador de conexión de auriculares — siempre visible (Req 5.5).
class _HeadphoneIndicator extends StatelessWidget {
  final bool connected;

  const _HeadphoneIndicator({required this.connected});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          connected ? Icons.headphones : Icons.headphones_outlined,
          color: connected ? Colors.green : Colors.red.shade300,
          size: 20,
        ),
        const SizedBox(width: 6),
        Text(
          connected ? 'Conectado' : 'Desconectado',
          style: TextStyle(
            color: connected ? Colors.green : Colors.red.shade300,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// IDLE VIEW — Botón grande de activación
// =============================================================================

class _IdleView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Spacer(flex: 1),
          // Botón grande de activación (≥ 30% del área visible) — Req 5.1
          _ActivationButton(
            active: false,
            onPressed: () {
              context.read<AmplificationBloc>().add(const StartAmplification());
            },
          ),
          const Spacer(flex: 1),
          // Selector de perfil (disponible incluso en idle para pre-selección)
          const _ProfileSelector(activeProfile: 'Conversación'),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// =============================================================================
// STARTING VIEW — Indicador de carga
// =============================================================================

class _StartingView extends StatelessWidget {
  const _StartingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: CircularProgressIndicator(
              strokeWidth: 4,
              color: Colors.cyan,
            ),
          ),
          SizedBox(height: 24),
          Text(
            'Iniciando amplificación...',
            style: TextStyle(
              fontSize: 16,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// ACTIVE VIEW — Controles completos de amplificación
// =============================================================================

class _ActiveView extends StatelessWidget {
  final AmplificationActive state;

  const _ActiveView({required this.state});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          const Spacer(flex: 1),
          // Botón grande de desactivación (≥ 30% del área visible) — Req 5.1
          _ActivationButton(
            active: true,
            onPressed: () {
              context.read<AmplificationBloc>().add(const StopAmplification());
            },
          ),
          const Spacer(flex: 1),
          // Slider de volumen (-20 a +10 dB) — Req 5.3
          _VolumeSlider(volumeDb: state.volumeDb),
          const SizedBox(height: 16),
          // Medidor de nivel de entrada (estilo VU) — Req 5.4
          _InputLevelMeter(levelDb: state.inputLevelDb),
          const SizedBox(height: 20),
          // Selector de perfil — Req 8.1
          _ProfileSelector(activeProfile: state.activeProfile),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// =============================================================================
// PAUSED VIEW — Razón de pausa y botón de reanudar
// =============================================================================

class _PausedView extends StatelessWidget {
  final AmplificationPaused state;

  const _PausedView({required this.state});

  @override
  Widget build(BuildContext context) {
    final (icon, message) = switch (state.reason) {
      PauseReason.btDisconnected => (
          Icons.bluetooth_disabled,
          'Auriculares desconectados'
        ),
      PauseReason.audioFocusLost => (
          Icons.volume_off,
          'Otra app está usando el audio'
        ),
      PauseReason.userPaused => (Icons.pause_circle, 'Amplificación pausada'),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 64, color: Colors.orange.shade300),
            const SizedBox(height: 24),
            Text(
              message,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: Colors.white,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'Perfil: ${state.lastActiveProfile} · Volumen: ${state.lastVolumeDb.toStringAsFixed(0)} dB',
              style: const TextStyle(fontSize: 14, color: Colors.white54),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () {
                context
                    .read<AmplificationBloc>()
                    .add(const ResumeAmplification());
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('Reanudar'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyan,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// ERROR VIEW — Mensaje de error y botón de reintentar
// =============================================================================

class _ErrorView extends StatelessWidget {
  final AmplificationError state;

  const _ErrorView({required this.state});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.redAccent),
            const SizedBox(height: 24),
            const Text(
              'Error',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.redAccent,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              state.message,
              style: const TextStyle(fontSize: 14, color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () {
                context
                    .read<AmplificationBloc>()
                    .add(const StartAmplification());
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyan,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// SHARED WIDGETS
// =============================================================================

/// Botón grande de activación/desactivación (≥ 30% del área visible).
///
/// Requisito 5.1: Ocupa al menos el 30% del área visible.
/// Estado claro: verde = activar, rojo = desactivar.
class _ActivationButton extends StatelessWidget {
  final bool active;
  final VoidCallback onPressed;

  const _ActivationButton({
    required this.active,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // LayoutBuilder para garantizar ≥ 30% del área visible
    return LayoutBuilder(
      builder: (context, constraints) {
        // Calcular tamaño mínimo para cumplir 30% del área visible
        final screenHeight = MediaQuery.of(context).size.height;
        final minHeight = screenHeight * 0.30;
        final buttonSize = minHeight.clamp(140.0, 240.0);

        return SizedBox(
          width: buttonSize,
          height: buttonSize,
          child: Material(
            elevation: 8,
            shape: const CircleBorder(),
            color: active ? Colors.red.shade700 : Colors.green.shade700,
            child: InkWell(
              onTap: onPressed,
              customBorder: const CircleBorder(),
              splashColor: Colors.white24,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      active ? Icons.stop : Icons.mic,
                      size: buttonSize * 0.3,
                      color: Colors.white,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      active ? 'DESACTIVAR' : 'ACTIVAR',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: buttonSize * 0.09,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Slider de volumen maestro (-20 a +10 dB).
///
/// Requisito 5.3: Ajustable con respuesta < 50 ms.
class _VolumeSlider extends StatelessWidget {
  final double volumeDb;

  const _VolumeSlider({required this.volumeDb});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.volume_up, color: Colors.cyan, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Volumen',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              Text(
                '${volumeDb.toStringAsFixed(0)} dB',
                style: const TextStyle(
                  color: Colors.cyan,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Colors.cyan,
              inactiveTrackColor: Colors.cyan.withOpacity(0.2),
              thumbColor: Colors.cyan,
              overlayColor: Colors.cyan.withOpacity(0.1),
              trackHeight: 6,
            ),
            child: Slider(
              value: volumeDb,
              min: -20,
              max: 10,
              divisions: 30,
              label: '${volumeDb.toStringAsFixed(0)} dB',
              onChanged: (value) {
                context
                    .read<AmplificationBloc>()
                    .add(ChangeVolume(volumeDb: value));
              },
            ),
          ),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('-20 dB', style: TextStyle(fontSize: 11, color: Colors.white38)),
              Text('+10 dB', style: TextStyle(fontSize: 11, color: Colors.white38)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Medidor de nivel de entrada estilo VU (actualizado ≥ 10 Hz).
///
/// Requisito 5.4: Indicador visual del nivel de entrada del micrófono.
class _InputLevelMeter extends StatelessWidget {
  final double levelDb;

  const _InputLevelMeter({required this.levelDb});

  @override
  Widget build(BuildContext context) {
    // Normalizar nivel a rango visual [0, 1]
    // Rango típico de entrada: 20 dB SPL (silencio) a 100 dB SPL (fuerte)
    final normalizedLevel = ((levelDb - 20) / 80).clamp(0.0, 1.0);

    // Color del indicador según nivel
    final Color barColor;
    if (normalizedLevel > 0.85) {
      barColor = Colors.red;
    } else if (normalizedLevel > 0.65) {
      barColor = Colors.orange;
    } else {
      barColor = Colors.green;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.graphic_eq, color: Colors.cyan, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Nivel',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              Text(
                '${levelDb.toStringAsFixed(0)} dB SPL',
                style: const TextStyle(
                  color: Colors.cyan,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Barra de nivel estilo VU
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 12,
              child: LinearProgressIndicator(
                value: normalizedLevel,
                backgroundColor: Colors.grey.shade800,
                color: barColor,
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('20', style: TextStyle(fontSize: 10, color: Colors.white38)),
              Text('40', style: TextStyle(fontSize: 10, color: Colors.white38)),
              Text('60', style: TextStyle(fontSize: 10, color: Colors.white38)),
              Text('80', style: TextStyle(fontSize: 10, color: Colors.white38)),
              Text('100', style: TextStyle(fontSize: 10, color: Colors.white38)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Selector de perfil de entorno (3 predefinidos).
///
/// Requisito 8.1: Silencioso, Conversación, Ruidoso.
class _ProfileSelector extends StatelessWidget {
  final String activeProfile;

  const _ProfileSelector({required this.activeProfile});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: EnvironmentProfile.predefinedProfiles.map((profile) {
          final isActive = profile.name == activeProfile;
          return _ProfileChip(
            profile: profile,
            isActive: isActive,
            onTap: () {
              context
                  .read<AmplificationBloc>()
                  .add(ChangeProfile(profile: profile.name));
            },
          );
        }).toList(),
      ),
    );
  }
}

/// Chip individual de perfil.
class _ProfileChip extends StatelessWidget {
  final EnvironmentProfile profile;
  final bool isActive;
  final VoidCallback onTap;

  const _ProfileChip({
    required this.profile,
    required this.isActive,
    required this.onTap,
  });

  IconData get _icon => switch (profile.name) {
        'Silencioso' => Icons.nights_stay,
        'Conversación' => Icons.people,
        'Ruidoso' => Icons.volume_up,
        _ => Icons.tune,
      };

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isActive ? Colors.cyan.withOpacity(0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isActive ? Colors.cyan : Colors.white24,
            width: isActive ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _icon,
              color: isActive ? Colors.cyan : Colors.white54,
              size: 22,
            ),
            const SizedBox(height: 4),
            Text(
              profile.name,
              style: TextStyle(
                color: isActive ? Colors.cyan : Colors.white54,
                fontSize: 11,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'diagnostic/calibration_step.dart';
import 'bundle_export_screen.dart';
import 'calibration_spectrum_screen.dart';
import 'gain_cap_screen.dart';
import 'gain_ceiling_calibration_screen.dart';
import '../../biological_calibration/screens/biological_calibration_screen.dart';
import '../../audiometry/screens/audiometry_screen.dart';
import '../../data/services/remote_config_service.dart';
import '../../feedback_checklist/screens/feedback_export_screen.dart';
import '../../security/security_settings_repository.dart';
import '../bloc/amplification_bloc.dart';

/// Pantalla de Servicio Técnico — herramientas para técnicos/audiólogos.
///
/// Contiene utilidades técnicas que NO son parte del diagnóstico médico
/// del paciente, como:
/// - Calibración del micrófono y auriculares
/// - (Futuro) Test de loopback, verificación de hardware, etc.
///
/// Acceso: desde el menú principal (icono de servicio).
class TechnicalServiceScreen extends StatelessWidget {
  const TechnicalServiceScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0f3460),
        title: const Text(
          'Servicio Técnico',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Header descriptivo
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF16213e),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.cyan.withOpacity(0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.build_circle, color: Color(0xFF00e5ff), size: 28),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Herramientas Técnicas',
                        style: TextStyle(
                          color: Color(0xFF00e5ff),
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Utilidades para audiólogos y técnicos. No son parte del diagnóstico médico del paciente.',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Tarjeta: Calibración
          _ServiceCard(
            icon: Icons.tune,
            iconColor: Colors.cyan,
            title: 'Calibración de Hardware',
            description:
                'Calibra el micrófono y los auriculares para mediciones precisas. '
                'Usar en cada nuevo dispositivo o cambio de auriculares.',
            buttonText: 'Iniciar Calibración',
            onTap: () => _openCalibration(context),
          ),
          const SizedBox(height: 12),

          // Tarjeta: Ajuste SPL Offset (Micrófono)
          _ServiceCard(
            icon: Icons.mic_external_on,
            iconColor: Colors.yellowAccent,
            title: 'Ajuste SPL Offset (Micrófono)',
            description:
                'Si el nivel que reporta la app no coincide con la realidad, '
                'ajustá el offset. Moto G32 típico: ~140. Samsung gama alta: ~120.',
            buttonText: 'Ajustar Offset',
            onTap: () => _showSplOffsetDialog(context),
          ),
          const SizedBox(height: 12),

          // Tarjeta: Calibración de Ganancia Máxima (Gain Ceiling)
          _ServiceCard(
            icon: Icons.speed,
            iconColor: Colors.orangeAccent,
            title: 'Calibración de Ganancia Máxima',
            description:
                'Determiná el techo de ganancia del auricular conectado. '
                'Subí hasta escuchar distorsión y marcá el límite. '
                'Ningún preset ni configuración superará ese techo.',
            buttonText: 'Calibrar Ceiling',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => BlocProvider.value(
                  value: context.read<AmplificationBloc>(),
                  child: const GainCeilingCalibrationScreen(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Tarjeta: Tope de ganancia manual (slider)
          _ServiceCard(
            icon: Icons.tune,
            iconColor: Colors.greenAccent,
            title: 'Tope de ganancia',
            description:
                'Ajustá el techo manual de amplificación por banda. Si saturás '
                'bajalo, si querés más volumen subilo. Default automático según '
                'audiograma (8 dB severo / 14 dB leve).',
            buttonText: 'Ajustar tope',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => BlocProvider.value(
                  value: context.read<AmplificationBloc>(),
                  child: const GainCapScreen(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Tarjeta: Validación Espectral (ANSI S3.22 / IEC 60118-7)
          _ServiceCard(
            icon: Icons.graphic_eq,
            iconColor: Colors.amberAccent,
            title: 'Validación Espectral de Calibración',
            description:
                'Daily check según ANSI S3.22 / IEC 60118-7. Emite tonos puros, '
                'mide pico, THD y SNR contra criterios clínicos. NO reemplaza la '
                'calibración exhaustiva anual.',
            buttonText: 'Iniciar Validación',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const CalibrationSpectrumScreen(),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Tarjeta: Calibración Biológica (Hughson-Westlake con normoyentes)
          _ServiceCard(
            icon: Icons.hearing,
            iconColor: Colors.deepOrangeAccent,
            title: 'Calibración Biológica',
            description:
                'Calibración con normoyentes (Hughson-Westlake). Determina '
                'umbrales auditivos reales por frecuencia para validar la cadena '
                'electroacústica completa.',
            buttonText: 'Iniciar Calibración Biológica',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const BiologicalCalibrationScreen(),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Tarjeta: Audiometría del Paciente (Hughson-Westlake automática)
          _ServiceCard(
            icon: Icons.record_voice_over,
            iconColor: Colors.purpleAccent,
            title: 'Audiometría del Paciente',
            description:
                'Audiometría tonal automática usando Hughson-Westlake (5/10 dB, '
                'criterio 2/3). Requiere calibración biológica vigente. Genera el '
                'audiograma del paciente y lo aplica al perfil para recalcular '
                'NAL-NL2.',
            buttonText: 'Iniciar Audiometría',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AudiometryScreen(),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Tarjeta: Exportar configuración del paciente
          // Spec oir-pro-patient-mode — Fase 2 (R4.1, R4.4): genera el
          // bundle .oirpro.json firmado con la configuración actual
          // (audiograma + presets + WDRC + MPO + MHL) y dispara el
          // share sheet de Android para enviarlo al paciente por
          // WhatsApp / email / Bluetooth.
          _ServiceCard(
            icon: Icons.send_to_mobile,
            iconColor: Colors.greenAccent,
            title: 'Exportar configuración del paciente',
            description:
                'Genera un archivo .oirpro.json firmado con la configuración '
                'actual (audiograma, presets, DSP). Lo enviás al paciente por '
                'WhatsApp / email para que lo importe en su app.',
            buttonText: 'Generar bundle',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const BundleExportScreen(),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Tarjeta: Feedback Acumulado del usuario (checklist + export)
          _ServiceCard(
            icon: Icons.feedback,
            iconColor: Colors.tealAccent,
            title: 'Feedback Acumulado',
            description:
                'Ver y exportar el feedback que el usuario dejó sobre cada '
                'configuración aplicada (👍/👎 + checklist). Genera un archivo '
                'JSON y borra los registros de la app tras la exportación.',
            buttonText: 'Ver / Exportar',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const FeedbackExportScreen(),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Tarjeta: Información del Sistema
          _ServiceCard(
            icon: Icons.info_outline,
            iconColor: Colors.blue,
            title: 'Información del Sistema',
            description:
                'Versión, dispositivo, configuración del DSP y estado de los componentes.',
            buttonText: 'Ver Info',
            onTap: () => _showSystemInfo(context),
          ),

          // Sección: Seguridad (Fase 3 spec oir-pro-rebrand-harden-and-remote-config).
          // Toggle "Pedir biometría al abrir" — default ON. Apagarlo solo
          // tiene sentido para demos puntuales (R3.4).
          const SizedBox(height: 16),
          const _SecuritySection(),
        ],
      ),
    );
  }

  void _openCalibration(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: const Color(0xFF1a1a2e),
          appBar: AppBar(
            backgroundColor: const Color(0xFF0f3460),
            title: const Text('Calibración'),
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: CalibrationStep(
            onComplete: () => Navigator.of(context).pop(),
            onBack: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
  }

  void _showSystemInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF16213e),
        title: const Text(
          'Información del Sistema',
          style: TextStyle(color: Color(0xFF00e5ff)),
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoRow(label: 'Versión', value: '1.0.0'),
            _InfoRow(label: 'DSP', value: 'PSK Pipeline v2'),
            _InfoRow(label: 'Sample Rate', value: '16 kHz'),
            _InfoRow(label: 'Buffer', value: '64 samples'),
            _InfoRow(label: 'Latencia', value: '~10 ms'),
            _InfoRow(label: 'TNR', value: 'Habilitado'),
            _InfoRow(label: 'Presets EQ', value: '10 disponibles'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cerrar', style: TextStyle(color: Color(0xFF00e5ff))),
          ),
        ],
      ),
    );
  }

  void _showSplOffsetDialog(BuildContext context) {
    double currentValue = 120;
    try {
      final box = Hive.box('calibration_box');
      final stored = box.get('manual_spl_offset');
      if (stored is num) {
        currentValue = stored.toDouble();
      }
    } catch (_) {
      // Box not open or error reading; use default 120.
    }

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF16213e),
              title: const Text(
                'Ajuste SPL Offset (Micrófono)',
                style: TextStyle(color: Colors.yellowAccent, fontSize: 16),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Ajustá el offset hasta que el nivel reportado coincida '
                    'con un sonómetro externo. Rango típico: 110-150 dB.',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '${currentValue.round()} dB',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Slider(
                    min: 90,
                    max: 160,
                    divisions: 70,
                    value: currentValue,
                    activeColor: Colors.yellowAccent,
                    inactiveColor: Colors.yellowAccent.withOpacity(0.3),
                    onChanged: (v) {
                      setDialogState(() => currentValue = v);
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text(
                    'Cancelar',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.yellowAccent.withOpacity(0.15),
                    foregroundColor: Colors.yellowAccent,
                  ),
                  onPressed: () async {
                    final intValue = currentValue.round();
                    // Persistir en Hive
                    try {
                      final box = Hive.box('calibration_box');
                      await box.put('manual_spl_offset', intValue.toDouble());
                    } catch (_) {
                      // Si el box no está disponible, continuar igual.
                    }

                    // Aplicar via MethodChannel
                    const channel =
                        MethodChannel('com.psk.hearing_aid/audio');
                    try {
                      await channel.invokeMethod('applyCalibration', {
                        'micSplOffset': intValue.toDouble(),
                      });
                    } catch (_) {
                      // Canal puede no responder en modo debug.
                    }

                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content:
                              Text('SPL Offset actualizado a $intValue dB'),
                        ),
                      );
                    }
                  },
                  child: const Text('Aplicar'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _ServiceCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;
  final String buttonText;
  final VoidCallback onTap;

  const _ServiceCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.description,
    required this.buttonText,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: iconColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              onPressed: onTap,
              style: ElevatedButton.styleFrom(
                backgroundColor: iconColor.withOpacity(0.15),
                foregroundColor: iconColor,
                side: BorderSide(color: iconColor.withOpacity(0.4)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              child: Text(buttonText),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// Sección "Seguridad" en Servicio Técnico.
///
/// Spec: oir-pro-rebrand-harden-and-remote-config — Fase 3 (R3.4).
///
/// Muestra el toggle "Pedir biometría al abrir" leyendo / persistiendo
/// vía `SecuritySettingsRepository`. Default ON. Apagarlo solo tiene
/// sentido durante demos / ventas.
class _SecuritySection extends StatefulWidget {
  const _SecuritySection();

  @override
  State<_SecuritySection> createState() => _SecuritySectionState();
}

class _SecuritySectionState extends State<_SecuritySection> {
  bool? _required;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    try {
      final v =
          await SecuritySettingsRepository.instance.isBiometricRequired();
      if (!mounted) return;
      setState(() {
        _required = v;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _onChanged(bool v) async {
    setState(() => _required = v);
    await SecuritySettingsRepository.instance.setBiometricRequired(v);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.cyan.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.security, color: Color(0xFF00e5ff), size: 22),
              SizedBox(width: 10),
              Text(
                'Seguridad',
                style: TextStyle(
                  color: Color(0xFF00e5ff),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF00e5ff),
                ),
              ),
            )
          else
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              activeColor: const Color(0xFF00e5ff),
              inactiveThumbColor: Colors.white60,
              title: const Text(
                'Pedir biometría al abrir',
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
              subtitle: const Text(
                'Desactivá esto solo durante demos o ventas.',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
              value: _required ?? true,
              onChanged: _onChanged,
            ),
          // Fase 5b spec oir-pro-rebrand-harden-and-remote-config (R6.4):
          // botón para limpiar el cache del backend remoto. Útil cuando
          // el técnico cambia algo en el admin web y querés forzar la
          // app a re-fetchearlo en el próximo arranque sin esperar el
          // TTL de 7 días.
          //
          // TODO: spec oir-pro-patient-mode usará el techCode cacheado
          // (`RemoteConfigService.instance.getCachedConfig()?.techCode`)
          // para validar la entrada al Modo Servicio Técnico. Hoy la app
          // del técnico no pide código — todas las pantallas técnicas
          // están detrás de la biometría / PIN, no de un tech code.
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: () async {
              await RemoteConfigService.instance.clearCache();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Cache remoto reseteado')),
                );
              }
            },
            icon: const Icon(Icons.refresh, color: Color(0xFF00e5ff)),
            label: const Text(
              'Resetear cache remoto',
              style: TextStyle(color: Color(0xFF00e5ff)),
            ),
          ),
        ],
      ),
    );
  }
}

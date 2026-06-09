// Spec oir-pro-patient-mode — Fase 2 (Task 2.2).
//
// Form de "Exportar configuración del paciente": el técnico llena
// nombre + notas + default preset y dispara `BundleExporter.exportBundle`
// con los valores actuales (audiograma + presets + WDRC + MPO + MHL)
// leídos desde los repositorios y el estado del `AmplificationBloc`.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../bundle_export/bundle_exporter.dart';
import '../../domain/audiogram_driven_presets/bundle_builder.dart';
import '../../domain/audiogram_driven_presets/custom_preset_record.dart';
import '../../domain/audiogram_driven_presets/style_applicator.dart';
import '../../domain/entities/audiogram.dart';
import '../../domain/entities/eq_preset.dart';
import '../../domain/entities/prescription_mode.dart';
import '../../domain/entities/wdrc_params.dart';
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_state.dart';

/// Pantalla "Exportar para paciente" — genera el `.oirpro.json` firmado
/// y lo dispara al share sheet.
///
/// Estilo consistente con `TechnicalServiceScreen` (dark `#1a1a2e`,
/// accent cyan `#00e5ff`).
class BundleExportScreen extends StatefulWidget {
  const BundleExportScreen({super.key});

  @override
  State<BundleExportScreen> createState() => _BundleExportScreenState();
}

class _BundleExportScreenState extends State<BundleExportScreen> {
  final _patientNameController = TextEditingController();
  final _notesController = TextEditingController();

  /// Lista de nombres de presets disponibles (predefinidos + custom).
  /// Se carga en `initState` para poblar el dropdown.
  List<String> _presetNames = const [];

  /// Preset elegido como default en el dropdown. `null` mientras los
  /// presets se cargan.
  String? _defaultPresetName;

  /// `true` mientras corre `_onGenerate` para evitar re-disparos.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadPresetOptions();
  }

  @override
  void dispose() {
    _patientNameController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// Lee los presets disponibles para mostrarlos en el dropdown:
  /// - Estilos audiogram-driven (Normal, Voice Clarity, etc.)
  /// - "Sin amplificación" (bypass)
  /// - Custom presets persistidos (lista del `ProfileRepository`).
  /// - Fallback al `activeEqPreset` del estado si todo falla.
  Future<void> _loadPresetOptions() async {
    final bloc = context.read<AmplificationBloc>();
    final names = <String>{};

    // 1. Estilos audiogram-driven (mismos que se exportan).
    for (final s in StyleApplicator.supportedStyles) {
      names.add(s);
    }
    names.add('Sin amplificación');

    // 2. Presets personalizados persistidos en el repo.
    try {
      final customs = await bloc.profileRepository.getCustomPresets();
      for (final c in customs) {
        names.add(c.name);
      }
    } catch (_) {
      // Si el repo falla seguimos con los predefinidos solamente.
    }

    // 3. Default = preset activo en el bloc, sino el primero disponible.
    String? initialDefault;
    final state = bloc.state;
    if (state is AmplificationActive && state.activeEqPreset.isNotEmpty) {
      initialDefault = state.activeEqPreset;
    }
    if (initialDefault == null || !names.contains(initialDefault)) {
      initialDefault = names.isNotEmpty ? names.first : null;
    }

    if (!mounted) return;
    setState(() {
      _presetNames = names.toList()..sort();
      _defaultPresetName = initialDefault;
    });
  }

  /// Construye el bundle con los valores actuales y dispara el share
  /// sheet vía `BundleExporter`.
  Future<void> _onGenerate() async {
    if (_busy) return;
    final defaultPreset = _defaultPresetName;
    if (defaultPreset == null || defaultPreset.isEmpty) {
      _showSnack('Elegí un preset por defecto.');
      return;
    }

    setState(() => _busy = true);
    try {
      final bloc = context.read<AmplificationBloc>();

      // 1. Audiograma del paciente (default si no hay uno persistido).
      final audiogram = await bloc.audiogramRepository.getAudiogram() ??
          Audiogram.defaultAudiogram();

      // 2. Lista de presets para el bundle: predefinidos + custom.
      final presets = await _collectPresets(bloc);

      // 3. WDRC + MPO + MHL: derivados del estado activo del bloc si
      //    está `AmplificationActive`, sino defaults seguros.
      final state = bloc.state;
      final wdrc = _wdrcFromState(state);
      final mpo = _mpoFromState(state);
      final mhlEnabled = state is AmplificationActive ? state.mhlActive : false;

      // 4. Generar y compartir.
      final exporter = BundleExporter();
      final File file = await exporter.exportBundle(
        audiogram: audiogram,
        presets: presets,
        wdrc: wdrc,
        mpoThresholdDbSpl: mpo,
        mhlEnabled: mhlEnabled,
        defaultPresetName: defaultPreset,
        patientName: _patientNameController.text.trim().isEmpty
            ? null
            : _patientNameController.text.trim(),
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
      );

      if (!mounted) return;
      final filename = file.uri.pathSegments.last;
      _showSnack('Bundle generado: $filename');
    } on StateError catch (e) {
      // HMAC_SECRET no configurado u otra precondición.
      _showSnack('No se pudo generar: ${e.message}');
    } catch (e) {
      _showSnack('Error al generar bundle: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Junta los presets audiogram-driven (con ganancias NAL-NL2 reales)
  /// + un preset "Sin amplificación" plano + custom del repo.
  ///
  /// El paciente ve ambos tipos en el selector y elige según preferencia:
  /// - Presets con nombre de estilo (Normal, Voice Clarity, etc.):
  ///   ganancias prescritas por NAL-NL2 + delta del estilo.
  /// - "Sin amplificación": bypass (ganancias 0 en todas las bandas).
  Future<List<EqPreset>> _collectPresets(AmplificationBloc bloc) async {
    final byName = <String, EqPreset>{};

    // 1. Generar presets audiogram-driven con ganancias reales.
    final audiogram = await bloc.audiogramRepository.getAudiogram() ??
        Audiogram.defaultAudiogram();
    try {
      final builder = BundleBuilder();
      final baseBundle = builder.buildFromAudiogram(
        audiogram,
        mode: PrescriptionMode.quiet,
        derivedAt: DateTime.now().toUtc(),
      );
      for (final styleName in StyleApplicator.supportedStyles) {
        final styled = StyleApplicator.applyStyle(baseBundle, styleName);
        final gains = styled.gainsDb.toList();
        double avg(List<double> xs, double fb) =>
            xs.isEmpty ? fb : xs.reduce((a, b) => a + b) / xs.length;
        byName[styleName] = EqPreset(
          name: styleName,
          description: 'Audiograma-driven ($styleName)',
          gains: gains,
          compressionRatio: avg(styled.compressionRatios, 2.0),
          compressionKnee: avg(styled.compressionKneesDbSpl, 55.0),
          expansionKnee: styled.expansionKneeDbSpl,
        );
      }
    } catch (e) {
      // Si falla la generación audiogram-driven, caer a los legacy.
      // ignore: deprecated_member_use_from_same_package
      for (final p in EqPreset.allPresets) {
        byName[p.name] = p;
      }
    }

    // 2. Siempre incluir un preset "Sin amplificación" (plano, ganancias 0)
    //    para que el paciente pueda comparar con/sin prescripción.
    byName['Sin amplificación'] = const EqPreset(
      name: 'Sin amplificación',
      description: 'Bypass — sin ganancia prescrita (solo reducción de ruido)',
      gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      compressionRatio: 1.2,
      compressionKnee: 60.0,
    );

    // 3. Custom presets del repo (ya tienen ganancias audiogram-driven).
    try {
      final customs = await bloc.profileRepository.getCustomPresets();
      for (final CustomPresetRecord c in customs) {
        final gains = c.bundle.gainsDb.toList();
        double avg(List<double> xs, double fallback) =>
            xs.isEmpty ? fallback : xs.reduce((a, b) => a + b) / xs.length;
        byName[c.name] = EqPreset(
          name: c.name,
          description: 'Preset personalizado',
          gains: gains,
          compressionRatio: avg(c.bundle.compressionRatios, 2.0),
          compressionKnee: avg(c.bundle.compressionKneesDbSpl, 55.0),
          expansionKnee: c.bundle.expansionKneeDbSpl,
        );
      }
    } catch (_) {
      // Si la lectura falla seguimos con los que ya tenemos.
    }
    return byName.values.toList();
  }

  /// Resuelve los `WdrcParams` actuales a partir del bundle activo en
  /// el bloc. Si todavía no se aplicó ningún bundle, retorna defaults.
  WdrcParams _wdrcFromState(AmplificationState state) {
    if (state is! AmplificationActive) return const WdrcParams();
    final bundle = state.bundle;
    if (bundle == null) return const WdrcParams();
    double avg(List<double> xs, double fallback) =>
        xs.isEmpty ? fallback : xs.reduce((a, b) => a + b) / xs.length;
    return WdrcParams(
      expansionKnee: bundle.expansionKneeDbSpl,
      compressionKnee: avg(bundle.compressionKneesDbSpl, 55.0),
      compressionRatio: avg(bundle.compressionRatios, 2.0),
      attackMs: bundle.wdrcAttackMs,
      releaseMs: bundle.wdrcReleaseMs,
    );
  }

  /// Resuelve el MPO broadband del bundle activo. Default 100 dB SPL si
  /// no hay bundle aplicado.
  double _mpoFromState(AmplificationState state) {
    if (state is! AmplificationActive) return 100.0;
    final bundle = state.bundle;
    if (bundle == null) return 100.0;
    final list = bundle.mpoProfileDbSpl;
    if (list.isEmpty) return 100.0;
    // El pipeline usa el mínimo del perfil como threshold broadband
    // (ver `_resolveBroadbandMpo` en `amplification_bloc.dart`).
    return list.reduce((a, b) => a < b ? a : b);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0f3460),
        title: const Text(
          'Exportar para paciente',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Header(),
          const SizedBox(height: 16),
          _SectionCard(
            title: 'Datos del paciente',
            children: [
              TextField(
                controller: _patientNameController,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration(
                  label: 'Nombre del paciente',
                  hint: 'Opcional — se usa en el nombre de archivo',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notesController,
                style: const TextStyle(color: Colors.white),
                maxLines: 4,
                minLines: 2,
                decoration: _inputDecoration(
                  label: 'Notas',
                  hint: 'Opcional — observaciones clínicas',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: 'Preset por defecto',
            children: [
              if (_defaultPresetName == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
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
                DropdownButtonFormField<String>(
                  value: _defaultPresetName,
                  dropdownColor: const Color(0xFF16213e),
                  iconEnabledColor: const Color(0xFF00e5ff),
                  style: const TextStyle(color: Colors.white),
                  decoration: _inputDecoration(label: 'Preset al iniciar'),
                  items: _presetNames
                      .map(
                        (name) => DropdownMenuItem<String>(
                          value: name,
                          child: Text(
                            name,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _defaultPresetName = v);
                  },
                ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _busy ? null : _onGenerate,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.greenAccent,
                      ),
                    )
                  : const Icon(Icons.send_to_mobile, color: Colors.greenAccent),
              label: Text(
                _busy ? 'Generando...' : 'Generar y compartir',
                style: const TextStyle(color: Colors.greenAccent),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.greenAccent.withOpacity(0.15),
                foregroundColor: Colors.greenAccent,
                side: BorderSide(color: Colors.greenAccent.withOpacity(0.4)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration({required String label, String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: const TextStyle(color: Color(0xFF00e5ff)),
      hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
      filled: true,
      fillColor: const Color(0xFF0f3460),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: Colors.cyan.withOpacity(0.3)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF00e5ff)),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
      ),
      child: Row(
        children: const [
          Icon(Icons.send_to_mobile, color: Colors.greenAccent, size: 28),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Bundle de fitting',
                  style: TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Genera un archivo .oirpro.json firmado con la '
                  'configuración actual (audiograma, presets, WDRC, MPO, MHL). '
                  'Pasalo al paciente por WhatsApp / email para que lo importe '
                  'en su app.',
                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _SectionCard({required this.title, required this.children});

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
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFF00e5ff),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

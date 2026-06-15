// Pantalla "Diagnóstico DSP" del técnico (spec
// `tecnico-paciente-feature-parity` · Task 12.1 · Requirements 6.1, 6.2, 6.3,
// 6.4, 6.10, 6.11, 6.12).
//
// Esta pantalla es la versión técnica de la `DiagnosticoDspScreen` del
// paciente (`PACIENTE/oir_pro_patient_app/lib/presentation/
// diagnostico_dsp_screen.dart`). El comportamiento — máquina de estados,
// duración nominal de 15 s, polling 1 Hz, generación de WAV+JSON,
// share sheet — replica al paciente bit a bit. La paleta de colores y
// el nombre del archivo (`diag_YYYYMMDD_HHMMSS.wav`, sin el prefijo
// `dsp_` que usa el paciente) son propios del técnico:
//
//   * Tema oscuro técnico (no se reutiliza `kPatientCyan`).
//   * Nombre del WAV: `diag_${YYYYMMDD_HHMMSS}.wav`, formato dictado por
//     la regex `^diag_\d{8}_\d{6}\.wav$` del design.md.
//
// La pantalla obtiene del [AmplificationBloc]:
//   * Estado del motor (engine running) vía `state is AmplificationActive`.
//   * Último `AudiogramDrivenBundle` aplicado (`bloc.lastBundle`) para el
//     snapshot clínico del JSON.
//   * Flags de modos: `state.mhlActive`, `state.musicModeActive` y el
//     mirror público `bloc.isSmartEnabled`.
//   * Audiograma actual (`bloc.currentAudiogram`).
//   * Comfort, NR, DNN intensity desde `bloc.settingsRepository` (lecturas
//     sincrónicas — los getters del repositorio ya saneann NaN/null y
//     clamp-ean al rango).
//   * `compressionRatio` EFECTIVAMENTE aplicado vía
//     `bloc.computeEffectiveCompressionRatio(bundle)` y MPO broadband
//     vía `bloc.computeBroadbandMpo(bundle)`.

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/diagnostic_metadata.dart';
import '../../data/services/diagnostic_export_service.dart';
import '../../data/services/local_downloads_service.dart';
import '../../domain/entities/audiogram.dart';
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_state.dart';
import 'diagnostico_dsp_helpers.dart';

// ─── Paleta del técnico (tema oscuro propio) ────────────────────────────────
//
// Replica los colores de `SimulatorScreen` y otras pantallas técnicas
// (`Color(0xFF0a1628)` background, `Color(0xFF16213e)` superficies,
// `Color(0xFF0f3460)` acentos). NO se importa `kPatientCyan`; la pantalla
// es independiente del paciente en lo visual.

const Color _kTechBg = Color(0xFF0a1628);
const Color _kTechSurface = Color(0xFF16213e);
const Color _kTechAccent = Color(0xFF0f3460);
const Color _kTechCyan = Color(0xFF1abc9c); // accent verde-azulado del técnico
const Color _kTechRed = Color(0xFFE53935);
const Color _kTechGreen = Color(0xFF43A047);
const Color _kTechAmber = Color(0xFFFFB300);

/// Estados del state machine de la pantalla.
///
/// Replica el del paciente (`ScreenState` en
/// `PACIENTE/.../diagnostico_dsp_screen.dart`).
///
///   Idle → PreCheck → Recording → Completed → Sharing → Completed
///                  ↘  Error                  ↗
///   Recording → Idle (early stop, descartar)
///   Recording → Error (getProgress=-1 antes de 15 s)
///   Error → Idle (Aceptar)
///   Completed → Idle (Nueva grabación)
enum DiagnosticoScreenState {
  idle,
  preCheck,
  recording,
  completed,
  sharing,
  error,
}

/// Pantalla de diagnóstico DSP del técnico.
///
/// Captura 15 s de audio dual-channel (left=pre-DSP, right=post-DSP) y
/// produce un par WAV+JSON exportable. Todos los textos están en español.
class DiagnosticoDspScreen extends StatefulWidget {
  const DiagnosticoDspScreen({super.key});

  @override
  State<DiagnosticoDspScreen> createState() => DiagnosticoDspScreenState();
}

@visibleForTesting
class DiagnosticoDspScreenState extends State<DiagnosticoDspScreen>
    with SingleTickerProviderStateMixin {
  // ─── State machine ──────────────────────────────────────────────────────
  DiagnosticoScreenState _screenState = DiagnosticoScreenState.idle;
  int _countdownSeconds = 15;
  String _errorMessage = '';

  // ─── Polling ────────────────────────────────────────────────────────────
  Timer? _progressTimer;

  /// Intervalo de polling de `getDiagnosticRecordingProgress()`.
  ///
  /// 1 Hz ± 50 ms según la spec (Req 6.3).
  static const Duration _progressPollInterval = Duration(milliseconds: 1000);

  // ─── Tracking de archivos de la última grabación ────────────────────────
  String? _lastBaseName;
  String? _lastDirectory;
  String? _lastWavPath;
  String? _lastJsonPath;

  // ─── Servicio de exportación ────────────────────────────────────────────
  final DiagnosticExportService _exportService = DiagnosticExportService();

  // ─── Servicio de guardado local (Descargas) ──────────────────────────────
  // Reusa el canal nativo `com.psk.hearing_aid/local_downloads`
  // (`LocalDownloadsChannel.kt`), ya registrado en `MainActivity`. NO depende
  // del share sheet de `share_plus`, así que es una vía de escape cuando el
  // share falla.
  final LocalDownloadsService _downloadsService = LocalDownloadsService();

  // ─── Animación pulsante del botón de grabar ─────────────────────────────
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  // ─── Getters para tests ─────────────────────────────────────────────────
  DiagnosticoScreenState get screenState => _screenState;
  int get countdownSeconds => _countdownSeconds;
  String get errorMessage => _errorMessage;
  String? get lastWavPath => _lastWavPath;
  String? get lastJsonPath => _lastJsonPath;

  // ─── Lifecycle ──────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  // ─── Filename helper ────────────────────────────────────────────────────

  /// Genera el nombre base del archivo de diagnóstico siguiendo el formato
  /// `diag_YYYYMMDD_HHMMSS` (sin extensión).
  ///
  /// Replica la regex `^diag_\d{8}_\d{6}\.wav$` del design.md (Req 6.2).
  /// El timestamp es local del dispositivo, según la spec.
  static String generateBaseName(DateTime now) {
    final y = now.year.toString().padLeft(4, '0');
    final mo = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final h = now.hour.toString().padLeft(2, '0');
    final mi = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    return 'diag_$y$mo${d}_$h$mi$s';
  }

  // ─── State machine transitions ──────────────────────────────────────────

  /// Pulsación del botón de grabación.
  ///
  /// - Si está [recording], dispara stop manual (descartar la grabación).
  /// - Si está [idle], dispara el flujo: PreCheck → Recording.
  /// - Cualquier otro estado se ignora.
  Future<void> onRecordPressed() async {
    if (_screenState == DiagnosticoScreenState.recording) {
      await _stopRecordingManually();
      return;
    }
    if (_screenState != DiagnosticoScreenState.idle) return;

    // Idle → PreCheck.
    setState(() => _screenState = DiagnosticoScreenState.preCheck);

    // Pre-check: el motor de audio debe estar corriendo (Req 6.11).
    final bloc = context.read<AmplificationBloc>();
    final engineActive = bloc.state is AmplificationActive;
    if (!engineActive) {
      _transitionToError(
        'El motor de audio debe estar activo para grabar. '
        'Verifique que la amplificación esté encendida.',
      );
      return;
    }

    // Resolver directorio de almacenamiento.
    Directory? dir;
    try {
      dir = await getExternalStorageDirectory();
    } catch (_) {
      dir = null;
    }
    if (dir == null) {
      _transitionToError(
        'No se pudo acceder al almacenamiento externo. '
        'Verifique los permisos de la app.',
      );
      return;
    }

    // Generar nombre del WAV con timestamp local del dispositivo (Req 6.2).
    final now = DateTime.now();
    final baseName = generateBaseName(now);
    final wavFilename = '$baseName.wav';
    _lastBaseName = baseName;
    _lastDirectory = dir.path;
    _lastWavPath = '${dir.path}/$wavFilename';
    _lastJsonPath = '${dir.path}/$baseName.json';

    // Iniciar grabación nativa.
    bool started = false;
    try {
      started = await bloc.audioBridge.startDiagnosticRecording(wavFilename);
    } catch (_) {
      started = false;
    }
    if (!started) {
      // Req 6.12: start retorna false → mensaje de error específico, NO
      // generar JSON. No hay WAV parcial todavía (el nativo no abrió el
      // archivo) pero borramos defensivamente si quedó algo huérfano.
      await _deletePartialWavSafe();
      _transitionToError(
        'No se pudo iniciar la grabación. '
        'Verifique el espacio disponible y los permisos de almacenamiento.',
      );
      return;
    }

    // PreCheck → Recording.
    setState(() {
      _screenState = DiagnosticoScreenState.recording;
      _countdownSeconds = 15;
    });
    _pulseController.repeat(reverse: true);
    _startProgressPolling();
  }

  /// Inicia el polling de progreso a 1 Hz (Req 6.3).
  void _startProgressPolling() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(_progressPollInterval, (_) => _pollProgress());
  }

  /// Tick de polling: lee el progreso, actualiza el countdown y dispara la
  /// transición Completed cuando se alcanzan los 15 s.
  Future<void> _pollProgress() async {
    if (!mounted || _screenState != DiagnosticoScreenState.recording) {
      _progressTimer?.cancel();
      return;
    }

    int elapsedMs;
    try {
      elapsedMs = await context
          .read<AmplificationBloc>()
          .audioBridge
          .getDiagnosticRecordingProgress();
    } catch (_) {
      elapsedMs = -1;
    }

    if (!mounted || _screenState != DiagnosticoScreenState.recording) return;

    if (elapsedMs < 0) {
      // Req 6.12: getProgress=-1 antes de 15 s → ruta de error.
      // Borramos el WAV parcial e intentamos un stop best-effort para
      // que el handler nativo libere el archivo, pero NO generamos JSON.
      _progressTimer?.cancel();
      _pulseController.stop();
      _pulseController.reset();
      await _bestEffortStopAndDeletePartial();
      _transitionToError(
        'Error interno de grabación. '
        'La grabación se interrumpió antes de los 15 segundos. '
        'Intente nuevamente.',
      );
      return;
    }

    final newCountdown = computeCountdown(elapsedMs);
    if (newCountdown <= 0) {
      // 15 s alcanzados — finalizar la grabación.
      await _finalizeRecording();
      return;
    }

    setState(() => _countdownSeconds = newCountdown);
  }

  /// Stop manual antes de los 15 s. Descarta la grabación (Req 6.4).
  ///
  /// Llama a `stopDiagnosticRecording()` y, sin importar el código de
  /// retorno (0/1/-1), borra el WAV parcial y vuelve a Idle. NO genera
  /// JSON. La spec describe este caso como "descartar grabación".
  Future<void> _stopRecordingManually() async {
    _progressTimer?.cancel();
    _pulseController.stop();
    _pulseController.reset();

    final bloc = context.read<AmplificationBloc>();
    int result;
    try {
      result = await bloc.audioBridge.stopDiagnosticRecording();
    } catch (_) {
      result = -1;
    }

    if (!mounted) return;

    // Caso `-1` durante stop manual: ya estamos descartando, así que
    // tratamos cualquier resultado como "ir a Idle". Si fue `-1`, igual
    // intentamos limpiar el archivo parcial.
    await _deletePartialWavSafe();

    setState(() {
      _screenState = DiagnosticoScreenState.idle;
      _countdownSeconds = 15;
      _errorMessage = '';
    });
    // Después de descartar, el archivo no debería ser exportable.
    _lastWavPath = null;
    _lastJsonPath = null;
    // Mantener un `result` distinto de 0 silencia un warning de variable
    // no usada en algunos linters; lo descartamos explícitamente.
    // ignore: unused_local_variable
    final _ = result;
  }

  /// Finaliza la grabación cuando se alcanzan los 15 s exactos.
  ///
  /// 1. Cancela el timer de polling.
  /// 2. Invoca `stopDiagnosticRecording()`.
  /// 3. Si retorna 0 (éxito), genera el JSON y transiciona a Completed.
  /// 4. Si retorna -1 (error), borra el WAV parcial y va a Error (Req 6.12).
  /// 5. Si retorna 1 (descartado), va a Idle (no debería ocurrir aquí porque
  ///    no fue un stop manual, pero lo manejamos defensivamente).
  Future<void> _finalizeRecording() async {
    _progressTimer?.cancel();
    _pulseController.stop();
    _pulseController.reset();

    final bloc = context.read<AmplificationBloc>();
    int stopResult;
    try {
      stopResult = await bloc.audioBridge.stopDiagnosticRecording();
    } catch (_) {
      stopResult = -1;
    }

    if (!mounted) return;

    if (stopResult == -1) {
      // Req 6.12: stop=-1 → borrar WAV parcial, NO generar JSON.
      await _deletePartialWavSafe();
      _transitionToError(
        'Error al cerrar la grabación. '
        'El archivo no se pudo guardar correctamente. Intente nuevamente.',
      );
      return;
    }

    if (stopResult == 1) {
      // Descartado — no debería pasar en finalización por timer, pero por
      // robustez volvemos a Idle.
      await _deletePartialWavSafe();
      setState(() {
        _screenState = DiagnosticoScreenState.idle;
        _countdownSeconds = 15;
      });
      return;
    }

    // stopResult == 0 — generar JSON acompañante (Req 6.5, 6.6, 6.7, 6.8).
    final ok = await _generateMetadataJson(bloc);
    if (!mounted) return;

    if (!ok) {
      // Si la generación del JSON falla, borrar WAV para evitar exportar
      // un par inconsistente.
      await _deletePartialWavSafe();
      _transitionToError(
        'No se pudo generar el archivo de metadatos. Intente nuevamente.',
      );
      return;
    }

    setState(() {
      _screenState = DiagnosticoScreenState.completed;
      _countdownSeconds = 0;
    });
  }

  /// Genera el archivo JSON acompañante invocando [DiagnosticExportService].
  ///
  /// Lee del bloc el snapshot clínico actual: bundle, audiograma, settings,
  /// estado de modos y device info. Devuelve `true` si la escritura se
  /// realizó correctamente.
  Future<bool> _generateMetadataJson(AmplificationBloc bloc) async {
    final baseName = _lastBaseName;
    final directory = _lastDirectory;
    if (baseName == null || directory == null) return false;

    try {
      final bundle = bloc.lastBundle;
      if (bundle == null) {
        // Sin bundle aplicado no se puede componer un snapshot clínico
        // válido — el motor estaría corriendo con defaults legacy.
        return false;
      }

      final settings = bloc.settingsRepository;
      final audiogram = bloc.currentAudiogram ?? Audiogram.defaultAudiogram();

      // Device info — falla tolerante.
      Map<String, dynamic> deviceInfo;
      try {
        deviceInfo = await bloc.audioBridge.getDeviceInfo();
      } catch (_) {
        deviceInfo = const <String, dynamic>{};
      }
      final device = DeviceMetadata(
        inputDevice: deviceInfo['inputDeviceName'] as String? ?? 'Desconocido',
        outputDevice:
            deviceInfo['outputDeviceName'] as String? ?? 'Desconocido',
        bluetoothDevice: deviceInfo['bluetoothName'] as String? ?? '',
        bluetoothConnectionType:
            (deviceInfo['bluetoothIsA2dp'] as bool? ?? false) ? 'A2DP' : '',
      );

      final state = bloc.state;
      final activePreset = state is AmplificationActive
          ? state.activeEqPreset
          : 'Desconocido';

      // Compression knee broadband: representativo del bundle. Usamos el
      // promedio de los 12 valores por banda (todos están dentro de
      // [35, 65] dB SPL por validación del bundle).
      final knees = bundle.compressionKneesDbSpl;
      final compressionKneeBroadband = knees.isEmpty
          ? 50.0
          : knees.reduce((a, b) => a + b) / knees.length;

      final wdrc = WdrcMetadata(
        expansionKnee: bundle.expansionKneeDbSpl,
        // El bundle no expone `expansionRatio` (siempre asumido 1.0 por
        // contrato del motor). Usamos 1.0 como valor literal.
        expansionRatio: 1.0,
        compressionKnee: compressionKneeBroadband,
        // Ratio EFECTIVAMENTE aplicado, con offset Comodidad (Req 6.7).
        compressionRatio: bloc.computeEffectiveCompressionRatio(bundle),
        attackMs: bundle.wdrcAttackMs,
        releaseMs: bundle.wdrcReleaseMs,
      );

      final dnn = DnnMetadata(
        enabled: true,
        intensity: settings.dnnIntensity,
      );

      // Snapshot del bundle: nivel pre-DNN y origen del nivel WDRC. Si el
      // bridge no expone `getDspStageMetrics()` (no está en la interfaz
      // de [AudioBridge] del técnico), caemos a los sentinelas
      // documentados en `DiagnosticMetadata` (`-1.0` / `'local'`).
      double preDnnLevelDb = -1.0;
      String wdrcLevelSource = 'local';

      _lastJsonPath = await _exportService.generateMetadata(
        directory: directory,
        baseName: baseName,
        recordedSamples: DiagnosticMetadata.defaultTotalSamplesPerChannel,
        audiogramThresholds: audiogram.thresholds,
        activePreset: activePreset,
        eqGainsDb: List<double>.from(bundle.gainsDb),
        wdrc: wdrc,
        mpoThresholdDbSpl: bloc.computeBroadbandMpo(bundle),
        dnn: dnn,
        nrLevel: settings.nrLevel,
        // El técnico no persiste `tnrEnabled` global; la pantalla
        // Smart Scene lo despacha por preset. Default `false` para no
        // afirmar un estado que no se está rastreando.
        tnrEnabled: false,
        device: device,
        appVersion: '1.0.0',
        mhlPrescriptionEnabled: state is AmplificationActive
            ? state.mhlActive
            : false,
        musicModeEnabled: state is AmplificationActive
            ? state.musicModeActive
            : false,
        smartEnabled: bloc.isSmartEnabled,
        effectiveComfort: settings.comfort,
        preDnnLevelDb: preDnnLevelDb,
        wdrcLevelSource: wdrcLevelSource,
      );
      return true;
    } catch (e, st) {
      // Logueamos la causa real para diagnóstico (Req: no tragar errores).
      // El llamador (`_finalizeRecording`) sigue tratando `false` como
      // "no se pudo generar el JSON" → borra el WAV y va a Error.
      developer.log(
        'generación de metadatos JSON falló: $e',
        name: 'DiagnosticoDsp',
        error: e,
        stackTrace: st,
        level: 1000,
      );
      return false;
    }
  }

  /// Pulsación del botón "Exportar" en estado Completed (Req 6.10).
  Future<void> onExportPressed() async {
    if (_screenState != DiagnosticoScreenState.completed) return;
    final wav = _lastWavPath;
    final json = _lastJsonPath;
    if (wav == null || json == null) {
      _showSnackBar(DiagnosticExportService.fileNotFoundError);
      return;
    }

    setState(() => _screenState = DiagnosticoScreenState.sharing);

    try {
      await _exportService.export(wav, json);
    } on FileSystemException catch (e) {
      _showSnackBar(e.message);
    } catch (e, st) {
      // Antes este catch tragaba la excepción y mostraba un mensaje
      // genérico. Ahora logueamos la causa real y la mostramos en el
      // snackbar para poder diagnosticar fallos del share sheet
      // (ej: FileProvider, plugin no registrado, intent sin handler).
      developer.log(
        'onExportPressed: share falló: $e',
        name: 'DiagnosticoDsp',
        error: e,
        stackTrace: st,
        level: 1000,
      );
      _showSnackBar('Error al exportar: $e');
    }

    if (!mounted) return;
    setState(() => _screenState = DiagnosticoScreenState.completed);
  }

  /// Pulsación del botón "Descargar" en estado Completed.
  ///
  /// Copia el WAV y el JSON de la última grabación a la carpeta pública
  /// **Descargas** del teléfono vía el canal nativo
  /// `com.psk.hearing_aid/local_downloads` (`LocalDownloadsChannel.kt`).
  /// A diferencia de [onExportPressed], NO depende del share sheet de
  /// `share_plus`, así que sirve como vía de escape cuando el share falla.
  ///
  /// Tolerante a fallos: si la copia falla, muestra el error real en el
  /// snackbar y loguea la causa.
  Future<void> onDownloadPressed() async {
    if (_screenState != DiagnosticoScreenState.completed) return;
    final wav = _lastWavPath;
    final json = _lastJsonPath;
    final base = _lastBaseName;
    if (wav == null || json == null || base == null) {
      _showSnackBar(DiagnosticExportService.fileNotFoundError);
      return;
    }

    try {
      final wavSaved = await _downloadsService.saveFileToDownloads(
        sourcePath: wav,
        filename: '$base.wav',
        mimeType: 'audio/wav',
      );
      final jsonSaved = await _downloadsService.saveFileToDownloads(
        sourcePath: json,
        filename: '$base.json',
        mimeType: 'application/json',
      );
      if (!mounted) return;
      _showSnackBar('Guardado en $wavSaved y $jsonSaved');
    } on LocalDownloadsException catch (e, st) {
      developer.log(
        'onDownloadPressed: guardado local falló: ${e.message}',
        name: 'DiagnosticoDsp',
        error: e,
        stackTrace: st,
        level: 1000,
      );
      if (!mounted) return;
      _showSnackBar('Error al descargar: ${e.message}');
    } catch (e, st) {
      developer.log(
        'onDownloadPressed: error inesperado: $e',
        name: 'DiagnosticoDsp',
        error: e,
        stackTrace: st,
        level: 1000,
      );
      if (!mounted) return;
      _showSnackBar('Error al descargar: $e');
    }
  }

  /// Vuelve a Idle desde el estado Error.
  void onDismissError() {
    setState(() {
      _screenState = DiagnosticoScreenState.idle;
      _errorMessage = '';
      _countdownSeconds = 15;
    });
  }

  /// Vuelve a Idle desde Completed para iniciar una nueva grabación.
  void onNewRecording() {
    setState(() {
      _screenState = DiagnosticoScreenState.idle;
      _countdownSeconds = 15;
    });
  }

  // ─── Helpers internos ───────────────────────────────────────────────────

  void _transitionToError(String message) {
    if (!mounted) return;
    setState(() {
      _screenState = DiagnosticoScreenState.error;
      _errorMessage = message;
    });
  }

  /// Borra el WAV parcial de la última grabación si existe (Req 6.12).
  ///
  /// Tolera errores de IO (archivo bloqueado, permiso denegado) sin
  /// propagar — la limpieza es best-effort.
  Future<void> _deletePartialWavSafe() async {
    final wav = _lastWavPath;
    if (wav == null) return;
    try {
      final f = File(wav);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {
      // best-effort: ignorar.
    }
  }

  /// Llama a `stopDiagnosticRecording()` ignorando el resultado y luego
  /// borra el WAV parcial. Usado en la ruta de error por
  /// `getProgress=-1` antes de los 15 s.
  Future<void> _bestEffortStopAndDeletePartial() async {
    try {
      await context.read<AmplificationBloc>().audioBridge
          .stopDiagnosticRecording();
    } catch (_) {
      // ignorar — ya estamos en ruta de error.
    }
    await _deletePartialWavSafe();
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  // ─── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AmplificationBloc, AmplificationState>(
      buildWhen: (prev, next) =>
          prev.runtimeType != next.runtimeType ||
          (prev is AmplificationActive &&
              next is AmplificationActive &&
              (prev.mhlActive != next.mhlActive ||
                  prev.musicModeActive != next.musicModeActive ||
                  prev.activeEqPreset != next.activeEqPreset)),
      builder: (context, state) {
        final engineRunning = state is AmplificationActive;
        return PopScope(
          // Bloqueamos el back gesture mientras grabamos para evitar dejar
          // el archivo huérfano (paralelo al `WillPopScope` del paciente).
          canPop: _screenState != DiagnosticoScreenState.recording,
          child: Scaffold(
            backgroundColor: _kTechBg,
            appBar: AppBar(
              title: const Text('Diagnóstico DSP'),
              backgroundColor: _kTechAccent,
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            body: SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Column(
                  children: [
                    _buildContextInfo(state),
                    const SizedBox(height: 12),
                    _buildStatusIndicators(
                      engineRunning: engineRunning,
                      mhlActive: state is AmplificationActive
                          ? state.mhlActive
                          : false,
                      musicActive: state is AmplificationActive
                          ? state.musicModeActive
                          : false,
                    ),
                    const SizedBox(height: 8),
                    Expanded(child: _buildMainContent()),
                    if (_screenState == DiagnosticoScreenState.error)
                      _buildErrorDisplay(),
                    if (_screenState == DiagnosticoScreenState.completed)
                      _buildExportActions(),
                    if (_screenState == DiagnosticoScreenState.completed)
                      _buildNewRecordingButton(),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildContextInfo(AmplificationState state) {
    final preset = state is AmplificationActive
        ? state.activeEqPreset
        : 'Sin preset activo';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _kTechSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kTechAccent),
      ),
      child: Row(
        children: [
          const Icon(Icons.science_outlined, color: Colors.white70, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Snapshot clínico de la sesión',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Preset activo: $preset',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusIndicators({
    required bool engineRunning,
    required bool mhlActive,
    required bool musicActive,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _StatusDot(
          label: 'Engine',
          active: engineRunning,
          activeColor: _kTechGreen,
        ),
        _StatusDot(
          label: 'MHL',
          active: mhlActive,
          activeColor: _kTechAmber,
        ),
        _StatusDot(
          label: 'Música',
          active: musicActive,
          activeColor: _kTechCyan,
        ),
      ],
    );
  }

  Widget _buildMainContent() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildRecordButton(),
        const SizedBox(height: 24),
        _buildCountdownTimer(),
        const SizedBox(height: 12),
        _buildStatusText(),
      ],
    );
  }

  Widget _buildRecordButton() {
    final isRecording = _screenState == DiagnosticoScreenState.recording;
    final isIdle = _screenState == DiagnosticoScreenState.idle;
    final canPress = isIdle || isRecording;

    Widget button = GestureDetector(
      onTap: canPress ? onRecordPressed : null,
      child: Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isRecording
              ? _kTechRed
              : (canPress ? _kTechAccent : const Color(0xFF2A2A2A)),
          boxShadow: isRecording
              ? [
                  BoxShadow(
                    color: _kTechRed.withOpacity(0.4),
                    blurRadius: 16,
                    spreadRadius: 4,
                  ),
                ]
              : null,
        ),
        child: Icon(
          isRecording ? Icons.stop : Icons.fiber_manual_record,
          color: isRecording ? Colors.white : _kTechRed,
          size: 40,
        ),
      ),
    );

    if (isRecording) {
      return AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          return Transform.scale(scale: _pulseAnimation.value, child: child);
        },
        child: button,
      );
    }
    return button;
  }

  Widget _buildCountdownTimer() {
    final showLive = _screenState == DiagnosticoScreenState.recording ||
        _screenState == DiagnosticoScreenState.completed;
    return Text(
      showLive ? '$_countdownSeconds' : '15',
      style: TextStyle(
        color: _screenState == DiagnosticoScreenState.recording
            ? _kTechRed
            : Colors.white70,
        fontSize: 48,
        fontWeight: FontWeight.w300,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  Widget _buildStatusText() {
    String text;
    Color color;
    switch (_screenState) {
      case DiagnosticoScreenState.idle:
        text = 'Presione para grabar 15 s';
        color = Colors.white70;
        break;
      case DiagnosticoScreenState.preCheck:
        text = 'Verificando…';
        color = Colors.white70;
        break;
      case DiagnosticoScreenState.recording:
        text = 'Grabando…';
        color = _kTechRed;
        break;
      case DiagnosticoScreenState.completed:
        text = 'Grabación completada';
        color = _kTechGreen;
        break;
      case DiagnosticoScreenState.sharing:
        text = 'Exportando…';
        color = _kTechCyan;
        break;
      case DiagnosticoScreenState.error:
        text = 'Error';
        color = _kTechRed;
        break;
    }
    return Text(
      text,
      style: TextStyle(
        color: color,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      textAlign: TextAlign.center,
    );
  }

  Widget _buildErrorDisplay() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _kTechRed.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _kTechRed.withOpacity(0.3)),
        ),
        child: Column(
          children: [
            Text(
              _errorMessage,
              style: const TextStyle(
                color: _kTechRed,
                fontSize: 13,
                height: 1.3,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: onDismissError,
              child: const Text(
                'Aceptar',
                style: TextStyle(color: _kTechRed),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExportActions() {
    final sharing = _screenState == DiagnosticoScreenState.sharing;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: sharing ? null : onExportPressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: _kTechCyan,
                foregroundColor: _kTechBg,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: const Icon(Icons.share),
              label: const Text(
                'Exportar',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: sharing ? null : onDownloadPressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: _kTechAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: const Icon(Icons.download),
              label: const Text(
                'Descargar',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNewRecordingButton() {
    return TextButton(
      onPressed: onNewRecording,
      child: const Text(
        'Nueva grabación',
        style: TextStyle(color: Colors.white70, fontSize: 13),
      ),
    );
  }
}

// ─── Helper widgets ─────────────────────────────────────────────────────────

class _StatusDot extends StatelessWidget {
  final String label;
  final bool active;
  final Color activeColor;

  const _StatusDot({
    required this.label,
    required this.active,
    required this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? activeColor : const Color(0xFF424242),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : Colors.white38,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

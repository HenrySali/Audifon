/// @file audiometry_controller.dart
/// @brief Orquestador (state machine) de la audiometría tonal del paciente.
///
/// Coordina los componentes de la audiometría:
///
///  - [BiologicalCalibrationStore]   — carga la calibración biológica del
///    dispositivo (mapea HL → dBFS por frecuencia).
///  - [SystemVolumeController]       — fija el volumen del sistema al máximo
///    durante la prueba (Requirement 1.3).
///  - [ToneEmitterDbfs]              — emite tonos puros directamente en dBFS.
///  - [AudiometryEngine]             — wrapper de Hughson-Westlake operando
///    en escala dB HL (orden ASHA, criterio 2/3, retest 1000 Hz).
///  - [AudiometryStore]              — persistencia Hive del resultado.
///
/// La clase extiende [ChangeNotifier] para que la pantalla de audiometría
/// (`AudiometryScreen`) se reconstruya ante cada cambio de estado (`phase`,
/// frecuencia actual, nivel HL, presentación, etc.).
///
/// Flujo general:
///
///  ```
///  idle
///   └─ start()
///      ├─ precheck (carga calibración + volumen al máximo)
///      └─ testing (frecuencia por frecuencia, orden ASHA)
///           ├─ playCurrentTone() → si false (outOfRange) → guardar y avanzar
///           ├─ presentationStage=playing → emisión
///           ├─ presentationStage=listening → ventana de respuesta
///           ├─ onUserResponse(heard) | timeout → recordResponse
///           ├─ engine.state == thresholdFound | outOfRange | invalid → guardar
///           └─ todas las freqs → retest 1000 Hz → finalize
///                ├─ saveLast() en Hive
///                └─ phase=complete; el padre invoca onApplyToProfile en
///                  applyToProfile() para despachar UpdateAudiogram.
///  ```
///
/// Orden ASHA de frecuencias (Requirement 3.1):
///   `[1000, 2000, 4000, 8000, 500, 250]` y al final retest a `1000`.
///
/// Ventana de respuesta:
///   tras emitir el tono se espera `toneDurationMs + responseWindowMs`. Si la
///   UI llama `onUserResponse(true)` dentro de ese intervalo se interpreta como
///   `heard=true`; si vence el timer, como `heard=false`.
///
/// Compatibilidad Flutter 3.19.6: no se usan `withValues`,
/// `onPopInvokedWithResult` ni APIs nuevas. Solo `ChangeNotifier` y `Timer`.

library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../biological_calibration/core/hughson_westlake_algorithm.dart';
import '../../biological_calibration/core/system_volume_controller.dart';
import '../../biological_calibration/core/tone_emitter_dbfs.dart';
import '../../biological_calibration/models/biological_calibration_result.dart';
import '../../biological_calibration/store/biological_calibration_store.dart';
import '../../domain/entities/audiogram.dart';
import '../core/audiometry_engine.dart';
import '../models/audiometry_result.dart';
import '../models/frequency_threshold_hl.dart';
import '../store/audiometry_store.dart';

/// Fases visuales/lógicas de la audiometría del paciente.
enum AudiometryPhase {
  /// Estado inicial — todavía no se llamó `start()`.
  idle,

  /// Chequeos previos: calibración biológica disponible, volumen al máximo,
  /// MAC del BT actual coincide con la calibración (TODO: verificación MAC).
  precheck,

  /// Prueba en curso (presentaciones de tonos por frecuencia).
  testing,

  /// Audiometría completa y resultado guardado en Hive.
  complete,

  /// Algún chequeo o paso falló — ver `errorMessage`.
  error,
}

/// Etapa actual de una presentación dentro de la fase `testing`.
///
/// Replica el patrón de [PresentationStage] de la calibración biológica para
/// que la UI pueda dar feedback visual claro durante el ciclo de cada tono.
enum AudiometryPresentationStage {
  /// Sin presentación activa (entre presentaciones, durante el ITI).
  idle,

  /// El emisor está reproduciendo el tono.
  playing,

  /// El tono terminó (o ya está sonando); la app espera la respuesta del
  /// paciente. La UI muestra el botón "LO ESCUCHO" como activo en azul.
  listening,

  /// El paciente presionó "LO ESCUCHO" o el timer venció. Estado breve, se
  /// usa para mostrar el feedback visual ("✓") antes de pasar al ITI.
  recorded,
}

/// Controlador principal de la audiometría del paciente.
class AudiometryController extends ChangeNotifier {
  // ─── Constantes del protocolo ──────────────────────────────────────────

  /// Orden ASHA de frecuencias (Requirement 3.1).
  static const List<int> frequencyOrder = <int>[
    1000,
    2000,
    4000,
    8000,
    500,
    250,
  ];

  /// Frecuencia que se repite al final como retest de consistencia
  /// (Requirement 3.2).
  static const int _retestFreqHz = 1000;

  /// Duración del tono entre rampas (ms). Coincide con el protocolo de la
  /// calibración biológica para mantener trazabilidad.
  static const int toneDurationMs = 1000;

  /// Margen extra (ms) tras el offset del tono donde aún se acepta una
  /// respuesta como válida.
  static const int responseWindowMs = 2500;

  /// ITI mínimo aleatorio entre presentaciones (ms).
  static const int itiMinMs = 1000;

  /// ITI máximo aleatorio entre presentaciones (ms).
  static const int itiMaxMs = 3000;

  /// Umbral por encima del cual la diferencia retest 1000 Hz dispara una
  /// advertencia (Requirement 3.3).
  static const double _retestWarningThresholdDb = 10.0;

  // ─── Dependencias inyectables ──────────────────────────────────────────

  final ToneEmitterDbfs _emitter;
  final SystemVolumeController _volumeController;
  final void Function(List<AudiogramPoint> audiogram) _onApplyToProfile;
  final math.Random _random;

  // ─── Estado expuesto a la UI ───────────────────────────────────────────

  AudiometryPhase _phase = AudiometryPhase.idle;
  int _currentFreqIndex = 0;
  int? _currentFreqHz;
  double _currentLevelHL = 30.0;
  AudiometryPresentationStage _presentationStage =
      AudiometryPresentationStage.idle;
  bool _lastResponseHeard = false;
  int _presentationsCount = 0;
  String? _errorMessage;
  String? _statusText;
  AudiometryResult? _finalResult;
  bool _appliedToProfile = false;

  /// Calibración biológica cargada al iniciar `start()`. `null` antes del
  /// precheck o si el precheck falló por falta de calibración.
  BiologicalCalibrationResult? _calibration;

  /// Umbrales encontrados hasta el momento, indexados por frecuencia (Hz).
  /// Se acumula durante `testing`; al `finalize` se copia a [_finalResult].
  final Map<int, FrequencyThresholdHL> _currentThresholds =
      <int, FrequencyThresholdHL>{};

  /// Diferencia (dB HL) entre el umbral original a 1000 Hz y el retest.
  double? _retest1000Diff;

  // ─── Espera de respuesta ───────────────────────────────────────────────

  Completer<bool>? _responseCompleter;
  Timer? _responseTimer;
  bool _disposed = false;

  /// Constructor.
  ///
  /// - [emitter]              — emisor de tonos (no se libera aquí; la
  ///                            lifecycle es del invocador).
  /// - [volumeController]     — fija/verifica volumen del sistema.
  /// - [onApplyToProfile]     — callback que el padre (la pantalla) usa para
  ///                            despachar `UpdateAudiogram` al BLoC. Se invoca
  ///                            desde [applyToProfile] con los puntos del
  ///                            audiograma derivado de [finalResult].
  /// - [seed]                 — semilla opcional para reproducibilidad de
  ///                            tests (afecta los ITI aleatorios).
  AudiometryController({
    required ToneEmitterDbfs emitter,
    required SystemVolumeController volumeController,
    required void Function(List<AudiogramPoint> audiogram) onApplyToProfile,
    int? seed,
  })  : _emitter = emitter,
        _volumeController = volumeController,
        _onApplyToProfile = onApplyToProfile,
        _random = seed != null ? math.Random(seed) : math.Random();

  // ─── Getters públicos ──────────────────────────────────────────────────

  AudiometryPhase get phase => _phase;
  int get currentFreqIndex => _currentFreqIndex;
  int? get currentFreqHz => _currentFreqHz;
  double get currentLevelHL => _currentLevelHL;
  AudiometryPresentationStage get presentationStage => _presentationStage;
  bool get lastResponseHeard => _lastResponseHeard;
  int get presentationsCount => _presentationsCount;
  String? get errorMessage => _errorMessage;
  String? get statusText => _statusText;
  AudiometryResult? get finalResult => _finalResult;
  bool get appliedToProfile => _appliedToProfile;

  /// Calibración biológica cargada en este controller (o `null` si no se
  /// llamó a `start()` o si el precheck falló).
  BiologicalCalibrationResult? get calibration => _calibration;

  /// Vista inmodificable de los umbrales encontrados hasta el momento.
  Map<int, FrequencyThresholdHL> get currentThresholds =>
      Map<int, FrequencyThresholdHL>.unmodifiable(_currentThresholds);

  // ─── API pública ───────────────────────────────────────────────────────

  /// Arranca la audiometría: precheck → testing → complete.
  ///
  /// - Carga la calibración biológica con [BiologicalCalibrationStore.load].
  ///   Si no hay calibración → `error` con mensaje hacia Calibración Biológica.
  /// - Fija el volumen del sistema al máximo. Si falla → `error`.
  /// - TODO: verificar la MAC del BT actual contra `calibration.device.bluetoothMac`.
  ///   Por ahora se omite porque no tenemos un plugin disponible para leer la
  ///   MAC del dispositivo BT activo (Requirement 1.4).
  /// - Recorre [frequencyOrder] usando [AudiometryEngine] por frecuencia.
  /// - Tras todas las frecuencias, hace retest a 1000 Hz con un nuevo engine.
  /// - Construye el [AudiometryResult] y lo persiste con [AudiometryStore.saveLast].
  ///
  /// Nunca lanza: cualquier error termina la sesión en `phase = error` con
  /// `errorMessage` informativo.
  Future<void> start() async {
    if (_disposed) return;
    if (_phase == AudiometryPhase.testing) return;

    _resetSessionState();
    _phase = AudiometryPhase.precheck;
    _statusText = 'Verificando calibración biológica...';
    _errorMessage = null;
    notifyListeners();

    // 1) Cargar la calibración biológica.
    BiologicalCalibrationResult? cal;
    try {
      cal = await BiologicalCalibrationStore.load();
    } catch (e, st) {
      debugPrint('AudiometryController.start: load() falló: $e\n$st');
      cal = null;
    }
    if (_disposed) return;

    if (cal == null) {
      _phase = AudiometryPhase.error;
      _errorMessage = 'Falta calibración biológica. Hacela primero desde '
          'Servicio Técnico → Calibración Biológica';
      _statusText = null;
      notifyListeners();
      return;
    }
    _calibration = cal;

    // 2) Volumen del sistema al máximo (Requirement 1.3).
    _statusText = 'Fijando volumen del sistema al máximo...';
    notifyListeners();

    bool volumeOk = false;
    try {
      volumeOk = await _volumeController.ensureMaxVolume();
    } catch (e, st) {
      debugPrint('AudiometryController.start: ensureMaxVolume falló: $e\n$st');
      volumeOk = false;
    }
    if (_disposed) return;

    if (!volumeOk) {
      _phase = AudiometryPhase.error;
      _errorMessage =
          'No se pudo fijar el volumen del sistema al máximo. Verifica que '
          'el modo No Molestar esté desactivado y vuelve a intentarlo.';
      _statusText = null;
      notifyListeners();
      return;
    }

    // 3) TODO: verificar MAC actual del BT contra cal.device.bluetoothMac.
    //    Requiere un plugin que exponga la MAC del dispositivo BT activo,
    //    todavía no disponible en este proyecto. Cuando exista:
    //      final currentMac = await btService.currentMac();
    //      if (currentMac != cal.device.bluetoothMac) {
    //        await BiologicalCalibrationStore.invalidate();
    //        _phase = AudiometryPhase.error;
    //        _errorMessage = 'Cambió el dispositivo BT respecto a la
    //            calibración. Hacé una nueva calibración biológica.';
    //        notifyListeners();
    //        return;
    //      }

    // 4) Comenzar el barrido de frecuencias.
    _phase = AudiometryPhase.testing;
    _statusText = 'Probando ${frequencyOrder.first} Hz';
    notifyListeners();

    try {
      await _runAllFrequencies(cal);
    } catch (e, st) {
      debugPrint('AudiometryController.start: barrido falló: $e\n$st');
      if (_disposed) return;
      _phase = AudiometryPhase.error;
      _errorMessage = 'Error durante la audiometría: $e';
      _statusText = null;
      notifyListeners();
      return;
    }

    if (_disposed) return;
    if (_phase == AudiometryPhase.error) return;

    // 5) Retest a 1000 Hz (Requirement 3.2).
    await _runRetest1000(cal);
    if (_disposed) return;
    if (_phase == AudiometryPhase.error) return;

    // 6) Finalize: construir resultado y persistir.
    await _finalize(cal);
  }

  /// Llamado desde la UI cuando el paciente presiona "LO ESCUCHO" dentro de
  /// la ventana de respuesta. Si el timer venció antes, este método es no-op.
  void onUserResponse(bool heard) {
    if (_disposed) return;
    final Completer<bool>? c = _responseCompleter;
    if (c == null || c.isCompleted) return;
    // Feedback inmediato a la UI: marcamos "recorded" antes de completar el
    // future para que la pantalla pueda mostrar el cambio de estado al instante.
    _lastResponseHeard = heard;
    _presentationStage = AudiometryPresentationStage.recorded;
    notifyListeners();
    c.complete(heard);
  }

  /// Aplica el resultado final al perfil del usuario despachando
  /// `UpdateAudiogram` vía el callback inyectado en el constructor.
  ///
  /// No-op si todavía no hay [finalResult] o si ya se aplicó previamente.
  Future<void> applyToProfile() async {
    if (_disposed) return;
    final AudiometryResult? r = _finalResult;
    if (r == null) return;
    if (_appliedToProfile) return;

    final List<AudiogramPoint> points = r.toAudiogramPoints();
    try {
      _onApplyToProfile(points);
    } catch (e, st) {
      debugPrint('AudiometryController.applyToProfile: callback falló: $e\n$st');
      _phase = AudiometryPhase.error;
      _errorMessage = 'No se pudo aplicar el audiograma al perfil: $e';
      notifyListeners();
      return;
    }
    _appliedToProfile = true;
    _statusText = 'Audiograma aplicado al perfil. Prescripción NAL-NL2 '
        'recalculada.';
    notifyListeners();
  }

  /// Vuelve al estado inicial [AudiometryPhase.idle]. Cancela cualquier
  /// timer/completer abierto. La UI puede llamar a `start()` nuevamente.
  void retry() {
    if (_disposed) return;
    _cancelResponseWindow();
    _resetSessionState();
    _phase = AudiometryPhase.idle;
    _statusText = null;
    _errorMessage = null;
    notifyListeners();
  }

  // ─── Lógica interna: barrido de frecuencias ────────────────────────────

  /// Recorre [frequencyOrder] aplicando la búsqueda de umbral por frecuencia.
  Future<void> _runAllFrequencies(BiologicalCalibrationResult cal) async {
    for (int i = 0; i < frequencyOrder.length; i++) {
      if (_disposed) return;
      _currentFreqIndex = i;
      final int freq = frequencyOrder[i];
      _statusText = 'Probando $freq Hz';
      notifyListeners();

      final FrequencyThresholdHL? result =
          await _runFrequency(cal: cal, freqHz: freq, isRetest: false);
      if (_disposed) return;
      if (_phase == AudiometryPhase.error) return;
      if (result != null) {
        _currentThresholds[freq] = result;
        notifyListeners();
      }
    }
  }

  /// Ejecuta el retest a 1000 Hz con un nuevo [AudiometryEngine] y calcula
  /// la diferencia con el umbral original. Si la frecuencia 1000 Hz quedó
  /// fuera de rango en el barrido principal, no se hace retest.
  Future<void> _runRetest1000(BiologicalCalibrationResult cal) async {
    final FrequencyThresholdHL? original = _currentThresholds[_retestFreqHz];
    if (original == null || original.outOfRange) {
      // No hay referencia válida para comparar — saltar retest.
      return;
    }

    _statusText = 'Retest $_retestFreqHz Hz para verificar consistencia';
    notifyListeners();

    final FrequencyThresholdHL? retest =
        await _runFrequency(cal: cal, freqHz: _retestFreqHz, isRetest: true);
    if (_disposed) return;
    if (_phase == AudiometryPhase.error) return;
    if (retest == null || retest.outOfRange) return;

    _retest1000Diff = retest.thresholdHL - original.thresholdHL;
    if (_retest1000Diff!.abs() > _retestWarningThresholdDb) {
      _statusText = 'Advertencia: diferencia retest 1000 Hz = '
          '${_retest1000Diff!.abs().toStringAsFixed(1)} dB HL '
          '(>${_retestWarningThresholdDb.toStringAsFixed(0)} dB). '
          'Considere repetir esa frecuencia.';
    }
    notifyListeners();
  }

  /// Búsqueda de umbral en una sola frecuencia. Devuelve el [FrequencyThresholdHL]
  /// resultante (con flags `outOfRange` / `normalLimit` apropiados) o `null`
  /// si la sesión fue cancelada.
  Future<FrequencyThresholdHL?> _runFrequency({
    required BiologicalCalibrationResult cal,
    required int freqHz,
    required bool isRetest,
  }) async {
    final AudiometryEngine engine = AudiometryEngine(
      calibration: cal,
      emitter: _emitter,
    );
    engine.startFrequency(freqHz);
    _currentFreqHz = freqHz;
    _currentLevelHL = engine.currentLevelHL;
    _presentationStage = AudiometryPresentationStage.idle;
    notifyListeners();

    // Loop de presentaciones hasta llegar a un estado terminal.
    while (true) {
      if (_disposed) return null;
      if (_phase != AudiometryPhase.testing) return null;

      _currentLevelHL = engine.currentLevelHL;
      _presentationsCount++;
      _presentationStage = AudiometryPresentationStage.playing;
      notifyListeners();

      // Emitir tono. Si la calibración no soporta el nivel solicitado, el
      // engine marca outOfRange y devuelve false sin emitir.
      bool emitted = false;
      try {
        emitted = await engine.playCurrentTone(durationMs: toneDurationMs);
      } catch (e, st) {
        debugPrint('AudiometryController._runFrequency: '
            'playCurrentTone falló: $e\n$st');
        _phase = AudiometryPhase.error;
        _errorMessage = 'Error al reproducir el tono: $e';
        _statusText = null;
        notifyListeners();
        return null;
      }
      if (_disposed) return null;
      if (_phase != AudiometryPhase.testing) return null;

      if (!emitted) {
        // El motor marcó outOfRange (techo del transductor para esta freq).
        _presentationStage = AudiometryPresentationStage.idle;
        notifyListeners();
        return FrequencyThresholdHL(
          freqHz: freqHz,
          thresholdHL: _currentLevelHL,
          outOfRange: true,
        );
      }

      // Ventana de respuesta: tono + 2500 ms.
      _presentationStage = AudiometryPresentationStage.listening;
      notifyListeners();
      final bool heard = await _waitForResponse();
      if (_disposed) return null;
      if (_phase != AudiometryPhase.testing) return null;

      if (_presentationStage != AudiometryPresentationStage.recorded) {
        _lastResponseHeard = heard;
        _presentationStage = AudiometryPresentationStage.recorded;
        notifyListeners();
      }

      engine.recordResponse(heard);

      // Inspeccionar el estado terminal.
      final HwState state = engine.state;
      if (state == HwState.thresholdFound) {
        final double? th = engine.threshold;
        if (th == null) {
          // Defensivo: no debería pasar; tratarlo como inválido.
          await _interPresentationPause();
          return FrequencyThresholdHL(
            freqHz: freqHz,
            thresholdHL: _currentLevelHL,
            outOfRange: true,
          );
        }
        // Requirement 2.6: -10 dB HL → audición normal o mejor.
        final bool normalLimit = th <= -10.0 + 1e-9;
        return FrequencyThresholdHL(
          freqHz: freqHz,
          thresholdHL: th,
          normalLimit: normalLimit,
        );
      }

      if (state == HwState.outOfRange) {
        return FrequencyThresholdHL(
          freqHz: freqHz,
          thresholdHL: engine.currentLevelHL,
          outOfRange: true,
        );
      }

      if (state == HwState.invalid) {
        // Familiarización falló — registrar como fuera de rango.
        return FrequencyThresholdHL(
          freqHz: freqHz,
          thresholdHL: engine.currentLevelHL,
          outOfRange: true,
        );
      }

      // Estado intermedio (familiarization / descending / ascending) → ITI
      // y nueva presentación.
      await _interPresentationPause();
      if (_disposed) return null;
      if (_phase != AudiometryPhase.testing) return null;
    }
  }

  /// Pausa entre presentaciones: 350 ms de feedback "✓" + ITI aleatorio
  /// dentro de [itiMinMs, itiMaxMs].
  Future<void> _interPresentationPause() async {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (_disposed) return;
    if (_phase != AudiometryPhase.testing) return;
    _presentationStage = AudiometryPresentationStage.idle;
    notifyListeners();
    final int iti = itiMinMs + _random.nextInt(itiMaxMs - itiMinMs + 1);
    await Future<void>.delayed(Duration(milliseconds: iti));
  }

  // ─── Espera de respuesta ───────────────────────────────────────────────

  /// Crea un [Completer<bool>] y un [Timer] que lo completa con `false` al
  /// cabo de `toneDurationMs + responseWindowMs`. Si la UI llama
  /// `onUserResponse(true)` antes, el future se resuelve con `true`.
  Future<bool> _waitForResponse() {
    _cancelResponseWindow();
    final Completer<bool> c = Completer<bool>();
    _responseCompleter = c;
    _responseTimer = Timer(
      const Duration(milliseconds: toneDurationMs + responseWindowMs),
      () {
        if (!c.isCompleted) c.complete(false);
      },
    );
    return c.future;
  }

  /// Limpia timer/completer pendientes. Si el completer aún estaba abierto se
  /// completa con `false` para no dejar futures colgados.
  void _cancelResponseWindow() {
    _responseTimer?.cancel();
    _responseTimer = null;
    final Completer<bool>? c = _responseCompleter;
    _responseCompleter = null;
    if (c != null && !c.isCompleted) c.complete(false);
  }

  // ─── Finalize ──────────────────────────────────────────────────────────

  /// Construye el [AudiometryResult] con los umbrales acumulados, lo persiste
  /// con [AudiometryStore.saveLast] y pasa a [AudiometryPhase.complete].
  Future<void> _finalize(BiologicalCalibrationResult cal) async {
    final DateTime now = DateTime.now();
    final AudiometryResult result = AudiometryResult(
      testedAt: now,
      calibrationMac: cal.device.bluetoothMac,
      calibrationDate: cal.createdAt,
      thresholds: Map<int, FrequencyThresholdHL>.unmodifiable(
        _currentThresholds,
      ),
      retest1000Diff: _retest1000Diff,
      patientAlias: 'Paciente',
    );

    try {
      await AudiometryStore.saveLast(result);
    } catch (e, st) {
      debugPrint('AudiometryController._finalize: saveLast() falló: $e\n$st');
      // No abortamos por un fallo de persistencia: el resultado en memoria
      // sigue siendo válido y aplicable al perfil.
    }
    if (_disposed) return;

    _finalResult = result;
    _phase = AudiometryPhase.complete;
    _presentationStage = AudiometryPresentationStage.idle;
    _currentFreqHz = null;
    _statusText = _retest1000Diff != null &&
            _retest1000Diff!.abs() > _retestWarningThresholdDb
        ? 'Audiometría completa con advertencia de retest 1000 Hz '
            '(${_retest1000Diff!.abs().toStringAsFixed(1)} dB HL).'
        : 'Audiometría completa.';
    notifyListeners();
  }

  // ─── Reset / Cleanup ───────────────────────────────────────────────────

  /// Limpia el estado de la sesión actual sin tocar `_phase` ni callbacks.
  void _resetSessionState() {
    _cancelResponseWindow();
    _currentFreqIndex = 0;
    _currentFreqHz = null;
    _currentLevelHL = 30.0;
    _presentationStage = AudiometryPresentationStage.idle;
    _lastResponseHeard = false;
    _presentationsCount = 0;
    _currentThresholds.clear();
    _retest1000Diff = null;
    _finalResult = null;
    _appliedToProfile = false;
    _calibration = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelResponseWindow();
    super.dispose();
  }
}

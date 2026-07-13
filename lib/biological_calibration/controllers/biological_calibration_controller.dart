/// @file biological_calibration_controller.dart
/// @brief Orquestador (state machine) de la calibración biológica.
///
/// Coordina los componentes de la calibración biológica:
///
///  - `ToneEmitterDbfs`        — emite tonos puros directamente en dBFS
///  - `SystemVolumeController` — fija/verifica el volumen del sistema
///  - `HughsonWestlakeAlgorithm` — máquina de búsqueda de umbral por
///    frecuencia (lógica pura)
///  - `CatchTrialScheduler`    — decide cuándo intercalar catch trials
///  - `BiologicalCalibrationStore` — persistencia Hive de la calibración
///
/// La clase extiende `ChangeNotifier` para que la UI (`BiologicalCalibrationScreen`)
/// se reconstruya ante cada cambio de estado (`phase`, nivel actual, etc.).
///
/// Flujo general:
///
///  ```
///  idle
///   └─ startSession()
///      ├─ setup (chequeo de volumen al máximo)
///      │    └─ ensureMaxVolume()
///      └─ questionnaire (cuestionario por sujeto)
///           └─ submitQuestionnaire(q)
///                ├─ si !eligible → error
///                └─ testing (frecuencia por frecuencia, orden ASHA)
///                     ├─ nextPresentation() → emite tono o catch trial
///                     ├─ onUserResponse(heard) | timeout → false
///                     ├─ recordResponse en HW algorithm
///                     ├─ thresholdFound | outOfRange → siguiente freq
///                     ├─ all freqs done → retest 1000 Hz
///                     └─ retest done → sessionComplete
///                          ├─ addAnotherSubject() → questionnaire (siguiente)
///                          └─ finalize() → allComplete + persist
///  ```
///
/// Orden ASHA de frecuencias (siguiendo Requirement 4):
///   `[1000, 2000, 4000, 8000, 500, 250]` y al final retest a `1000`.
///
/// Ventana de respuesta:
///   tras emitir tono se espera `toneDurationMs + 2500 ms`. Si la UI llama
///   `onUserResponse(true)` dentro de ese intervalo se interpreta como
///   `heard=true`; si vence el timer, como `heard=false`.
///
/// Compatibilidad Flutter 3.19.6: no se usa `withValues`, `onPopInvokedWithResult`
/// ni APIs nuevas. Solo `ChangeNotifier` y `Timer`.

library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/catch_trial_scheduler.dart';
import '../core/hughson_westlake_algorithm.dart';
import '../core/system_volume_controller.dart';
import '../core/tone_emitter_dbfs.dart';
import '../models/biological_calibration_result.dart';
import '../models/catch_trial_stats.dart';
import '../models/eligibility_questionnaire.dart';
import '../models/frequency_threshold.dart';
import '../models/subject_session.dart';
import '../store/biological_calibration_store.dart';

/// Fases visuales/lógicas de la calibración biológica.
enum CalibrationPhase {
  /// Estado inicial — todavía no se ha llamado `startSession()`.
  idle,

  /// Chequeos previos: volumen al máximo, BT conectado, ambiente silencioso.
  setup,

  /// Cuestionario de elegibilidad del sujeto actual.
  questionnaire,

  /// Test en curso (presentaciones de tonos / catch trials).
  testing,

  /// El sujeto actual completó (o invalidó) su sesión.
  sessionComplete,

  /// Todos los sujetos completados y resultado guardado en Hive.
  allComplete,

  /// Algún chequeo o paso falló — ver `errorMessage`.
  error,
}

/// Etapa actual de una presentación dentro de la fase `testing`.
///
/// Se usa para que la UI pueda reflejar visualmente el estado interno del
/// loop de presentaciones (esperando ITI, reproduciendo tono, escuchando
/// respuesta, respuesta registrada).
enum PresentationStage {
  /// Sin presentación activa (entre presentaciones, durante el ITI).
  idle,

  /// El emisor está reproduciendo el tono.
  playing,

  /// El tono terminó (o es catch trial); la app está esperando la respuesta
  /// del sujeto. La UI debe mostrar el botón "LO ESCUCHO" como activo.
  listening,

  /// El sujeto presionó "LO ESCUCHO" o el timer venció. Estado breve, se usa
  /// para dar feedback visual ("✓ Registrado") antes de pasar al ITI.
  recorded,
}

/// Controlador principal de la calibración biológica.
class BiologicalCalibrationController extends ChangeNotifier {
  // ─── Constantes del protocolo ──────────────────────────────────────────

  /// Orden ASHA de frecuencias (Requirement 4.2).
  static const List<int> _frequencyOrder = <int>[
    1000,
    2000,
    4000,
    8000,
    500,
    250,
  ];

  /// Frecuencia que se repite al final como retest de consistencia.
  static const int _retestFreqHz = 1000;

  /// Duración del tono entre rampas (ms). Coincide con [ProtocolInfo].
  static const int toneDurationMs = 1000;

  /// Margen extra (ms) tras el offset del tono donde aún se acepta una
  /// respuesta como válida (Requirement 2.3).
  static const int responseWindowMs = 2500;

  /// ITI mínimo aleatorio entre presentaciones (ms).
  static const int itiMinMs = 1000;

  /// ITI máximo aleatorio entre presentaciones (ms).
  static const int itiMaxMs = 3000;

  /// Tasa de falsos positivos a partir de la cual se invalida la sesión.
  /// (Requirement 2.8 — umbral fuerte tras reinstrucción.)
  static const double _falsePositiveInvalidThreshold = 0.50;

  /// Mínimo de catch trials necesarios para que la tasa sea representativa
  /// (evita invalidar tras 1 solo falso positivo aislado).
  static const int _minCatchTrialsForRateCheck = 3;

  /// Mínimo de sujetos exigido por defecto (Requirement 3.4).
  static const int _minSubjects = 3;

  // ─── Dependencias inyectables ──────────────────────────────────────────

  final ToneEmitterDbfs _emitter;
  final SystemVolumeController _volumeController;
  final math.Random _random;
  final int? _schedulerSeed;
  final bool _enableCatchTrials;

  // ─── Configuración pública ─────────────────────────────────────────────

  /// Cantidad de sujetos objetivo (≥ 3). Configurable en construcción.
  final int totalSubjectsTarget;

  /// Información del dispositivo a usar al construir
  /// `BiologicalCalibrationResult` en `finalize()`. Si es `null`, se rellena
  /// con un placeholder genérico.
  DeviceInfo? deviceInfo;

  /// Información del protocolo. Si es `null`, se construye con los valores
  /// por defecto que aplica este controller.
  ProtocolInfo? protocolInfo;

  // ─── Estado expuesto a la UI ───────────────────────────────────────────

  CalibrationPhase _phase = CalibrationPhase.idle;
  int _currentSubjectIndex = 0; // 1-based una vez que arranca el primer sujeto.
  double? _currentFreqHz;
  double _currentLevelDbFS = -30.0;
  HwState _hwState = HwState.familiarization;
  bool _isCatchTrialPending = false;
  PresentationStage _presentationStage = PresentationStage.idle;
  int _presentationsCount = 0; // total presentaciones del sujeto actual
  bool _lastResponseHeard = false; // resultado de la última respuesta
  final List<SubjectSession> _completedSessions = <SubjectSession>[];
  BiologicalCalibrationResult? _finalResult;
  String? _statusText;
  String? _errorMessage;

  // ─── Estado interno por sujeto ─────────────────────────────────────────

  HughsonWestlakeAlgorithm? _algorithm;
  CatchTrialScheduler? _scheduler;
  EligibilityQuestionnaire? _currentQuestionnaire;
  int _currentFreqIndex = 0;
  bool _isRetest = false;
  final Map<int, double> _currentThresholds = <int, double>{};
  double? _firstThreshold1000DbFS;
  double? _retestThreshold1000DbFS;
  int _presentationIndex = 0;
  int _totalCatchTrials = 0;
  int _falsePositives = 0;
  bool _sessionInvalidated = false;
  DateTime? _subjectStartedAt;

  // ─── Espera de respuesta ───────────────────────────────────────────────

  Completer<bool>? _responseCompleter;
  Timer? _responseTimer;
  bool _disposed = false;

  /// Constructor.
  ///
  /// - [emitter]            — emisor de tonos (no se libera al hacer dispose;
  ///                          la lifecycle es responsabilidad del invocador).
  /// - [volumeController]   — controla volumen del sistema.
  /// - [totalSubjectsTarget] — sujetos exigidos. Se eleva a [_minSubjects]
  ///                          si es menor.
  /// - [enableCatchTrials]  — activa las presentaciones silenciosas de
  ///                          control. Por defecto `false`: en uso típico
  ///                          (3 normoyentes conocidos) no aportan valor y
  ///                          sólo generan invalidaciones por error humano.
  /// - [seed]               — semilla opcional para reproducibilidad de tests
  ///                          (afecta ITI y CatchTrialScheduler).
  BiologicalCalibrationController({
    required ToneEmitterDbfs emitter,
    required SystemVolumeController volumeController,
    int totalSubjectsTarget = _minSubjects,
    bool enableCatchTrials = false,
    int? seed,
    this.deviceInfo,
    this.protocolInfo,
  })  : _emitter = emitter,
        _volumeController = volumeController,
        totalSubjectsTarget = math.max(_minSubjects, totalSubjectsTarget),
        _enableCatchTrials = enableCatchTrials,
        _schedulerSeed = seed,
        _random = seed != null ? math.Random(seed) : math.Random();

  // ─── Getters públicos ──────────────────────────────────────────────────

  CalibrationPhase get phase => _phase;
  int get currentSubjectIndex => _currentSubjectIndex;
  double? get currentFreqHz => _currentFreqHz;
  double get currentLevelDbFS => _currentLevelDbFS;
  HwState get hwState => _hwState;
  bool get isCatchTrialPending => _isCatchTrialPending;
  PresentationStage get presentationStage => _presentationStage;
  int get presentationsCount => _presentationsCount;
  bool get lastResponseHeard => _lastResponseHeard;
  List<SubjectSession> get completedSessions =>
      List<SubjectSession>.unmodifiable(_completedSessions);
  BiologicalCalibrationResult? get finalResult => _finalResult;
  String? get statusText => _statusText;
  String? get errorMessage => _errorMessage;

  /// Cantidad de sesiones válidas acumuladas hasta el momento.
  int get validSessionsCount =>
      _completedSessions.where((SubjectSession s) => s.valid).length;

  /// Cantidad de sesiones válidas que aún faltan para alcanzar el mínimo.
  int get sessionsRemaining =>
      math.max(0, totalSubjectsTarget - validSessionsCount);

  // ─── API pública: arranque y avance ────────────────────────────────────

  /// Inicia la sesión: pasa a [CalibrationPhase.setup], asegura volumen al
  /// máximo y, si todo está OK, deja la sesión lista en
  /// [CalibrationPhase.questionnaire] esperando al primer cuestionario.
  Future<void> startSession() async {
    if (_disposed) return;
    _phase = CalibrationPhase.setup;
    _statusText = 'Configurando volumen del sistema al máximo...';
    _errorMessage = null;
    notifyListeners();

    bool ok = false;
    try {
      ok = await _volumeController.ensureMaxVolume();
    } catch (e, st) {
      debugPrint('startSession: ensureMaxVolume falló: $e\n$st');
      ok = false;
    }
    if (_disposed) return;

    if (!ok) {
      _phase = CalibrationPhase.error;
      _errorMessage =
          'No se pudo fijar el volumen del sistema al máximo. Verifica que '
          'el modo No Molestar esté desactivado y vuelve a intentarlo.';
      notifyListeners();
      return;
    }

    _completedSessions.clear();
    _finalResult = null;
    _currentSubjectIndex = 1;
    _resetSubjectState();
    _phase = CalibrationPhase.questionnaire;
    _statusText = 'Sujeto $_currentSubjectIndex: complete el cuestionario.';
    notifyListeners();
  }

  /// Recibe el cuestionario del sujeto actual. Si es elegible, arranca la
  /// fase de testing en la primera frecuencia; si no, marca error.
  void submitQuestionnaire(EligibilityQuestionnaire q) {
    if (_disposed) return;
    if (_phase != CalibrationPhase.questionnaire) return;

    _currentQuestionnaire = q;
    if (!q.isEligible) {
      _phase = CalibrationPhase.error;
      _errorMessage =
          'El sujeto no cumple los criterios de elegibilidad. Seleccione '
          'otro participante o ajuste las respuestas.';
      notifyListeners();
      return;
    }

    _subjectStartedAt = DateTime.now();
    _startFrequency(_frequencyOrder.first, isRetest: false);
    _phase = CalibrationPhase.testing;
    _statusText = 'Sujeto $_currentSubjectIndex — '
        'Frecuencia ${_currentFreqHz?.round()} Hz';
    notifyListeners();

    // Bootstrap de la primera presentación. Se hace en microtask para que
    // el cambio de fase sea visible en la UI antes de que arranque el tono.
    Future<void>.microtask(nextPresentation);
  }

  /// La UI invoca este método cuando el usuario presiona "LO ESCUCHO" dentro
  /// de la ventana de respuesta. Internamente, el controller también lo
  /// invoca con `heard=false` cuando vence el timer.
  void onUserResponse(bool heard) {
    if (_disposed) return;
    final Completer<bool>? c = _responseCompleter;
    if (c == null || c.isCompleted) return;
    // Feedback inmediato a la UI: marcamos "recorded" antes de completar el
    // future para que la pantalla pueda mostrar el cambio de estado al instante.
    _lastResponseHeard = heard;
    _presentationStage = PresentationStage.recorded;
    notifyListeners();
    c.complete(heard);
  }

  /// Emite el siguiente tono (o catch trial), abre la ventana de respuesta y
  /// procesa el resultado. Se reagenda automáticamente tras el ITI hasta que
  /// la sesión del sujeto termina.
  Future<void> nextPresentation() async {
    if (_disposed) return;
    if (_phase != CalibrationPhase.testing) return;
    final HughsonWestlakeAlgorithm? algo = _algorithm;
    final CatchTrialScheduler? scheduler = _scheduler;
    final double? freqHz = _currentFreqHz;
    if (algo == null || scheduler == null || freqHz == null) return;

    final HwStep step = algo.nextStep();
    _currentLevelDbFS = step.levelDbFS;
    _hwState = step.state;

    final bool isCatchTrial = _enableCatchTrials &&
        scheduler.shouldBeCatchTrial(_presentationIndex);
    _isCatchTrialPending = isCatchTrial;
    _presentationStage = PresentationStage.playing;
    _presentationsCount++;
    _statusText = isCatchTrial
        ? 'Atención (presentación silenciosa)…'
        : '${freqHz.round()} Hz a ${_currentLevelDbFS.toStringAsFixed(0)} dBFS';
    notifyListeners();

    // Emitir (o no, si es catch trial). Cualquier excepción del emisor
    // termina la sesión con error, no se propaga al caller.
    if (!isCatchTrial) {
      try {
        await _emitter.playToneAtDbFS(
          freqHz: freqHz,
          levelDbFS: _currentLevelDbFS,
          durationMs: toneDurationMs,
        );
      } catch (e, st) {
        debugPrint('nextPresentation: emitter falló: $e\n$st');
        _phase = CalibrationPhase.error;
        _errorMessage = 'Error al reproducir el tono: $e';
        notifyListeners();
        return;
      }
    }

    if (_disposed || _phase != CalibrationPhase.testing) return;

    // Entramos en fase de escucha: el botón "LO ESCUCHO" se habilita en la UI.
    _presentationStage = PresentationStage.listening;
    notifyListeners();

    // Abrir ventana de respuesta. El timer cierra la ventana con heard=false
    // si la UI no llama onUserResponse antes.
    final bool heard = await _waitForResponse();
    if (_disposed || _phase != CalibrationPhase.testing) return;

    // Si fue timeout (la UI no llamó onUserResponse), garantizar feedback
    // visual de "registrado" igualmente, antes del ITI.
    if (_presentationStage != PresentationStage.recorded) {
      _lastResponseHeard = heard;
      _presentationStage = PresentationStage.recorded;
      notifyListeners();
    }

    _processResponse(heard: heard, wasCatchTrial: isCatchTrial);
    _presentationIndex++;

    // Si seguimos en testing tras procesar, programar siguiente presentación
    // tras un ITI aleatorio.
    if (!_disposed && _phase == CalibrationPhase.testing) {
      final int iti = itiMinMs + _random.nextInt(itiMaxMs - itiMinMs + 1);
      // Esperar un poco para que el "✓ Registrado" sea visible antes del ITI.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (_disposed || _phase != CalibrationPhase.testing) return;
      _presentationStage = PresentationStage.idle;
      notifyListeners();
      await Future<void>.delayed(Duration(milliseconds: iti));
      if (_disposed || _phase != CalibrationPhase.testing) return;
      // Microtask para evitar crecer la pila si la sesión es muy larga.
      Future<void>.microtask(nextPresentation);
    }
  }

  /// Pasa al siguiente sujeto. Solo válido tras [CalibrationPhase.sessionComplete].
  void addAnotherSubject() {
    if (_disposed) return;
    if (_phase != CalibrationPhase.sessionComplete) return;
    _currentSubjectIndex++;
    _resetSubjectState();
    _phase = CalibrationPhase.questionnaire;
    _statusText = 'Sujeto $_currentSubjectIndex: complete el cuestionario.';
    notifyListeners();
  }

  /// Cierra la calibración: calcula promedio por frecuencia, genera el
  /// resultado y lo persiste en Hive. Falla si no hay suficientes sesiones
  /// válidas.
  Future<void> finalize() async {
    if (_disposed) return;
    if (_phase != CalibrationPhase.sessionComplete) return;

    final List<SubjectSession> validSessions = _completedSessions
        .where((SubjectSession s) => s.valid)
        .toList(growable: false);

    if (validSessions.length < totalSubjectsTarget) {
      _phase = CalibrationPhase.error;
      _errorMessage = 'Se requieren al menos $totalSubjectsTarget sesiones '
          'válidas (hay ${validSessions.length}).';
      notifyListeners();
      return;
    }

    // Promedio por frecuencia.
    final Map<int, FrequencyThreshold> frequencies = <int, FrequencyThreshold>{};
    for (final int freq in _frequencyOrder) {
      final List<double> values = <double>[];
      for (final SubjectSession s in validSessions) {
        final double? v = s.thresholdsDbFS[freq];
        if (v != null) values.add(v);
      }
      if (values.isNotEmpty) {
        frequencies[freq] = FrequencyThreshold.compute(
          freqHz: freq,
          values: values,
        );
      }
    }

    // QualityMetrics globales.
    final List<double> spreads = frequencies.values
        .map((FrequencyThreshold f) => f.spreadDb)
        .toList(growable: false);
    final double spreadMean = spreads.isEmpty
        ? 0.0
        : spreads.reduce((double a, double b) => a + b) / spreads.length;
    final double spreadMax =
        spreads.isEmpty ? 0.0 : spreads.reduce(math.max);
    final int totalCatch = validSessions.fold<int>(
      0,
      (int sum, SubjectSession s) => sum + s.catchTrials.total,
    );
    final int totalFp = validSessions.fold<int>(
      0,
      (int sum, SubjectSession s) => sum + s.catchTrials.falsePositives,
    );
    final double fpRate = totalCatch == 0 ? 0.0 : totalFp / totalCatch;
    final bool allRetestsWithin5 = validSessions.every(
      (SubjectSession s) =>
          s.retestDifferenceDb != null && s.retestDifferenceDb!.abs() <= 5.0,
    );
    final bool calibrationValid = frequencies.length == _frequencyOrder.length &&
        validSessions.length >= totalSubjectsTarget &&
        fpRate <= 0.33;

    final QualityMetrics quality = QualityMetrics(
      overallSpreadMeanDb: spreadMean,
      overallSpreadMaxDb: spreadMax,
      totalCatchTrials: totalCatch,
      totalFalsePositives: totalFp,
      overallFalsePositiveRate: fpRate,
      allRetestsWithin5Db: allRetestsWithin5,
      calibrationValid: calibrationValid,
    );

    final DateTime now = DateTime.now();
    final BiologicalCalibrationResult result = BiologicalCalibrationResult(
      createdAt: now,
      expiresAt: now.add(const Duration(days: 90)),
      device: deviceInfo ?? _defaultDeviceInfo(),
      protocol: protocolInfo ?? _defaultProtocolInfo(),
      sessions: List<SubjectSession>.unmodifiable(_completedSessions),
      frequencies: Map<int, FrequencyThreshold>.unmodifiable(frequencies),
      quality: quality,
    );

    try {
      await BiologicalCalibrationStore.save(result);
    } catch (e, st) {
      debugPrint('finalize: save() falló: $e\n$st');
      _phase = CalibrationPhase.error;
      _errorMessage = 'No se pudo guardar la calibración: $e';
      notifyListeners();
      return;
    }
    if (_disposed) return;

    _finalResult = result;
    _phase = CalibrationPhase.allComplete;
    _statusText = calibrationValid
        ? 'Calibración guardada. ${frequencies.length} frecuencias '
            'promediadas con ${validSessions.length} sujetos válidos.'
        : 'Calibración guardada con advertencias (revise calidad).';
    notifyListeners();
  }

  // ─── Lógica interna ────────────────────────────────────────────────────

  /// Crea un nuevo algoritmo HW + scheduler para una nueva frecuencia.
  /// El primer llamado de cada sujeto debe ir precedido de [_resetSubjectState].
  void _startFrequency(int freqHz, {required bool isRetest}) {
    _isRetest = isRetest;
    _currentFreqHz = freqHz.toDouble();
    _algorithm = HughsonWestlakeAlgorithm();
    _hwState = _algorithm!.state;
    _currentLevelDbFS = _algorithm!.currentLevelDbFS;
    // Reset del scheduler para que la cadencia 1/6 reinicie en cada freq.
    _scheduler ??= CatchTrialScheduler(seed: _schedulerSeed);
    _scheduler!.reset();
    _presentationIndex = 0;
  }

  /// Reinicia todo el estado interno del sujeto antes de aplicarle el
  /// cuestionario. Mantiene la lista global `_completedSessions`.
  void _resetSubjectState() {
    _algorithm = null;
    _scheduler = null;
    _currentQuestionnaire = null;
    _currentFreqIndex = 0;
    _isRetest = false;
    _currentThresholds.clear();
    _firstThreshold1000DbFS = null;
    _retestThreshold1000DbFS = null;
    _presentationIndex = 0;
    _totalCatchTrials = 0;
    _falsePositives = 0;
    _sessionInvalidated = false;
    _subjectStartedAt = null;
    _isCatchTrialPending = false;
    _hwState = HwState.familiarization;
    _currentLevelDbFS = -30.0;
    _currentFreqHz = null;
    _presentationStage = PresentationStage.idle;
    _presentationsCount = 0;
    _lastResponseHeard = false;
    _cancelResponseWindow();
  }

  /// Espera a que la UI responda o a que venza el timer
  /// (`toneDurationMs + responseWindowMs`).
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

  /// Limpia timer y completer pendientes. Si el completer aún estaba abierto
  /// se completa con `false` para no dejar futures colgados.
  void _cancelResponseWindow() {
    _responseTimer?.cancel();
    _responseTimer = null;
    final Completer<bool>? c = _responseCompleter;
    _responseCompleter = null;
    if (c != null && !c.isCompleted) c.complete(false);
  }

  /// Procesa el resultado de la última presentación.
  ///
  ///  - Catch trial → actualiza estadísticas, posible invalidación.
  ///  - Tono normal → delega en `HughsonWestlakeAlgorithm.recordResponse`
  ///    y reacciona al cambio de estado (threshold/outOfRange/invalid).
  void _processResponse({required bool heard, required bool wasCatchTrial}) {
    if (wasCatchTrial) {
      _totalCatchTrials++;
      if (heard) _falsePositives++;
      // Si la tasa de falsos positivos es muy alta, invalidar la sesión.
      if (_totalCatchTrials >= _minCatchTrialsForRateCheck) {
        final double rate = _falsePositives / _totalCatchTrials;
        if (rate > _falsePositiveInvalidThreshold) {
          _sessionInvalidated = true;
          _statusText =
              'Sesión invalidada: tasa de falsos positivos ${(rate * 100).toStringAsFixed(0)}% > '
              '${(_falsePositiveInvalidThreshold * 100).toStringAsFixed(0)}%';
          _finalizeSubjectSession();
        }
      }
      return;
    }

    final HughsonWestlakeAlgorithm? algo = _algorithm;
    if (algo == null) return;
    algo.recordResponse(heard, wasCatchTrial: false);
    _hwState = algo.state;
    _currentLevelDbFS = algo.currentLevelDbFS;

    switch (algo.state) {
      case HwState.thresholdFound:
        _saveCurrentThreshold(algo.threshold);
        _advanceFrequency();
        break;
      case HwState.outOfRange:
        // No se pudo medir el umbral — registramos el último nivel intentado
        // como el límite del transductor para esta frecuencia (Requirement 4.4).
        _saveCurrentThreshold(algo.currentLevelDbFS, outOfRange: true);
        _advanceFrequency();
        break;
      case HwState.invalid:
        _sessionInvalidated = true;
        _statusText = 'Sujeto $_currentSubjectIndex: familiarización fallida.';
        _finalizeSubjectSession();
        break;
      case HwState.familiarization:
      case HwState.descending:
      case HwState.ascending:
        // Continúa el bracketing en la misma frecuencia.
        break;
    }
  }

  /// Guarda el umbral medido en la frecuencia actual.
  void _saveCurrentThreshold(double? thresholdDbFS, {bool outOfRange = false}) {
    if (thresholdDbFS == null) return;
    if (_isRetest) {
      _retestThreshold1000DbFS = thresholdDbFS;
      return;
    }
    final int freq = _frequencyOrder[_currentFreqIndex];
    _currentThresholds[freq] = thresholdDbFS;
    if (freq == _retestFreqHz && !outOfRange) {
      _firstThreshold1000DbFS = thresholdDbFS;
    }
  }

  /// Pasa a la siguiente frecuencia siguiendo el orden ASHA. Cuando se
  /// terminan las frecuencias del orden principal, dispara el retest a
  /// 1000 Hz. Cuando el retest también termina, finaliza la sesión del
  /// sujeto.
  void _advanceFrequency() {
    if (_isRetest) {
      _finalizeSubjectSession();
      return;
    }
    _currentFreqIndex++;
    if (_currentFreqIndex >= _frequencyOrder.length) {
      // Comenzar retest 1000 Hz si tenemos referencia y no fue out-of-range.
      if (_firstThreshold1000DbFS != null) {
        _startFrequency(_retestFreqHz, isRetest: true);
        _statusText = 'Retest 1000 Hz para verificar consistencia';
        notifyListeners();
      } else {
        _finalizeSubjectSession();
      }
    } else {
      _startFrequency(_frequencyOrder[_currentFreqIndex], isRetest: false);
      _statusText = 'Sujeto $_currentSubjectIndex — '
          'Frecuencia ${_currentFreqHz?.round()} Hz';
      notifyListeners();
    }
  }

  /// Construye el `SubjectSession`, lo añade a la lista y pasa la fase a
  /// [CalibrationPhase.sessionComplete]. Cancela cualquier timer abierto.
  void _finalizeSubjectSession() {
    _cancelResponseWindow();
    final EligibilityQuestionnaire q = _currentQuestionnaire ??
        const EligibilityQuestionnaire(
          ageInRange: false,
          normalHearingSelfReported: false,
          noActiveTinnitus: false,
          noCongestion: false,
        );

    double? retestDiff;
    if (_firstThreshold1000DbFS != null && _retestThreshold1000DbFS != null) {
      retestDiff =
          (_retestThreshold1000DbFS! - _firstThreshold1000DbFS!);
    }

    final CatchTrialStats stats = CatchTrialStats(
      total: _totalCatchTrials,
      falsePositives: _falsePositives,
    );

    // Sesión válida si:
    //   - no fue invalidada (familiarización fallida o catch trials malos)
    //   - tasa de catch trials dentro de tolerancia
    //   - tiene al menos una frecuencia medida
    //   - retest dentro de ±10 dB (si existe)
    final bool retestOk =
        retestDiff == null || retestDiff.abs() <= 10.0;
    final bool valid = !_sessionInvalidated &&
        stats.valid &&
        _currentThresholds.isNotEmpty &&
        retestOk;

    final SubjectSession session = SubjectSession(
      id: _currentSubjectIndex,
      alias: 'Sujeto $_currentSubjectIndex',
      testedAt: _subjectStartedAt ?? DateTime.now(),
      questionnaire: q,
      thresholdsDbFS: Map<int, double>.from(_currentThresholds),
      retest1000DbFS: _retestThreshold1000DbFS,
      retestDifferenceDb: retestDiff,
      catchTrials: stats,
      valid: valid,
    );

    _completedSessions.add(session);

    if (!valid) {
      _statusText ??= 'Sujeto $_currentSubjectIndex: sesión inválida.';
    } else if (retestDiff != null && retestDiff.abs() > 10.0) {
      _statusText = 'Advertencia: diferencia retest 1000 Hz = '
          '${retestDiff.abs().toStringAsFixed(1)} dB (>10 dB). '
          'Considere repetir el sujeto.';
    } else {
      _statusText = 'Sujeto $_currentSubjectIndex completado.';
    }

    _phase = CalibrationPhase.sessionComplete;
    notifyListeners();
  }

  // ─── Defaults ──────────────────────────────────────────────────────────

  DeviceInfo _defaultDeviceInfo() {
    return const DeviceInfo(
      phoneModel: 'unknown',
      phoneOs: 'unknown',
      bluetoothDeviceName: 'unknown',
      bluetoothMac: '00:00:00:00:00:00',
      bluetoothCodec: 'unknown',
      systemVolumeLevel: 0,
      systemVolumeMax: 0,
      audioStream: 'STREAM_MUSIC',
    );
  }

  ProtocolInfo _defaultProtocolInfo() {
    return const ProtocolInfo(
      method: 'hughson_westlake_modified',
      stepUpDb: 5.0,
      stepDownDb: 10.0,
      toneDurationMs: toneDurationMs,
      rampMs: ToneEmitterDbfs.rampMs,
      rampType: 'raised_cosine',
      itiMinMs: itiMinMs,
      itiMaxMs: itiMaxMs,
      thresholdCriterion: '2_of_3_ascending',
      sampleRate: ToneEmitterDbfs.sampleRate,
      bitDepth: ToneEmitterDbfs.bitsPerSample,
      channels: ToneEmitterDbfs.channels,
    );
  }

  // ─── Cleanup ───────────────────────────────────────────────────────────

  @override
  void dispose() {
    _disposed = true;
    _cancelResponseWindow();
    super.dispose();
  }
}

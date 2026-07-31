/// Hughson-Westlake threshold-finding state machine for biological calibration.
///
/// Pure logic with no audio I/O or UI dependencies. Callers drive the algorithm
/// by alternating [nextStep] (to know what level to present) and
/// [recordResponse] (to feed back whether the subject heard the tone).
///
/// Reference: `investigaciones/calibracion-biologica-parametros-tecnicos.md`
/// section §8.4.3 — pseudocode of the algorithm per frequency.
///
/// State machine overview:
///   familiarization → descending → ascending → thresholdFound | outOfRange
///                                            └→ invalid (familiarization
///                                               failed at maxDbFS)
library;

/// Phases of the Hughson-Westlake search at a single frequency.
enum HwState {
  /// Initial phase: confirm the subject can hear at the starting level.
  familiarization,

  /// Coarse descent (10 dB steps) until the subject misses a tone.
  descending,

  /// Bracketing phase (5 dB up steps) accumulating the 2/3 response criterion.
  ascending,

  /// Threshold reached: criterion satisfied at [currentLevelDbFS].
  thresholdFound,

  /// Step-up exceeded [maxDbFS] before the criterion was met.
  outOfRange,

  /// Familiarization could not be achieved (subject not normoyente or rig issue).
  invalid,
}

/// Snapshot of the algorithm's next decision.
///
/// `nextStep()` returns this without mutating internal state. The caller uses
/// [levelDbFS] to drive the tone emitter and [state] to drive UI/flow control.
class HwStep {
  /// Level (in dBFS) the caller should present next.
  final double levelDbFS;

  /// Whether this step should be a catch trial (no tone emitted).
  ///
  /// Always `false` here: the catch-trial decision is made by an external
  /// scheduler (see `catch_trial_scheduler.dart`).
  final bool isCatchTrial;

  /// Current state of the underlying algorithm.
  final HwState state;

  /// Resolved threshold in dBFS, populated when [state] is
  /// [HwState.thresholdFound].
  final double? thresholdDbFS;

  const HwStep({
    required this.levelDbFS,
    required this.isCatchTrial,
    required this.state,
    this.thresholdDbFS,
  });
}

/// Hughson-Westlake threshold finder for a single frequency.
///
/// All thresholds are expressed in dBFS (digital scale). The mapping to
/// dB SPL / dB HL is done at a higher layer (`BiologicalCalibrationResult`).
class HughsonWestlakeAlgorithm {
  /// Starting level for familiarization.
  final double initialDbFS;

  /// Lowest level the algorithm is allowed to present.
  final double minDbFS;

  /// Highest level the algorithm is allowed to present.
  final double maxDbFS;

  /// Up-step during the ascending bracketing phase.
  final double stepUp;

  /// Down-step during the descending phase.
  final double stepDown;

  /// Required positive responses at a level to declare threshold (2 of N).
  final int criterionResponses;

  /// Maximum presentations at a single ascending level (3 by default).
  final int criterionPresentations;

  /// Up-step used during familiarization when the subject does not respond.
  final double familiarizationStepUp;

  double _currentLevelDbFS;
  HwState _state;
  int _ascendingCount;
  int _responseCountAtLevel;
  int _presentationsAtLevel;
  double? _threshold;

  HughsonWestlakeAlgorithm({
    this.initialDbFS = -30.0,
    this.minDbFS = -80.0,
    this.maxDbFS = -5.0,
    this.stepUp = 5.0,
    this.stepDown = 10.0,
    this.criterionResponses = 2,
    this.criterionPresentations = 3,
    this.familiarizationStepUp = 10.0,
  })  : _currentLevelDbFS = initialDbFS,
        _state = HwState.familiarization,
        _ascendingCount = 0,
        _responseCountAtLevel = 0,
        _presentationsAtLevel = 0,
        _threshold = null;

  /// Current state of the search.
  HwState get state => _state;

  /// Threshold in dBFS once [HwState.thresholdFound]; otherwise `null`.
  double? get threshold => _threshold;

  /// Level to be presented at the next step.
  double get currentLevelDbFS => _currentLevelDbFS;

  /// Number of ascending series performed so far at this frequency.
  int get ascendingCount => _ascendingCount;

  /// Reset the algorithm to its initial conditions.
  void reset() {
    _currentLevelDbFS = initialDbFS;
    _state = HwState.familiarization;
    _ascendingCount = 0;
    _responseCountAtLevel = 0;
    _presentationsAtLevel = 0;
    _threshold = null;
  }

  /// Compute the step the caller should perform next.
  ///
  /// This method is pure: it does not mutate any internal state. It always
  /// reports `isCatchTrial = false` — the external scheduler decides catch
  /// trials and signals them via the `wasCatchTrial` flag of [recordResponse].
  HwStep nextStep() {
    return HwStep(
      levelDbFS: _currentLevelDbFS,
      isCatchTrial: false,
      state: _state,
      thresholdDbFS: _threshold,
    );
  }

  /// Feed back the subject's response.
  ///
  /// [heard] — `true` if the subject pressed the response button within the
  /// validity window.
  /// [wasCatchTrial] — `true` if the presentation was a catch trial. Catch
  /// trials never advance the threshold-search state (they are tracked by an
  /// external scheduler / stats collector).
  void recordResponse(bool heard, {bool wasCatchTrial = false}) {
    // Catch trials don't drive the state machine. They're accounted for
    // separately to estimate false-positive rate.
    if (wasCatchTrial) return;

    // Terminal states are absorbing.
    if (_state == HwState.thresholdFound ||
        _state == HwState.outOfRange ||
        _state == HwState.invalid) {
      return;
    }

    switch (_state) {
      case HwState.familiarization:
        _handleFamiliarization(heard);
        break;
      case HwState.descending:
        _handleDescending(heard);
        break;
      case HwState.ascending:
        _handleAscending(heard);
        break;
      case HwState.thresholdFound:
      case HwState.outOfRange:
      case HwState.invalid:
        // Already handled above; included for exhaustiveness.
        break;
    }
  }

  // -------------------------------------------------------------------------
  // Internal phase handlers
  // -------------------------------------------------------------------------

  void _handleFamiliarization(bool heard) {
    if (heard) {
      // Subject responded at the familiarization level — start descending.
      _state = HwState.descending;
      return;
    }

    // No response: ramp up by `familiarizationStepUp`.
    final next = _currentLevelDbFS + familiarizationStepUp;
    if (next > maxDbFS) {
      // Subject did not respond even at safe maximum — invalidate session.
      _state = HwState.invalid;
    } else {
      _currentLevelDbFS = next;
    }
  }

  void _handleDescending(bool heard) {
    if (heard) {
      // Keep descending in big steps.
      final next = _currentLevelDbFS - stepDown;
      if (next < minDbFS) {
        // Subject hears even at the floor — clamp without leaving descending.
        _currentLevelDbFS = minDbFS;
      } else {
        _currentLevelDbFS = next;
      }
      return;
    }

    // First miss → switch to ascending bracketing.
    _state = HwState.ascending;
    _ascendingCount++;
    _responseCountAtLevel = 0;
    _presentationsAtLevel = 0;
    final next = _currentLevelDbFS + stepUp;
    if (next > maxDbFS) {
      _state = HwState.outOfRange;
    } else {
      _currentLevelDbFS = next;
    }
  }

  void _handleAscending(bool heard) {
    _presentationsAtLevel++;
    if (heard) {
      _responseCountAtLevel++;
    }

    if (_responseCountAtLevel >= criterionResponses) {
      // Criterion satisfied at this level — threshold found.
      _threshold = _currentLevelDbFS;
      _state = HwState.thresholdFound;
      return;
    }

    if (_presentationsAtLevel >= criterionPresentations) {
      // Criterion failed at this level — step up and reset counters.
      _responseCountAtLevel = 0;
      _presentationsAtLevel = 0;
      final next = _currentLevelDbFS + stepUp;
      if (next > maxDbFS) {
        // Out of safe range without hitting criterion.
        _state = HwState.outOfRange;
      } else {
        _currentLevelDbFS = next;
      }
    }
    // else: still room for more presentations at the same level.
  }
}

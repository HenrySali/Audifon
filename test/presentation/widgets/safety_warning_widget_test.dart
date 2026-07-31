import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'dart:async';

import 'package:hearing_aid_app/presentation/bloc/amplification_bloc.dart';
import 'package:hearing_aid_app/presentation/bloc/amplification_event.dart';
import 'package:hearing_aid_app/presentation/bloc/amplification_state.dart';
import 'package:hearing_aid_app/presentation/widgets/safety_warning_widget.dart';

class MockAmplificationBloc
    extends MockBloc<AmplificationEvent, AmplificationState>
    implements AmplificationBloc {}

/// Reloj manual para los tests del widget. `tester.pump(Duration)` solo
/// avanza el reloj del test framework; el widget compara `DateTime.now()`
/// real, así que sin un reloj mock las diferencias temporales del widget
/// quedan en ~0 ms y el banner nunca aparece.
class TestClock {
  DateTime _now = DateTime(2024, 1, 1, 12, 0, 0);
  DateTime now() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

void main() {
  late MockAmplificationBloc mockBloc;
  late TestClock clock;

  setUp(() {
    mockBloc = MockAmplificationBloc();
    clock = TestClock();
  });

  Widget buildTestWidget({double thresholdDbSpl = 85.0}) {
    return MaterialApp(
      home: BlocProvider<AmplificationBloc>.value(
        value: mockBloc,
        child: SafetyWarningWidget(
          thresholdDbSpl: thresholdDbSpl,
          showAfter: const Duration(seconds: 5),
          hideAfter: const Duration(seconds: 2),
          nowProvider: clock.now,
          child: const Scaffold(
            body: Center(child: Text('Main Content')),
          ),
        ),
      ),
    );
  }

  /// Avanza el reloj mock y bombea el frame del widget en bloques de
  /// 500 ms (el período del Timer.periodic interno) hasta cubrir el
  /// total deseado.
  Future<void> advanceClockAndPump(
    WidgetTester tester,
    Duration total,
  ) async {
    const tick = Duration(milliseconds: 500);
    var elapsed = Duration.zero;
    while (elapsed < total) {
      clock.advance(tick);
      await tester.pump(tick);
      elapsed += tick;
    }
  }

  group('SafetyWarningWidget', () {
    testWidgets('does not show warning initially', (tester) async {
      when(() => mockBloc.state).thenReturn(const AmplificationIdle());

      await tester.pumpWidget(buildTestWidget());

      // Warning text should not be present
      expect(
        find.text('⚠️ Nivel de salida alto — Considere reducir el volumen'),
        findsNothing,
      );
      // Main content should be visible
      expect(find.text('Main Content'), findsOneWidget);
    });

    testWidgets('does not show warning when level is below threshold',
        (tester) async {
      when(() => mockBloc.state).thenReturn(const AmplificationActive(
        inputLevelDb: 70.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
      ));

      await tester.pumpWidget(buildTestWidget());

      // Simulate time passing with level below threshold
      await tester.pump(const Duration(seconds: 6));

      expect(
        find.text('⚠️ Nivel de salida alto — Considere reducir el volumen'),
        findsNothing,
      );
    });

    testWidgets('shows warning after 5 seconds above threshold',
        (tester) async {
      // Setup mock state and stream BEFORE pumpWidget so the
      // BlocListener picks up the high-level event on the first build.
      whenListen(
        mockBloc,
        Stream.fromIterable([
          const AmplificationActive(
            inputLevelDb: 90.0,
            activeProfile: 'Conversación',
            volumeDb: 0.0,
            headphonesConnected: true,
          ),
        ]),
        initialState: const AmplificationActive(
          inputLevelDb: 90.0,
          activeProfile: 'Conversación',
          volumeDb: 0.0,
          headphonesConnected: true,
        ),
      );

      await tester.pumpWidget(buildTestWidget());
      await tester.pump(); // Process the stream event

      // Wait for the evaluation timer (500ms intervals) + 5 seconds.
      // The widget compares wall-clock timestamps via nowProvider, so we
      // also have to advance the test clock alongside the framework pump.
      await advanceClockAndPump(tester, const Duration(seconds: 6));

      // Now the warning should be visible
      expect(
        find.text('⚠️ Nivel de salida alto — Considere reducir el volumen'),
        findsOneWidget,
      );
    });

    testWidgets('warning has dismiss button', (tester) async {
      when(() => mockBloc.state).thenReturn(const AmplificationActive(
        inputLevelDb: 90.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
      ));

      whenListen(
        mockBloc,
        Stream.fromIterable([
          const AmplificationActive(
            inputLevelDb: 90.0,
            activeProfile: 'Conversación',
            volumeDb: 0.0,
            headphonesConnected: true,
          ),
        ]),
        initialState: const AmplificationActive(
          inputLevelDb: 90.0,
          activeProfile: 'Conversación',
          volumeDb: 0.0,
          headphonesConnected: true,
        ),
      );

      await tester.pumpWidget(buildTestWidget());
      await tester.pump();

      // Wait for warning to appear
      await advanceClockAndPump(tester, const Duration(seconds: 6));

      // Verify dismiss button (close icon) exists
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('dismiss button hides warning', (tester) async {
      when(() => mockBloc.state).thenReturn(const AmplificationActive(
        inputLevelDb: 90.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
      ));

      whenListen(
        mockBloc,
        Stream.fromIterable([
          const AmplificationActive(
            inputLevelDb: 90.0,
            activeProfile: 'Conversación',
            volumeDb: 0.0,
            headphonesConnected: true,
          ),
        ]),
        initialState: const AmplificationActive(
          inputLevelDb: 90.0,
          activeProfile: 'Conversación',
          volumeDb: 0.0,
          headphonesConnected: true,
        ),
      );

      await tester.pumpWidget(buildTestWidget());
      await tester.pump();

      // Wait for warning to appear
      await advanceClockAndPump(tester, const Duration(seconds: 6));

      // Tap dismiss button
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      // Warning should be hidden after dismiss
      expect(
        find.text('⚠️ Nivel de salida alto — Considere reducir el volumen'),
        findsNothing,
      );
    });

    testWidgets('main content is always accessible (not blocked)',
        (tester) async {
      when(() => mockBloc.state).thenReturn(const AmplificationActive(
        inputLevelDb: 90.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
      ));

      whenListen(
        mockBloc,
        Stream.fromIterable([
          const AmplificationActive(
            inputLevelDb: 90.0,
            activeProfile: 'Conversación',
            volumeDb: 0.0,
            headphonesConnected: true,
          ),
        ]),
        initialState: const AmplificationActive(
          inputLevelDb: 90.0,
          activeProfile: 'Conversación',
          volumeDb: 0.0,
          headphonesConnected: true,
        ),
      );

      await tester.pumpWidget(buildTestWidget());
      await tester.pump();

      // Wait for warning to appear
      await advanceClockAndPump(tester, const Duration(seconds: 6));

      // Main content should still be visible even with warning showing
      expect(find.text('Main Content'), findsOneWidget);
    });

    testWidgets('warning disappears when state is no longer active',
        (tester) async {
      final stateController =
          StreamController<AmplificationState>.broadcast();

      when(() => mockBloc.state).thenReturn(const AmplificationActive(
        inputLevelDb: 90.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
      ));

      whenListen(
        mockBloc,
        stateController.stream,
        initialState: const AmplificationActive(
          inputLevelDb: 90.0,
          activeProfile: 'Conversación',
          volumeDb: 0.0,
          headphonesConnected: true,
        ),
      );

      await tester.pumpWidget(buildTestWidget());

      // Emit high level state
      stateController.add(const AmplificationActive(
        inputLevelDb: 90.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
      ));
      await tester.pump();

      // Wait for warning to appear
      await advanceClockAndPump(tester, const Duration(seconds: 6));

      expect(
        find.text('⚠️ Nivel de salida alto — Considere reducir el volumen'),
        findsOneWidget,
      );

      // Now transition to Idle state
      when(() => mockBloc.state).thenReturn(const AmplificationIdle());
      stateController.add(const AmplificationIdle());
      await tester.pumpAndSettle();

      // Warning should disappear
      expect(
        find.text('⚠️ Nivel de salida alto — Considere reducir el volumen'),
        findsNothing,
      );

      await stateController.close();
    });
  });
}

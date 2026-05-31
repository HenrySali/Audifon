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

void main() {
  late MockAmplificationBloc mockBloc;

  setUp(() {
    mockBloc = MockAmplificationBloc();
  });

  Widget buildTestWidget({double thresholdDbSpl = 85.0}) {
    return MaterialApp(
      home: BlocProvider<AmplificationBloc>.value(
        value: mockBloc,
        child: SafetyWarningWidget(
          thresholdDbSpl: thresholdDbSpl,
          showAfter: const Duration(seconds: 5),
          hideAfter: const Duration(seconds: 2),
          child: const Scaffold(
            body: Center(child: Text('Main Content')),
          ),
        ),
      ),
    );
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
      // Start with level above threshold
      when(() => mockBloc.state).thenReturn(const AmplificationActive(
        inputLevelDb: 90.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
      ));

      await tester.pumpWidget(buildTestWidget());

      // Emit state with high level to trigger the BlocListener
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

      // Wait for the evaluation timer (500ms intervals) + 5 seconds
      // The timer evaluates every 500ms, so after 5.5s it should trigger
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

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
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

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
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

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
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

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
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

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

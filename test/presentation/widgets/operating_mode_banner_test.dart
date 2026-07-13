import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:hearing_aid_app/domain/audiogram_driven_presets/operating_mode.dart';
import 'package:hearing_aid_app/presentation/bloc/amplification_bloc.dart';
import 'package:hearing_aid_app/presentation/bloc/amplification_event.dart';
import 'package:hearing_aid_app/presentation/bloc/amplification_state.dart';
import 'package:hearing_aid_app/presentation/widgets/operating_mode_banner.dart';

class MockAmplificationBloc
    extends MockBloc<AmplificationEvent, AmplificationState>
    implements AmplificationBloc {}

void main() {
  late MockAmplificationBloc mockBloc;

  setUp(() {
    mockBloc = MockAmplificationBloc();
  });

  Widget buildTestWidget() {
    return MaterialApp(
      home: BlocProvider<AmplificationBloc>.value(
        value: mockBloc,
        child: const Scaffold(
          body: OperatingModeBanner(),
        ),
      ),
    );
  }

  group('OperatingModeBanner', () {
    testWidgets('shows disclaimer in amplifier mode', (tester) async {
      when(() => mockBloc.state).thenReturn(const AmplificationActive(
        inputLevelDb: 50.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
        operatingMode: OperatingMode.amplifier,
      ));

      await tester.pumpWidget(buildTestWidget());

      expect(
        find.text(OperatingModeBanner.disclaimerText),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('hides banner in diagnostic mode', (tester) async {
      when(() => mockBloc.state).thenReturn(const AmplificationActive(
        inputLevelDb: 50.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
        operatingMode: OperatingMode.diagnostic,
      ));

      await tester.pumpWidget(buildTestWidget());

      expect(
        find.text(OperatingModeBanner.disclaimerText),
        findsNothing,
      );
    });

    testWidgets('hides banner when state is not AmplificationActive',
        (tester) async {
      when(() => mockBloc.state).thenReturn(const AmplificationIdle());

      await tester.pumpWidget(buildTestWidget());

      expect(
        find.text(OperatingModeBanner.disclaimerText),
        findsNothing,
      );
    });

    testWidgets('has accessibility semantics label', (tester) async {
      when(() => mockBloc.state).thenReturn(const AmplificationActive(
        inputLevelDb: 50.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
        operatingMode: OperatingMode.amplifier,
      ));

      await tester.pumpWidget(buildTestWidget());

      final semantics = tester.getSemantics(find.byType(OperatingModeBanner));
      expect(semantics.label, contains('Modo Amplificador'));
    });

    testWidgets('transitions from amplifier to diagnostic hides banner',
        (tester) async {
      final stateController =
          StreamController<AmplificationState>.broadcast();

      final amplifierState = const AmplificationActive(
        inputLevelDb: 50.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
        operatingMode: OperatingMode.amplifier,
      );

      final diagnosticState = const AmplificationActive(
        inputLevelDb: 50.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
        operatingMode: OperatingMode.diagnostic,
      );

      when(() => mockBloc.state).thenReturn(amplifierState);
      whenListen(mockBloc, stateController.stream);

      await tester.pumpWidget(buildTestWidget());
      expect(find.text(OperatingModeBanner.disclaimerText), findsOneWidget);

      // Transition to diagnostic
      when(() => mockBloc.state).thenReturn(diagnosticState);
      stateController.add(diagnosticState);
      await tester.pumpAndSettle();

      expect(find.text(OperatingModeBanner.disclaimerText), findsNothing);

      await stateController.close();
    });
  });
}

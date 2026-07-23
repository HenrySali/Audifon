import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';
import 'package:hearing_aid_app/presentation/widgets/prescriber_mode_selector.dart';

/// Widget tests para [PrescriberModeSelector] (tarea 13.1).
///
/// Validates: Requirements 5.1, 5.2, 5.3, 5.4
void main() {
  /// Helper para envolver el widget en un MaterialApp/Scaffold de prueba.
  Widget buildTestWidget({
    required PrescriberMode currentMode,
    required ValueChanged<PrescriberMode> onModeChanged,
    bool enabled = true,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: PrescriberModeSelector(
          currentMode: currentMode,
          onModeChanged: onModeChanged,
          enabled: enabled,
        ),
      ),
    );
  }

  /// Predicate para detectar el badge verde (Container 8x8 greenAccent circle)
  /// que marca el modo activo.
  final activeBadgeFinder = find.byWidgetPredicate(
    (w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).color == Colors.greenAccent &&
        (w.decoration as BoxDecoration).shape == BoxShape.circle,
    description: 'badge greenAccent circle',
  );

  group('PrescriberModeSelector', () {
    testWidgets('renderiza ambos botones Smart-NL2 y Smart-NL3', (tester) async {
      await tester.pumpWidget(
        buildTestWidget(
          currentMode: PrescriberMode.smartNl2,
          onModeChanged: (_) {},
        ),
      );

      expect(find.text('Smart-NL2'), findsOneWidget);
      expect(find.text('Smart-NL3'), findsOneWidget);
      // También se muestran los subtítulos descriptivos.
      expect(find.text('NAL-NL2 clásico'), findsOneWidget);
      expect(find.text('NL3 + CIN adaptativo'), findsOneWidget);
    });

    testWidgets(
      'marca Smart-NL2 como activo (border cyan + badge verde) y Smart-NL3 inactivo cuando currentMode == smartNl2',
      (tester) async {
        await tester.pumpWidget(
          buildTestWidget(
            currentMode: PrescriberMode.smartNl2,
            onModeChanged: (_) {},
          ),
        );

        // Texto del botón activo: bold + cyan.
        final activeText = tester.widget<Text>(find.text('Smart-NL2'));
        expect(activeText.style?.color, Colors.cyan);
        expect(activeText.style?.fontWeight, FontWeight.bold);

        // Texto del botón inactivo: white54 + w500.
        final inactiveText = tester.widget<Text>(find.text('Smart-NL3'));
        expect(inactiveText.style?.color, Colors.white54);
        expect(inactiveText.style?.fontWeight, FontWeight.w500);

        // Solo un badge verde visible y debe ser descendiente del botón Smart-NL2.
        expect(activeBadgeFinder, findsOneWidget);
        final smartNl2Container = find.ancestor(
          of: find.text('Smart-NL2'),
          matching: find.byType(AnimatedContainer),
        );
        expect(
          find.descendant(of: smartNl2Container, matching: activeBadgeFinder),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'marca Smart-NL3 como activo y Smart-NL2 inactivo cuando currentMode == smartNl3',
      (tester) async {
        await tester.pumpWidget(
          buildTestWidget(
            currentMode: PrescriberMode.smartNl3,
            onModeChanged: (_) {},
          ),
        );

        final activeText = tester.widget<Text>(find.text('Smart-NL3'));
        expect(activeText.style?.color, Colors.cyan);
        expect(activeText.style?.fontWeight, FontWeight.bold);

        final inactiveText = tester.widget<Text>(find.text('Smart-NL2'));
        expect(inactiveText.style?.color, Colors.white54);
        expect(inactiveText.style?.fontWeight, FontWeight.w500);

        expect(activeBadgeFinder, findsOneWidget);
        final smartNl3Container = find.ancestor(
          of: find.text('Smart-NL3'),
          matching: find.byType(AnimatedContainer),
        );
        expect(
          find.descendant(of: smartNl3Container, matching: activeBadgeFinder),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'invoca onModeChanged con el nuevo modo al tocar el botón inactivo',
      (tester) async {
        PrescriberMode? receivedMode;
        await tester.pumpWidget(
          buildTestWidget(
            currentMode: PrescriberMode.smartNl2,
            onModeChanged: (mode) => receivedMode = mode,
          ),
        );

        await tester.tap(find.text('Smart-NL3'));
        await tester.pump();

        expect(receivedMode, PrescriberMode.smartNl3);
      },
    );

    testWidgets(
      'no invoca onModeChanged al tocar el botón ya activo',
      (tester) async {
        var callCount = 0;
        await tester.pumpWidget(
          buildTestWidget(
            currentMode: PrescriberMode.smartNl2,
            onModeChanged: (_) => callCount++,
          ),
        );

        await tester.tap(find.text('Smart-NL2'));
        await tester.pump();

        expect(callCount, 0);
      },
    );

    testWidgets(
      'enabled: false deshabilita la interacción y no dispara el callback',
      (tester) async {
        var callCount = 0;
        await tester.pumpWidget(
          buildTestWidget(
            currentMode: PrescriberMode.smartNl2,
            onModeChanged: (_) => callCount++,
            enabled: false,
          ),
        );

        // Con enabled=false el GestureDetector tiene onTap=null, por eso
        // se omite la advertencia de tap perdido.
        await tester.tap(find.text('Smart-NL3'), warnIfMissed: false);
        await tester.pump();

        expect(callCount, 0);
      },
    );
  });
}

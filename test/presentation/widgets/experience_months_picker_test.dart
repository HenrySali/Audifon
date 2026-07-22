import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hearing_aid_app/presentation/widgets/experience_months_picker.dart';

/// Widget tests para [ExperienceMonthsPicker].
///
/// Cubre los 5 chips presets, el indicador visual del chip activo,
/// el callback `onChanged` y el comportamiento cuando `enabled: false`
/// o cuando `currentMonths == null`.
void main() {
  // Mapa preset → (label visible, valor en meses).
  const presets = <String, int>{
    'Primera vez': 0,
    'Menos de 6 meses': 3,
    '6 a 12 meses': 9,
    '1 a 2 años': 18,
    'Más de 2 años': 36,
  };

  Widget buildTestWidget({
    required int? currentMonths,
    required ValueChanged<int> onChanged,
    bool enabled = true,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ExperienceMonthsPicker(
          currentMonths: currentMonths,
          onChanged: onChanged,
          enabled: enabled,
        ),
      ),
    );
  }

  /// Predicate para detectar el badge greenAccent (Container 6x6 circle)
  /// que marca el chip activo.
  final activeBadgeFinder = find.byWidgetPredicate(
    (w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).color == Colors.greenAccent &&
        (w.decoration as BoxDecoration).shape == BoxShape.circle,
    description: 'badge greenAccent circle',
  );

  group('ExperienceMonthsPicker — renderizado', () {
    testWidgets('renderiza los 5 chips presets', (tester) async {
      await tester.pumpWidget(
        buildTestWidget(currentMonths: null, onChanged: (_) {}),
      );

      for (final label in presets.keys) {
        expect(find.text(label), findsOneWidget,
            reason: 'Falta el chip "$label"');
      }
    });

    testWidgets(
      'cuando currentMonths == null ningún chip aparece activo (sin badge verde)',
      (tester) async {
        await tester.pumpWidget(
          buildTestWidget(currentMonths: null, onChanged: (_) {}),
        );

        expect(activeBadgeFinder, findsNothing);

        // Todos los textos están en color inactivo (white70).
        for (final label in presets.keys) {
          final t = tester.widget<Text>(find.text(label));
          expect(t.style?.color, Colors.white70,
              reason: 'El chip "$label" no debería aparecer activo');
        }
      },
    );
  });

  group('ExperienceMonthsPicker — estado activo', () {
    testWidgets(
      'el chip cuyo months coincide con currentMonths muestra badge verde y texto cyan',
      (tester) async {
        // Caso representativo: 9 meses → "6 a 12 meses".
        await tester.pumpWidget(
          buildTestWidget(currentMonths: 9, onChanged: (_) {}),
        );

        // Solo un badge verde presente.
        expect(activeBadgeFinder, findsOneWidget);

        // El texto activo es cyan + bold.
        final activeText = tester.widget<Text>(find.text('6 a 12 meses'));
        expect(activeText.style?.color, Colors.cyan);
        expect(activeText.style?.fontWeight, FontWeight.bold);

        // El badge es descendiente del chip activo.
        final activeChip = find.ancestor(
          of: find.text('6 a 12 meses'),
          matching: find.byType(AnimatedContainer),
        );
        expect(
          find.descendant(of: activeChip, matching: activeBadgeFinder),
          findsOneWidget,
        );

        // Los demás chips siguen inactivos.
        for (final label in presets.keys.where((l) => l != '6 a 12 meses')) {
          final t = tester.widget<Text>(find.text(label));
          expect(t.style?.color, Colors.white70);
        }
      },
    );

    testWidgets(
      'currentMonths = 0 marca correctamente "Primera vez" como activo',
      (tester) async {
        await tester.pumpWidget(
          buildTestWidget(currentMonths: 0, onChanged: (_) {}),
        );

        final activeText = tester.widget<Text>(find.text('Primera vez'));
        expect(activeText.style?.color, Colors.cyan);
        expect(activeBadgeFinder, findsOneWidget);
      },
    );
  });

  group('ExperienceMonthsPicker — callback onChanged', () {
    testWidgets(
      'invoca onChanged con el valor correcto al tocar un chip distinto al activo',
      (tester) async {
        int? receivedMonths;
        await tester.pumpWidget(
          buildTestWidget(
            currentMonths: 0,
            onChanged: (m) => receivedMonths = m,
          ),
        );

        await tester.tap(find.text('1 a 2 años'));
        await tester.pump();

        expect(receivedMonths, 18);
      },
    );

    testWidgets(
      'no dispara onChanged al tocar el chip que ya está activo',
      (tester) async {
        var callCount = 0;
        await tester.pumpWidget(
          buildTestWidget(
            currentMonths: 3,
            onChanged: (_) => callCount++,
          ),
        );

        await tester.tap(find.text('Menos de 6 meses'));
        await tester.pump();

        expect(callCount, 0);
      },
    );

    testWidgets(
      'desde currentMonths == null, tocar cualquier chip dispara onChanged',
      (tester) async {
        int? receivedMonths;
        await tester.pumpWidget(
          buildTestWidget(
            currentMonths: null,
            onChanged: (m) => receivedMonths = m,
          ),
        );

        await tester.tap(find.text('Más de 2 años'));
        await tester.pump();

        expect(receivedMonths, 36);
      },
    );
  });

  group('ExperienceMonthsPicker — enabled', () {
    testWidgets(
      'enabled: false deshabilita la interacción y no dispara el callback',
      (tester) async {
        var callCount = 0;
        await tester.pumpWidget(
          buildTestWidget(
            currentMonths: 0,
            onChanged: (_) => callCount++,
            enabled: false,
          ),
        );

        await tester.tap(find.text('1 a 2 años'), warnIfMissed: false);
        await tester.pump();

        expect(callCount, 0);
      },
    );
  });
}

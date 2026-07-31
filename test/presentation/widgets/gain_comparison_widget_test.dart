import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hearing_aid_app/domain/entities/loss_type.dart';
import 'package:hearing_aid_app/presentation/widgets/gain_comparison_widget.dart';

/// Widget tests para [GainComparisonWidget] (tarea 13.2).
///
/// Como el chart es un [CustomPainter] no se puede inspeccionar el canvas
/// directamente. La estrategia es validar la leyenda visible y el label
/// del LossType, que son señales de los trazos pintados.
///
/// Validates: Requirements 12.1, 12.2, 12.3, 12.4
void main() {
  // Datos de prueba: 12 bandas con valores plausibles.
  final nl2Gains = [
    10.0, 15.0, 18.0, 20.0, 22.0, 24.0, 23.0, 21.0, 19.0, 17.0, 14.0, 11.0,
  ];
  final nl3Gains = [
    9.0, 14.0, 17.0, 20.0, 23.0, 25.0, 24.0, 22.0, 20.0, 18.0, 13.0, 10.0,
  ];
  final cinGains = [
    6.0, 11.0, 17.0, 20.0, 23.0, 25.0, 24.0, 22.0, 20.0, 18.0, 9.0, 6.0,
  ];

  Widget buildTestWidget({
    List<double>? cin,
    LossType lossType = LossType.sloping,
    VoidCallback? onTap,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: GainComparisonWidget(
          nl2Gains: nl2Gains,
          nl3Gains: nl3Gains,
          cinGains: cin,
          lossType: lossType,
          onTap: onTap,
        ),
      ),
    );
  }

  group('GainComparisonWidget — leyenda', () {
    testWidgets(
      'muestra los items NL2 y NL3 (pero NO CIN) cuando cinGains es null',
      (tester) async {
        await tester.pumpWidget(buildTestWidget());

        expect(find.text('NL2'), findsOneWidget);
        expect(find.text('NL3'), findsOneWidget);
        expect(find.text('CIN'), findsNothing);
      },
    );

    testWidgets(
      'muestra los tres items NL2, NL3 y CIN cuando cinGains está presente',
      (tester) async {
        await tester.pumpWidget(buildTestWidget(cin: cinGains));

        expect(find.text('NL2'), findsOneWidget);
        expect(find.text('NL3'), findsOneWidget);
        expect(find.text('CIN'), findsOneWidget);
      },
    );
  });

  group('GainComparisonWidget — etiqueta de LossType', () {
    testWidgets('flat → "Plana"', (tester) async {
      await tester.pumpWidget(buildTestWidget(lossType: LossType.flat));

      expect(find.text('Tipo de pérdida: Plana'), findsOneWidget);
    });

    testWidgets('sloping → "Descendente"', (tester) async {
      await tester.pumpWidget(buildTestWidget(lossType: LossType.sloping));

      expect(find.text('Tipo de pérdida: Descendente'), findsOneWidget);
    });

    testWidgets('reverseSlope → "Pendiente inversa"', (tester) async {
      await tester.pumpWidget(buildTestWidget(lossType: LossType.reverseSlope));

      expect(find.text('Tipo de pérdida: Pendiente inversa'), findsOneWidget);
    });

    testWidgets('cookieBite → "Cookie bite (medios)"', (tester) async {
      await tester.pumpWidget(buildTestWidget(lossType: LossType.cookieBite));

      expect(find.text('Tipo de pérdida: Cookie bite (medios)'), findsOneWidget);
    });

    testWidgets('notch → "Muesca"', (tester) async {
      await tester.pumpWidget(buildTestWidget(lossType: LossType.notch));

      expect(find.text('Tipo de pérdida: Muesca'), findsOneWidget);
    });

    testWidgets('mixed → "Mixta (conductiva)"', (tester) async {
      await tester.pumpWidget(buildTestWidget(lossType: LossType.mixed));

      expect(find.text('Tipo de pérdida: Mixta (conductiva)'), findsOneWidget);
    });
  });

  group('GainComparisonWidget — onTap', () {
    testWidgets('invoca el callback onTap al tocar el widget', (tester) async {
      var tapCount = 0;
      await tester.pumpWidget(
        buildTestWidget(onTap: () => tapCount++),
      );

      // Tocar el container raíz del widget.
      await tester.tap(find.byType(GainComparisonWidget));
      await tester.pump();

      expect(tapCount, 1);
    });
  });

  group('GainComparisonWidget — chart', () {
    testWidgets(
      'pinta el chart vía CustomPaint sin lanzar excepciones (título "Comparación de ganancias" se renderiza en canvas)',
      (tester) async {
        await tester.pumpWidget(buildTestWidget());
        await tester.pumpAndSettle();

        // El título se pinta vía TextPainter sobre el canvas (no es un widget
        // Text), así que verificamos la presencia del CustomPaint del chart
        // y que el frame se renderizó sin errores.
        expect(find.byType(CustomPaint), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'renderiza sin error con LossType.notch + cinGains válido',
      (tester) async {
        await tester.pumpWidget(
          buildTestWidget(cin: cinGains, lossType: LossType.notch),
        );
        await tester.pumpAndSettle();

        // Etiqueta correcta del LossType y leyenda completa con CIN.
        expect(find.text('Tipo de pérdida: Muesca'), findsOneWidget);
        expect(find.text('NL2'), findsOneWidget);
        expect(find.text('NL3'), findsOneWidget);
        expect(find.text('CIN'), findsOneWidget);
        expect(find.byType(CustomPaint), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );
  });
}

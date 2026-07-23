import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hearing_aid_app/presentation/widgets/gain_detail_view.dart';

void main() {
  // Datos de prueba: 12 bandas con diferencias variadas.
  final nl2Gains = [10.0, 15.0, 18.0, 20.0, 22.0, 24.0, 23.0, 21.0, 19.0, 17.0, 14.0, 11.0];
  final nl3Gains = [9.0, 14.0, 17.0, 20.0, 23.0, 25.0, 24.0, 22.0, 20.0, 18.0, 13.0, 10.0];
  final cinGains = [9.0, 14.0, 17.0, 20.0, 23.0, 25.0, 24.0, 22.0, 20.0, 18.0, 10.0, 7.0];

  Widget buildTestWidget({
    List<double>? cin,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: GainDetailView(
          nl2Gains: nl2Gains,
          nl3Gains: nl3Gains,
          cinGains: cin,
        ),
      ),
    );
  }

  group('GainDetailView', () {
    testWidgets('muestra título de diferencias', (tester) async {
      await tester.pumpWidget(buildTestWidget());

      expect(find.text('Diferencias de ganancia por banda'), findsOneWidget);
    });

    testWidgets('muestra encabezados de columna sin CIN', (tester) async {
      await tester.pumpWidget(buildTestWidget());

      expect(find.text('Frecuencia'), findsOneWidget);
      expect(find.text('NL2'), findsOneWidget);
      expect(find.text('NL3'), findsOneWidget);
      expect(find.text('Δ dB'), findsOneWidget);
      // CIN no debería estar presente sin cinGains.
      expect(find.text('CIN'), findsNothing);
    });

    testWidgets('muestra columna CIN cuando cinGains está presente', (tester) async {
      await tester.pumpWidget(buildTestWidget(cin: cinGains));

      expect(find.text('CIN'), findsOneWidget);
    });

    testWidgets('muestra las 12 etiquetas de frecuencia', (tester) async {
      await tester.pumpWidget(buildTestWidget());
      await tester.pumpAndSettle();

      // Verificar algunas etiquetas representativas.
      expect(find.text('250 Hz'), findsOneWidget);
      expect(find.text('1000 Hz'), findsOneWidget);
      expect(find.text('8000 Hz'), findsOneWidget);
    });

    testWidgets('muestra diferencia positiva con signo +', (tester) async {
      await tester.pumpWidget(buildTestWidget());
      await tester.pumpAndSettle();

      // Banda 4 (1500 Hz): NL3=23 - NL2=22 = +1.0
      expect(find.text('+1.0'), findsWidgets);
    });

    testWidgets('muestra diferencia negativa con signo -', (tester) async {
      await tester.pumpWidget(buildTestWidget());
      await tester.pumpAndSettle();

      // Banda 0 (250 Hz): NL3=9 - NL2=10 = -1.0
      expect(find.text('-1.0'), findsWidgets);
    });

    testWidgets('muestra diferencia cero sin signo', (tester) async {
      await tester.pumpWidget(buildTestWidget());
      await tester.pumpAndSettle();

      // Banda 3 (1000 Hz): NL3=20 - NL2=20 = 0.0
      expect(find.text('0.0'), findsWidgets);
    });

    testWidgets('muestra valores NL2 y NL3 formateados', (tester) async {
      await tester.pumpWidget(buildTestWidget());
      await tester.pumpAndSettle();

      // Verificar que se muestran los valores con un decimal.
      expect(find.text('10.0'), findsWidgets); // NL2 banda 0
      expect(find.text('24.0'), findsWidgets); // NL2 banda 5 o NL3 banda 6
    });
  });

  group('showGainDetailBottomSheet', () {
    testWidgets('muestra el GainDetailView como BottomSheet', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showGainDetailBottomSheet(
                  context: context,
                  nl2Gains: nl2Gains,
                  nl3Gains: nl3Gains,
                ),
                child: const Text('Mostrar detalle'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Mostrar detalle'));
      await tester.pumpAndSettle();

      // Verificar que se muestra el sheet con el título.
      expect(find.text('Diferencias de ganancia por banda'), findsOneWidget);
    });
  });
}

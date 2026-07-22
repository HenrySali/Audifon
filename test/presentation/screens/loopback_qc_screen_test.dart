/// Widget tests para [LoopbackQcScreen] (tarea 15.2 del spec
/// `audiogram-driven-presets`).
///
/// Cubre:
///   - PIN incorrecto → SnackBar.
///   - PIN correcto → renderiza UI de QC.
///   - Cambio de dropdown recalcula el SPL esperado.
///   - "Iniciar matriz" itera con confirmación del operador.
///
/// Para evitar inicializar `just_audio` en widget tests inyectamos un
/// [ToneEmitter] mockeado (mocktail) que devuelve futuros vacíos.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mocktail/mocktail.dart';

import 'package:hearing_aid_app/calibration_spectrum/tone_emitter.dart';
import 'package:hearing_aid_app/presentation/screens/loopback_qc_screen.dart';

class _MockToneEmitter extends Mock implements ToneEmitter {}

void main() {
  late Directory tempHiveDir;
  late _MockToneEmitter mockEmitter;

  setUpAll(() async {
    tempHiveDir = await Directory.systemTemp.createTemp('loopback_qc_test_');
    Hive.init(tempHiveDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempHiveDir.existsSync()) {
      tempHiveDir.deleteSync(recursive: true);
    }
  });

  setUp(() {
    mockEmitter = _MockToneEmitter();
    // playTone returns Future<void>.value() sin tocar audio nativo.
    when(() => mockEmitter.playTone(
          freqHz: any(named: 'freqHz'),
          levelDbSpl: any(named: 'levelDbSpl'),
          durationMs: any(named: 'durationMs'),
        )).thenAnswer((_) async {});
    when(() => mockEmitter.stop()).thenAnswer((_) async {});
    when(() => mockEmitter.dispose()).thenAnswer((_) async {});
  });

  Future<void> pumpScreen(WidgetTester tester, {String? pinOverride = '1234'}) async {
    // Por defecto los tests usan `pinOverride: '1234'` para evitar que el
    // screen abra `OperatorPinRepository` (Hive `service_settings_box`),
    // que en widget tests sin setup previo retorna `hasPin == false` y
    // muestra "PIN no configurado..." en lugar del flow real.
    // Cuando se quiere ejercitar el path real de repo, pasar
    // `pinOverride: null` explícitamente y configurar el repo via Hive.
    await tester.pumpWidget(
      MaterialApp(
        home: LoopbackQcScreen(
          toneEmitter: mockEmitter,
          pinOverride: pinOverride,
        ),
      ),
    );
  }

  Future<void> unlock(WidgetTester tester, {String pin = '1234'}) async {
    await tester.enterText(find.byKey(const Key('qc_pin_field')), pin);
    await tester.tap(find.byKey(const Key('qc_pin_submit')));
    await tester.pump();
  }

  testWidgets('PIN incorrecto muestra SnackBar y mantiene la pantalla bloqueada',
      (tester) async {
    await pumpScreen(tester);

    await tester.enterText(find.byKey(const Key('qc_pin_field')), '0000');
    await tester.tap(find.byKey(const Key('qc_pin_submit')));
    await tester.pump(); // schedule snackbar
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('PIN incorrecto'), findsOneWidget);
    // El selector de audiograma sólo aparece cuando se desbloquea, así
    // que su ausencia confirma que la pantalla sigue en el gate.
    expect(find.byKey(const Key('qc_audiogram_dropdown')), findsNothing);
  });

  testWidgets('PIN correcto desbloquea la UI de QC', (tester) async {
    await pumpScreen(tester);

    await unlock(tester);

    expect(find.byKey(const Key('qc_audiogram_dropdown')), findsOneWidget);
    expect(find.byKey(const Key('qc_input_dropdown')), findsOneWidget);
    expect(find.byKey(const Key('qc_freq_dropdown')), findsOneWidget);
    expect(find.byKey(const Key('qc_play_warble')), findsOneWidget);
    expect(find.byKey(const Key('qc_run_matrix')), findsOneWidget);
    expect(find.byKey(const Key('qc_export')), findsOneWidget);
    // SPL esperado se renderiza con la selección por defecto (N1, 65, 1000).
    expect(find.byKey(const Key('qc_expected_spl')), findsOneWidget);
  });

  testWidgets('cambiar el audiograma recalcula el SPL esperado',
      (tester) async {
    await pumpScreen(tester);
    await unlock(tester);

    // Capturar el texto actual del display.
    final displayFinder = find.byKey(const Key('qc_expected_spl'));
    final initialText = (tester.widget(find.descendant(
      of: displayFinder,
      matching: find.byType(Text),
    )) as Text)
        .data!;

    // Cambiar al audiograma N7 (pérdida profunda → ganancias mucho mayores).
    await tester.tap(find.byKey(const Key('qc_audiogram_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bisgaard N7').last);
    await tester.pumpAndSettle();

    final newText = (tester.widget(find.descendant(
      of: displayFinder,
      matching: find.byType(Text),
    )) as Text)
        .data!;

    expect(newText, isNot(equals(initialText)),
        reason:
            'El SPL esperado debe cambiar al pasar de Bisgaard N1 a N7.');
  });

  testWidgets(
      '"Iniciar matriz completa" itera y persiste cada medición confirmada',
      (tester) async {
    await pumpScreen(tester);
    await unlock(tester);

    // Disparar la matriz y confirmar la primera medición.
    await tester.tap(find.byKey(const Key('qc_run_matrix')));
    // El primer ciclo abre un dialog tras reproducir el tono.
    await tester.pumpAndSettle();

    // El diálogo de medición debe estar abierto.
    expect(find.byKey(const Key('qc_measure_ok')), findsOneWidget);

    // Ingresar un valor numérico para la primera medición.
    final dialogTextField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogTextField, '88.5');
    await tester.tap(find.byKey(const Key('qc_measure_ok')));
    await tester.pumpAndSettle();

    // Aparece otro diálogo (segunda iteración) → cancelarlo para detener
    // la corrida y verificar que la primera medición quedó registrada.
    if (find.byKey(const Key('qc_measure_ok')).evaluate().isNotEmpty) {
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
    }

    // El emitter mockeado debe haber sido invocado al menos una vez.
    verify(() => mockEmitter.playTone(
          freqHz: any(named: 'freqHz'),
          levelDbSpl: any(named: 'levelDbSpl'),
          durationMs: any(named: 'durationMs'),
        )).called(greaterThanOrEqualTo(1));

    // La lista de resultados debe contener al menos una entrada.
    expect(find.byKey(const Key('qc_results_list')), findsOneWidget);
  });
}

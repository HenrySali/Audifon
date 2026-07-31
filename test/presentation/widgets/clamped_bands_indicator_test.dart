import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hearing_aid_app/presentation/widgets/clamped_bands_indicator.dart';
import 'package:hearing_aid_app/scene/smart_preset.dart';
import 'package:hearing_aid_app/scene/scene_snapshot.dart';

void main() {
  Widget buildTestWidget(List<int> clampedBands) {
    return MaterialApp(
      home: Scaffold(
        body: ClampedBandsIndicator(clampedBands: clampedBands),
      ),
    );
  }

  group('ClampedBandsIndicator', () {
    testWidgets('renders nothing when clampedBands is empty', (tester) async {
      await tester.pumpWidget(buildTestWidget([]));

      expect(find.byType(ClampedBandsIndicator), findsOneWidget);
      // Should render SizedBox.shrink — no visible content
      expect(find.text('Bandas limitadas por MPO'), findsNothing);
      expect(find.byIcon(Icons.vertical_align_top), findsNothing);
    });

    testWidgets('renders header and band count when bands are clamped',
        (tester) async {
      await tester.pumpWidget(buildTestWidget([0, 3, 7]));

      expect(find.text('Bandas limitadas por MPO'), findsOneWidget);
      expect(
        find.text('3 de 12 bandas alcanzaron el límite MPO'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.vertical_align_top), findsOneWidget);
    });

    testWidgets('renders 12 band indicators always', (tester) async {
      await tester.pumpWidget(buildTestWidget([2, 5]));

      // 12 AnimatedContainers for the 12 bands
      expect(find.byType(AnimatedContainer), findsNWidgets(12));
    });

    testWidgets('tooltip on clamped band shows MPO protection message',
        (tester) async {
      await tester.pumpWidget(buildTestWidget([0]));

      // Find the tooltip for band 0 (250 Hz)
      final tooltips = tester.widgetList<Tooltip>(find.byType(Tooltip));
      final firstTooltip = tooltips.first;
      expect(
        firstTooltip.message,
        '250 Hz — Ganancia limitada por protección MPO',
      );
    });

    testWidgets('tooltip on non-clamped band shows only frequency',
        (tester) async {
      await tester.pumpWidget(buildTestWidget([0]));

      // Second tooltip (band 1 = 500 Hz) is NOT clamped
      final tooltips = tester.widgetList<Tooltip>(find.byType(Tooltip)).toList();
      expect(tooltips[1].message, '500 Hz');
    });

    testWidgets('has Semantics widget for accessibility', (tester) async {
      await tester.pumpWidget(buildTestWidget([1, 4, 9]));

      // Verify the Semantics widget is in the tree with correct label
      final semanticsWidget = tester.widget<Semantics>(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.label ==
                  '3 de 12 bandas tienen ganancia limitada por protección MPO',
        ),
      );
      expect(semanticsWidget, isNotNull);
    });

    testWidgets('fromPreset factory constructs correctly', (tester) async {
      final preset = SmartPreset(
        name: 'test_preset',
        isPersonalized: true,
        sceneClass: SceneClass.silence,
        gains: List.filled(12, 10.0),
        compressionRatio: 1.5,
        compressionKnee: 45.0,
        expansionKnee: 35.0,
        nrLevel: 1,
        tnrEnabled: false,
        volumeDeltaDb: 0.0,
        confidence: 0.9,
        clampedBands: [2, 6, 10],
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ClampedBandsIndicator.fromPreset(preset),
        ),
      ));

      expect(
        find.text('3 de 12 bandas alcanzaron el límite MPO'),
        findsOneWidget,
      );
    });

    testWidgets('all 12 bands clamped renders correctly', (tester) async {
      await tester.pumpWidget(
        buildTestWidget(List.generate(12, (i) => i)),
      );

      expect(
        find.text('12 de 12 bandas alcanzaron el límite MPO'),
        findsOneWidget,
      );
    });
  });
}

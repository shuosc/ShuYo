import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/features/course_recordings/recording_status_icon.dart';

void main() {
  testWidgets('live indicator repaints without rebuilding its widget',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: RecordingStatusIcon(isLive: true))),
    ));
    final indicator = find.byKey(const ValueKey('recording-live-indicator'));
    final paintWidget = tester.widget<CustomPaint>(indicator);
    final boundary = find
        .ancestor(
          of: indicator,
          matching: find.byType(RepaintBoundary),
        )
        .first;
    Future<List<int>> pixels() async {
      final image = await tester
          .renderObject<RenderRepaintBoundary>(boundary)
          .toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return bytes!.buffer.asUint8List().toList();
    }

    final before = await tester.runAsync(pixels);
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.widget<CustomPaint>(indicator), same(paintWidget));
    expect(await tester.runAsync(pixels), isNot(equals(before)));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'generation marker rotates at the icon bottom right while disabled',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: Center(
      child: RecordingStatusIcon(
          isLive: false,
          isGenerating: true,
          enabled: false,
          disabledColor: Colors.grey),
    ))));
    final icon = find.byIcon(Icons.smart_display_rounded);
    final marker = find.byKey(const ValueKey('recording-generating-indicator'));
    expect(tester.widget<Icon>(icon).color, Colors.grey);
    expect(tester.getCenter(marker).dx, greaterThan(tester.getCenter(icon).dx));
    expect(tester.getCenter(marker).dy, greaterThan(tester.getCenter(icon).dy));
    expect(find.bySemanticsLabel('回放生成中'), findsOneWidget);
    final rotation =
        find.ancestor(of: marker, matching: find.byType(Transform)).first;
    final before = tester.widget<Transform>(rotation).transform.storage[0];
    await tester.pump(const Duration(milliseconds: 250));
    expect(
        tester.widget<Transform>(rotation).transform.storage[0], isNot(before));
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets(
      'reduced motion keeps the generation status and stops its rotation',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: MediaQuery(
      data: MediaQueryData(disableAnimations: true),
      child: RecordingStatusIcon(
          isLive: false, isGenerating: true, enabled: false),
    )));
    final marker = find.byKey(const ValueKey('recording-generating-indicator'));
    final rotation =
        find.ancestor(of: marker, matching: find.byType(Transform)).first;
    final before =
        List<double>.from(tester.widget<Transform>(rotation).transform.storage);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<Transform>(rotation).transform.storage, before);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

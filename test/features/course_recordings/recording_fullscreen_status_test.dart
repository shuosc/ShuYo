import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/features/course_recordings/recording_fullscreen_status.dart';

void main() {
  testWidgets('clock refreshes only while enabled and active', (tester) async {
    var now = DateTime(2026, 10, 30, 9, 59);
    var reads = 0;
    Widget status({bool active = true, bool showClock = true}) => MaterialApp(
          home: RecordingFullscreenStatus(
            active: active,
            showClock: showClock,
            clock: () {
              reads++;
              return now;
            },
          ),
        );
    await tester.pumpWidget(status());
    expect(find.text('09:59'), findsOneWidget);
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('10:00'), findsOneWidget);
    await tester.pumpWidget(status(active: false));
    final stoppedReads = reads;
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(reads, stoppedReads);
    await tester.pumpWidget(status());
    expect(find.text('10:01'), findsOneWidget);
    await tester.pumpWidget(status(showClock: false));
    expect(find.byType(Text), findsNothing);
    final hiddenReads = reads;
    await tester.pump(const Duration(minutes: 1));
    expect(reads, hiddenReads);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

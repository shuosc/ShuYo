import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/features/course_recordings/recording_seek_controller.dart';

void main() {
  testWidgets('drag seeks immediately and throttles previews to the latest',
      (tester) async {
    final positions = <Duration>[];
    final controller = RecordingSeekController(seek: (position) async {
      positions.add(position);
    });
    addTearDown(controller.dispose);

    controller.begin();
    controller.preview(const Duration(seconds: 10));
    await tester.pump();
    controller.preview(const Duration(seconds: 20));
    controller.preview(const Duration(seconds: 30));
    await tester.pump(const Duration(milliseconds: 89));
    expect(positions, [const Duration(seconds: 10)]);
    await tester.pump(const Duration(milliseconds: 1));
    expect(positions, [
      const Duration(seconds: 10),
      const Duration(seconds: 30),
    ]);

    final finished = controller.finish(const Duration(milliseconds: 30525));
    await tester.pump();
    await finished;
    expect(positions.last, const Duration(milliseconds: 30525));
  });

  testWidgets('release discards queued previews and waits for in-flight seek',
      (tester) async {
    final firstSeek = Completer<void>();
    final positions = <Duration>[];
    var running = 0;
    var maxRunning = 0;
    final controller = RecordingSeekController(seek: (position) async {
      positions.add(position);
      running++;
      if (running > maxRunning) maxRunning = running;
      if (positions.length == 1) await firstSeek.future;
      running--;
    });
    addTearDown(controller.dispose);

    controller.preview(const Duration(seconds: 1));
    controller.preview(const Duration(seconds: 2));
    controller.preview(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 150));
    final finished = controller.finish(const Duration(milliseconds: 4123));
    expect(positions, [const Duration(seconds: 1)]);
    firstSeek.complete();
    await tester.pump();
    await finished;
    expect(positions, [
      const Duration(seconds: 1),
      const Duration(milliseconds: 4123),
    ]);
    expect(maxRunning, 1);
  });

  testWidgets('a failed preview does not block the final seek', (tester) async {
    final positions = <Duration>[];
    final errors = <Object>[];
    final controller = RecordingSeekController(
      seek: (position) async {
        positions.add(position);
        if (positions.length == 1) throw StateError('decoder unavailable');
      },
      onPreviewError: (error, _) => errors.add(error),
    );
    addTearDown(controller.dispose);

    controller.preview(const Duration(seconds: 1));
    final finished = controller.finish(const Duration(seconds: 5));
    await tester.pump();
    await finished;
    expect(errors, hasLength(1));
    expect(positions.last, const Duration(seconds: 5));
  });

  testWidgets('disposing cancels the pending drag target', (tester) async {
    final positions = <Duration>[];
    final controller = RecordingSeekController(seek: (position) async {
      positions.add(position);
    });

    controller.preview(const Duration(seconds: 1));
    await tester.pump();
    controller.preview(const Duration(seconds: 2));
    controller.dispose();
    await tester.pump(const Duration(seconds: 1));
    expect(positions, [const Duration(seconds: 1)]);
  });
}

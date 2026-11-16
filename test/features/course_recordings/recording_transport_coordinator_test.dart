import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/features/course_recordings/recording_transport_coordinator.dart';

void main() {
  testWidgets('a late native open is stopped before the next transport',
      (tester) async {
    final coordinator = RecordingTransportCoordinator();
    final open = Completer<void>();
    final finalStop = Completer<void>();
    final events = <String>[];
    coordinator.trackOpen(open.future, secondary: false);

    final transition = coordinator.prepare(() async {
      await coordinator.stopAndDrain(
        stop: () async {
          events.add('stop');
          if (events.where((event) => event == 'stop').length == 2) {
            await finalStop.future;
          }
        },
        primaryQueue: open.future,
        secondaryQueue: Future<void>.value(),
        drain: true,
      );
      events.add('dispose proxy and start next transport');
    });

    await tester.pump();
    expect(events, ['stop']);
    open.complete();
    await tester.pump();
    expect(events, ['stop', 'stop']);
    finalStop.complete();
    await tester.pump();
    await transition;
    expect(events, ['stop', 'stop', 'dispose proxy and start next transport']);
  });

  testWidgets('a timed out final stop remains a barrier on retry',
      (tester) async {
    final coordinator =
        RecordingTransportCoordinator(timeout: const Duration(seconds: 1));
    final finalStop = Completer<void>();
    var stops = 0;
    Future<void> stop() async {
      stops++;
      if (stops == 2) await finalStop.future;
    }

    Future<void> transition() =>
        coordinator.prepare(() => coordinator.stopAndDrain(
            stop: stop,
            primaryQueue: Future<void>.value(),
            secondaryQueue: Future<void>.value(),
            drain: true));
    final first = transition();
    final firstFailure = expectLater(first, throwsA(isA<TimeoutException>()));
    await tester.pump();
    expect(stops, 2);
    await tester.pump(const Duration(seconds: 2));
    await firstFailure;

    final retry = transition();
    await tester.pump();
    expect(stops, 2);
    finalStop.complete();
    await tester.pump();
    await retry;
    expect(stops, 4);
  });

  testWidgets('all native opens remain barriers when a view is reopened',
      (tester) async {
    final coordinator = RecordingTransportCoordinator();
    final olderOpen = Completer<void>();
    final newerOpen = Completer<void>();
    var stops = 0;
    var switched = false;
    coordinator.trackOpen(olderOpen.future, secondary: true);
    coordinator.trackOpen(newerOpen.future, secondary: true);

    final transition = coordinator.prepare(() async {
      await coordinator.stopAndDrain(
        stop: () async => stops++,
        primaryQueue: Future<void>.value(),
        secondaryQueue: Future<void>.value(),
        drain: true,
      );
      switched = true;
    });
    newerOpen.complete();
    await tester.pump();
    expect(stops, 1);
    expect(switched, isFalse);
    olderOpen.complete();
    await tester.pump();
    await transition;
    expect(stops, 2);
    expect(switched, isTrue);
  });
}

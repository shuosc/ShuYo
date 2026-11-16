import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/features/course_recordings/recording_route_work_gate.dart';

void main() {
  testWidgets('native work waits for the real entry animation only',
      (tester) async {
    final animation = AnimationController(
        vsync: tester, duration: const Duration(milliseconds: 300));
    final gate = RecordingRouteWorkGate()..attach(animation);
    addTearDown(() {
      gate.dispose();
      animation.dispose();
    });
    animation.forward();
    bool? ready;
    final waiting = gate.ready.then((allowed) => ready = allowed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(ready, isNull);
    // A ticker can need one more frame at the exact duration boundary. Drain
    // scheduled frames before awaiting the gate inside the fake async zone.
    await tester.pumpAndSettle(const Duration(milliseconds: 20));
    expect(animation.status, AnimationStatus.completed);
    expect(ready, isTrue);
    await waiting;
    expect(await gate.ready, isTrue);
  });

  testWidgets('cancelling an entry releases pending work for revision checks',
      (tester) async {
    final animation = AnimationController(
        vsync: tester, duration: const Duration(milliseconds: 300));
    final gate = RecordingRouteWorkGate()..attach(animation);
    animation.forward();
    final waiting = gate.ready;
    gate.dispose();
    expect(await waiting, isFalse);
    animation.dispose();
  });

  testWidgets('cancelled interactive back resumes pending native work once',
      (tester) async {
    final animation = AnimationController(
        vsync: tester, duration: const Duration(milliseconds: 400));
    final gate = RecordingRouteWorkGate()..attach(animation);
    addTearDown(() {
      gate.dispose();
      animation.dispose();
    });
    animation.forward();
    bool? ready;
    var starts = 0;
    final waiting = gate.ready.then((allowed) {
      ready = allowed;
      if (allowed) starts++;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    animation.reverse();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(animation.status, AnimationStatus.reverse);
    expect(ready, isNull);
    expect(starts, 0);
    animation.forward();
    await tester.pumpAndSettle(const Duration(milliseconds: 20));
    expect(animation.status, AnimationStatus.completed);
    expect(ready, isTrue);
    await waiting;
    expect(starts, 1);
  });

  testWidgets('completed back dismissal rejects pending native work',
      (tester) async {
    final animation = AnimationController(
        vsync: tester, duration: const Duration(milliseconds: 300), value: 1);
    final gate = RecordingRouteWorkGate()..attach(animation);
    addTearDown(() {
      gate.dispose();
      animation.dispose();
    });
    animation.reverse();
    bool? ready;
    var starts = 0;
    final waiting = gate.ready.then((allowed) {
      ready = allowed;
      if (allowed) starts++;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(ready, isNull);
    await tester.pumpAndSettle(const Duration(milliseconds: 20));
    expect(animation.status, AnimationStatus.dismissed);
    expect(ready, isFalse);
    await waiting;
    expect(starts, 0);
    expect(await gate.ready, isFalse);
  });

  test('a page without a route animation is immediately ready', () async {
    final gate = RecordingRouteWorkGate();
    expect(await gate.ready, isTrue);
    gate.dispose();
    expect(await gate.ready, isFalse);
  });
}

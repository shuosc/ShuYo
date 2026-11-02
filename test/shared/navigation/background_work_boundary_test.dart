import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/core/background_work_gate.dart';
import 'package:shuyo/shared/navigation/background_work_boundary.dart';
import 'package:shuyo/shared/navigation/shuyo_route.dart';

void main() {
  testWidgets('route transitions defer work and release it after settling',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator, home: const Scaffold(body: Text('home'))));
    navigator.currentState!.push(shuyoRoute<void>(
        builder: (_) => const Scaffold(body: Text('incoming'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(BackgroundWorkGate.isBusy, isTrue);
    var resumed = false;
    BackgroundWorkGate.idle.then((_) => resumed = true);
    await tester.pumpAndSettle();
    expect(BackgroundWorkGate.isBusy, isFalse);
    expect(resumed, isTrue);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(BackgroundWorkGate.isBusy, isFalse);
  });

  testWidgets('disposing an active scroll releases its work blocker',
      (tester) async {
    late BuildContext scrollContext;
    await tester.pumpWidget(MaterialApp(
        home: BackgroundWorkBoundary(child: Builder(builder: (context) {
      scrollContext = context;
      return const SizedBox.expand();
    }))));
    final metrics = FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 3000,
        pixels: 0,
        viewportDimension: 600,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1);
    ScrollStartNotification(metrics: metrics, context: scrollContext)
        .dispatch(scrollContext);
    expect(BackgroundWorkGate.isBusy, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(BackgroundWorkGate.isBusy, isFalse);
    await BackgroundWorkGate.idle;
  });

  test('nested owners must all finish before background work resumes',
      () async {
    final first = Object();
    final second = Object();
    BackgroundWorkGate.hold(first);
    BackgroundWorkGate.hold(second);
    var resumed = false;
    final pending = BackgroundWorkGate.idle.then((_) => resumed = true);
    BackgroundWorkGate.release(first);
    await Future<void>.delayed(Duration.zero);
    expect(resumed, isFalse);
    BackgroundWorkGate.release(second);
    await pending;
    expect(resumed, isTrue);
  });
}

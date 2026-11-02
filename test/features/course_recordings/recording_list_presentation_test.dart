import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/features/course_recordings/recording_list_presentation.dart';

void main() {
  testWidgets(
      'an interactive back gesture defers updates even without an animating controller',
      (tester) async {
    final updates = ValueNotifier(0);
    addTearDown(updates.dispose);
    final navigator = GlobalKey<NavigatorState>();
    var builds = 0;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      home: RecordingListPresentation(
        changes: updates,
        builder: (_) {
          builds++;
          return Text('items ${updates.value}');
        },
      ),
    ));
    await tester.pumpAndSettle();
    final beforeGesture = builds;
    navigator.currentState!.didStartUserGesture();
    updates.value = 4;
    await tester.pump();
    expect(builds, beforeGesture);
    expect(find.text('items 0'), findsOneWidget);
    navigator.currentState!.didStopUserGesture();
    await tester.pumpAndSettle();
    expect(builds, beforeGesture + 1);
    expect(find.text('items 4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a scrolling viewport defers and coalesces business notifications',
      (tester) async {
    final updates = ValueNotifier(0);
    addTearDown(updates.dispose);
    var builds = 0;
    late BuildContext scrollContext;
    late BuildContext nestedContext;
    await tester.pumpWidget(MaterialApp(
      home: RecordingListPresentation(
        changes: updates,
        builder: (context) {
          builds++;
          return Builder(builder: (context) {
            scrollContext = context;
            return Builder(builder: (context) {
              nestedContext = context;
              return Text('items ${updates.value}');
            });
          });
        },
      ),
    ));
    await tester.pumpAndSettle();
    final initial = builds;
    final metrics = FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 3000,
        pixels: 0,
        viewportDimension: 600,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1);
    ScrollStartNotification(metrics: metrics, context: scrollContext)
        .dispatch(scrollContext);
    ScrollStartNotification(metrics: metrics, context: nestedContext)
        .dispatch(nestedContext);
    for (var value = 1; value <= 20; value++) {
      updates.value = value;
    }
    await tester.pump(const Duration(milliseconds: 200));
    expect(builds, initial);
    expect(find.text('items 0'), findsOneWidget);
    ScrollEndNotification(metrics: metrics, context: scrollContext)
        .dispatch(scrollContext);
    await tester.pump();
    expect(builds, initial);
    ScrollEndNotification(metrics: metrics, context: nestedContext)
        .dispatch(nestedContext);
    await tester.pump();
    expect(builds, initial + 1);
    expect(find.text('items 20'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'hidden and transitioning routes publish only after return settles',
      (tester) async {
    final updates = ValueNotifier(0);
    addTearDown(updates.dispose);
    final navigator = GlobalKey<NavigatorState>();
    var builds = 0;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      home: RecordingListPresentation(
        changes: updates,
        builder: (context) {
          builds++;
          return Text('items ${updates.value}');
        },
      ),
    ));
    await tester.pumpAndSettle();
    final beforePush = builds;
    navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('player'))));
    updates.value = 1;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(builds, beforePush);
    await tester.pumpAndSettle();
    updates.value = 2;
    updates.value = 3;
    await tester.pump();
    expect(builds, beforePush);
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(builds, beforePush);
    await tester.pumpAndSettle();
    expect(builds, beforePush + 1);
    expect(find.text('items 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

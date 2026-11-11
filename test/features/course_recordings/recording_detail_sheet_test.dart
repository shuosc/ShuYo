import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/features/course_recordings/recording_detail_sheet.dart';

void main() {
  late RecordingDetailSheet controller;
  late ScrollController scrollController;

  Widget app({double topInset = 220, Widget? child}) => MaterialApp(
        home: Scaffold(
          body: RecordingDetailSheetHost(
            topInset: topInset,
            child: child ??
                Builder(builder: (context) {
                  controller = RecordingDetailSheet.of(context);
                  return const ColoredBox(color: Colors.blue);
                }),
          ),
        ),
      );

  Widget detail(VoidCallback close) => ColoredBox(
        color: Colors.white,
        child: Column(
          children: [
            SizedBox(
              height: 45,
              child: Row(children: [
                const Expanded(child: Text('笔记详情')),
                IconButton(
                  key: const ValueKey('close-details'),
                  onPressed: close,
                  icon: const Icon(Icons.close, size: 20),
                ),
              ]),
            ),
            Expanded(
              child: ListView.builder(
                key: const ValueKey('detail-scroll'),
                controller: scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: 100,
                itemExtent: 50,
                itemBuilder: (context, index) => Text('正文 $index'),
              ),
            ),
          ],
        ),
      );

  setUp(() {
    scrollController = ScrollController();
  });

  tearDown(() {
    scrollController.dispose();
  });

  testWidgets('sheet fills only the area below the player without a barrier',
      (tester) async {
    await tester.pumpWidget(app());
    final barriers = find.byType(ModalBarrier).evaluate().length;
    controller.show(detail);
    await tester.pumpAndSettle();

    final sheet =
        tester.getRect(find.byKey(const ValueKey('recording-detail-sheet')));
    expect(sheet, const Rect.fromLTRB(0, 220, 800, 600));
    expect(find.byType(ModalBarrier), findsNWidgets(barriers));
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(find.byType(Navigator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('header icons remain tappable and close the detail sheet',
      (tester) async {
    await tester.pumpWidget(app());
    controller.show(detail);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('close-details')));
    await tester.pumpAndSettle();
    expect(find.text('笔记详情'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('body scrolling does not drag or dismiss the sheet',
      (tester) async {
    await tester.pumpWidget(app());
    controller.show(detail);
    await tester.pumpAndSettle();
    await tester.drag(
        find.byKey(const ValueKey('detail-scroll')), const Offset(0, -230));
    await tester.pumpAndSettle();

    expect(scrollController.offset, greaterThan(200));
    expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('recording-detail-sheet')))
            .dy,
        220);
    expect(find.text('笔记详情'), findsOneWidget);

    await tester.drag(
        find.byKey(const ValueKey('detail-scroll')), const Offset(0, 450));
    await tester.pumpAndSettle();
    expect(find.text('笔记详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short header drag restores and long header drag closes',
      (tester) async {
    await tester.pumpWidget(app());
    controller.show(detail);
    await tester.pumpAndSettle();

    await tester.timedDragFrom(
      const Offset(300, 240),
      const Offset(0, 65),
      const Duration(seconds: 1),
    );
    await tester.pumpAndSettle();
    expect(find.text('笔记详情'), findsOneWidget);
    expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('recording-detail-sheet')))
            .dy,
        220);

    await tester.timedDragFrom(
      const Offset(300, 240),
      const Offset(0, 260),
      const Duration(seconds: 1),
    );
    await tester.pumpAndSettle();
    expect(find.text('笔记详情'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only the side edges accept an inward swipe to close',
      (tester) async {
    await tester.pumpWidget(app());
    controller.show(detail);
    await tester.pumpAndSettle();

    await tester.dragFrom(const Offset(300, 350), const Offset(150, 0));
    await tester.pumpAndSettle();
    expect(find.text('笔记详情'), findsOneWidget);

    await tester.dragFrom(const Offset(5, 350), const Offset(150, 0));
    await tester.pumpAndSettle();
    expect(find.text('笔记详情'), findsNothing);

    controller.show(detail);
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(795, 350), const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(find.text('笔记详情'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system back closes local history before leaving the player',
      (tester) async {
    await tester.pumpWidget(app());
    controller.show(detail);
    await tester.pumpAndSettle();

    expect(
        await tester.state<NavigatorState>(find.byType(Navigator)).maybePop(),
        isTrue);
    await tester.pumpAndSettle();
    expect(find.text('笔记详情'), findsNothing);
    expect(find.byType(RecordingDetailSheetHost), findsOneWidget);
    expect(
        await tester.state<NavigatorState>(find.byType(Navigator)).maybePop(),
        isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('updating the video inset preserves the open panel and scroll',
      (tester) async {
    final inset = ValueNotifier<double>(220);
    addTearDown(inset.dispose);
    final body = Builder(builder: (context) {
      controller = RecordingDetailSheet.of(context);
      return const ColoredBox(color: Colors.blue);
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<double>(
          valueListenable: inset,
          builder: (context, value, child) => RecordingDetailSheetHost(
            topInset: value,
            child: child!,
          ),
          child: body,
        ),
      ),
    ));
    controller.show(detail);
    await tester.pumpAndSettle();
    scrollController.jumpTo(300);
    inset.value = 100;
    await tester.pump();
    expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('recording-detail-sheet')))
            .dy,
        100);
    expect(scrollController.offset, 300);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a panel can be closed before its first animation frame',
      (tester) async {
    await tester.pumpWidget(app());
    controller.show(detail);
    controller.close();
    await tester.pumpAndSettle();
    expect(find.text('笔记详情'), findsNothing);
    expect(
        await tester.state<NavigatorState>(find.byType(Navigator)).maybePop(),
        isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('maybeOf is null outside the host', (tester) async {
    RecordingDetailSheet? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      result = RecordingDetailSheet.maybeOf(context);
      return const SizedBox.shrink();
    })));
    expect(result, isNull);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shuyo/data/demo/demo_library_booking.dart';
import 'package:shuyo/features/library_booking/library_booking_page.dart';

void main() {
  testWidgets('demo reservations can be created and cancelled across visits',
      (tester) async {
    final session = DemoLibraryBookingSession(
      schoolClock: () => DateTime.utc(2026, 11, 18, 10),
    );

    Future<void> openPage(
        DemoLibraryBookingSession session, String visit) async {
      await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage.demo(key: ValueKey(visit), session: session),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> tap(Finder finder) async {
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    await openPage(session, 'first visit');
    expect(find.text('图书馆预约 · 演示'), findsOneWidget);
    await tap(find.text('本部图书馆'));
    await tap(find.text('2楼东侧'));
    final manualSeat = find.byKey(const ValueKey('manual-seat-button'));
    await tester.scrollUntilVisible(manualSeat, 160);
    await tap(manualSeat);
    await tap(find.byTooltip('01，可选'));
    await tap(find.text('确认座位'));
    final create = find.widgetWithText(FilledButton, '创建预约');
    await tester.scrollUntilVisible(create, 160);
    await tap(create);
    expect(find.text('确认演示预约'), findsOneWidget);
    await tap(find.text('提交'));
    expect(find.text('取消预约'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await openPage(session, 'second visit');
    final booking = find.byKey(const ValueKey('home:demo-LIB_SEAT-1'));
    expect(booking, findsOneWidget);
    await tap(booking);
    await tap(find.text('取消预约'));
    await tap(find.widgetWithText(FilledButton, '确认'));
    expect(booking, findsNothing);
    await tap(find.text('查看历史预约'));
    expect(find.text('已取消'), findsWidgets);
    expect(find.text('01 · 2楼东侧'), findsOneWidget);

    await openPage(DemoLibraryBookingSession(), 'new demo session');
    await tap(find.text('查看历史预约'));
    expect(find.text('01 · 2楼东侧'), findsNothing);
  });
}

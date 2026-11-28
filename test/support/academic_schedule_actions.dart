import 'package:flutter/foundation.dart' show ValueKey;
import 'package:flutter_test/flutter_test.dart';

final scheduleMoreButton = find.byKey(const ValueKey('schedule-more-menu'));
final scheduleRefreshAction =
    find.byKey(const ValueKey('schedule-refresh-action'));
final scheduleRefreshConfirmButton =
    find.byKey(const ValueKey('schedule-refresh-confirm'));

Future<void> openScheduleMenu(WidgetTester tester) async {
  await tester.tap(scheduleMoreButton);
  await tester.pumpAndSettle();
}

Future<void> openScheduleRefreshConfirmation(WidgetTester tester) async {
  await openScheduleMenu(tester);
  await tester.tap(scheduleRefreshAction);
  await tester.pumpAndSettle();
}

Future<void> refreshSchedule(WidgetTester tester) async {
  await openScheduleRefreshConfirmation(tester);
  await tester.tap(scheduleRefreshConfirmButton);
  await tester.pumpAndSettle();
}

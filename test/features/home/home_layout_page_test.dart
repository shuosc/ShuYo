import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shuyo/data/models/home_layout.dart';
import 'package:shuyo/features/home/home_layout_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

void main() {
  Future<void> pumpPage(WidgetTester tester,
      {Future<void> Function(HomeLayout)? onChanged}) async {
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
      home: HomeLayoutPage(
        initialLayout: HomeLayout.defaults(),
        onChanged: onChanged ?? (_) async {},
      ),
    ));
    await tester.pumpAndSettle();
  }

  Finder checkbox(HomeModule module) => find.descendant(
        of: find.byKey(ValueKey('module:${module.id}')),
        matching: find.byType(Checkbox),
      );

  testWidgets('rapid checkbox changes are saved in order', (tester) async {
    final firstSave = Completer<void>();
    final saves = <HomeLayout>[];
    await pumpPage(tester, onChanged: (layout) async {
      saves.add(layout);
      if (saves.length == 1) await firstSave.future;
    });
    await tester.tap(checkbox(HomeModule.todayCourse));
    await tester.pump();
    await tester.tap(checkbox(HomeModule.campusCard));
    await tester.pump();
    expect(saves, hasLength(1));
    expect(tester.widget<Checkbox>(checkbox(HomeModule.todayCourse)).value,
        isFalse);
    expect(tester.widget<Checkbox>(checkbox(HomeModule.campusCard)).value,
        isFalse);
    firstSave.complete();
    await tester.pumpAndSettle();
    expect(saves, hasLength(2));
    expect(
        saves.last.entries
            .where((e) => e.isModule && !e.enabled)
            .map((e) => e.module),
        [HomeModule.todayCourse, HomeModule.campusCard]);
  });

  testWidgets('pressing and moving a handle reorders without a long press',
      (tester) async {
    HomeLayout? saved;
    await pumpPage(tester, onChanged: (layout) async => saved = layout);
    final handle = find.descendant(
      of: find.byKey(const ValueKey('module:today_course')),
      matching: find.byIcon(Icons.drag_handle_rounded),
    );
    final start = tester.getCenter(handle);
    final targetY = tester
            .getBottomLeft(find.byKey(const ValueKey('module:campus_card')))
            .dy +
        24;
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveTo(Offset(start.dx, targetY));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(saved, isNotNull);
    final modules =
        saved!.entries.where((e) => e.isModule).map((e) => e.module).toList();
    expect(modules.indexOf(HomeModule.campusCard),
        lessThan(modules.indexOf(HomeModule.todayCourse)));
  });

  testWidgets('merging a group retains every module and reset restores groups',
      (tester) async {
    HomeLayout? saved;
    await pumpPage(tester, onChanged: (layout) async => saved = layout);
    final remove = find.byKey(const ValueKey('remove-group:services'));
    await tester.ensureVisible(remove);
    await tester.pumpAndSettle();
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(saved!.visibleGroups, hasLength(1));
    expect(saved!.visibleGroups.single.modules, HomeModule.values);
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(saved!.toJson(), HomeLayout.defaults().toJson());
  });

  testWidgets('new boundaries can be added without losing modules',
      (tester) async {
    HomeLayout? saved;
    await pumpPage(tester, onChanged: (layout) async => saved = layout);
    await tester.scrollUntilVisible(find.text('添加分组'), 240);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加分组'));
    await tester.pumpAndSettle();
    expect(saved!.entries.last.isGroup, isTrue);
    expect(saved!.entries.where((e) => e.isGroup), hasLength(3));
    expect(saved!.entries.where((e) => e.isModule),
        hasLength(HomeModule.values.length));
    expect(tester.takeException(), isNull);
  });

  testWidgets('dividers can be added and removed separately from card groups',
      (tester) async {
    HomeLayout? saved;
    await pumpPage(tester, onChanged: (layout) async => saved = layout);
    expect(find.textContaining('勾选显示'), findsNothing);
    await tester.scrollUntilVisible(find.text('添加分割线'), 240);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加分割线'));
    await tester.pumpAndSettle();
    final divider = saved!.entries.lastWhere((entry) => entry.isDivider);
    expect(
        find.descendant(
            of: find.byKey(ValueKey(divider.key)), matching: find.text('分割线')),
        findsOneWidget);
    final remove = find.byKey(ValueKey('remove-divider:${divider.dividerId}'));
    await tester.ensureVisible(remove);
    await tester.pumpAndSettle();
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(
        saved!.entries
            .where((entry) => entry.isDivider)
            .map((entry) => entry.dividerId),
        ['overview-divider']);
    expect(saved!.entries.where((entry) => entry.isGroup), hasLength(2));
    expect(saved!.entries.where((entry) => entry.isModule),
        hasLength(HomeModule.values.length));
  });

  testWidgets('failed save restores the last persisted checkbox state',
      (tester) async {
    await pumpPage(tester,
        onChanged: (_) async => throw StateError('disk full'));
    await tester.tap(checkbox(HomeModule.campusCard));
    await tester.pumpAndSettle();
    expect(
        tester.widget<Checkbox>(checkbox(HomeModule.campusCard)).value, isTrue);
    expect(find.text('保存失败，已恢复上次布局，请重试'), findsOneWidget);
  });

  testWidgets('back navigation waits for an outstanding save', (tester) async {
    final save = Completer<void>();
    await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => HomeLayoutPage(
                      initialLayout: HomeLayout.defaults(),
                      onChanged: (_) => save.future,
                    ),
                  )),
                  child: const Text('打开编辑'),
                ),
              )),
    ));
    await tester.tap(find.text('打开编辑'));
    await tester.pumpAndSettle();
    await tester.tap(checkbox(HomeModule.todayCourse));
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(HomeLayoutPage), findsOneWidget);
    save.complete();
    await tester.pumpAndSettle();
    expect(find.byType(HomeLayoutPage), findsNothing);
    expect(find.text('打开编辑'), findsOneWidget);
  });
}

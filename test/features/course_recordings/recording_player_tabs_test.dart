import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/features/course_recordings/recording_player_tabs.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

class _TabsHarness extends StatefulWidget {
  const _TabsHarness({this.noteCount});

  final int? noteCount;

  @override
  State<_TabsHarness> createState() => _TabsHarnessState();
}

class _TabsHarnessState extends State<_TabsHarness>
    with SingleTickerProviderStateMixin {
  late final controller = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: RecordingPlayerTabs(
            controller: controller,
            noteCount: widget.noteCount,
          ),
        ),
      );
}

void main() {
  Widget app({int? noteCount, ThemeData? theme}) => MaterialApp(
        theme: theme ?? ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
        home: _TabsHarness(noteCount: noteCount),
      );

  TextStyle renderedStyle(WidgetTester tester, Finder finder) =>
      DefaultTextStyle.of(tester.element(finder)).style;

  testWidgets(
      'labels and count use the same PiliPlus typography in both states',
      (tester) async {
    await tester.pumpWidget(app(noteCount: 57));
    await tester.pumpAndSettle();
    final intro = find.text('简介');
    final notes = find.byKey(const ValueKey('recording-notes-tab-label'));
    final scheme = Theme.of(tester.element(notes)).colorScheme;
    for (final finder in [intro, notes]) {
      final style = renderedStyle(tester, finder);
      expect(style.fontSize, 13);
      expect(style.fontWeight, FontWeight.w500);
      expect(style.height, 1.43);
      expect(style.letterSpacing, .1);
    }
    expect(tester.widget<Text>(notes).data, '笔记 57');
    expect(tester.widget<Text>(notes).textSpan, isNull);
    expect(renderedStyle(tester, intro).color, scheme.primary);
    expect(renderedStyle(tester, notes).color, scheme.onSurfaceVariant);
    await tester.tap(notes);
    await tester.pumpAndSettle();
    expect(renderedStyle(tester, intro).fontWeight, FontWeight.w500);
    expect(renderedStyle(tester, notes).fontWeight, FontWeight.w500);
    expect(renderedStyle(tester, notes).fontSize, 13);
    expect(renderedStyle(tester, notes).color, scheme.primary);
    expect(renderedStyle(tester, intro).color, scheme.onSurfaceVariant);
  });

  testWidgets('the 45-pixel bar keeps two 96-pixel tabs aligned left',
      (tester) async {
    await tester.pumpWidget(app(noteCount: 12));
    final bar = find.byType(TabBar);
    final tabs = tester.widget<TabBar>(bar);
    expect(tester.getSize(bar), const Size(192, 45));
    expect(tester.getTopLeft(bar), Offset.zero);
    expect(tester.getSize(find.byType(RecordingPlayerTabs)).height, 45);
    expect(tabs.padding, EdgeInsets.zero);
    expect(tabs.labelPadding, EdgeInsets.zero);
    expect(tabs.dividerHeight, 0);
    expect(tabs.indicatorSize, isNull);
    expect(tester.getCenter(find.text('简介')).dx, 48);
    expect(tester.getCenter(find.text('笔记 12')).dx, 144);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown, empty, and populated counts preserve the selected tab',
      (tester) async {
    await tester.pumpWidget(app());
    expect(find.text('笔记'), findsOneWidget);
    expect(find.text('笔记 0'), findsNothing);
    await tester.tap(find.text('笔记'));
    await tester.pumpAndSettle();
    final controller = tester.widget<TabBar>(find.byType(TabBar)).controller!;
    expect(controller.index, 1);
    await tester.pumpWidget(app(noteCount: 0));
    expect(find.text('笔记 0'), findsOneWidget);
    expect(find.text('笔记'), findsNothing);
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller, controller);
    expect(controller.index, 1);
    await tester.pumpWidget(app(noteCount: 8));
    expect(find.text('笔记 8'), findsOneWidget);
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller, controller);
    expect(controller.index, 1);
    await tester.pumpWidget(app());
    expect(find.text('笔记'), findsOneWidget);
    expect(find.text('笔记 0'), findsNothing);
    expect(find.text('笔记 8'), findsNothing);
    expect(controller.index, 1);
    expect(tester.takeException(), isNull);
  });
}

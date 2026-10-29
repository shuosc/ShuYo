import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/features/course_recordings/recording_episode_metadata.dart';
import 'package:shuyo/features/course_recordings/recording_episode_sort_icon.dart';
import 'package:shuyo/features/course_recordings/recording_episode_tile.dart';
import 'package:shuyo/features/course_recordings/recording_status_icon.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

void main() {
  testWidgets('sort glyph follows icon foreground in both orders',
      (tester) async {
    for (final color in [Colors.white, Colors.black87, Colors.white38]) {
      for (final descending in [true, false]) {
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
          body: IconTheme(
              data: IconThemeData(color: color),
              child: RecordingEpisodeSortIcon(descending: descending)),
        )));
        final icon = find.byType(RecordingEpisodeSortIcon);
        final texts = tester.widgetList<Text>(
            find.descendant(of: icon, matching: find.byType(Text)));
        expect(texts.map((text) => text.style!.color), everyElement(color));
        final arrow = find.descendant(
            of: icon, matching: find.byIcon(Icons.arrow_downward));
        expect(IconTheme.of(tester.element(arrow)).color, color);
      }
    }
  });

  test('missing course metadata does not add empty separators', () {
    const lesson = VodLesson(
        id: 1,
        teachingClassId: 10,
        name: '课程',
        isPlayable: true,
        weekNumber: 7,
        sectionLabel: '第4节');
    expect(recordingEpisodeHeading(lesson), '第7周 · 第4节');
    expect(recordingEpisodeDetails(lesson), isEmpty);
    expect(recordingFullscreenEpisodeHeading(lesson), '第7周 · 第4节');
  });

  test('episode date uses zero-padded month and day regardless of year', () {
    final lesson = VodLesson(
        id: 1,
        teachingClassId: 10,
        name: '课程',
        isPlayable: true,
        beginTime: DateTime(2025, 1, 3, 8, 5),
        endTime: DateTime(2025, 1, 3, 8, 50),
        classroom: 'A101');
    expect(recordingEpisodeDetails(lesson), '01-03 08:05-08:50 · A101');
  });

  Widget buildTile(VodLesson lesson,
          {bool selected = false, bool dark = false, double scale = 1}) =>
      MaterialApp(
        theme: ShuYoThemes.all.first.themeData(),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: RecordingEpisodeTile(
              tileKey: const ValueKey('episode'),
              lesson: lesson,
              number: 26,
              selected: selected,
              dark: dark,
              onTap: lesson.canPlay ? () {} : null,
            ),
          ),
        ),
      );

  testWidgets('recording shows date and class details without repeated status',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final lesson = VodLesson(
      id: 1,
      teachingClassId: 10,
      name: '课程',
      isPlayable: true,
      beginTime: DateTime(2026, 10, 29, 13),
      endTime: DateTime(2026, 10, 29, 13, 45),
      weekNumber: 6,
      sectionLabel: '第5节',
      classroom: 'DJ204',
    );
    await tester.pumpWidget(buildTile(lesson, selected: true));
    expect(find.text('26'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('第 26 集')), findsOneWidget);
    expect(find.text('第6周 周四 · 第5节'), findsOneWidget);
    expect(find.text('10-29 13:00-13:45 · DJ204'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
    expect(find.text('录播回放'), findsNothing);
    expect(find.byIcon(Icons.play_circle_outline_rounded), findsOneWidget);
    final title = tester.widget<Text>(find.text('26'));
    expect(title.style!.fontWeight, FontWeight.w600);
    expect(
        title.style!.color,
        Theme.of(tester.element(find.byKey(const ValueKey('episode'))))
            .colorScheme
            .primary);
    semantics.dispose();
  });

  testWidgets('special states remain visible and unavailable lessons disabled',
      (tester) async {
    const generating = VodLesson(
        id: 2,
        teachingClassId: 10,
        name: '课程',
        isPlayable: false,
        isGenerating: true,
        classroom: 'C502');
    await tester.pumpWidget(buildTile(generating, dark: true));
    expect(find.text('回放生成中'), findsOneWidget);
    expect(
        tester.widget<ListTile>(find.byKey(const ValueKey('episode'))).enabled,
        isFalse);
    expect(find.text('C502'), findsOneWidget);
    final live = VodLesson(
        id: 3, teachingClassId: 10, name: '直播', isPlayable: true, isLive: true);
    await tester.pumpWidget(buildTile(live, selected: true));
    expect(find.text('正在直播'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
    expect(
        tester
            .widget<RecordingStatusIcon>(find.byType(RecordingStatusIcon))
            .isLive,
        isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('narrow large text and missing or cross-day times stay safe',
      (tester) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final lesson = VodLesson(
        id: 4,
        teachingClassId: 10,
        name: '课程',
        isPlayable: false,
        isGenerating: true,
        classroom: '特别长的教室名称测试房间',
        beginTime: DateTime(2026, 12, 31, 23, 30),
        endTime: DateTime(2027, 1, 1, 0, 15));
    await tester.pumpWidget(buildTile(lesson, scale: 2));
    expect(find.text('回放生成中'), findsOneWidget);
    expect(find.textContaining('23:30'), findsOneWidget);
    expect(find.textContaining('00:15'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fullscreen fixed-height row fits long labels at scaled text',
      (tester) async {
    tester.view.physicalSize = const Size(260, 180);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final lesson = VodLesson(
        id: 5,
        teachingClassId: 10,
        name: '课程',
        isPlayable: false,
        isGenerating: true,
        classroom: '特别长的教室名称测试房间',
        beginTime: DateTime(2026, 10, 29, 13),
        endTime: DateTime(2026, 10, 29, 13, 45),
        weekNumber: 7,
        sectionLabel: '第4节');
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      home: Scaffold(
          body: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: SizedBox(
            height: 80,
            child: RecordingEpisodeTile(
              tileKey: const ValueKey('episode'),
              lesson: lesson,
              number: 999,
              selected: false,
              dark: true,
              onTap: null,
            )),
      )),
    ));
    expect(find.text('回放生成中'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

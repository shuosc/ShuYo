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
    expect(recordingEpisodeDateTime(lesson), '01-03 08:05-08:50');
    expect(recordingEpisodeDetails(lesson), 'A101 · 01-03 08:05-08:50');
  });

  test('fullscreen heading puts its time range in parentheses', () {
    final lesson = VodLesson(
      id: 1,
      teachingClassId: 10,
      name: '课程',
      isPlayable: true,
      beginTime: DateTime(2026, 10, 29, 13),
      endTime: DateTime(2026, 10, 29, 13, 45),
      weekNumber: 1,
      sectionLabel: '第5节',
      classroom: 'A101',
    );
    expect(recordingFullscreenEpisodeHeading(lesson),
        '第1周 周四 · 第5节 (13:00-13:45)');
    expect(recordingEpisodeHeading(lesson), '第1周 周四 · 第5节');
    expect(recordingEpisodeDateTime(lesson), '10-29 13:00-13:45');
    expect(recordingEpisodeDetails(lesson), 'A101 · 10-29 13:00-13:45');
  });

  test('fullscreen heading omits missing fields without stray punctuation', () {
    final withoutSection = VodLesson(
      id: 1,
      teachingClassId: 10,
      name: '课程',
      isPlayable: true,
      beginTime: DateTime(2026, 10, 29, 13),
    );
    expect(recordingFullscreenEpisodeHeading(withoutSection), '周四 (13:00)');
    const withoutMetadata = VodLesson(
      id: 2,
      teachingClassId: 10,
      name: '课程',
      isPlayable: true,
    );
    expect(recordingFullscreenEpisodeHeading(withoutMetadata), isEmpty);
  });

  Widget buildTile(VodLesson lesson,
          {bool selected = false,
          bool dark = false,
          double scale = 1,
          String themeId = ShuYoThemes.defaultId}) =>
      MaterialApp(
        theme: ShuYoThemes.byId(themeId).themeData(),
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
    expect(find.text('DJ204 · 10-29 13:00-13:45'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
    expect(find.text('录播回放'), findsNothing);
    final icon = find.byIcon(Icons.smart_display_rounded);
    expect(icon, findsOneWidget);
    expect(tester.widget<Icon>(icon).color,
        Theme.of(tester.element(icon)).colorScheme.primary);
    final title = tester.widget<Text>(find.text('26'));
    expect(title.style!.fontWeight, FontWeight.w600);
    expect(
        title.style!.color,
        Theme.of(tester.element(find.byKey(const ValueKey('episode'))))
            .colorScheme
            .primary);
    semantics.dispose();
  });

  testWidgets('classroom leads the subtitle with scoped colors in every mode',
      (tester) async {
    for (final themeId in [ShuYoThemes.defaultId, ShuYoThemes.systemDarkId]) {
      for (final dark in [false, true]) {
        for (final playable in [true, false]) {
          for (final selected in [false, true]) {
            final lesson = VodLesson(
              id: 1,
              teachingClassId: 10,
              name: '课程',
              isPlayable: playable,
              beginTime: DateTime(2026, 10, 29, 13),
              endTime: DateTime(2026, 10, 29, 13, 45),
              weekNumber: 6,
              sectionLabel: '第5节',
              classroom: ' DJ204 ',
            );
            await tester.pumpWidget(buildTile(lesson,
                selected: selected, dark: dark, themeId: themeId));
            final tile = find.byKey(const ValueKey('episode'));
            final context = tester.element(tile);
            final colors = context.shuyoColors;
            final primary = Theme.of(context).colorScheme.primary;
            final disabledColor = dark ? Colors.white38 : colors.textMuted;
            final secondary = !playable
                ? disabledColor
                : dark
                    ? Colors.white70
                    : colors.textSecondary;
            final titleColor = !playable
                ? disabledColor
                : selected
                    ? primary
                    : dark
                        ? Colors.white
                        : colors.textPrimary;
            final row = tester.widget<ListTile>(tile);
            final title = row.title! as Text;
            expect(title.data, '第6周 周四 · 第5节');
            expect(title.style!.color, titleColor);
            expect(title.maxLines, 1);
            expect(title.overflow, TextOverflow.ellipsis);
            expect(row.subtitle, isA<Text>());
            final subtitle = row.subtitle! as Text;
            expect(subtitle.data, isNull);
            expect(
                subtitle.textSpan!.toPlainText(), 'DJ204 · 10-29 13:00-13:45');
            expect(subtitle.style!.color, secondary);
            expect(subtitle.maxLines, 2);
            expect(subtitle.overflow, TextOverflow.ellipsis);
            final spans =
                (subtitle.textSpan! as TextSpan).children!.cast<TextSpan>();
            expect(spans, hasLength(3));
            expect(spans[0].text, 'DJ204');
            expect(spans[0].style!.color, playable ? primary : disabledColor);
            expect(spans[1].text, ' · ');
            expect(spans[1].style, isNull);
            expect(spans[2].text, '10-29 13:00-13:45');
            expect(spans[2].style, isNull);
            expect(tester.takeException(), isNull);
          }
        }
      }
    }
  });

  testWidgets(
      'subtitle omits missing classroom or time without extra separators',
      (tester) async {
    final cases = <({String classroom, DateTime? begin, String expected})>[
      (classroom: ' C502 ', begin: null, expected: 'C502'),
      (
        classroom: ' ',
        begin: DateTime(2026, 10, 29, 13),
        expected: '10-29 13:00'
      ),
      (classroom: '', begin: null, expected: ''),
    ];
    for (final dark in [false, true]) {
      for (final testCase in cases) {
        final lesson = VodLesson(
          id: 1,
          teachingClassId: 10,
          name: '课程',
          isPlayable: true,
          classroom: testCase.classroom,
          beginTime: testCase.begin,
        );
        await tester.pumpWidget(buildTile(lesson, dark: dark));
        final row =
            tester.widget<ListTile>(find.byKey(const ValueKey('episode')));
        expect(recordingEpisodeDetails(lesson), testCase.expected);
        if (testCase.expected.isEmpty) {
          expect(row.subtitle, isNull);
        } else {
          final subtitle = row.subtitle! as Text;
          expect(subtitle.textSpan!.toPlainText(), testCase.expected);
          final spans =
              (subtitle.textSpan! as TextSpan).children!.cast<TextSpan>();
          expect(spans, hasLength(1));
          expect(spans.single.text, testCase.expected);
          final context = tester.element(find.byKey(const ValueKey('episode')));
          expect(subtitle.style!.color,
              dark ? Colors.white70 : context.shuyoColors.textSecondary);
          if (testCase.classroom.trim().isNotEmpty) {
            expect(spans.single.style!.color,
                Theme.of(context).colorScheme.primary);
          } else {
            expect(spans.single.style, isNull);
          }
        }
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('unavailable episode numbers and icons use the disabled color',
      (tester) async {
    for (final generating in [false, true]) {
      for (final dark in [false, true]) {
        final lesson = VodLesson(
            id: 2,
            teachingClassId: 10,
            name: '课程',
            isPlayable: false,
            isGenerating: generating,
            sectionLabel: '第4节');
        await tester.pumpWidget(buildTile(lesson, dark: dark));
        final tile = find.byKey(const ValueKey('episode'));
        final disabledColor =
            dark ? Colors.white38 : tester.element(tile).shuyoColors.textMuted;
        expect(
            tester.widget<Text>(find.text('26')).style!.color, disabledColor);
        expect(
            tester.widget<Text>(find.text('第4节')).style!.color, disabledColor);
        final status = find.text(generating ? '回放生成中' : '暂不可看');
        expect(tester.widget<Text>(status).style!.color, disabledColor);
        expect(
            tester.widget<Icon>(find.byIcon(Icons.smart_display_rounded)).color,
            disabledColor);
        expect(tester.widget<ListTile>(tile).enabled, isFalse);
        expect(tester.widget<ListTile>(tile).onTap, isNull);
      }
    }
    expect(tester.takeException(), isNull);
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/features/course_recordings/recording_player_menu.dart';
import 'package:shuyo/features/course_recordings/recording_player_preferences.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

void main() {
  Widget harness(
          {bool fullscreen = false,
          ValueChanged<RecordingPlayerPreferences>? onChanged}) =>
      MaterialApp(
          home: Scaffold(
        body: Builder(
            builder: (context) => TextButton(
                onPressed: () => showRecordingPlayerMenu(
                      context: context,
                      fullscreen: fullscreen,
                      preferences: const RecordingPlayerPreferences(),
                      onPreferencesChanged: onChanged,
                      secondaryAvailable: true,
                      views: [
                        VodView(
                            viewNumber: 1,
                            displayLabel: '教室',
                            url: Uri.parse(
                                'https://example.test/classroom.mp4?auth_key=synthetic')),
                        VodView(
                            viewNumber: 5,
                            displayLabel: 'PPT',
                            url: Uri.parse('https://example.test/ppt.mp4')),
                      ],
                      informationLoader: () async => [
                        (title: 'Resolution', value: '1920x1080'),
                        (title: 'VideoParams', value: 'H264'),
                        (title: 'AudioParams', value: 'AAC'),
                        (title: 'hwdec', value: 'mediacodec'),
                      ],
                    ),
                child: const Text('更多'))),
      ));

  testWidgets('portrait menu and settings follow the existing bottom sheet',
      (tester) async {
    final changes = <RecordingPlayerPreferences>[];
    await tester.pumpWidget(harness(onChanged: changes.add));
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('播放设置'), findsOneWidget);
    expect(find.text('播放信息'), findsOneWidget);
    expect(find.text('播放链接'), findsOneWidget);
    await tester.tap(find.text('播放设置'));
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsNWidgets(2));
    expect(find.text('显示电量'), findsNothing);
    await tester.tap(find.text('显示现实时间'));
    await tester.pump();
    await tester.tap(find.text('第二视角浮窗'));
    await tester.pump();
    expect(changes.last.showClock, isFalse);
    expect(changes.last.secondaryView, isTrue);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('fullscreen links use the right panel and copy the full source',
      (tester) async {
    tester.view.physicalSize = const Size(873, 393);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(harness(fullscreen: true));
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.getRect(find.text('播放链接')).left, greaterThan(873 / 2));
    await tester.tap(find.text('播放链接'));
    await tester.pumpAndSettle();
    expect(find.text('教室'), findsOneWidget);
    expect(find.text('PPT'), findsOneWidget);
    expect(find.textContaining('音视频流'), findsNothing);
    final link = find.byKey(const ValueKey('recording-playback-link-1'));
    final address =
        find.text('https://example.test/classroom.mp4?auth_key=synthetic');
    expect(tester.getCenter(find.text('教室')).dx, tester.getCenter(link).dx);
    expect(tester.getBottomLeft(find.text('教室')).dy,
        lessThan(tester.getTopLeft(address).dy));
    expect(tester.widget<Text>(address).style?.color,
        tester.element(address).shuyoColors.textSecondary);
    await tester.tap(link);
    await tester.pump();
    expect(copied, 'https://example.test/classroom.mp4?auth_key=synthetic');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fullscreen playback information uses the diagnostic dialog',
      (tester) async {
    await tester.pumpWidget(harness(fullscreen: true));
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放信息'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('1920x1080'), findsOneWidget);
    expect(find.text('mediacodec'), findsOneWidget);
    final confirmContext = tester.element(find.text('确定'));
    expect(DefaultTextStyle.of(confirmContext).style.color,
        Theme.of(confirmContext).colorScheme.primary);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  test('player display settings persist independently of media links',
      () async {
    SharedPreferences.setMockInitialValues({});
    final initial = await RecordingPlayerPreferences.load();
    expect(initial.showClock, isTrue);
    await initial.copyWith(showClock: false, secondaryView: true).save();
    final saved = await RecordingPlayerPreferences.load();
    expect(saved.showClock, isFalse);
    expect(saved.secondaryView, isTrue);
  });
}

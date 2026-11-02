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
          double textScale = 1,
          ValueChanged<RecordingPlayerPreferences>? onChanged}) =>
      MaterialApp(
          builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
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

  void expectLiveProtocolRow(WidgetTester tester) {
    final heading = tester.getRect(find.text('默认直播流'));
    final description = tester.getRect(find.text('新打开直播时使用'));
    final bounds = <Rect>[
      for (final protocol in VodLiveProtocol.values)
        tester.getRect(find.byKey(
            ValueKey('recording-default-live-protocol-${protocol.name}'))),
    ];
    expect(heading.right, lessThanOrEqualTo(bounds.first.left));
    expect(description.right, lessThanOrEqualTo(bounds.first.left));
    for (var index = 1; index < bounds.length; index++) {
      expect(bounds[index - 1].right, lessThanOrEqualTo(bounds[index].left));
      expect(bounds[index].center.dy, closeTo(bounds.first.center.dy, .01));
    }
    expect(bounds.first.bottom, greaterThan(heading.top));
    expect(bounds.first.top, lessThan(description.bottom));
    final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
    for (final bound in bounds) {
      expect(bound.left, greaterThanOrEqualTo(0));
      expect(bound.right, lessThanOrEqualTo(viewport.width));
      expect(bound.top, greaterThanOrEqualTo(0));
      expect(bound.bottom, lessThanOrEqualTo(viewport.height));
    }
    for (final entry in [
      (protocol: VodLiveProtocol.hls, label: 'HLS'),
      (protocol: VodLiveProtocol.flv, label: 'FLV'),
      (protocol: VodLiveProtocol.webRtc, label: 'WebRTC'),
    ]) {
      final chip = tester.widget<ChoiceChip>(find.byKey(
          ValueKey('recording-default-live-protocol-${entry.protocol.name}')));
      expect(
          chip.label,
          isA<Text>()
              .having((text) => text.data, 'protocol label', entry.label));
    }
  }

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

  for (final fullscreen in [false, true]) {
    testWidgets(
        'default live stream chips select exactly one protocol in ${fullscreen ? 'fullscreen' : 'portrait'}',
        (tester) async {
      if (fullscreen) {
        tester.view.physicalSize = const Size(873, 393);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }
      final changes = <RecordingPlayerPreferences>[];
      await tester
          .pumpWidget(harness(fullscreen: fullscreen, onChanged: changes.add));
      await tester.tap(find.text('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('播放设置'));
      await tester.pumpAndSettle();

      final selector =
          find.byKey(const ValueKey('recording-default-live-protocol'));
      await tester.ensureVisible(selector);
      final chips =
          find.descendant(of: selector, matching: find.byType(ChoiceChip));
      expect(chips, findsNWidgets(3));
      expect(find.byType(DropdownButton<VodLiveProtocol>), findsNothing);
      expectLiveProtocolRow(tester);

      Finder protocolChip(VodLiveProtocol protocol) => find
          .byKey(ValueKey('recording-default-live-protocol-${protocol.name}'));

      void expectSelected(VodLiveProtocol selected) {
        for (final protocol in VodLiveProtocol.values) {
          expect(tester.widget<ChoiceChip>(protocolChip(protocol)).selected,
              protocol == selected);
        }
      }

      expectSelected(VodLiveProtocol.hls);
      await tester.tap(protocolChip(VodLiveProtocol.hls));
      await tester.pump();
      expect(changes, isEmpty);
      expectSelected(VodLiveProtocol.hls);

      for (final protocol in [
        VodLiveProtocol.flv,
        VodLiveProtocol.webRtc,
        VodLiveProtocol.hls,
      ]) {
        await tester.ensureVisible(protocolChip(protocol));
        await tester.tap(protocolChip(protocol));
        await tester.pumpAndSettle();
        expect(changes.last.defaultLiveProtocol, protocol);
        expect(changes.last.showClock, isTrue);
        expect(changes.last.secondaryView, isFalse);
        expectSelected(protocol);
        final changeCount = changes.length;
        await tester.tap(protocolChip(protocol));
        await tester.pump();
        expect(changes, hasLength(changeCount));
        expectSelected(protocol);
      }
      expect(changes, hasLength(3));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('live stream selector is disabled for read-only settings',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放设置'));
    await tester.pumpAndSettle();

    final selector =
        find.byKey(const ValueKey('recording-default-live-protocol'));
    final chips = tester.widgetList<ChoiceChip>(
        find.descendant(of: selector, matching: find.byType(ChoiceChip)));
    expect(chips, hasLength(3));
    for (final chip in chips) {
      expect(chip.onSelected, isNull);
    }
    expect(chips.where((chip) => chip.selected).single.label,
        isA<Text>().having((text) => text.data, 'protocol label', 'HLS'));
  });

  for (final fullscreen in [false, true]) {
    testWidgets(
        'default live stream chips fit narrow ${fullscreen ? 'fullscreen' : 'portrait'} settings with large text',
        (tester) async {
      tester.view.physicalSize =
          fullscreen ? const Size(640, 360) : const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final changes = <RecordingPlayerPreferences>[];
      await tester.pumpWidget(harness(
          fullscreen: fullscreen, textScale: 2, onChanged: changes.add));
      await tester.tap(find.text('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('播放设置'));
      await tester.pumpAndSettle();
      final selector =
          find.byKey(const ValueKey('recording-default-live-protocol'));
      expect(find.descendant(of: selector, matching: find.byType(ChoiceChip)),
          findsNWidgets(3));
      await tester.ensureVisible(selector);
      await tester.pumpAndSettle();
      expectLiveProtocolRow(tester);
      for (final protocol in VodLiveProtocol.values) {
        final chip = find.byKey(
            ValueKey('recording-default-live-protocol-${protocol.name}'));
        await tester.ensureVisible(chip);
        await tester.pumpAndSettle();
        await tester.tap(chip);
        await tester.pumpAndSettle();
        expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
        final chips = tester.widgetList<ChoiceChip>(
            find.descendant(of: selector, matching: find.byType(ChoiceChip)));
        expect(chips.where((candidate) => candidate.selected), hasLength(1));
        expectLiveProtocolRow(tester);
        expect(tester.takeException(), isNull);
      }
      expect(changes.last.defaultLiveProtocol, VodLiveProtocol.webRtc);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

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

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/features/course_recordings/recording_player_system_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  final pending = <Completer<void>>[];

  setUp(() {
    calls.clear();
    pending.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      final completion = Completer<void>();
      pending.add(completion);
      await completion.future;
      return null;
    });
  });

  tearDown(() async {
    for (final completion in pending) {
      if (!completion.isCompleted) completion.complete();
    }
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('fullscreen issues orientation and immersive requests without waiting',
      () async {
    final systemUi = RecordingPlayerSystemUi();
    systemUi.lockPortrait();
    systemUi.enterFullscreen();
    await Future<void>.delayed(Duration.zero);

    expect(calls.map((call) => call.method), [
      'SystemChrome.setPreferredOrientations',
      'SystemChrome.setPreferredOrientations',
      'SystemChrome.setEnabledSystemUIMode',
    ]);
    expect(calls[1].arguments, [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);
    expect(calls[2].arguments, 'SystemUiMode.immersiveSticky');
    expect(pending.every((completion) => !completion.isCompleted), isTrue);
  });

  test('exit requests portrait directly without unlocking or restoring twice',
      () async {
    final systemUi = RecordingPlayerSystemUi();
    systemUi.enterFullscreen();
    systemUi.exitFullscreen();
    systemUi.exitFullscreen();
    await Future<void>.delayed(Duration.zero);

    expect(calls, hasLength(4));
    expect(calls[2].method, 'SystemChrome.setPreferredOrientations');
    expect(calls[2].arguments, ['DeviceOrientation.portraitUp']);
    expect(calls[3].arguments, 'SystemUiMode.edgeToEdge');
    expect(
        calls.any((call) =>
            call.arguments is List && (call.arguments as List).isEmpty),
        isFalse);
    expect(pending.every((completion) => !completion.isCompleted), isTrue);
  });

  test('rapid toggles submit the newest target without waiting for rotation',
      () async {
    final systemUi = RecordingPlayerSystemUi();
    systemUi.enterFullscreen();
    systemUi.exitFullscreen();
    systemUi.enterFullscreen();
    systemUi.enterFullscreen();
    await Future<void>.delayed(Duration.zero);

    expect(calls, hasLength(6));
    expect(calls[4].arguments, [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);
    expect(calls[5].arguments, 'SystemUiMode.immersiveSticky');
    expect(pending.every((completion) => !completion.isCompleted), isTrue);
  });

  test('release restores UI once and prevents a stale exit from locking again',
      () async {
    final systemUi = RecordingPlayerSystemUi();
    systemUi.enterFullscreen();
    systemUi.release();
    systemUi.exitFullscreen();
    systemUi.enterFullscreen();
    systemUi.release();
    await Future<void>.delayed(Duration.zero);

    expect(calls, hasLength(4));
    expect(calls[2].arguments, isEmpty);
    expect(calls[3].arguments, 'SystemUiMode.edgeToEdge');
  });

  test('release from embedded mode does not repeat the system bar request',
      () async {
    final systemUi = RecordingPlayerSystemUi();
    systemUi.enterFullscreen();
    systemUi.exitFullscreen();
    systemUi.release();
    await Future<void>.delayed(Duration.zero);

    expect(calls, hasLength(5));
    expect(calls.last.method, 'SystemChrome.setPreferredOrientations');
    expect(calls.last.arguments, isEmpty);
  });
}

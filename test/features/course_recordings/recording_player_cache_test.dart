import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/features/course_recordings/recording_player_cache.dart';

void main() {
  test('recording configures bounded read-ahead and restores live defaults',
      () async {
    final initial = <String, String>{
      'cache': 'yes',
      'cache-secs': '360000',
      'demuxer-hysteresis-secs': '0',
      'demuxer-max-bytes': '33554432',
      'demuxer-max-back-bytes': '33554432',
    };
    final properties = Map<String, String>.of(initial);
    final cache = RecordingPlayerCache(
      readProperty: (name) async => properties[name]!,
      writeProperty: (name, value) async => properties[name] = value,
    );

    await cache.configure(isLive: true);
    expect(properties, initial);

    await cache.configure(isLive: false);
    expect(properties, {
      'cache': 'yes',
      'cache-secs': '300.000',
      'demuxer-hysteresis-secs': '200.000',
      'demuxer-max-bytes': '134217728',
      'demuxer-max-back-bytes': '4194304',
    });

    await cache.configure(isLive: false);
    await cache.configure(isLive: true);
    expect(properties, initial);
  });

  test('each player restores its own defaults after recording playback',
      () async {
    final main = <String, String>{};
    final secondary = <String, String>{};
    RecordingPlayerCache makeCache(
        Map<String, String> properties, String base) {
      return RecordingPlayerCache(
        readProperty: (name) async => properties[name] ?? base,
        writeProperty: (name, value) async => properties[name] = value,
      );
    }

    final mainCache = makeCache(main, 'main-default');
    final secondaryCache = makeCache(secondary, 'secondary-default');
    await mainCache.configure(isLive: false);
    await secondaryCache.configure(isLive: false);
    expect(main, secondary);
    await secondaryCache.configure(isLive: true);
    expect(secondary.values, everyElement('secondary-default'));
    expect(main['cache-secs'], '300.000');
    await mainCache.configure(isLive: true);
    expect(main.values, everyElement('main-default'));
  });

  test('leaves player unchanged if its original options cannot be read',
      () async {
    final writes = <String, String>{};
    final cache = RecordingPlayerCache(
      readProperty: (name) async => name == 'cache-secs' ? '' : 'default',
      writeProperty: (name, value) async => writes[name] = value,
    );

    await cache.configure(isLive: false);
    await cache.configure(isLive: true);
    expect(writes, isEmpty);
  });

  test('recording rate updates its read-ahead and restores live defaults',
      () async {
    final properties = <String, String>{};
    final cache = RecordingPlayerCache(
      readProperty: (name) async => properties[name] ?? 'original',
      writeProperty: (name, value) async => properties[name] = value,
    );

    await cache.configure(isLive: false, rate: 1.5);
    expect(properties['cache-secs'], '450.000');
    expect(properties['demuxer-hysteresis-secs'], '300.000');
    await cache.configure(isLive: false, rate: 2);
    expect(properties['cache-secs'], '600.000');
    expect(properties['demuxer-hysteresis-secs'], '400.000');
    expect(properties['demuxer-max-bytes'], '134217728');
    await cache.configure(isLive: true);
    expect(properties.values, everyElement('original'));
  });

  test('invalid playback rates use the normal read-ahead target', () async {
    final properties = <String, String>{};
    final cache = RecordingPlayerCache(
      readProperty: (name) async => properties[name] ?? 'original',
      writeProperty: (name, value) async => properties[name] = value,
    );
    for (final rate in [0.0, -1.0, double.nan, double.infinity]) {
      await cache.configure(isLive: false, rate: rate);
      expect(properties['cache-secs'], '300.000');
      expect(properties['demuxer-max-bytes'], '134217728');
    }
  });

  test('a live switch supersedes an in-flight recording rate update', () async {
    final properties = <String, String>{};
    final blocked = Completer<void>();
    final started = Completer<void>();
    var blockWrites = false;
    final cache = RecordingPlayerCache(
      readProperty: (name) async => properties[name] ?? 'original',
      writeProperty: (name, value) async {
        if (blockWrites) {
          blockWrites = false;
          started.complete();
          await blocked.future;
        }
        properties[name] = value;
      },
    );
    await cache.configure(isLive: false);
    blockWrites = true;
    final rateUpdate = cache.configure(isLive: false, rate: 2);
    await started.future;
    final liveUpdate = cache.configure(isLive: true);
    blocked.complete();
    await Future.wait([rateUpdate, liveUpdate]);
    expect(properties.values, everyElement('original'));
  });

  test('failed reads or writes do not escape and partial writes restore',
      () async {
    final properties = <String, String>{};
    var failRead = true;
    var failWrite = true;
    final cache = RecordingPlayerCache(
      readProperty: (name) async {
        if (failRead) {
          failRead = false;
          throw StateError('read failed');
        }
        return properties[name] ?? 'original';
      },
      writeProperty: (name, value) async {
        if (failWrite && name == 'cache-secs') {
          failWrite = false;
          throw StateError('write failed');
        }
        properties[name] = value;
      },
    );
    await cache.configure(isLive: false);
    expect(properties, isEmpty);
    await cache.configure(isLive: false);
    expect(properties.values, everyElement('original'));
    await cache.configure(isLive: false);
    expect(properties['cache-secs'], '300.000');
    await cache.configure(isLive: true);
    expect(properties.values, everyElement('original'));
  });
}

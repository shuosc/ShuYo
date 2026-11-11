import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/services/secure_app_store.dart';
import 'package:shuyo/data/services/vod_recording_cache.dart';

class _Store extends SecureAppStore {
  final values = <String, String>{};
  int writes = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }
}

class _LargePayload {
  Map<String, Object?> toJson() => {
        'encodedBy': Isolate.current.debugName,
        'lessons': [
          for (var i = 0; i < 400; i++)
            {'id': i, 'name': '录播课程 $i', 'classroom': '教学楼 A316'},
        ],
      };
}

void main() {
  test('background writes share a bounded batch', () async {
    final store = _Store();
    final cache = VodRecordingCache(
        store: store, backgroundWriteDelay: const Duration(milliseconds: 200));
    final first = cache.save('a', false, 'one', 1, background: true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final second = cache.save('a', false, 'two', 2, background: true);
    expect(store.writes, 0);
    await Future.wait([first, second]);
    expect(store.writes, 1);
    final saved =
        jsonDecode(store.values[VodRecordingCache.storageKey]!) as Map;
    expect(saved['a:direct'], {'one': 1, 'two': 2});
  });

  test('foreground writes expedite pending batches across cache instances',
      () async {
    final store = _Store();
    final background = VodRecordingCache(
        store: store, backgroundWriteDelay: const Duration(seconds: 20));
    final foreground = VodRecordingCache(store: store);
    final pending = background.save('a', false, 'old', 1, background: true);
    await foreground
        .save('a', false, 'new', 2)
        .timeout(const Duration(seconds: 2));
    await pending;
    expect(await foreground.load('a', false, 'old'), 1);
    expect(await foreground.load('a', false, 'new'), 2);
  });

  test('foreground reads expedite pending background writes', () async {
    final store = _Store();
    final background = VodRecordingCache(
        store: store, backgroundWriteDelay: const Duration(seconds: 20));
    final foreground = VodRecordingCache(store: store);
    final pending = background.save('a', false, 'one', 1, background: true);
    expect(
        await foreground
            .load('a', false, 'one')
            .timeout(const Duration(seconds: 2)),
        1);
    await pending;
  });

  test('batch checks session validity and keeps the latest entry version',
      () async {
    final store = _Store();
    final cache = VodRecordingCache(
        store: store, backgroundWriteDelay: const Duration(seconds: 20));
    var valid = true;
    final writes = [
      cache.save('a', false, 'course', 'old', version: 1, background: true),
      cache.save('a', false, 'course', 'new', version: 2, background: true),
      cache.save('a', false, 'course', 'stale', version: 1, background: true),
      cache.save('b', false, 'other', 'secret',
          canWrite: () => valid, canCommit: () => valid, background: true),
    ];
    valid = false;
    expect(await cache.load('a', false, 'course'), 'new');
    await Future.wait(writes);
    expect(await cache.load('b', false, 'other'), isNull);
    expect(store.writes, 1);
  });

  test('a single large course is serialized outside the caller isolate',
      () async {
    final store = _Store();
    final cache = VodRecordingCache(store: store);
    await cache.save('a', false, 'lessons:42', _LargePayload());

    final saved =
        jsonDecode(store.values[VodRecordingCache.storageKey]!) as Map;
    final course = saved['a:direct']['lessons:42'] as Map;
    expect(course['encodedBy'], isNot(Isolate.current.debugName));
    expect(course['lessons'], hasLength(400));
    expect(store.writes, 1);
  });

  test('equal values acknowledge the write without rewriting storage',
      () async {
    final store = _Store();
    final cache = VodRecordingCache(store: store);
    const payload = {
      'lessons': [
        {'id': 1, 'name': '课程'},
      ],
    };
    await cache.save('a', false, 'course', payload);
    var committed = 0;
    await cache.save('a', false, 'course', payload,
        onCommitted: () => committed++);

    expect(store.writes, 1);
    expect(committed, 1);
  });

  test('equal-value writes revalidate the session before acknowledgement',
      () async {
    final store = _Store();
    final cache = VodRecordingCache(store: store);
    await cache.save('a', false, 'course', 'original');
    var checks = 0;
    var committed = 0;
    await cache.save('a', false, 'course', 'original',
        canWrite: () => ++checks == 1, onCommitted: () => committed++);

    expect(await cache.load('a', false, 'course'), 'original');
    expect(store.writes, 1);
    expect(committed, 0);
  });

  test('invalid newer write preserves an earlier equal-value candidate',
      () async {
    final store = _Store();
    final cache = VodRecordingCache(
        store: store, backgroundWriteDelay: const Duration(seconds: 20));
    await cache.save('a', false, 'course', 'original');
    var checks = 0;
    var originalCommitted = 0;
    var staleCommitted = 0;
    final original = cache.save('a', false, 'course', 'original',
        version: 1, onCommitted: () => originalCommitted++, background: true);
    final stale = cache.save('a', false, 'course', 'stale',
        version: 2,
        canWrite: () => ++checks == 1,
        onCommitted: () => staleCommitted++,
        background: true);

    expect(await cache.load('a', false, 'course'), 'original');
    await Future.wait([original, stale]);
    expect(store.writes, 1);
    expect(originalCommitted, 1);
    expect(staleCommitted, 0);
  });

  test('final commit guards recheck entries after async account validation',
      () async {
    final store = _Store();
    final cache = VodRecordingCache(
        store: store, backgroundWriteDelay: const Duration(seconds: 20));
    var firstValid = true;
    var secondChecks = 0;
    var staleCommitted = 0;
    final first = cache.save('a', false, 'stale', 'old account',
        canCommit: () => firstValid,
        onCommitted: () => staleCommitted++,
        background: true);
    final second =
        cache.save('b', false, 'current', 'new account', canWrite: () async {
      if (++secondChecks == 2) {
        await Future<void>.delayed(Duration.zero);
        firstValid = false;
      }
      return true;
    }, background: true);

    expect(await cache.load('b', false, 'current'), 'new account');
    await Future.wait([first, second]);
    expect(await cache.load('a', false, 'stale'), isNull);
    expect(staleCommitted, 0);
    expect(store.writes, 1);
  });
}

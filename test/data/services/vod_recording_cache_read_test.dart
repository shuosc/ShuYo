import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/services/secure_app_store.dart';
import 'package:shuyo/data/services/vod_recording_cache.dart';

class _Store extends SecureAppStore {
  String? value;

  @override
  Future<String?> read(String key) async => value;

  @override
  Future<void> write(String key, String next) async => value = next;
}

void main() {
  test('large cache reads select only the requested account transport and term',
      () async {
    final store = _Store()
      ..value = jsonEncode({
        'other:direct': {
          for (var id = 1; id <= 4000; id++)
            'playback:42:$id': {
              'course': {'acteId': 7},
              'playback': {'title': '其他账号 $id', 'description': 'x' * 100},
            },
        },
        'a:direct': {
          'courses:7': ['metadata'],
          'playback:42:1': {
            'course': {'acteId': 7},
            'playback': {'title': '所选学期'},
          },
          'playback:42:2': {
            'course': {'acteId': 8},
            'playback': {'title': '其他学期'},
          },
          'playback:invalid': 'broken',
        },
        'a:webvpn': {
          'playback:42:1': {
            'course': {'acteId': 7},
            'playback': {'title': 'WebVPN'},
          },
        },
      });
    final cache = VodRecordingCache(store: store);
    expect(await cache.load('a', false, 'courses:7'), ['metadata']);
    expect(await cache.load('missing', false, 'courses:7'), isNull);
    final direct = await cache.savedLessons('a', false, 7);
    expect(direct, hasLength(1));
    expect(direct.single['playback']['title'], '所选学期');
    expect(await cache.savedLessons('a', false, null), hasLength(2));
    expect((await cache.savedLessons('a', true, 7)).single['playback']['title'],
        'WebVPN');
    expect(await cache.hasSavedLessons('a', false), isTrue);
    expect(await cache.hasSavedLessons('missing', false), isFalse);
  });

  test(
      'availability reads flush pending batches and ignore metadata-only scopes',
      () async {
    final store = _Store();
    final cache = VodRecordingCache(
        store: store, backgroundWriteDelay: const Duration(seconds: 20));
    final metadata =
        cache.save('a', false, 'courses:7', ['course'], background: true);
    expect(await cache.hasSavedLessons('a', false), isFalse);
    await metadata;
    final playback = cache.save(
        'a',
        false,
        'playback:42:1',
        {
          'course': {'acteId': 7}
        },
        background: true);
    expect(await cache.hasSavedLessons('a', false), isTrue);
    await playback;
    expect(await cache.hasSavedLessons('a', true), isFalse);
  });

  test('missing malformed and non-map caches remain safe misses', () async {
    final store = _Store();
    final cache = VodRecordingCache(store: store);
    for (final raw in [null, '{invalid', '[]', '{"a:direct": []}']) {
      store.value = raw;
      expect(await cache.load('a', false, 'courses:7'), isNull);
      expect(await cache.savedLessons('a', false, 7), isEmpty);
      expect(await cache.hasSavedLessons('a', false), isFalse);
    }
  });
}

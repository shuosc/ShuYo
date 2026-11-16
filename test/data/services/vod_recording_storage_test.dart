import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/core/background_work_gate.dart';
import 'package:shuyo/data/services/vod_recording_cache.dart';
import 'package:shuyo/data/services/vod_recording_storage.dart';

class _Payload {
  Map<String, Object> toJson() => {
        'isolate': Isolate.current.debugName ?? '',
        'course': {'acteId': 7},
        'url': 'https://example.invalid/signed?key=keep-private',
      };
}

void main() {
  late Directory directory;
  late VodRecordingStorage storage;
  final key = List.generate(32, (i) => i);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shuyo-recording-test-');
    storage = await VodRecordingStorage.open(
        directory: directory.path, encryptionKey: key);
  });
  tearDown(() async {
    await storage.close();
    await directory.delete(recursive: true);
  });

  Future<void> save(List<VodCacheRecord> records) async =>
      storage.commit(await storage.prepare(records));

  test('worker encrypts records and restores them after reopening', () async {
    await save([
      (scope: 'a:direct', key: 'playback:42:1', value: _Payload(), version: 1)
    ]);
    final restored = await storage.load('a:direct', 'playback:42:1') as Map;
    expect(restored['isolate'], 'vod-recording-storage');
    final files =
        await directory.list(recursive: true).where((e) => e is File).toList();
    for (final file in files.cast<File>()) {
      final bytes = await file.readAsBytes();
      expect(utf8.decode(bytes, allowMalformed: true),
          isNot(contains('keep-private')));
      expect(utf8.decode(bytes, allowMalformed: true),
          isNot(contains('playback:42:1')));
    }
    await storage.close();
    storage = await VodRecordingStorage.open(
        directory: directory.path, encryptionKey: key);
    expect(await storage.load('a:direct', 'playback:42:1'), restored);
  });

  test('single record updates do not rewrite the historical library', () async {
    await save([
      for (var i = 0; i < 350; i++)
        (
          scope: 'a:direct',
          key: 'playback:42:$i',
          value: {
            'course': {'acteId': 7},
            'description': 'x' * 3000
          },
          version: 1
        ),
    ]);
    final before = await storage.statistics();
    await save([
      (
        scope: 'a:direct',
        key: 'playback:42:1',
        value: {
          'course': {'acteId': 7},
          'description': 'updated'
        },
        version: 2
      )
    ]);
    final after = await storage.statistics();
    expect(after['recordWrites']! - before['recordWrites']!, 1);
    expect(after['bytesWritten']! - before['bytesWritten']!, lessThan(20000));
    expect(after['cachedIndexes'], lessThanOrEqualTo(32));
  });

  test('identical values avoid physical record and index writes', () async {
    final records = [
      (scope: 'a:direct', key: 'terms', value: [7], version: 1)
    ];
    await save(records);
    final before = await storage.statistics();
    await save(records);
    final after = await storage.statistics();
    expect(after['bytesWritten'], before['bytesWritten']);
    expect(after['recordWrites'], before['recordWrites']);
  });

  test('failed index replacement preserves the previous committed generation',
      () async {
    await save([(scope: 'a:direct', key: 'one', value: 'old', version: 1)]);
    final index = (await directory
            .list(recursive: true)
            .where((e) => e is File && e.path.endsWith('index.cache'))
            .toList())
        .single;
    final blocker = Directory('${index.path}.pending');
    await blocker.create();
    final token = await storage.prepare([
      (scope: 'a:direct', key: 'one', value: 'new', version: 2),
    ]);
    await expectLater(storage.commit(token), throwsStateError);
    expect(await storage.load('a:direct', 'one'), 'old');
    await blocker.delete();
    await save([(scope: 'a:direct', key: 'one', value: 'new', version: 2)]);
    expect(await storage.load('a:direct', 'one'), 'new');
  });

  test('prepared writes remain invisible until authorized and can be discarded',
      () async {
    final token = await storage.prepare([
      (scope: 'a:direct', key: 'terms', value: [7], version: null),
    ]);
    expect(await storage.load('a:direct', 'terms'), isNull);
    await storage.discard(token);
    expect(await storage.load('a:direct', 'terms'), isNull);
    expect((await storage.statistics())['recordWrites'], 0);
  });

  test(
      'legacy migration preserves accounts transports terms and newest versions',
      () async {
    await storage.close();
    final migration = Directory('${directory.path}/migration');
    storage = await VodRecordingStorage.open(
        directory: migration.path,
        encryptionKey: key,
        legacyJson: jsonEncode({
          'a:direct': {
            'playback:42:1': {
              'course': {'acteId': 7}
            },
            'playback:42:2': {
              'course': {'acteId': 8}
            },
            'courses:7': ['metadata'],
          },
          'a:webvpn': {
            'playback:42:1': {
              'course': {'acteId': 9}
            }
          },
          'b:direct': {
            'terms': ['private']
          },
        }));
    expect(await storage.savedLessons('a:direct', 7), hasLength(1));
    expect(await storage.savedLessons('a:direct', null), hasLength(2));
    expect(await storage.savedLessons('a:webvpn', 9), hasLength(1));
    expect(await storage.load('a:direct', 'terms'), isNull);
    expect(await storage.hasSavedLessons('missing:direct'), isFalse);
    await save([
      (scope: 'a:direct', key: 'terms', value: 'new', version: 2),
      (scope: 'a:direct', key: 'terms', value: 'stale', version: 1),
    ]);
    expect(await storage.load('a:direct', 'terms'), 'new');
    await storage.close();
    storage = await VodRecordingStorage.open(
        directory: migration.path,
        encryptionKey: key,
        legacyJson: '{"a:direct":{"terms":"old"}}');
    expect(await storage.load('a:direct', 'terms'), 'new');
  });

  test('a damaged record is a safe miss and does not destroy other records',
      () async {
    await save([
      (scope: 'a:direct', key: 'one', value: 1, version: null),
      (scope: 'b:direct', key: 'two', value: 2, version: null),
    ]);
    final files = await directory
        .list(recursive: true)
        .where((e) =>
            e is File &&
            e.path.endsWith('.cache') &&
            !e.path.endsWith('index.cache'))
        .toList();
    final file = files.first as File;
    final bytes = await file.readAsBytes();
    bytes[bytes.length - 1] ^= 1;
    await file.writeAsBytes(bytes);
    final values = [
      await storage.load('a:direct', 'one'),
      await storage.load('b:direct', 'two')
    ];
    expect(values.where((v) => v == null), hasLength(1));
    expect(values.where((v) => v != null), hasLength(1));
  });

  test(
      'pending reads remain visible across instances without forcing persistence',
      () async {
    final owner = Object();
    BackgroundWorkGate.hold(owner);
    final first = VodRecordingCache(
        storage: storage,
        backgroundWriteDelay: const Duration(milliseconds: 10));
    final other = VodRecordingCache(storage: storage);
    final pending = first.save(
        'a',
        false,
        'playback:42:1',
        {
          'course': {'acteId': 7}
        },
        background: true);
    try {
      expect(await other.load('a', false, 'playback:42:1'), isA<Map>());
      expect(await other.hasSavedLessons('a', false), isTrue);
      expect(await other.savedLessons('a', false, 7), hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect((await storage.statistics())['recordWrites'], 0);
    } finally {
      BackgroundWorkGate.release(owner);
      await pending;
    }
    expect((await storage.statistics())['recordWrites'], 1);
  });

  test('account invalidation during worker encoding prevents persistence',
      () async {
    final cache = VodRecordingCache(storage: storage);
    var checks = 0;
    var committed = 0;
    await cache.save('a', false, 'course', _Payload(),
        canWrite: () => ++checks == 1, onCommitted: () => committed++);
    expect(await storage.load('a:direct', 'course'), isNull);
    expect((await storage.statistics())['recordWrites'], 0);
    expect(committed, 0);
  });

  test('pending reads recheck account validity after worker projection',
      () async {
    final cache = VodRecordingCache(
        storage: storage, backgroundWriteDelay: const Duration(seconds: 20));
    var checks = 0;
    final pending = cache.save('a', false, 'course', _Payload(),
        background: true, canWrite: () => ++checks == 1);
    expect(await cache.load('a', false, 'course'), isNull);
    await VodRecordingCache.flush();
    await pending;
    expect(await storage.load('a:direct', 'course'), isNull);
  });
}

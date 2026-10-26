import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/services/announcement_memory_cache.dart';

void main() {
  test(
      'field updates retain the original TTL and cannot revive an expired entry',
      () {
    var now = DateTime(2026, 10, 27);
    final cache = AnnouncementMemoryCache<String>(
      maxEntries: 2,
      maxBytes: 100,
      sizeOf: (value) => value.length,
      now: () => now,
    );
    cache.put('a', 'partial');
    now = now.add(const Duration(minutes: 4));
    cache.update('a', 'complete');
    expect(cache.lookup('a')?.value, 'complete');
    now = now.add(const Duration(minutes: 1));
    cache.update('a', 'too late');
    expect(cache.lookup('a'), isNull);
    cache.update('absent', 'new');
    expect(cache.lookup('absent'), isNull);
  });

  test('field updates account for their new size and retain the bounded budget',
      () {
    final cache = AnnouncementMemoryCache<String>(
      maxEntries: 3,
      maxBytes: 12,
      sizeOf: (value) => value.length,
    );
    cache.put('a', '12');
    cache.put('b', '12');
    cache.update('b', '1234567');
    expect(cache.lookup('a'), isNull);
    expect(cache.lookup('b')?.value, '1234567');
    cache.update('b', '12345678901');
    expect(cache.lookup('b'), isNull);
  });

  test('reads refresh LRU order without extending the cached value lifetime',
      () {
    var now = DateTime(2026, 10, 25);
    final cache = AnnouncementMemoryCache<String>(
      maxEntries: 2,
      maxBytes: 100,
      ttl: const Duration(minutes: 5),
      sizeOf: (value) => value.length * 2,
      now: () => now,
    );
    cache.put('a', 'first');
    cache.put('b', 'second');
    now = now.add(const Duration(minutes: 4));
    expect(cache.lookup('a')?.value, 'first');
    cache.put('c', 'third');
    expect(cache.lookup('b'), isNull);
    expect(cache.lookup('a')?.value, 'first');
    now = now.add(const Duration(minutes: 1));
    expect(cache.lookup('a'), isNull);
    expect(cache.lookup('c')?.value, 'third');
  });

  test('payload bytes and keys share a bounded budget', () {
    final cache = AnnouncementMemoryCache<String>(
      maxEntries: 20,
      maxBytes: 10,
      ttl: const Duration(minutes: 5),
      sizeOf: (value) => value.length * 2,
    );
    cache.put('a', '123');
    cache.put('b', '12');
    expect(cache.lookup('a'), isNull);
    expect(cache.lookup('b')?.value, '12');
    cache.put('b', '123456');
    expect(cache.lookup('b'), isNull);
    cache.put('c', '1234');
    expect(cache.lookup('c')?.value, '1234');
  });

  test('expired entries are reclaimed before a live LRU entry is evicted', () {
    var now = DateTime(2026, 10, 25);
    final cache = AnnouncementMemoryCache<String>(
      maxEntries: 2,
      maxBytes: 100,
      ttl: const Duration(minutes: 5),
      sizeOf: (value) => value.length,
      now: () => now,
    );
    cache.put('old', 'old');
    now = now.add(const Duration(minutes: 4));
    cache.put('live', 'live');
    cache.lookup('old');
    now = now.add(const Duration(minutes: 1));
    cache.put('new', 'new');
    expect(cache.lookup('old'), isNull);
    expect(cache.lookup('live')?.value, 'live');
    expect(cache.lookup('new')?.value, 'new');
  });

  test('null previews are cached and targeted removal releases their budget',
      () {
    final cache = AnnouncementMemoryCache<String?>(
      maxEntries: 5,
      maxBytes: 20,
      ttl: const Duration(minutes: 5),
      sizeOf: (value) => (value?.length ?? 0) * 2,
    );
    cache.put('a', null);
    cache.put('b', '1234');
    expect(cache.lookup('a'), isNotNull);
    expect(cache.lookup('a')!.value, isNull);
    cache.removeWhere((key, _) => key == 'b');
    cache.put('c', '1234');
    expect(cache.lookup('a'), isNotNull);
    expect(cache.lookup('c')?.value, '1234');
    cache.clear();
    expect(cache.lookup('a'), isNull);
    expect(cache.lookup('c'), isNull);
  });
}

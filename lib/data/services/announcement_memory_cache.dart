import 'dart:collection';

/// Short-lived announcement data, bounded by both entry count and payload size.
class AnnouncementMemoryCache<T> {
  AnnouncementMemoryCache({
    required this.maxEntries,
    required this.maxBytes,
    required this.ttl,
    required int Function(T) sizeOf,
    DateTime Function()? now,
  })  : assert(maxEntries > 0),
        assert(maxBytes > 0),
        _sizeOf = sizeOf,
        _now = now ?? DateTime.now;

  final int maxEntries;
  final int maxBytes;
  final Duration ttl;
  final int Function(T) _sizeOf;
  final DateTime Function() _now;
  final LinkedHashMap<String, _CachedAnnouncementValue<T>> _entries =
      LinkedHashMap();
  int _bytes = 0;

  /// A wrapper distinguishes a cached null value from a cache miss.
  ({T value})? lookup(String key) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    if (_now().difference(entry.createdAt) >= ttl) {
      _bytes -= entry.bytes;
      return null;
    }
    _entries[key] = entry;
    return (value: entry.value);
  }

  void put(String key, T value) {
    final previous = _entries.remove(key);
    if (previous != null) _bytes -= previous.bytes;
    final bytes = _sizeOf(value) + key.length * 2;
    if (bytes > maxBytes) return;
    final now = _now();
    _removeWhere((_, entry) => now.difference(entry.createdAt) >= ttl);
    _entries[key] = _CachedAnnouncementValue(value, bytes, now);
    _bytes += bytes;
    while (_entries.length > maxEntries || _bytes > maxBytes) {
      _bytes -= _entries.remove(_entries.keys.first)!.bytes;
    }
  }

  void removeWhere(bool Function(String key, T value) test) {
    _removeWhere((key, entry) => test(key, entry.value));
  }

  void _removeWhere(
      bool Function(String key, _CachedAnnouncementValue<T> entry) test) {
    final keys = [
      for (final entry in _entries.entries)
        if (test(entry.key, entry.value)) entry.key,
    ];
    for (final key in keys) {
      _bytes -= _entries.remove(key)!.bytes;
    }
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }
}

class _CachedAnnouncementValue<T> {
  const _CachedAnnouncementValue(this.value, this.bytes, this.createdAt);

  final T value;
  final int bytes;
  final DateTime createdAt;
}

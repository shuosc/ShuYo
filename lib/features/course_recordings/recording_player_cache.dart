import 'package:media_kit/media_kit.dart';

typedef CachePropertyReader = Future<String> Function(String name);
typedef CachePropertyWriter = Future<void> Function(String name, String value);

class RecordingPlayerCache {
  static const _readAheadSeconds = 300;
  static const _maxForwardBytes = 128 * 1024 * 1024;

  RecordingPlayerCache({
    required CachePropertyReader readProperty,
    required CachePropertyWriter writeProperty,
  })  : _readProperty = readProperty,
        _writeProperty = writeProperty;

  final CachePropertyReader _readProperty;
  final CachePropertyWriter _writeProperty;
  Map<String, String>? _original;
  Future<void> _pending = Future.value();
  int _revision = 0;

  Map<String, String> _recordingOptions(double rate) {
    final seconds = _readAheadSeconds * (rate.isFinite && rate > 0 ? rate : 1);
    return {
      'cache': 'yes',
      'cache-secs': seconds.toStringAsFixed(3),
      'demuxer-hysteresis-secs': (seconds / 1.5).toStringAsFixed(3),
      'demuxer-max-bytes': _maxForwardBytes.toString(),
      'demuxer-max-back-bytes': '4194304',
    };
  }

  Future<void> configure({required bool isLive, double rate = 1}) {
    final revision = ++_revision;
    _pending = _pending.then((_) => _configure(isLive, rate, revision));
    return _pending;
  }

  Future<bool> _restoreOriginal() async {
    final original = _original;
    if (original == null) return true;
    var restored = true;
    for (final entry in original.entries) {
      try {
        await _writeProperty(entry.key, entry.value);
      } on Object {
        restored = false;
      }
    }
    if (restored) _original = null;
    return restored;
  }

  Future<void> _configure(bool isLive, double rate, int revision) async {
    if (revision != _revision) return;
    if (isLive) {
      await _restoreOriginal();
      return;
    }

    final options = _recordingOptions(rate);
    try {
      if (_original == null) {
        final original = <String, String>{};
        for (final name in options.keys) {
          final value = await _readProperty(name);
          if (value.isEmpty || revision != _revision) return;
          original[name] = value;
        }
        _original = original;
      }
      for (final entry in options.entries) {
        if (revision != _revision) return;
        await _writeProperty(entry.key, entry.value);
      }
    } on Object {
      await _restoreOriginal();
    }
  }
}

final _playerCaches = Expando<RecordingPlayerCache>();

Future<void> configureRecordingPlayerCache(
  Player player, {
  required bool isLive,
  double rate = 1,
}) async {
  final platform = player.platform;
  if (platform is! NativePlayer) return;
  final cache = _playerCaches[player] ??= RecordingPlayerCache(
    readProperty: platform.getProperty,
    writeProperty: platform.setProperty,
  );
  await cache.configure(isLive: isLive, rate: rate);
}

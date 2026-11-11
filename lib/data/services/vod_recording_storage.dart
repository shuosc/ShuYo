import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';

import '../../core/background_work_gate.dart';
import 'secure_app_store.dart';

typedef VodCacheRecord = ({
  String scope,
  String key,
  Object value,
  int? version
});

/// Owns encrypted recording records in a long-lived isolate. Neither the full
/// library nor encrypted file contents cross the UI isolate's platform channel.
class VodRecordingStorage {
  VodRecordingStorage._(this._port, this._responses, this._isolate) {
    _subscription = _responses.listen(_received);
  }

  static const keyStorageKey = 'vod.recording.encryption.v2';
  static Future<VodRecordingStorage>? _shared;

  static Future<VodRecordingStorage> shared() =>
      _shared ??= _openDefault().catchError((Object error, StackTrace stack) {
        _shared = null;
        Error.throwWithStackTrace(error, stack);
      });

  static Future<VodRecordingStorage> _openDefault() async {
    await BackgroundWorkGate.idle;
    final store = SecureAppStore();
    // Initialize the installation marker in the root isolate before the legacy
    // reader starts. Only this small key ever needs a UI platform-channel call.
    var encodedKey = await store.read(keyStorageKey);
    if (encodedKey == null) {
      final random = Random.secure();
      encodedKey = base64Encode(List.generate(32, (_) => random.nextInt(256)));
      await store.write(keyStorageKey, encodedKey);
    }
    final key = base64Decode(encodedKey);
    if (key.length != 32) throw const FormatException('Invalid cache key');
    final directory = await getApplicationSupportDirectory();
    await BackgroundWorkGate.idle;
    return open(
      directory: '${directory.path}/vod-recordings-v2',
      encryptionKey: key,
      rootToken: RootIsolateToken.instance,
      migratePlatformStore: true,
    );
  }

  /// Explicit paths and keys also allow testing the real worker and ciphertext
  /// without replacing filesystem/encryption operations with a mock.
  static Future<VodRecordingStorage> open({
    required String directory,
    required List<int> encryptionKey,
    RootIsolateToken? rootToken,
    bool migratePlatformStore = false,
    String? legacyJson,
  }) async {
    if (encryptionKey.length != 32) throw ArgumentError('Expected AES-256 key');
    final handshake = ReceivePort();
    final responses = ReceivePort();
    final isolate = await Isolate.spawn(
      _worker,
      (
        handshake.sendPort,
        responses.sendPort,
        directory,
        Uint8List.fromList(encryptionKey),
        rootToken,
        migratePlatformStore,
        legacyJson
      ),
      debugName: 'vod-recording-storage',
      onError: responses.sendPort,
      onExit: responses.sendPort,
    );
    try {
      final message = await handshake.first;
      if (message is! SendPort) {
        throw StateError('Recording cache initialization failed');
      }
      return VodRecordingStorage._(message, responses, isolate);
    } on Object {
      isolate.kill(priority: Isolate.immediate);
      responses.close();
      rethrow;
    } finally {
      handshake.close();
    }
  }

  final SendPort _port;
  final ReceivePort _responses;
  final Isolate _isolate;
  late final StreamSubscription<dynamic> _subscription;
  final _pending = <int, Completer<Object?>>{};
  var _sequence = 0;
  bool _closed = false;

  void _received(dynamic message) {
    if (message is! List || message.length != 3 || message[0] is! int) {
      _failPending();
      return;
    }
    final completion = _pending.remove(message[0]);
    if (message[1] == true) {
      completion?.complete(message[2]);
    } else {
      completion?.completeError(StateError('Recording cache operation failed'));
    }
  }

  void _failPending() {
    _closed = true;
    for (final completion in _pending.values) {
      completion.completeError(StateError('Recording cache worker stopped'));
    }
    _pending.clear();
  }

  Future<Object?> _request(String operation, Object? value) {
    if (_closed) return Future.error(StateError('Recording cache is closed'));
    final id = ++_sequence;
    final completion = _pending[id] = Completer<Object?>();
    _port.send([id, operation, value]);
    return completion.future;
  }

  Future<Object?> load(String scope, String key) =>
      _request('load', (scope, key));

  Future<bool> hasSavedLessons(String scope) async =>
      await _request('has', scope) as bool;

  Future<Map<String, Map<String, dynamic>>> savedLessons(
          String scope, int? term) async =>
      (await _request('lessons', (scope, term)) as Map)
          .cast<String, Map<String, dynamic>>();

  // Encoding is prepared in the worker, then the caller rechecks account and
  // revision guards before authorizing any physical write.
  Future<int> prepare(List<VodCacheRecord> records) async =>
      await _request('prepare', records) as int;
  Future<void> commit(int token) async => await _request('commit', token);
  Future<void> discard(int token) async => await _request('discard', token);

  Future<Map<String, int>> statistics() async =>
      (await _request('stats', null) as Map).cast<String, int>();

  Future<void> close() async {
    if (_closed) return;
    await _request('close', null);
    _failPending();
    await _subscription.cancel();
    _responses.close();
    _isolate.kill();
  }
}

typedef _Boot = (
  SendPort,
  SendPort,
  String,
  Uint8List,
  RootIsolateToken?,
  bool,
  String?
);

Future<void> _worker(_Boot boot) async {
  final (handshake, replies, path, key, rootToken, migrate, legacy) = boot;
  final commands = ReceivePort();
  try {
    if (rootToken != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken);
    }
    final disk = _RecordingDisk(Directory(path), key);
    await disk.initialize();
    final marker = File('$path/migrated');
    if (!await marker.exists()) {
      final raw = legacy ??
          (migrate
              ? await SecureAppStore().read('vod.recording.cache.v1')
              : null);
      await disk.migrate(raw);
      await marker.writeAsString('2', flush: true);
    }
    // A failed deletion is retried next launch; never reimport stale data after
    // the migration marker was committed successfully.
    if (migrate) {
      try {
        await SecureAppStore().delete('vod.recording.cache.v1');
      } on Object {
        // The encrypted migrated records are already durable.
      }
    }
    handshake.send(commands.sendPort);
    await for (final dynamic message in commands) {
      final id = message[0] as int;
      final operation = message[1] as String;
      try {
        final result = await disk.handle(operation, message[2]);
        replies.send([id, true, result]);
        if (operation == 'close') break;
      } on Object {
        // Never return exception text containing JSON, URLs or filesystem data.
        replies.send([id, false, null]);
      }
    }
  } on Object {
    handshake.send(false);
  } finally {
    commands.close();
  }
}

class _RecordingDisk {
  _RecordingDisk(this.directory, this.key);

  final Directory directory;
  final Uint8List key;
  final _random = Random.secure();
  final _indexes = <String, Map<String, dynamic>>{};
  final _prepared = <int, List<_PreparedRecord>>{};
  var _token = 0;
  var _recordWrites = 0;
  var _bytesRead = 0;
  var _bytesWritten = 0;

  Future<void> initialize() => directory.create(recursive: true);

  String _digest(String text) => SHA256Digest()
      .process(Uint8List.fromList(utf8.encode(text)))
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();

  String _bucket(String scope, String entry) =>
      '${_digest(scope)}/${_digest(entry).substring(0, 2)}';
  String _recordPath(String scope, String entry) =>
      '${_bucket(scope, entry)}/${_digest(entry)}';

  Future<Object?> _read(String relative) async {
    final file = File('${directory.path}/$relative.cache');
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    _bytesRead += bytes.length;
    if (bytes.length < 29 || bytes.first != 2) {
      throw const FormatException('Invalid encrypted recording record');
    }
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
          false,
          AEADParameters(KeyParameter(key), 128,
              Uint8List.sublistView(bytes, 1, 13), utf8.encode(relative)));
    return jsonDecode(utf8.decode(cipher.process(
      Uint8List.sublistView(bytes, 13),
    )));
  }

  Uint8List _encrypt(String relative, String json) {
    final nonce =
        Uint8List.fromList(List.generate(12, (_) => _random.nextInt(256)));
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true,
          AEADParameters(KeyParameter(key), 128, nonce, utf8.encode(relative)));
    return Uint8List.fromList(
        [2, ...nonce, ...cipher.process(utf8.encode(json))]);
  }

  Future<void> _write(String relative, Uint8List bytes) async {
    final file = File('${directory.path}/$relative.cache');
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.pending');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
    _bytesWritten += bytes.length;
  }

  Future<Map<String, dynamic>> _index(String bucket) async {
    final cached = _indexes.remove(bucket);
    if (cached != null) {
      _indexes[bucket] = cached;
      return cached;
    }
    final value = await _read('$bucket/index');
    final index = value is Map<String, dynamic> ? value : <String, dynamic>{};
    // Bound in-memory index retention; the on-disk library stays available.
    if (_indexes.length >= 32) _indexes.remove(_indexes.keys.first);
    _indexes[bucket] = index;
    return index;
  }

  Future<List<String>> _buckets(String scope) async {
    final folder = Directory('${directory.path}/${_digest(scope)}');
    if (!await folder.exists()) return const [];
    return [
      await for (final entity in folder.list(followLinks: false))
        if (entity is Directory)
          '${_digest(scope)}/${entity.uri.pathSegments.where((s) => s.isNotEmpty).last}',
    ];
  }

  Future<Object?> load(String scope, String entry) async {
    try {
      final index = await _index(_bucket(scope, entry));
      final metadata = index[entry];
      if (metadata is! Map || metadata['hash'] is! String) return null;
      return await _read('${_recordPath(scope, entry)}.${metadata['hash']}');
    } on Object {
      // A damaged record is a safe miss, without losing other courses/scopes.
      _indexes[_bucket(scope, entry)]?.remove(entry);
      return null;
    }
  }

  Future<Map<String, Map<String, dynamic>>> lessons(String scope, int? term,
      {bool firstOnly = false}) async {
    final result = <String, Map<String, dynamic>>{};
    for (final bucket in await _buckets(scope)) {
      Map<String, dynamic> index;
      try {
        index = await _index(bucket);
      } on Object {
        continue;
      }
      for (final entry in index.entries.toList(growable: false)) {
        if (!entry.key.startsWith('playback:')) continue;
        final metadata = entry.value;
        if (term != null && (metadata as Map?)?['term'] != term) continue;
        final value = await load(scope, entry.key);
        if (value is Map<String, dynamic>) {
          result[entry.key] = value;
          if (firstOnly) return result;
        }
      }
    }
    return result;
  }

  Future<int> prepare(List<VodCacheRecord> records) async {
    final selected = <String, VodCacheRecord>{};
    for (final record in records) {
      final identity = _recordPath(record.scope, record.key);
      final previous = selected[identity];
      if (previous?.version != null &&
          record.version != null &&
          previous!.version! > record.version!) {
        continue;
      }
      selected[identity] = record;
    }
    final changes = <_PreparedRecord>[];
    for (final entry in selected.entries) {
      final record = entry.value;
      final json = jsonEncode(record.value);
      final hash = _digest(json);
      final bucket = _bucket(record.scope, record.key);
      Map<String, dynamic> index;
      try {
        index = await _index(bucket);
      } on Object {
        index = <String, dynamic>{};
        _indexes[bucket] = index;
      }
      final path = '${entry.key}.$hash';
      if ((index[record.key] as Map?)?['hash'] == hash &&
          await File('${directory.path}/$path.cache').exists()) {
        continue;
      }
      final decoded = jsonDecode(json);
      final course = decoded is Map ? decoded['course'] : null;
      final term = course is Map ? course['acteId'] : null;
      changes.add(_PreparedRecord(bucket, record.key, path,
          {'hash': hash, 'term': term}, _encrypt(path, json)));
    }
    final token = ++_token;
    _prepared[token] = changes;
    return token;
  }

  Future<void> commit(int token) async {
    final records = _prepared.remove(token);
    if (records == null) {
      throw StateError('Unknown recording cache transaction');
    }
    final changed = <String, Map<String, dynamic>>{};
    final obsolete = <String>[];
    try {
      for (final record in records) {
        await _write(record.path, record.bytes);
        _recordWrites++;
        final index = changed[record.bucket] ??=
            Map<String, dynamic>.of(await _index(record.bucket));
        final previous = index[record.key];
        if (previous is Map &&
            previous['hash'] is String &&
            previous['hash'] != record.metadata['hash']) {
          obsolete.add(
              '${record.path.substring(0, record.path.lastIndexOf('.'))}.${previous['hash']}');
        }
        index[record.key] = record.metadata;
      }
      for (final entry in changed.entries) {
        final path = '${entry.key}/index';
        await _write(path, _encrypt(path, jsonEncode(entry.value)));
        _indexes[entry.key] = entry.value;
      }
      while (_indexes.length > 32) {
        _indexes.remove(_indexes.keys.first);
      }
      // Index replacement is the visibility/commit point. Keep old generations
      // until then so an interrupted update cannot corrupt a previous value.
      for (final path in obsolete) {
        try {
          final file = File('${directory.path}/$path.cache');
          if (await file.exists()) await file.delete();
        } on Object {
          // A leftover encrypted generation cannot invalidate a committed index.
        }
      }
    } on Object {
      for (final record in records) {
        _indexes.remove(record.bucket);
      }
      rethrow;
    }
  }

  Future<void> migrate(String? raw) async {
    if (raw == null) return;
    Object? value;
    try {
      value = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (value is! Map) return;
    // Bound temporary ciphertext and JSON retention while importing a large v1
    // cache. The original remains intact until all indexes have been committed.
    var batch = <VodCacheRecord>[];
    for (final scope in value.entries) {
      if (scope.key is! String || scope.value is! Map) continue;
      for (final entry in (scope.value as Map).entries) {
        if (entry.key is! String || entry.value == null) continue;
        batch.add((
          scope: scope.key as String,
          key: entry.key as String,
          value: entry.value as Object,
          version: null
        ));
        if (batch.length == 32) {
          await commit(await prepare(batch));
          batch = [];
        }
      }
    }
    if (batch.isNotEmpty) await commit(await prepare(batch));
  }

  Future<Object?> handle(String operation, dynamic argument) async {
    switch (operation) {
      case 'load':
        final (scope, entry) = argument as (String, String);
        return load(scope, entry);
      case 'has':
        return (await lessons(argument as String, null, firstOnly: true))
            .isNotEmpty;
      case 'lessons':
        final (scope, term) = argument as (String, int?);
        return lessons(scope, term);
      case 'prepare':
        return prepare((argument as List).cast<VodCacheRecord>());
      case 'commit':
        await commit(argument as int);
        return null;
      case 'discard':
        _prepared.remove(argument);
        return null;
      case 'stats':
        return {
          'recordWrites': _recordWrites,
          'bytesRead': _bytesRead,
          'bytesWritten': _bytesWritten,
          'cachedIndexes': _indexes.length
        };
      case 'close':
        _prepared.clear();
        return null;
      default:
        throw ArgumentError('Unknown recording cache operation');
    }
  }
}

class _PreparedRecord {
  const _PreparedRecord(
      this.bucket, this.key, this.path, this.metadata, this.bytes);
  final String bucket;
  final String key;
  final String path;
  final Map<String, dynamic> metadata;
  final Uint8List bytes;
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/campus_card.dart';
import 'package:shuyo/data/models/campus_card_snapshot.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/campus_card_cache.dart';
import 'package:shuyo/data/services/secure_app_store.dart';

const _bill =
    CampusCardBill(name: '食堂', payTime: '2026-11-07 12:00:00', amount: 3.5);
final _time = DateTime(2026, 11, 8, 12);
const _key = SecureAppStore.campusCardSnapshotKey;

CampusCardInfo _card(String id, double balance) => CampusCardInfo(
    studentId: id, name: '姓名', status: '正常', balance: balance, validUntil: '');

CampusCardSnapshot _snapshot({String studentId = 'A'}) => CampusCardSnapshot(
      studentId: studentId,
      balance: CampusCardBalanceSnapshot(balance: 100, queriedAt: _time),
      recent: CampusCardRecentSnapshot(
        bills: const [_bill, _bill],
        balances: const [null, null],
        startDate: DateTime(2025, 11, 8),
        endDate: DateTime(2026, 11, 8),
        queriedAt: _time,
        balance: CampusCardBalanceSnapshot(balance: 100, queriedAt: _time),
      ),
      chart: CampusCardChartSnapshot(
          bills: const [_bill],
          endDate: DateTime(2026, 11, 7),
          queriedAt: _time),
    );

CampusCardCache _cache(_MemoryStore store) =>
    CampusCardCache(store: store, accountIdLoader: () async => 'A')
      ..selectAccount('A');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('snapshots round-trip duplicate rows, null balances and original dates',
      () {
    final source = _snapshot();
    final raw = jsonEncode(source.toJson());
    final restored = CampusCardSnapshot.fromJson(jsonDecode(raw));
    expect(restored.toJson(), source.toJson());
    expect(restored.recent!.bills.map((bill) => bill.name), ['食堂', '食堂']);
    expect(restored.recent!.balances, [null, null]);
    expect(restored.chart!.endDate, DateTime(2026, 11, 7));
    expect(() => restored.recent!.bills.clear(), throwsUnsupportedError);
    expect(() => restored.chart!.bills.clear(), throwsUnsupportedError);
    expect(raw, isNot(contains('姓名')));
  });

  test('the preview stores only its newest five rows and matching balances',
      () {
    final recent = CampusCardRecentSnapshot(
      bills: List.filled(8, _bill),
      balances: List.generate(8, (index) => index.toDouble()),
      startDate: DateTime(2025),
      endDate: _time,
      queriedAt: _time,
    );
    expect(recent.bills, hasLength(5));
    expect(recent.balances, [0, 1, 2, 3, 4]);
  });

  test('completed sections survive a new cache instance', () async {
    final store = _MemoryStore();
    final cache = _cache(store);
    final source = _snapshot();
    await cache.rememberBalance(_card('A', 100), _time,
        revision: cache.revision);
    await cache.rememberRecent(source.recent!, revision: cache.revision);
    await cache.rememberChart(source.chart!, revision: cache.revision);
    expect(cache.snapshot!.toJson(), source.toJson());

    final restarted = _cache(store);
    expect(restarted.snapshot, isNull);
    expect((await restarted.load())!.toJson(), source.toJson());
    expect(store.values[_key], isNotNull);
  });

  test('a late disk read merges missing sections without replacing fresh data',
      () async {
    final store = _MemoryStore();
    final source = _snapshot();
    final read = Completer<String?>();
    store.nextRead = read;
    store.readStarted = Completer<void>();
    final cache = _cache(store);
    final loading = cache.load();
    await store.readStarted!.future;
    final saving = cache.rememberBalance(
        _card('A', 200), _time.add(const Duration(minutes: 1)),
        revision: cache.revision);
    expect(cache.snapshot!.balance!.balance, 200);
    read.complete(jsonEncode(source.toJson()));
    await loading;
    await saving;
    expect(cache.snapshot!.balance!.balance, 200);
    expect(cache.snapshot!.recent!.toJson(), source.recent!.toJson());
    expect(cache.snapshot!.chart!.toJson(), source.chart!.toJson());
    final saved = CampusCardSnapshot.fromJson(jsonDecode(store.values[_key]!));
    expect(saved.balance!.balance, 200);
    expect(saved.recent, isNotNull);
    expect(saved.chart, isNotNull);
    // Subsequent visits must not replay the snapshot from the first disk read.
    expect(await cache.load(), same(cache.snapshot));
    expect((await cache.load())!.balance!.balance, 200);
  });

  test('a memoized disk read always returns the latest in-memory sections',
      () async {
    final store = _MemoryStore()
      ..values[_key] = jsonEncode(_snapshot().toJson());
    final cache = _cache(store);
    final firstLoad = await cache.load();
    final updated = CampusCardRecentSnapshot(
      bills: const [],
      balances: const [],
      startDate: DateTime(2025),
      endDate: _time,
      queriedAt: _time.add(const Duration(minutes: 1)),
    );
    await cache.rememberRecent(updated, revision: cache.revision);
    expect(firstLoad!.recent!.bills, isNotEmpty);
    expect((await cache.load())!.recent, same(updated));
    expect((await cache.load())!.chart, same(firstLoad.chart));
  });

  test('older updates cannot replace a newer section', () async {
    final store = _MemoryStore()
      ..values[_key] = jsonEncode(_snapshot().toJson());
    final cache = _cache(store);
    await cache.load();
    await cache.rememberBalance(
        _card('A', 1), _time.subtract(const Duration(minutes: 1)),
        revision: cache.revision);
    expect(cache.snapshot!.balance!.balance, 100);
    expect(cache.snapshot!.recent, isNotNull);
  });

  test('a completed empty ledger replaces older nonempty data', () async {
    final store = _MemoryStore()
      ..values[_key] = jsonEncode(_snapshot().toJson());
    final cache = _cache(store);
    await cache.load();
    await cache.rememberRecent(
      CampusCardRecentSnapshot(
          bills: const [],
          balances: const [],
          startDate: DateTime(2025),
          endDate: _time,
          queriedAt: _time.add(const Duration(minutes: 1))),
      revision: cache.revision,
    );
    expect(cache.snapshot!.recent!.bills, isEmpty);
    final restarted = _cache(store);
    expect((await restarted.load())!.recent!.bills, isEmpty);
    expect(restarted.snapshot!.chart, isNotNull);
  });

  test('corrupt, incompatible and other-account snapshots are ignored',
      () async {
    final malformed = _snapshot().toJson();
    (malformed['recent'] as Map<String, dynamic>)['balances'] = [double.nan];
    for (final raw in [
      '{',
      '[]',
      '{"version":2,"studentId":"A"}',
      jsonEncode(_snapshot(studentId: 'B').toJson()),
      jsonEncode({
        ..._snapshot().toJson(),
        'balance': {'balance': 'bad'}
      }),
      jsonEncode({
        ..._snapshot().toJson(),
        'recent': {..._snapshot().recent!.toJson(), 'balances': []},
      }),
    ]) {
      final cache = _cache(_MemoryStore()..values[_key] = raw);
      expect(await cache.load(), isNull, reason: raw);
    }
    expect(() => CampusCardSnapshot.fromJson(malformed), throwsFormatException);
  });

  test('switching accounts retires pending reads and stale writes', () async {
    String? currentId = 'A';
    final store = _MemoryStore();
    final read = Completer<String?>();
    store.nextRead = read;
    store.readStarted = Completer<void>();
    final cache =
        CampusCardCache(store: store, accountIdLoader: () async => currentId)
          ..selectAccount('A');
    final oldRevision = cache.revision;
    final loading = cache.load();
    await store.readStarted!.future;
    currentId = 'B';
    cache.selectAccount('B');
    await cache.rememberBalance(_card('B', 300), _time,
        revision: cache.revision);
    read.complete(jsonEncode(_snapshot().toJson()));
    expect(await loading, isNull);
    await cache.rememberRecent(_snapshot().recent!, revision: oldRevision);
    expect(cache.snapshot!.studentId, 'B');
    expect(cache.snapshot!.recent, isNull);
    expect(jsonDecode(store.values[_key]!)['studentId'], 'B');

    // Returning to A still cannot admit a response from its previous visit.
    currentId = 'A';
    cache.selectAccount('A');
    await cache.rememberBalance(_card('A', 1), _time, revision: oldRevision);
    expect(cache.snapshot, isNull);
    expect(await cache.load(), isNull);
  });

  test('a write finishing after sign-out cannot resurrect the old account',
      () async {
    String? currentId = 'A';
    final store = _MemoryStore();
    final write = Completer<void>();
    store.nextWrite = write;
    store.writeStarted = Completer<void>();
    final cache =
        CampusCardCache(store: store, accountIdLoader: () async => currentId)
          ..selectAccount('A');
    final oldSave =
        cache.rememberBalance(_card('A', 100), _time, revision: cache.revision);
    await store.writeStarted!.future;
    currentId = null;
    final clearing = cache.clear();
    expect(cache.snapshot, isNull);
    currentId = 'B';
    cache.selectAccount('B');
    final newSave =
        cache.rememberBalance(_card('B', 200), _time, revision: cache.revision);
    write.complete();
    await Future.wait([oldSave, clearing, newSave]);
    expect(jsonDecode(store.values[_key]!)['studentId'], 'B');
    expect(cache.snapshot!.balance!.balance, 200);
  });

  test('account validation rejects a stale identity even before host rebinding',
      () async {
    final store = _MemoryStore();
    final cache =
        CampusCardCache(store: store, accountIdLoader: () async => 'B')
          ..selectAccount('A');
    await cache.rememberBalance(_card('A', 100), _time,
        revision: cache.revision);
    expect(store.values[_key], isNull);
  });

  test('storage failures keep successful data in memory', () async {
    final cache = CampusCardCache(
        store: _UnavailableStore(), accountIdLoader: () async => 'A')
      ..selectAccount('A');
    await cache.rememberBalance(_card('A', 100), _time,
        revision: cache.revision);
    await cache.rememberChart(_snapshot().chart!, revision: cache.revision);
    expect(cache.snapshot!.balance!.balance, 100);
    expect(cache.snapshot!.chart!.bills, hasLength(1));
    await cache.clear();
    expect(cache.snapshot, isNull);
  });

  test('expired sessions retain snapshots and explicit logout deletes them',
      () async {
    final accounts = AcademicAccountStore();
    await accounts.saveStudentId('A');
    final cache = CampusCardCache()..selectAccount('A');
    await cache.rememberBalance(_card('A', 100), _time,
        revision: cache.revision);
    await accounts.clear(sessionExpired: true);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(_key), isNotNull);
    final restarted = CampusCardCache()..selectAccount('A');
    expect((await restarted.load())!.balance!.balance, 100);
    await restarted.rememberChart(_snapshot().chart!,
        revision: restarted.revision);
    expect(jsonDecode(preferences.getString(_key)!)['chart'], isNotNull);
    await accounts.clear();
    expect(preferences.getString(_key), isNull);
  });

  test('account storage removes the old snapshot on an account switch',
      () async {
    final accounts = AcademicAccountStore();
    await accounts.saveStudentId('A');
    final cache = CampusCardCache()..selectAccount('A');
    await cache.rememberBalance(_card('A', 100), _time,
        revision: cache.revision);
    await accounts.saveStudentId('B');
    expect((await SharedPreferences.getInstance()).getString(_key), isNull);
  });
}

class _MemoryStore extends SecureAppStore {
  final values = <String, String>{};
  Completer<String?>? nextRead;
  Completer<void>? nextWrite;
  Completer<void>? readStarted;
  Completer<void>? writeStarted;

  @override
  Future<String?> read(String key) async {
    final pending = nextRead;
    nextRead = null;
    if (pending != null) {
      readStarted?.complete();
      return pending.future;
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    final pending = nextWrite;
    nextWrite = null;
    if (pending != null) {
      writeStarted?.complete();
      await pending.future;
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _UnavailableStore extends SecureAppStore {
  @override
  Future<String?> read(String key) async => throw StateError('unavailable');
  @override
  Future<void> write(String key, String value) async =>
      throw StateError('unavailable');
  @override
  Future<void> delete(String key) async => throw StateError('unavailable');
}

import 'dart:convert';

import '../models/campus_card.dart';
import '../models/campus_card_snapshot.dart';
import 'academic_account_store.dart';
import 'secure_app_store.dart';

/// Account-scoped completed snapshots, shared across campus-card routes.
class CampusCardCache {
  CampusCardCache({
    SecureAppStore? store,
    Future<String?> Function()? accountIdLoader,
  })  : _store = store ?? SecureAppStore(),
        _accountIdLoader = accountIdLoader ?? _loadAccountId;

  final SecureAppStore _store;
  final Future<String?> Function() _accountIdLoader;
  String? _studentId;
  int _revision = 0;
  CampusCardSnapshot? _snapshot;
  Future<void>? _loadTask;
  Future<void> _writes = Future<void>.value();

  String? get studentId => _studentId;
  int get revision => _revision;
  CampusCardSnapshot? get snapshot => _snapshot;

  static Future<String?> _loadAccountId() async {
    final accounts = AcademicAccountStore();
    final current = await accounts.loadStudentId();
    if (current != null) return current;
    return await accounts.isSessionExpired()
        ? accounts.loadDataStudentId()
        : null;
  }

  void selectAccount(String? studentId) {
    if (_studentId == studentId) return;
    final hadAccount = _studentId != null;
    _studentId = studentId;
    _revision++;
    _snapshot = null;
    _loadTask = null;
    if (hadAccount) {
      _queue(() => _store.delete(SecureAppStore.campusCardSnapshotKey));
    }
  }

  Future<void> clear() {
    _studentId = null;
    _revision++;
    _snapshot = null;
    _loadTask = null;
    return _queue(() => _store.delete(SecureAppStore.campusCardSnapshotKey));
  }

  bool _isCurrent(String studentId, int revision) =>
      studentId == _studentId && revision == _revision;

  Future<CampusCardSnapshot?> load() async {
    final studentId = _studentId;
    final revision = _revision;
    if (studentId == null) return null;
    await (_loadTask ??= _load(studentId, revision));
    // Return the current snapshot, not the value captured by the first read.
    return _isCurrent(studentId, revision) ? _snapshot : null;
  }

  Future<void> _load(String studentId, int revision) async {
    try {
      await _writes;
      if (!_isCurrent(studentId, revision)) return;
      final raw = await _store.read(SecureAppStore.campusCardSnapshotKey);
      if (!_isCurrent(studentId, revision)) return;
      if (raw != null) {
        final saved = CampusCardSnapshot.fromJson(
            jsonDecode(raw) as Map<String, dynamic>);
        if (saved.studentId == studentId) {
          // Sections already in memory came from this session's successful
          // queries and take precedence over a late disk read.
          _snapshot = CampusCardSnapshot(
            studentId: studentId,
            balance: _snapshot?.balance ?? saved.balance,
            recent: _snapshot?.recent ?? saved.recent,
            chart: _snapshot?.chart ?? saved.chart,
          );
        }
      }
    } on Object {
      // An unavailable or damaged cache leaves live queries usable.
    }
  }

  Future<void> rememberBalance(CampusCardInfo card, DateTime queriedAt,
      {required int revision}) {
    if (!_isCurrent(card.studentId, revision) || !card.balance.isFinite) {
      return Future.value();
    }
    return _remember(CampusCardSnapshot(
      studentId: card.studentId,
      balance: CampusCardBalanceSnapshot(
          balance: card.balance, queriedAt: queriedAt),
    ));
  }

  Future<void> rememberRecent(CampusCardRecentSnapshot recent,
      {required int revision}) {
    final studentId = _studentId;
    if (studentId == null || revision != _revision) return Future.value();
    return _remember(CampusCardSnapshot(studentId: studentId, recent: recent));
  }

  Future<void> rememberChart(CampusCardChartSnapshot chart,
      {required int revision}) {
    final studentId = _studentId;
    if (studentId == null || revision != _revision) return Future.value();
    return _remember(CampusCardSnapshot(studentId: studentId, chart: chart));
  }

  Future<void> _remember(CampusCardSnapshot update) {
    final next = _snapshot?.merge(update) ?? update;
    if (identical(next, _snapshot)) return Future.value();
    _snapshot = next;
    return _persist(update.studentId, _revision);
  }

  Future<void> _persist(String studentId, int revision) async {
    // Hydrate other sections before persisting an independently completed one.
    await load();
    if (!_isCurrent(studentId, revision)) return;
    await _queue(() async {
      if (!_isCurrent(studentId, revision) ||
          await _accountIdLoader() != studentId) {
        return;
      }
      final snapshot = _snapshot;
      if (snapshot == null || !_isCurrent(studentId, revision)) return;
      await _store.write(
          SecureAppStore.campusCardSnapshotKey, jsonEncode(snapshot.toJson()));
      if (!_isCurrent(studentId, revision) ||
          await _accountIdLoader() != studentId) {
        // Writes and deletion share one queue, including writes finishing
        // after sign-out. A later account's snapshot cannot be deleted here.
        await _store.delete(SecureAppStore.campusCardSnapshotKey);
      }
    });
  }

  Future<void> _queue(Future<void> Function() operation) {
    return _writes = _writes.then((_) async {
      try {
        await operation();
      } on Object {
        // Persistence never turns a successful query into a refresh failure.
      }
    });
  }
}

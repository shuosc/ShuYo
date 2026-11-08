part of 'academic_schedule_repository.dart';

extension AcademicScheduleCollection on AcademicScheduleRepository {
  Future<String?> _dataOwner() async {
    final owner = await AcademicAccountStore(
      preferencesLoader: _preferencesLoader,
    ).loadDataStudentId();
    if (owner != null) return owner;
    final raw = (await _preferencesLoader())
        .getString(AcademicScheduleRepository._scheduleKey);
    if (raw == null) return null;
    try {
      return AcademicSchedule.fromJson(jsonDecode(raw) as Map<String, dynamic>)
          .term
          .studentId;
    } on Object {
      return null;
    }
  }

  AcademicScheduleRecord _recordFor(AcademicSchedule schedule) =>
      AcademicScheduleRecord(
        studentId: schedule.term.studentId,
        yearCode: schedule.term.yearCode,
        termCode: schedule.term.termCode,
        academicYearName: schedule.term.academicYearName,
        termName: schedule.term.termName,
        availability: ScheduleAvailability.available,
      );

  AcademicTermQuery _queryFor(AcademicScheduleRecord record) =>
      AcademicTermQuery(
        yearCode: record.yearCode,
        termCode: record.termCode,
        academicYearName: record.academicYearName,
        termName: record.termName,
      );

  Future<void> _migrateLegacy(
      AcademicSchedule schedule, SharedPreferences prefs) async {
    final term = schedule.term;
    final key = academicTermKey(term.yearCode, term.termCode);
    if (await _collection.load(term.studentId, key) == null) {
      final monday = DateTime.tryParse(
          prefs.getString(AcademicScheduleRepository._anchorMondayKey) ?? '');
      final week = prefs.getInt(AcademicScheduleRepository._anchorWeekKey) ?? 1;
      await _collection.update(
          term.studentId,
          key,
          (existing) async =>
              existing ??
              _recordFor(schedule).copyWith(
                schedule: schedule,
                remoteSchedule: schedule,
                syncedAt: schedule.fetchedAt,
                // Old snapshots may already contain edits; protect them on discovery.
                locallyEdited: true,
                firstWeekStart:
                    monday?.subtract(Duration(days: (week - 1) * 7)),
              ));
    }
    if (await _collection.primaryKey(term.studentId) == null) {
      await _collection.setPrimaryKey(term.studentId, key);
    }
  }

  Future<void> _mirrorPrimary(AcademicScheduleRecord record,
      {bool force = false}) async {
    if (record.schedule == null) return;
    final owner = await _dataOwner();
    if (owner != null && owner != record.studentId) return;
    final prefs = await _preferencesLoader();
    final raw = prefs.getString(AcademicScheduleRepository._scheduleKey);
    var sameTerm = false;
    if (raw != null) {
      try {
        final old =
            AcademicSchedule.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        sameTerm = old.term.studentId == record.studentId &&
            academicTermKey(old.term.yearCode, old.term.termCode) == record.key;
      } on Object {
        // Replace a damaged legacy mirror with the scoped record.
      }
    }
    final encoded = jsonEncode(record.schedule!.toJson());
    if (raw != encoded) {
      await prefs.setString(AcademicScheduleRepository._scheduleKey, encoded);
    }
    if (force || !sameTerm) {
      await prefs.setInt(AcademicScheduleRepository._anchorWeekKey, 1);
      if (record.firstWeekStart != null) {
        await prefs.setString(AcademicScheduleRepository._anchorMondayKey,
            record.firstWeekStart!.toIso8601String());
      } else {
        await prefs.remove(AcademicScheduleRepository._anchorMondayKey);
      }
    }
  }

  Future<List<AcademicScheduleRecord>> loadSavedSchedules() async {
    final legacy = await loadCachedSchedule();
    final owner = await _dataOwner() ?? legacy?.term.studentId;
    return owner == null
        ? <AcademicScheduleRecord>[]
        : await _collection.list(owner);
  }

  Future<String?> loadPrimaryTermKey() async {
    final owner = await _dataOwner();
    return owner == null ? null : _collection.primaryKey(owner);
  }

  Future<AcademicScheduleRecord?> loadTermRecord(String key) async {
    final owner = await _dataOwner();
    return owner == null ? null : _collection.load(owner, key);
  }

  Future<ScheduleWeekState> loadTermWeekState(String key,
      {DateTime? now}) async {
    if (key == await loadPrimaryTermKey()) return loadWeekState(now: now);
    final record = await loadTermRecord(key);
    return ScheduleWeekState(
      currentWeek: 1,
      anchorMonday: record?.firstWeekStart ??
          AcademicScheduleRepository.startOfWeek(now ?? DateTime.now()),
    );
  }

  Future<bool> primaryCalendarConfigured() async {
    final primary = await loadPrimaryTermKey();
    if (primary == null) return true; // Legacy/demo repository compatibility.
    final record = await loadTermRecord(primary);
    return record == null || record.firstWeekStart != null;
  }

  Future<void> _saveCalendar(
      AcademicSchedule schedule, DateTime firstDay) async {
    final key = academicTermKey(schedule.term.yearCode, schedule.term.termCode);
    await _collection.update(
        schedule.term.studentId,
        key,
        (record) async =>
            (record ?? _recordFor(schedule).copyWith(schedule: schedule))
                .copyWith(firstWeekStart: firstDay));
  }

  Future<void> setTermFirstWeekStart(String key, DateTime date) async {
    if (key == await loadPrimaryTermKey()) return setFirstWeekStart(date);
    final record = await loadTermRecord(key);
    if (record?.schedule == null) return;
    await _saveCalendar(
        record!.schedule!, AcademicScheduleRepository.startOfWeek(date));
  }

  Future<void> setPrimaryTerm(String key) async {
    final record = await loadTermRecord(key);
    if (record == null || record.schedule == null) {
      throw const AcademicApiException('该学期尚未保存课表');
    }
    await _collection.setPrimaryKey(record.studentId, key);
    await _mirrorPrimary(record, force: true);
  }

  Future<void> saveWorkingSchedule(AcademicSchedule schedule) async {
    // saveCachedSchedule routes writes to the schedule's scoped term and only
    // mirrors it when that term is primary. Keep its virtual demo/test behavior.
    await saveCachedSchedule(schedule);
  }

  Future<void> _checkAccount(String? studentId, int generation) async {
    final current = await AcademicAccountStore(
      preferencesLoader: _preferencesLoader,
    ).loadStudentId();
    if (current != studentId || generation != _discoveryGeneration) {
      throw const AcademicApiException('账号或应用状态已变化，已停止课表同步');
    }
  }

  Future<AcademicSchedule> _fetchTerm(AcademicTermQuery query) {
    final requestKey = '$_discoveryGeneration:${query.key}';
    final pending = _termRequests[requestKey];
    if (pending != null) return pending;
    final task = _client.fetchScheduleForTerm(query);
    _termRequests[requestKey] = task;
    // Attach both branches so a failed request never creates an unhandled
    // error from an ignored whenComplete future.
    unawaited(task.then<void>((_) {
      _termRequests.remove(requestKey);
    }, onError: (Object _, StackTrace __) {
      _termRequests.remove(requestKey);
    }));
    return task;
  }

  Future<void> _acceptRemote(
    AcademicSchedule schedule, {
    bool replaceWorking = false,
    bool makePrimary = false,
    bool protectConcurrentEdits = false,
    AcademicSchedule? expectedWorking,
  }) async {
    final term = schedule.term;
    final owner = await _dataOwner();
    if (owner != null && owner != term.studentId) {
      throw const AcademicApiException('教务返回的课表与当前账号不匹配');
    }
    final key = academicTermKey(term.yearCode, term.termCode);
    final empty = schedule.sessions.isEmpty && schedule.untimedCourses.isEmpty;
    if (term.admissionYearCode.isNotEmpty) {
      await _collection.setMetadata(
          term.studentId, 'admissionYear', term.admissionYearCode);
    }
    var conflict = false;
    await _collection.update(term.studentId, key, (previous) async {
      final base = previous ?? _recordFor(schedule);
      conflict = protectConcurrentEdits &&
          replaceWorking &&
          jsonEncode(base.schedule?.toJson()) !=
              jsonEncode(expectedWorking?.toJson());
      final applyWorking = replaceWorking && !conflict;
      final replace = !conflict && (applyWorking || !base.locallyEdited);
      return base.copyWith(
        availability:
            empty ? ScheduleAvailability.empty : ScheduleAvailability.available,
        remoteSchedule: schedule,
        // A valid empty response is recorded, not silently applied over a
        // previously saved timetable. Explicit refresh confirms it separately.
        schedule: empty
            ? applyWorking && base.schedule != null
                ? schedule
                : null
            : replace || base.schedule == null
                ? schedule
                : null,
        locallyEdited: conflict || (applyWorking ? false : base.locallyEdited),
        checkedAt: schedule.fetchedAt,
        syncedAt: !empty || applyWorking ? schedule.fetchedAt : null,
        clearError: true,
      );
    });
    final primary = await _collection.primaryKey(term.studentId);
    if (!empty && primary == null && makePrimary) {
      await _collection.setPrimaryKey(term.studentId, key);
    }
    if (await _collection.primaryKey(term.studentId) == key) {
      await _mirrorPrimary((await _collection.load(term.studentId, key))!);
    }
    if (conflict) {
      throw const AcademicApiException('同步期间产生了新的本地修改，已保留本地版本，请再次确认更新');
    }
  }

  Future<AcademicSchedule> refreshTerm(String key,
      {bool replaceEdited = false, bool acceptEmpty = false}) async {
    final record = await loadTermRecord(key);
    if (record == null) throw const AcademicApiException('找不到该学期');
    if (record.locallyEdited && !replaceEdited) {
      throw const AcademicApiException('该学期有本地修改，请确认覆盖后更新');
    }
    final studentId = await AcademicAccountStore(
      preferencesLoader: _preferencesLoader,
    ).loadStudentId();
    if (studentId == null) throw const AcademicAuthException();
    final generation = _discoveryGeneration;
    final schedule = await _fetchTerm(_queryFor(record));
    await _checkAccount(studentId, generation);
    if (schedule.term.studentId != studentId) {
      throw const AcademicApiException('教务返回的课表与当前账号不匹配');
    }
    final empty = schedule.sessions.isEmpty && schedule.untimedCourses.isEmpty;
    await _acceptRemote(schedule,
        replaceWorking: !empty || acceptEmpty,
        makePrimary: false,
        protectConcurrentEdits: true,
        expectedWorking: record.schedule);
    if (empty && !acceptEmpty) throw const AcademicNoScheduleException();
    return schedule;
  }

  Future<void> acceptEmptyTerm(String key) async {
    final record = await loadTermRecord(key);
    final remote = record?.remoteSchedule;
    if (remote == null ||
        remote.sessions.isNotEmpty ||
        remote.untimedCourses.isNotEmpty) {
      throw const AcademicApiException('没有待确认的空课表');
    }
    await _acceptRemote(remote,
        replaceWorking: true,
        protectConcurrentEdits: true,
        expectedWorking: record!.schedule);
  }

  Future<void> _recordDiscoveryFailure(String studentId,
      AcademicTermQuery query, Object error, DateTime now) async {
    await _collection.update(studentId, query.key, (previous) async {
      final base = previous ??
          AcademicScheduleRecord(
            studentId: studentId,
            yearCode: query.yearCode,
            termCode: query.termCode,
            academicYearName: query.academicYearName,
            termName: query.termName,
            availability: ScheduleAvailability.failed,
          );
      return base.copyWith(
        availability: ScheduleAvailability.failed,
        checkedAt: now,
        lastError: error is AcademicApiException ? error.message : '请求失败，请稍后重试',
      );
    });
  }

  void pauseDiscovery() {
    _discoveryPaused = _discoveryTask != null || discoveryState.value.running;
    _discoveryGeneration++;
    final state = discoveryState.value;
    discoveryState.value = ScheduleDiscoveryState(
      checked: state.checked,
      total: state.total,
      saved: state.saved,
      failed: state.failed,
      message: state.running ? '查找已暂停，下次进入后继续' : state.message,
      requiresLogin: state.requiresLogin,
    );
  }

  Future<void> discoverSchedules({
    bool force = false,
    bool fullScan = false,
    bool retryFailuresOnly = false,
    DateTime? now,
  }) {
    final pending = _discoveryTask;
    if (pending != null) {
      if (_discoveryPaused) {
        return pending.then((_) => discoverSchedules(
            force: true,
            fullScan: fullScan,
            retryFailuresOnly: retryFailuresOnly,
            now: now));
      }
      return pending;
    }
    final resume = _discoveryPaused;
    _discoveryPaused = false;
    final task = _discoverSchedules(
        force: force || resume,
        fullScan: fullScan,
        retryFailuresOnly: retryFailuresOnly,
        now: now ?? DateTime.now());
    _discoveryTask = task;
    unawaited(task.then<void>((_) {
      _discoveryTask = null;
    }, onError: (Object _, StackTrace __) {
      _discoveryTask = null;
    }));
    return task;
  }

  Future<void> _discoverSchedules({
    required bool force,
    required bool fullScan,
    required bool retryFailuresOnly,
    required DateTime now,
  }) async {
    if (!supportsTermDiscovery) return;
    final generation = _discoveryGeneration;
    final studentId = await AcademicAccountStore(
      preferencesLoader: _preferencesLoader,
    ).loadStudentId();
    if (studentId == null) {
      discoveryState.value = const ScheduleDiscoveryState(
          requiresLogin: true, message: '请先登录校园账户再查找课表');
      return;
    }
    if (generation != _discoveryGeneration) return;
    if (!force) {
      final last = DateTime.tryParse(
          await _collection.metadata(studentId, 'discoveryAttempt') ?? '');
      final completed = DateTime.tryParse(
          await _collection.metadata(studentId, 'discoveryCompleted') ?? '');
      if (last != null && now.difference(last) < const Duration(minutes: 5)) {
        return;
      }
      if (completed != null &&
          (last == null || !completed.isBefore(last)) &&
          now.difference(completed) < const Duration(hours: 24)) {
        return;
      }
    }
    await _collection.setMetadata(
        studentId, 'discoveryAttempt', now.toIso8601String());
    discoveryState.value =
        const ScheduleDiscoveryState(running: true, message: '正在读取学年和学期选项…');
    var checked = 0;
    var total = 0;
    var failures = 0;
    try {
      await loadCachedSchedule(); // Migrate the old cache before discovery.
      await _checkAccount(studentId, generation);
      final catalog = await _client.fetchTermCatalog();
      await _checkAccount(studentId, generation);
      var admissionYear = int.tryParse(
          await _collection.metadata(studentId, 'admissionYear') ?? '');
      final records = await _collection.list(studentId);
      final byKey = {for (final record in records) record.key: record};
      // The default response supplies NJDM_ID even when its course lists are
      // empty. Fetch it once if migration has not provided an admission year.
      var probedDefault = false;
      if (admissionYear == null && !retryFailuresOnly) {
        probedDefault = true;
        try {
          final schedule = await _fetchTerm(catalog.currentTerm);
          await _checkAccount(studentId, generation);
          await _acceptRemote(schedule, makePrimary: true);
          admissionYear = int.tryParse(schedule.term.admissionYearCode);
        } on AcademicAuthException {
          rethrow;
        } on Object catch (error) {
          await _checkAccount(studentId, generation);
          failures++;
          await _recordDiscoveryFailure(
              studentId, catalog.currentTerm, error, now);
        }
        byKey[catalog.currentTerm.key] =
            (await _collection.load(studentId, catalog.currentTerm.key))!;
      }
      final defaultYear = int.tryParse(catalog.currentTerm.yearCode);
      if (admissionYear != null &&
          (admissionYear < 1900 ||
              (defaultYear != null && admissionYear > defaultYear + 1))) {
        admissionYear = null;
      }
      final terms = catalog.terms.where((query) {
        if (retryFailuresOnly) {
          return byKey[query.key]?.availability == ScheduleAvailability.failed;
        }
        if (fullScan || query.key == catalog.currentTerm.key) return true;
        final year = int.tryParse(query.yearCode);
        // NJDM_ID is a discovery hint, not an ownership assertion. Include one
        // preceding year; complete checks can inspect the whole portal catalog.
        if (year != null && admissionYear != null && year < admissionYear - 1) {
          return false;
        }
        if (year != null && defaultYear != null && year > defaultYear + 1) {
          return false;
        }
        return true;
      }).toList();
      total = terms.length;
      final savedKeys = {
        for (final record in byKey.values)
          if (record.hasSavedSchedule) record.key,
      };
      var consecutiveFailures = 0;
      for (final query in terms) {
        await _checkAccount(studentId, generation);
        final previous = await _collection.load(studentId, query.key);
        var skip = previous?.hasSavedSchedule == true;
        if (previous?.availability == ScheduleAvailability.failed) skip = false;
        if (previous?.availability == ScheduleAvailability.empty &&
            !previous!.hasSavedSchedule) {
          final year = int.tryParse(query.yearCode);
          final recent =
              year != null && defaultYear != null && year >= defaultYear - 1;
          final ttl =
              recent ? const Duration(hours: 24) : const Duration(days: 30);
          skip = !force &&
              previous.checkedAt != null &&
              now.difference(previous.checkedAt!) < ttl;
        }
        if (probedDefault && query.key == catalog.currentTerm.key) skip = true;
        if (!skip) {
          try {
            final schedule = await _fetchTerm(query);
            await _checkAccount(studentId, generation);
            await _acceptRemote(schedule,
                makePrimary: query.key == catalog.currentTerm.key);
            consecutiveFailures = 0;
          } on AcademicAuthException {
            rethrow;
          } on Object catch (error) {
            await _checkAccount(studentId, generation);
            failures++;
            consecutiveFailures++;
            await _recordDiscoveryFailure(studentId, query, error, now);
          }
        }
        checked++;
        final updated = await _collection.load(studentId, query.key);
        if (updated?.hasSavedSchedule == true) savedKeys.add(query.key);
        discoveryState.value = ScheduleDiscoveryState(
          running: consecutiveFailures < 3,
          checked: checked,
          total: total,
          saved: savedKeys.length,
          failed: failures,
          message: consecutiveFailures >= 3 ? '连续多个学期请求失败，查找已暂停，可稍后重试' : null,
        );
        if (consecutiveFailures >= 3) return;
      }
      await _checkAccount(studentId, generation);
      if (failures == 0) {
        await _collection.setMetadata(
            studentId, 'discoveryCompleted', now.toIso8601String());
      }
      final saved = (await _collection.list(studentId))
          .where((record) => record.hasSavedSchedule)
          .length;
      discoveryState.value = ScheduleDiscoveryState(
          checked: checked, total: total, saved: saved, failed: failures);
    } on AcademicAuthException {
      discoveryState.value = ScheduleDiscoveryState(
        checked: checked,
        total: total,
        failed: failures,
        requiresLogin: true,
        message: '教务登录已失效，登录后可继续查找',
      );
    } on Object catch (error) {
      if (generation != _discoveryGeneration) return;
      discoveryState.value = ScheduleDiscoveryState(
        checked: checked,
        total: total,
        failed: failures,
        message: error is AcademicApiException ? error.message : '查找课表失败，可稍后重试',
      );
    }
  }
}

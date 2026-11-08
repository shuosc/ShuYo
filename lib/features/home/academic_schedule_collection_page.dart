import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/academic_schedule_collection.dart';
import '../../data/repositories/academic_schedule_repository.dart';
import '../../data/services/academic_schedule_api_client.dart';
import '../../shared/theme/shuyo_theme.dart';

const scheduleManagerSelection = 'manage-schedules';

class AcademicScheduleTermPicker extends StatefulWidget {
  const AcademicScheduleTermPicker({
    super.key,
    required this.repository,
    required this.viewedKey,
  });

  final AcademicScheduleRepository repository;
  final String? viewedKey;

  @override
  State<AcademicScheduleTermPicker> createState() => _TermPickerState();
}

class _TermPickerState extends State<AcademicScheduleTermPicker> {
  List<AcademicScheduleRecord> _records = const [];
  String? _primary;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.repository.collectionChanges.addListener(_reload);
    unawaited(_load());
  }

  void _reload() => unawaited(_load());

  Future<void> _load() async {
    final records = await widget.repository.loadSavedSchedules();
    final primary = await widget.repository.loadPrimaryTermKey();
    if (!mounted) return;
    setState(() {
      _records = records.where((record) => record.hasSavedSchedule).toList();
      _primary = primary;
      _loading = false;
    });
  }

  @override
  void dispose() {
    widget.repository.collectionChanges.removeListener(_reload);
    super.dispose();
  }

  Widget _yearSection(List<AcademicScheduleRecord> records) {
    final colors = context.shuyoColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          key: ValueKey('schedule-year-${records.first.yearCode}'),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Text(
            '${records.first.academicYearName} 学年',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.textTertiary,
                  fontWeight: FontWeight.w500,
                ),
          ),
        ),
        for (final record in records)
          ListTile(
            key: ValueKey('schedule-term-${record.key}'),
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            title: Text('${record.termName}季学期'),
            trailing: record.key == _primary || widget.viewedKey == record.key
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (record.key == _primary)
                        Text('常用',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: colors.textSecondary)),
                      if (widget.viewedKey == record.key) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.check, size: 18, color: colors.textPrimary),
                      ],
                    ],
                  )
                : null,
            onTap: () => Navigator.of(context).pop(record.key),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
    final years = <String, List<AcademicScheduleRecord>>{};
    for (final record in _records) {
      years.putIfAbsent(record.yearCode, () => []).add(record);
    }
    return SafeArea(
      top: false,
      bottom: false,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .75),
        child: Container(
          key: const ValueKey('schedule-term-picker-sheet'),
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(12, 8, 12, 12 + bottomPadding),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: _loading
                      ? const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      : ListView(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          children: [
                            if (_records.isEmpty)
                              const Padding(
                                padding: EdgeInsets.all(12),
                                child: Text('暂无已保存的课表'),
                              ),
                            for (final entry in years.entries)
                              _yearSection(entry.value),
                          ],
                        ),
                ),
                ValueListenableBuilder<ScheduleDiscoveryState>(
                  valueListenable: widget.repository.discoveryState,
                  builder: (context, state, _) => state.running
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: LinearProgressIndicator(minHeight: 2),
                        )
                      : const SizedBox.shrink(),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('管理课表'),
                  onTap: () =>
                      Navigator.of(context).pop(scheduleManagerSelection),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AcademicScheduleCollectionPage extends StatefulWidget {
  const AcademicScheduleCollectionPage({
    super.key,
    required this.repository,
    required this.onLoginRequired,
    required this.onPrimaryChanged,
  });

  final AcademicScheduleRepository repository;
  final Future<void> Function() onLoginRequired;
  final Future<void> Function() onPrimaryChanged;

  @override
  State<AcademicScheduleCollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends State<AcademicScheduleCollectionPage> {
  List<AcademicScheduleRecord> _records = const [];
  String? _primary;
  final _busy = <String>{};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.repository.collectionChanges.addListener(_reload);
    unawaited(_load());
  }

  void _reload() => unawaited(_load());

  Future<void> _load() async {
    final records = await widget.repository.loadSavedSchedules();
    final primary = await widget.repository.loadPrimaryTermKey();
    if (!mounted) return;
    setState(() {
      _records = records;
      _primary = primary;
      _loading = false;
    });
  }

  @override
  void dispose() {
    widget.repository.collectionChanges.removeListener(_reload);
    super.dispose();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确定')),
          ],
        ),
      ) ??
      false;

  Future<void> _update(AcademicScheduleRecord record) async {
    if (_busy.contains(record.key)) return;
    if (record.locallyEdited &&
        !await _confirm('更新这一学期', '更新将覆盖 ${record.displayName} 的本地修改。')) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy.add(record.key));
    try {
      try {
        await widget.repository.refreshTerm(record.key, replaceEdited: true);
        if (record.key == _primary) await widget.onPrimaryChanged();
        _message('这一学期的课表已更新');
      } on AcademicNoScheduleException {
        if (!mounted) return;
        if (record.hasSavedSchedule &&
            await _confirm('教务返回空课表',
                '教务当前未返回 ${record.displayName} 的课程。是否将这一学期替换为空课表？')) {
          await widget.repository.acceptEmptyTerm(record.key);
          if (record.key == _primary) await widget.onPrimaryChanged();
        } else {
          _message(record.hasSavedSchedule ? '教务暂未返回课程，已保留本地版本' : '该学期暂无课表');
        }
      }
    } on AcademicAuthException {
      await widget.onLoginRequired();
      _message('登录恢复后，请再次更新这一学期');
    } on Object catch (error) {
      _message(error.toString());
    } finally {
      if (mounted) setState(() => _busy.remove(record.key));
      await _load();
    }
  }

  Future<void> _discover({bool full = false, bool failedOnly = false}) async {
    if (full &&
        !await _confirm(
            '完整检查所有学年', '将检查教务提供的全部学年，包含入学前和较远的未来学年。已保存的课表不会被覆盖，检查可能需要较长时间。')) {
      return;
    }
    await widget.repository.discoverSchedules(
        force: true, fullScan: full, retryFailuresOnly: failedOnly);
    if (!mounted) return;
    if (widget.repository.discoveryState.value.requiresLogin) {
      await widget.onLoginRequired();
    }
    await _load();
  }

  Future<void> _action(AcademicScheduleRecord record, String action) async {
    try {
      switch (action) {
        case 'view':
          Navigator.of(context).pop(record.key);
        case 'update':
          await _update(record);
        case 'primary':
          await widget.repository.setPrimaryTerm(record.key);
          await widget.onPrimaryChanged();
          _message(record.firstWeekStart == null
              ? '已设为常用课表，请设置开学日期后启用课程提醒'
              : '已设为常用课表');
      }
    } on Object catch (error) {
      _message(error.toString());
    }
    await _load();
  }

  Widget _recordTile(AcademicScheduleRecord record) {
    final colors = context.shuyoColors;
    final textTheme = Theme.of(context).textTheme;
    final status = switch (record.availability) {
      ScheduleAvailability.failed => '更新失败',
      ScheduleAvailability.empty => '教务暂未返回课程',
      ScheduleAvailability.available => record.locallyEdited ? '有本地修改' : null,
    };
    return ListTile(
      key: ValueKey('managed-schedule-${record.key}'),
      leading: const Icon(Icons.calendar_month_outlined),
      title: Text.rich(
        TextSpan(children: [
          TextSpan(
            text: '${record.termName}季学期',
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          TextSpan(
            text: '  ${record.courseCount} 门课',
            style: textTheme.bodySmall?.copyWith(
              color: colors.textTertiary,
            ),
          ),
        ]),
        style: textTheme.bodyLarge?.copyWith(color: colors.textPrimary),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: status != null || record.syncedAt != null
          ? Text.rich(
              TextSpan(children: [
                if (status != null)
                  TextSpan(
                    text: '$status${record.syncedAt == null ? '' : ' · '}',
                    style: TextStyle(color: colors.textSecondary),
                  ),
                if (record.syncedAt != null)
                  TextSpan(text: '同步于 ${_dateText(record.syncedAt!)}'),
              ]),
              key: ValueKey('managed-schedule-meta-${record.key}'),
              style: textTheme.bodySmall?.copyWith(color: colors.textMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      isThreeLine: false,
      onTap: () => Navigator.of(context).pop(record.key),
      titleAlignment: ListTileTitleAlignment.center,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (record.key == _primary)
            Container(
              key: ValueKey('managed-schedule-primary-${record.key}'),
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: colors.accent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '常用',
                // Preserve the title typography when placed in trailing.
                style: textTheme.bodyLarge?.copyWith(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          if (_busy.contains(record.key))
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            PopupMenuButton<String>(
              tooltip: '管理 ${record.displayName}',
              onSelected: (action) => unawaited(_action(record, action)),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'view', child: Text('查看课表')),
                const PopupMenuItem(value: 'update', child: Text('更新这一学期')),
                if (record.key != _primary)
                  const PopupMenuItem(value: 'primary', child: Text('设为常用')),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final saved = _records.where((r) => r.hasSavedSchedule).toList();
    final failed = _records
        .where((r) => r.availability == ScheduleAvailability.failed)
        .toList();
    String? previousYear;
    final rows = <Widget>[];
    for (final record in saved) {
      if (previousYear != record.yearCode) {
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
          child: Text('${record.academicYearName} 学年',
              style: Theme.of(context).textTheme.titleSmall),
        ));
        previousYear = record.yearCode;
      }
      rows.add(_recordTile(record));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('管理课表'),
        actions: [
          PopupMenuButton<String>(
            tooltip: '更多检查选项',
            onSelected: (_) => unawaited(_discover(full: true)),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'full', child: Text('完整检查所有学年')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text('已保存 ${saved.length} 份课表',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              ValueListenableBuilder<ScheduleDiscoveryState>(
                valueListenable: widget.repository.discoveryState,
                builder: (context, state, _) => Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (state.running) const LinearProgressIndicator(),
                      if (state.running || state.message != null)
                        Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(state.description)),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, children: [
                        FilledButton.tonalIcon(
                          onPressed: state.running ? null : () => _discover(),
                          icon: const Icon(Icons.search),
                          label: const Text('查找其他课表'),
                        ),
                        if (failed.isNotEmpty)
                          TextButton(
                            onPressed: state.running
                                ? null
                                : () => _discover(failedOnly: true),
                            child: Text('重试失败项（${failed.length}）'),
                          ),
                        if (state.running)
                          TextButton(
                            onPressed: widget.repository.pauseDiscovery,
                            child: const Text('暂停'),
                          ),
                      ]),
                    ],
                  ),
                ),
              ),
              const Divider(),
              if (saved.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('尚未发现课表，可点击上方按钮查找。')),
              ...rows,
              if (failed.isNotEmpty) ...[
                const Padding(
                    padding: EdgeInsets.fromLTRB(20, 20, 20, 4),
                    child: Text('检查失败')),
                for (final record in failed)
                  ListTile(
                    title: Text(record.displayName),
                    subtitle: Text(record.lastError ?? '可重试这一学期'),
                    trailing: IconButton(
                      tooltip: '重试 ${record.displayName}',
                      icon: const Icon(Icons.refresh),
                      onPressed: () => _update(record),
                    ),
                  ),
              ],
              const SizedBox(height: 24),
            ]),
    );
  }
}

String _dateText(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')} '
    '${date.hour.toString().padLeft(2, '0')}:'
    '${date.minute.toString().padLeft(2, '0')}';

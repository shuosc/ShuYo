import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/models/academic_schedule.dart';
import '../../data/repositories/academic_schedule_repository.dart';
import '../../data/services/schedule_share_cache.dart';
import '../../data/services/schedule_share_service.dart';
import '../../data/services/student_identity_service.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../settings/student_identity_page.dart';
import 'academic_schedule_page.dart';

class ScheduleSharePage extends StatefulWidget {
  const ScheduleSharePage({
    super.key,
    required this.ownSchedule,
    required this.ownWeekState,
    required this.scheduleRepository,
    required this.identityService,
    this.shareApi,
    this.shareCache,
    this.importStore,
    this.calendarStore,
  });

  final AcademicSchedule? ownSchedule;
  final ScheduleWeekState? ownWeekState;
  final AcademicScheduleRepository scheduleRepository;
  final StudentIdentityService? identityService;
  final ScheduleShareApi? shareApi;
  final ScheduleShareCache? shareCache;
  final ImportedScheduleStore? importStore;
  final TermCalendarStore? calendarStore;

  @override
  State<ScheduleSharePage> createState() => _ScheduleSharePageState();
}

class _ScheduleSharePageState extends State<ScheduleSharePage> {
  late final _api = widget.shareApi ?? ScheduleShareApi();
  late final _cache = widget.shareCache ??
      (widget.identityService == null
          ? null
          : ScheduleShareCache.forIdentity(widget.identityService!));
  late final _store = widget.importStore ?? ImportedScheduleStore.shared;
  late final _calendars = widget.calendarStore ?? TermCalendarStore();
  final _importController = TextEditingController();
  final _importFocus = FocusNode();
  ShareCodeInfo? _code;
  List<ImportedSchedule> _imports = const [];
  bool _generatingMode = true;
  bool _busy = false;
  bool _includeNote = false;
  bool _includeNoteEdited = false;
  int _importsRevision = 0;
  Timer? _codeExpiration;
  String? _pendingRequestId;

  @override
  void initState() {
    super.initState();
    _imports = _store.cachedItems;
    _code = _cache?.code;
    _includeNote = _code?.includeNote ?? false;
    _cache?.addListener(_shareCodeChanged);
    widget.identityService?.addListener(_identityChanged);
    _scheduleCodeExpiration();
    unawaited(_load());
  }

  void _identityChanged() {
    if (!mounted || widget.identityService?.isVerified != false) return;
    setState(() {
      _code = null;
      _pendingRequestId = null;
      _includeNote = false;
      _includeNoteEdited = false;
    });
    _codeExpiration?.cancel();
  }

  void _shareCodeChanged() {
    if (!mounted) return;
    final code = _cache?.code;
    if (_code == code) {
      _scheduleCodeExpiration();
      return;
    }
    setState(() {
      _code = code;
      if (code != null && !_includeNoteEdited) {
        _includeNote = code.includeNote;
      }
    });
    _scheduleCodeExpiration();
  }

  void _scheduleCodeExpiration() {
    _codeExpiration?.cancel();
    final expiresAt = _cache?.validUntil;
    if (expiresAt == null) return;
    _codeExpiration = Timer(expiresAt.difference(DateTime.now()), () {
      _shareCodeChanged();
      final cache = _cache;
      if (cache != null) unawaited(cache.refresh(_api, force: true));
    });
  }

  @override
  void dispose() {
    widget.identityService?.removeListener(_identityChanged);
    _cache?.removeListener(_shareCodeChanged);
    _codeExpiration?.cancel();
    _importFocus.dispose();
    _importController.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    await Future.wait([
      _loadImports(),
      _saveOwnCalendar(),
      if (_cache != null) _cache.refresh(_api, force: force),
    ]);
  }

  Future<void> _loadImports() async {
    final revision = _importsRevision;
    try {
      final imports = await _store.list();
      if (mounted && revision == _importsRevision) {
        setState(() => _imports = imports);
      }
    } on Object {
      // Previously loaded imports remain visible if local reading fails.
    }
  }

  Future<void> _saveOwnCalendar() async {
    final own = widget.ownSchedule;
    final weekState = widget.ownWeekState;
    if (own == null || weekState == null) return;
    try {
      await _calendars.save('${own.term.yearCode}:${own.term.termCode}',
          weekState.firstWeekStart);
    } on Object {
      // Calendar persistence must not delay imports or share-code lookup.
    }
  }

  void _dismissImportFocus() => _importFocus.unfocus();

  void _snack(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
    }
  }

  String _newRequestId() {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(18, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  Future<void> _openIdentity() async {
    _dismissImportFocus();
    final service = widget.identityService;
    if (service == null) return;
    await Navigator.of(context).push<void>(
      shuyoRoute(builder: (_) => StudentIdentityPage(service: service)),
    );
    if (mounted) await _load(force: true);
  }

  Future<void> _generate() async {
    _dismissImportFocus();
    final own = widget.ownSchedule;
    if (own == null) {
      _snack('请先同步课表');
      return;
    }
    if (_busy) return;
    final service = widget.identityService;
    if (service == null || !await service.ensureForProtectedAction()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('请先完成身份验证'),
        action: SnackBarAction(label: '去验证', onPressed: _openIdentity),
      ));
      return;
    }
    if (!mounted) return;
    if (_code != null && _pendingRequestId == null) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('重新生成分享码'),
          content: const Text('旧分享码将失效'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认')),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }
    final session = await service.loadLocalSession();
    if (session == null) {
      _snack('请先完成身份验证');
      return;
    }
    if (own.term.studentId.isEmpty || own.term.studentId != session.studentId) {
      _snack('校园账户已切换，请重新打开课表');
      return;
    }
    setState(() => _busy = true);
    _pendingRequestId ??= _newRequestId();
    try {
      final code = await _api.generate(session.token, own,
          includeNote: _includeNote, requestId: _pendingRequestId!);
      final saved = await _cache!.replace(session, code);
      if (!mounted || !saved) return;
      setState(() {
        _pendingRequestId = null;
      });
      _snack('分享码已生成');
    } on Object catch (error) {
      _snack('生成失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _destroy() async {
    _dismissImportFocus();
    if (_code == null || _busy) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('销毁分享码'),
        content: const Text('销毁后，旧分享码将不可用'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('销毁')),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    StudentIdentitySession? session;
    try {
      session = await widget.identityService?.checkCurrentSession();
    } on Object catch (error) {
      _snack('销毁失败：$error');
      return;
    }
    if (session == null) {
      _snack('请先完成身份验证');
      return;
    }
    setState(() => _busy = true);
    try {
      await _api.destroy(session.token);
      final saved = await _cache!.replace(session, null);
      if (!mounted || !saved) return;
      setState(() {
        _pendingRequestId = null;
      });
      _snack('已销毁');
    } on Object catch (error) {
      _snack('销毁失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openShareMore() async {
    _dismissImportFocus();
    final selected = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
        return SafeArea(
          top: false,
          bottom: false,
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(12, 8, 12, 12 + bottomPadding),
            decoration: BoxDecoration(
              color: context.shuyoColors.surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('销毁分享码'),
                enabled: _code != null && !_busy,
                onTap: _code == null || _busy
                    ? null
                    : () => Navigator.of(context).pop(true),
              ),
            ),
          ),
        );
      },
    );
    if (selected == true && mounted) await _destroy();
  }

  Future<void> _showInfo() async {
    _dismissImportFocus();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('说明'),
        content: const Text('导入他人课表后可计算出两者共同空闲时间，支持多人比较'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _import() async {
    _dismissImportFocus();
    final code = _importController.text.trim();
    if (!RegExp(r'^[A-Za-z0-9]{6}$').hasMatch(code)) {
      _snack('请输入 6 位分享码');
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await _api.resolve(code);
      final item = await _store.save(result);
      if (!mounted) return;
      _importController.clear();
      _importsRevision++;
      setState(() =>
          _imports = [item, ..._imports.where((value) => value.id != item.id)]);
      _snack('已导入');
    } on Object catch (error) {
      _snack('导入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<ScheduleWeekState?> _weekStateFor(ImportedSchedule item) async {
    final own = widget.ownSchedule;
    if (own != null &&
        '${own.term.yearCode}:${own.term.termCode}' == item.termKey &&
        widget.ownWeekState != null) {
      return widget.ownWeekState;
    }
    var monday = await _calendars.load(item.termKey);
    if (monday == null && mounted) {
      final picked = await showDatePicker(
        context: context,
        initialDate: DateTime.now(),
        firstDate: DateTime(2020),
        lastDate: DateTime(2040),
        helpText: '设置该学期开学日期',
      );
      if (picked == null) return null;
      await _calendars.save(item.termKey, picked);
      monday = AcademicScheduleRepository.startOfWeek(picked);
    }
    return monday == null
        ? null
        : ScheduleWeekState(currentWeek: 1, anchorMonday: monday);
  }

  Future<void> _openImported(ImportedSchedule item) async {
    _dismissImportFocus();
    final weekState = await _weekStateFor(item);
    if (!mounted || weekState == null) return;
    final own = widget.ownSchedule;
    final sameTerm = own != null &&
        '${own.term.yearCode}:${own.term.termCode}' == item.termKey;
    await Navigator.of(context).push<void>(shuyoRoute(
      builder: (_) => ImportedSchedulePage(
        schedule:
            item.toSchedule(localWeekCount: sameTerm ? own.maxWeek : null),
        weekState: weekState,
        title: item.name,
        importId: item.id,
        onCompare: () => _openCompare(item, weekState),
      ),
    ));
  }

  Future<void> _openCompare(
      ImportedSchedule item, ScheduleWeekState weekState) async {
    _dismissImportFocus();
    await Navigator.of(context).push<void>(shuyoRoute(
      builder: (_) => ScheduleComparePickerPage(
        subject: item,
        imports: _imports,
        ownSchedule: widget.ownSchedule,
        weekState: weekState,
      ),
    ));
  }

  Future<void> _itemAction(ImportedSchedule item, String action) async {
    _dismissImportFocus();
    if (action == 'rename') {
      var draftName = item.name;
      final name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('重命名'),
          content: TextFormField(
            initialValue: item.name,
            maxLength: 40,
            autofocus: true,
            onChanged: (value) => draftName = value,
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(context, draftName.trim()),
                child: const Text('保存')),
          ],
        ),
      );
      if (name == null || name.isEmpty) return;
      try {
        await _store.rename(item, name);
        if (mounted) {
          _importsRevision++;
          setState(() => _imports = [
                for (final value in _imports)
                  value.id == item.id ? value.copyWith(name: name) : value,
              ]);
        }
      } on Object catch (error) {
        _snack('重命名失败：$error');
      }
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除导入课表'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (approved != true) return;
    await _store.delete(item.id);
    if (mounted) {
      _importsRevision++;
      setState(() =>
          _imports = _imports.where((value) => value.id != item.id).toList());
    }
  }

  Widget _modeSwitch(ShuYoColors colors) {
    const labelStyle = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500);
    double choiceWidth(String label) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final width = painter.width + 24;
      painter.dispose();
      return width;
    }

    final generateWidth = choiceWidth('生成分享码');
    final importWidth = choiceWidth('导入');
    Widget choice(bool mode, String label, double width) => SizedBox(
          key: ValueKey(mode ? 'share-mode-generate' : 'share-mode-import'),
          width: width,
          height: 38,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () {
              _dismissImportFocus();
              setState(() => _generatingMode = mode);
            },
            child: Center(
              child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  style: labelStyle.copyWith(
                    color: _generatingMode == mode
                        ? colors.onAccent
                        : colors.textSecondary,
                  ),
                  child: Text(label)),
            ),
          ),
        );

    return Container(
      key: const ValueKey('share-mode-switch'),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          colors.surfaceAlt.withValues(alpha: 0.88),
          colors.surfaceMuted.withValues(alpha: 0.72),
        ]),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.borderStrong.withValues(alpha: 0.7)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: SizedBox(
          width: generateWidth + importWidth,
          height: 38,
          child: Stack(children: [
            AnimatedPositioned(
              key: const ValueKey('share-mode-selection'),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              left: _generatingMode ? 0 : generateWidth,
              top: 0,
              bottom: 0,
              width: _generatingMode ? generateWidth : importWidth,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.accent,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Row(children: [
              choice(true, '生成分享码', generateWidth),
              choice(false, '导入', importWidth),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _shareControls(ShuYoColors colors) {
    return Container(
      key: const ValueKey('share-controls'),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Row(children: [
          _modeSwitch(colors),
          const Spacer(),
          IgnorePointer(
            ignoring: !_generatingMode,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 160),
              opacity: _generatingMode ? 1 : 0,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('含备注',
                    style:
                        TextStyle(color: colors.textSecondary, fontSize: 13.5)),
                SizedBox(
                  width: 30,
                  height: 40,
                  child: Checkbox(
                    value: _includeNote,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() {
                              _includeNote = value ?? false;
                              _includeNoteEdited = true;
                              _pendingRequestId = null;
                            }),
                  ),
                ),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: 16),
        Container(
          key: const ValueKey('share-code-capsule'),
          height: 56,
          padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
          decoration: BoxDecoration(
            color: colors.surfaceAlt,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: colors.border),
          ),
          child: Stack(children: [
            Positioned.fill(
                child: IgnorePointer(
              ignoring: !_generatingMode,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 160),
                opacity: _generatingMode ? 1 : 0,
                child: Row(children: [
                  Expanded(
                      child: SelectableText(_code?.code ?? '',
                          style: TextStyle(
                              color: colors.textPrimary,
                              fontSize: 17,
                              letterSpacing: 2))),
                  TextButton(
                    onPressed: _busy ? null : _generate,
                    child: Text(_pendingRequestId == null ? '生成' : '重试'),
                  ),
                  IconButton(
                    tooltip: '复制',
                    onPressed: _code == null || _busy
                        ? null
                        : () async {
                            final code = _cache?.code;
                            if (code == null) {
                              _shareCodeChanged();
                              return;
                            }
                            await Clipboard.setData(
                                ClipboardData(text: code.code));
                            _snack('已复制');
                          },
                    icon: const Icon(Icons.copy_outlined),
                  ),
                ]),
              ),
            )),
            Positioned.fill(
                child: IgnorePointer(
              ignoring: _generatingMode,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 160),
                opacity: _generatingMode ? 0 : 1,
                child: Row(children: [
                  Expanded(
                      child: TextField(
                    controller: _importController,
                    focusNode: _importFocus,
                    onTapOutside: (_) => _dismissImportFocus(),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                      LengthLimitingTextInputFormatter(6),
                    ],
                    style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 17,
                        letterSpacing: 1.4),
                    decoration: InputDecoration(
                      hintText: '输入分享码',
                      hintStyle: TextStyle(color: colors.textMuted),
                      isCollapsed: true,
                      contentPadding: EdgeInsets.zero,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                    ),
                  )),
                  TextButton(
                      onPressed: _busy ? null : _import,
                      child: const Text('导入')),
                ]),
              ),
            )),
          ]),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 18,
          child: Align(
            alignment: Alignment.centerLeft,
            child: _generatingMode && _code != null
                ? Text(
                    '有效至 ${_code!.expiresAt.toLocal().year}-'
                    '${_code!.expiresAt.toLocal().month.toString().padLeft(2, '0')}-'
                    '${_code!.expiresAt.toLocal().day.toString().padLeft(2, '0')}',
                    style: TextStyle(color: colors.textMuted, fontSize: 12),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('分享与导入'),
            Transform.translate(
              offset: const Offset(-3, -0.5),
              child: Opacity(
                opacity: 0.65,
                child: IconButton(
                  tooltip: '说明',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(Icons.info_outline, size: 18),
                  onPressed: _showInfo,
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
              tooltip: '更多',
              onPressed: _openShareMore,
              icon: const Icon(Icons.more_horiz)),
          const SizedBox(width: 2),
        ],
      ),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(16),
        children: [
          _shareControls(colors),
          const SizedBox(height: 20),
          for (final item in _imports)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Material(
                color: colors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: colors.border),
                ),
                child: ListTile(
                  title: Text(item.name),
                  onTap: () => _openImported(item),
                  trailing: PopupMenuButton<String>(
                    tooltip: '更多',
                    onOpened: _dismissImportFocus,
                    color: colors.surface,
                    surfaceTintColor: Colors.transparent,
                    onSelected: (action) => _itemAction(item, action),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('重命名')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ScheduleComparePickerPage extends StatefulWidget {
  const ScheduleComparePickerPage({
    super.key,
    required this.subject,
    required this.imports,
    required this.ownSchedule,
    required this.weekState,
  });

  final ImportedSchedule subject;
  final List<ImportedSchedule> imports;
  final AcademicSchedule? ownSchedule;
  final ScheduleWeekState weekState;

  @override
  State<ScheduleComparePickerPage> createState() =>
      _ScheduleComparePickerPageState();
}

class _ScheduleComparePickerPageState extends State<ScheduleComparePickerPage> {
  final Set<String> _selected = {};
  bool get _ownMatches =>
      widget.ownSchedule != null &&
      '${widget.ownSchedule!.term.yearCode}:${widget.ownSchedule!.term.termCode}' ==
          widget.subject.termKey;

  void _compare() {
    if (_selected.isEmpty) return;
    final selected = <AcademicSchedule>[
      widget.subject.toSchedule(
          localWeekCount: _ownMatches ? widget.ownSchedule!.maxWeek : null),
      if (_selected.contains('own') && _ownMatches)
        widget.ownSchedule!.copyWith(
            teachingWeekCount: max(widget.ownSchedule!.maxWeek,
                widget.ownSchedule!.term.termName == '夏' ? 4 : 16)),
      for (final item in widget.imports)
        if (_selected.contains(item.id))
          item.toSchedule(
              localWeekCount: _ownMatches ? widget.ownSchedule!.maxWeek : null),
    ];
    Navigator.of(context).push<void>(shuyoRoute(
      builder: (_) =>
          SharedFreeTimePage(schedules: selected, weekState: widget.weekState),
    ));
  }

  Widget _option(String id, String name,
      {required bool enabled, bool locked = false}) {
    return CheckboxListTile(
      title: Text(name),
      value: locked || _selected.contains(id),
      onChanged: !enabled || locked
          ? null
          : (value) => setState(() {
                if (value == true) {
                  _selected.add(id);
                } else {
                  _selected.remove(id);
                }
              }),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('选择课表')),
        body: ListView(children: [
          _option(widget.subject.id, widget.subject.name,
              enabled: true, locked: true),
          if (widget.ownSchedule != null)
            _option('own', '我的课表', enabled: _ownMatches),
          for (final item in widget.imports)
            if (item.id != widget.subject.id)
              _option(item.id, item.name,
                  enabled: item.termKey == widget.subject.termKey),
        ]),
        bottomNavigationBar: SafeArea(
            child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
              onPressed: _selected.isEmpty ? null : _compare,
              child: const Text('比较')),
        )),
      );
}

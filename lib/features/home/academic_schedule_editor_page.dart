import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/models/academic_schedule.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';

class ScheduleCourseEditorResult {
  const ScheduleCourseEditorResult({
    required this.courseName,
    required this.credit,
    required this.colorValue,
    required this.times,
  });

  final String courseName;
  final String credit;
  final int? colorValue;
  final List<ScheduleCourseTimeDraft> times;
}

class ScheduleCourseTimeDraft {
  const ScheduleCourseTimeDraft({
    required this.weekday,
    required this.startSection,
    required this.endSection,
    required this.weeks,
    required this.campus,
    required this.location,
    required this.teacherName,
    required this.note,
  });

  final int weekday;
  final int startSection;
  final int endSection;
  final List<int> weeks;
  final String campus;
  final String location;
  final String teacherName;
  final String note;
}

class AcademicScheduleEditorPage extends StatefulWidget {
  const AcademicScheduleEditorPage({
    super.key,
    required this.maxWeek,
    required this.initialWeek,
    required this.initialWeekday,
    required this.initialStartSection,
    required this.colorful,
    required this.palette,
    required this.conflictValidator,
    this.initialSessions = const [],
    this.initialColorValue,
  });

  final int maxWeek;
  final int initialWeek;
  final int initialWeekday;
  final int initialStartSection;
  final bool colorful;
  final List<Color> palette;
  final List<String> Function(ScheduleCourseEditorResult result)
      conflictValidator;
  final List<CourseSession> initialSessions;
  final int? initialColorValue;

  @override
  State<AcademicScheduleEditorPage> createState() =>
      _AcademicScheduleEditorPageState();
}

class _AcademicScheduleEditorPageState
    extends State<AcademicScheduleEditorPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _creditController;
  final List<_EditableCourseTime> _times = [];
  int? _colorValue;
  bool _dirty = false;
  bool _saving = false;
  late final String _initialSignature;

  bool get _editing => widget.initialSessions.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final first = widget.initialSessions.firstOrNull;
    _nameController = TextEditingController(text: first?.courseName ?? '');
    _creditController = TextEditingController(text: first?.credit ?? '');
    _colorValue = widget.initialColorValue;
    if (widget.initialSessions.isEmpty) {
      _times.add(
        _EditableCourseTime.empty(
          weekday: widget.initialWeekday,
          section: widget.initialStartSection,
          week: widget.initialWeek,
        ),
      );
    } else {
      _times
          .addAll(widget.initialSessions.map(_EditableCourseTime.fromSession));
    }
    _initialSignature = _signature();
    _nameController.addListener(_syncTextDirty);
    _creditController.addListener(_syncTextDirty);
  }

  @override
  void dispose() {
    _nameController.removeListener(_syncTextDirty);
    _creditController.removeListener(_syncTextDirty);
    _nameController.dispose();
    _creditController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_editing ? '编辑课程' : '添加课程'),
          actions: [
            TextButton(
              onPressed: _saving ? null : _save,
              child: const Text('保存'),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              TextFormField(
                controller: _nameController,
                onTapOutside: (_) =>
                    FocusManager.instance.primaryFocus?.unfocus(),
                decoration: const InputDecoration(
                  labelText: '课程名称',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    (value ?? '').trim().isEmpty ? '请填写课程名称' : null,
              ),
              const SizedBox(height: 12),
              _EditorFieldGroup(
                children: [
                  if (widget.colorful)
                    _EditorValueTile(
                      icon: Icons.palette_outlined,
                      label: '颜色',
                      value: _colorValue == null ? '自动分配' : '已选择',
                      trailing: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: _colorValue == null
                              ? colors.scheduleCourseFill
                              : Color(_colorValue!),
                          shape: BoxShape.circle,
                          border: Border.all(color: colors.border),
                        ),
                      ),
                      onTap: _chooseColor,
                    ),
                  _EditorTextTile(
                    icon: Icons.school_outlined,
                    label: '学分',
                    hint: '选填',
                    controller: _creditController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              for (var index = 0; index < _times.length; index++) ...[
                _TimeEditor(
                  key: ObjectKey(_times[index]),
                  index: index,
                  value: _times[index],
                  maxWeek: widget.maxWeek,
                  canDelete: _times.length > 1,
                  onChanged: _markDirty,
                  onCopy: () => _copyTime(index),
                  onDelete: () => _deleteTime(index),
                ),
                const SizedBox(height: 18),
              ],
              TextButton.icon(
                onPressed: _addTime,
                icon: const Icon(Icons.add),
                label: const Text('添加时段'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _markDirty() {
    final dirty = _signature() != _initialSignature;
    if (_dirty != dirty && mounted) setState(() => _dirty = dirty);
  }

  void _syncTextDirty() {
    _markDirty();
  }

  String _signature() => [
        _nameController.text,
        _creditController.text,
        _colorValue?.toString() ?? '',
        ..._times.map((time) => time.signature),
      ].join('\u{1f}');

  void _addTime() {
    FocusManager.instance.primaryFocus?.unfocus();
    final source = _times.last;
    setState(() {
      _times.add(_EditableCourseTime.empty(
        weekday: source.weekday,
        section: source.startSection,
        week: widget.initialWeek,
      ));
      _dirty = _signature() != _initialSignature;
    });
  }

  void _copyTime(int index) {
    setState(() {
      _times.insert(index + 1, _times[index].copy());
      _dirty = _signature() != _initialSignature;
    });
  }

  void _deleteTime(int index) {
    if (_times.length <= 1) return;
    setState(() {
      _times.removeAt(index);
      _dirty = _signature() != _initialSignature;
    });
  }

  Future<void> _chooseColor() async {
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择颜色'),
        content: SizedBox(
          width: 280,
          child: GridView.count(
            shrinkWrap: true,
            crossAxisCount: 4,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            children: [
              for (final color in widget.palette)
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => Navigator.of(context).pop(color.toARGB32()),
                  child: Container(
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: _colorValue == color.toARGB32()
                          ? Border.all(color: Colors.white, width: 3)
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() {
        _colorValue = selected;
        _dirty = _signature() != _initialSignature;
      });
    }
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('未保存的修改'),
        content: const Text('当前修改尚未保存，确定要返回吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('放弃'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('继续修改'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      setState(() => _dirty = false);
      Navigator.of(context).pop();
    }
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final result = ScheduleCourseEditorResult(
      courseName: _nameController.text.trim(),
      credit: _creditController.text.trim(),
      colorValue: _colorValue,
      times: _times.map((time) => time.toDraft()).toList(),
    );
    final conflicts = widget.conflictValidator(result).toSet().toList();
    if (conflicts.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('存在时段冲突'),
          content: Text('以下时段与已有课程冲突：\n\n${conflicts.join('\n')}'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('返回修改'),
            ),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _saving = true);
    _dirty = false;
    Navigator.of(context).pop(result);
  }
}

class _EditableCourseTime {
  _EditableCourseTime({
    required this.weekday,
    required this.startSection,
    required this.endSection,
    required this.weeks,
    required String campus,
    required String location,
    required String teacherName,
    required String note,
  })  : campusController = TextEditingController(text: campus),
        locationController = TextEditingController(text: location),
        teacherController = TextEditingController(text: teacherName),
        noteController = TextEditingController(text: note);

  factory _EditableCourseTime.empty({
    required int weekday,
    required int section,
    required int week,
  }) =>
      _EditableCourseTime(
        weekday: weekday,
        startSection: section,
        endSection: section,
        weeks: {week},
        campus: '',
        location: '',
        teacherName: '',
        note: '',
      );

  factory _EditableCourseTime.fromSession(CourseSession session) =>
      _EditableCourseTime(
        weekday: session.weekday,
        startSection: session.startSection,
        endSection: session.endSection,
        weeks: session.weeks.toSet(),
        campus: session.campus,
        location: session.location,
        teacherName: session.teacherName,
        note: session.note,
      );

  int weekday;
  int startSection;
  int endSection;
  Set<int> weeks;
  final TextEditingController campusController;
  final TextEditingController locationController;
  final TextEditingController teacherController;
  final TextEditingController noteController;

  String get signature => [
        weekday,
        startSection,
        endSection,
        (weeks.toList()..sort()).join(','),
        campusController.text,
        locationController.text,
        teacherController.text,
        noteController.text,
      ].join('\u{1e}');

  _EditableCourseTime copy() => _EditableCourseTime(
        weekday: weekday,
        startSection: startSection,
        endSection: endSection,
        weeks: {...weeks},
        campus: campusController.text,
        location: locationController.text,
        teacherName: teacherController.text,
        note: noteController.text,
      );

  ScheduleCourseTimeDraft toDraft() => ScheduleCourseTimeDraft(
        weekday: weekday,
        startSection: startSection,
        endSection: endSection,
        weeks: weeks.toList()..sort(),
        campus: campusController.text.trim(),
        location: locationController.text.trim(),
        teacherName: teacherController.text.trim(),
        note: noteController.text.trim(),
      );

  void dispose() {
    campusController.dispose();
    locationController.dispose();
    teacherController.dispose();
    noteController.dispose();
  }
}

class _TimeEditor extends StatefulWidget {
  const _TimeEditor({
    super.key,
    required this.index,
    required this.value,
    required this.maxWeek,
    required this.canDelete,
    required this.onChanged,
    required this.onCopy,
    required this.onDelete,
  });

  final int index;
  final _EditableCourseTime value;
  final int maxWeek;
  final bool canDelete;
  final VoidCallback onChanged;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  @override
  State<_TimeEditor> createState() => _TimeEditorState();
}

class _TimeEditorState extends State<_TimeEditor> {
  late String _lastCampus;
  late String _lastLocation;
  late String _lastTeacher;
  late String _lastNote;

  @override
  void initState() {
    super.initState();
    _lastCampus = widget.value.campusController.text;
    _lastLocation = widget.value.locationController.text;
    _lastTeacher = widget.value.teacherController.text;
    _lastNote = widget.value.noteController.text;
    widget.value.campusController.addListener(_syncTextDirty);
    widget.value.locationController.addListener(_syncTextDirty);
    widget.value.teacherController.addListener(_syncTextDirty);
    widget.value.noteController.addListener(_syncTextDirty);
  }

  @override
  void dispose() {
    widget.value.campusController.removeListener(_syncTextDirty);
    widget.value.locationController.removeListener(_syncTextDirty);
    widget.value.teacherController.removeListener(_syncTextDirty);
    widget.value.noteController.removeListener(_syncTextDirty);
    widget.value.dispose();
    super.dispose();
  }

  void _syncTextDirty() {
    final campus = widget.value.campusController.text;
    final location = widget.value.locationController.text;
    final teacher = widget.value.teacherController.text;
    final note = widget.value.noteController.text;
    if (campus == _lastCampus &&
        location == _lastLocation &&
        teacher == _lastTeacher &&
        note == _lastNote) {
      return;
    }
    _lastCampus = campus;
    _lastLocation = location;
    _lastTeacher = teacher;
    _lastNote = note;
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text(
                  '时段${widget.index + 1}',
                  style: ShuYoTextStyles.theme.titleSmall!.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ),
            _EditorHeaderAction(
              label: '复制',
              onTap: widget.onCopy,
            ),
            const SizedBox(width: 14),
            _EditorHeaderAction(
              label: '删除',
              onTap: widget.canDelete ? widget.onDelete : null,
              color: widget.canDelete ? colors.danger : colors.textMuted,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            color: colors.surfaceAlt,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            children: [
              _EditorValueTile(
                icon: Icons.date_range_outlined,
                label: '周数',
                value: _formatWeeks(widget.value.weeks, widget.maxWeek),
                onTap: _chooseWeeks,
              ),
              _EditorValueTile(
                icon: Icons.schedule_outlined,
                label: '节数',
                value:
                    '${_weekdayName(widget.value.weekday)} 第${widget.value.startSection}-${widget.value.endSection}节',
                onTap: _chooseSections,
              ),
              _EditorTextTile(
                icon: Icons.location_city_outlined,
                label: '校区',
                hint: '选填',
                controller: widget.value.campusController,
              ),
              _EditorTextTile(
                icon: Icons.place_outlined,
                label: '教室',
                hint: '选填',
                controller: widget.value.locationController,
              ),
              _EditorTextTile(
                icon: Icons.person_outline,
                label: '教师',
                hint: '选填',
                controller: widget.value.teacherController,
              ),
              _EditorTextTile(
                icon: Icons.notes_outlined,
                label: '备注',
                hint: '选填',
                controller: widget.value.noteController,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _chooseWeeks() async {
    final selected = {...widget.value.weeks};
    final result = await showModalBottomSheet<Set<int>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  TextButton(
                    onPressed: () => setSheetState(() {
                      if (selected.length == widget.maxWeek) {
                        selected.clear();
                      } else {
                        selected
                          ..clear()
                          ..addAll(List.generate(widget.maxWeek, (i) => i + 1));
                      }
                    }),
                    child: const Text('全选'),
                  ),
                  TextButton(
                    onPressed: () => setSheetState(() {
                      selected
                        ..clear()
                        ..addAll(
                            [for (var i = 1; i <= widget.maxWeek; i += 2) i]);
                    }),
                    child: const Text('单周'),
                  ),
                  TextButton(
                    onPressed: () => setSheetState(() {
                      selected
                        ..clear()
                        ..addAll(
                            [for (var i = 2; i <= widget.maxWeek; i += 2) i]);
                    }),
                    child: const Text('双周'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: selected.isEmpty
                        ? null
                        : () => Navigator.of(context).pop(selected),
                    child: const Text('完成'),
                  ),
                ]),
                GridView.count(
                  shrinkWrap: true,
                  crossAxisCount: 6,
                  children: [
                    for (var week = 1; week <= widget.maxWeek; week++)
                      Center(
                        child: SizedBox.square(
                          dimension: 48,
                          child: Material(
                            color: Colors.transparent,
                            shape: const CircleBorder(),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () => setSheetState(() {
                                selected.contains(week)
                                    ? selected.remove(week)
                                    : selected.add(week);
                              }),
                              child: Center(
                                child: SizedBox.square(
                                  dimension: 40,
                                  child: CircleAvatar(
                                    backgroundColor: selected.contains(week)
                                        ? Theme.of(context).colorScheme.primary
                                        : Colors.transparent,
                                    child: Text(
                                      '$week',
                                      style: TextStyle(
                                        color: selected.contains(week)
                                            ? Theme.of(context)
                                                .colorScheme
                                                .onPrimary
                                            : context.shuyoColors.textPrimary,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (result != null) {
      setState(() => widget.value.weeks = result);
      widget.onChanged();
    }
  }

  Future<void> _chooseSections() async {
    final result = await showModalBottomSheet<List<int>>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (context) => _SectionPickerSheet(
        initialWeekday: widget.value.weekday,
        initialStart: widget.value.startSection,
        initialEnd: widget.value.endSection,
      ),
    );
    if (result != null) {
      setState(() {
        widget.value.weekday = result[0];
        widget.value.startSection = result[1];
        widget.value.endSection = result[2];
      });
      widget.onChanged();
    }
  }
}

class _SectionPickerSheet extends StatefulWidget {
  const _SectionPickerSheet({
    required this.initialWeekday,
    required this.initialStart,
    required this.initialEnd,
  });

  final int initialWeekday;
  final int initialStart;
  final int initialEnd;

  @override
  State<_SectionPickerSheet> createState() => _SectionPickerSheetState();
}

class _SectionPickerSheetState extends State<_SectionPickerSheet> {
  late int _weekday;
  late int _start;
  late int _end;
  late final FixedExtentScrollController _weekdayController;
  late final FixedExtentScrollController _startController;
  late final FixedExtentScrollController _endController;

  @override
  void initState() {
    super.initState();
    _weekday = widget.initialWeekday;
    _start = widget.initialStart;
    _end = widget.initialEnd;
    _weekdayController = FixedExtentScrollController(initialItem: _weekday - 1);
    _startController = FixedExtentScrollController(initialItem: _start - 1);
    _endController = FixedExtentScrollController(initialItem: _end - 1);
  }

  @override
  void dispose() {
    _weekdayController.dispose();
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '选择节数',
                    style: ShuYoTextStyles.sectionTitle(
                      color: context.shuyoColors.textPrimary,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).pop([_weekday, _start, _end]),
                  child: const Text('完成'),
                ),
              ],
            ),
            SizedBox(
              height: 180,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 74,
                      child: Row(
                        children: [
                          const Text('周'),
                          SizedBox(
                            width: 54,
                            child: _picker(
                              controller: _weekdayController,
                              count: 7,
                              text: (index) => _weekdayShortName(index + 1),
                              onChanged: (index) => _weekday = index + 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    _sectionWheel(
                      controller: _startController,
                      onChanged: (index) => _start = index + 1,
                      onScrollEnd: _settleStart,
                    ),
                    const SizedBox(
                      width: 28,
                      child: Center(child: Text('-')),
                    ),
                    _sectionWheel(
                      controller: _endController,
                      onChanged: (index) => _end = index + 1,
                      onScrollEnd: _settleEnd,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionWheel({
    required FixedExtentScrollController controller,
    required ValueChanged<int> onChanged,
    required VoidCallback onScrollEnd,
  }) {
    return SizedBox(
      width: 82,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('第'),
          SizedBox(
            width: 44,
            child: NotificationListener<ScrollEndNotification>(
              onNotification: (_) {
                onScrollEnd();
                return false;
              },
              child: _picker(
                controller: controller,
                count: 12,
                text: (index) => '${index + 1}',
                onChanged: onChanged,
              ),
            ),
          ),
          const Text('节'),
        ],
      ),
    );
  }

  Widget _picker({
    required FixedExtentScrollController controller,
    required int count,
    required String Function(int) text,
    required ValueChanged<int> onChanged,
  }) {
    return CupertinoPicker(
      itemExtent: 42,
      scrollController: controller,
      onSelectedItemChanged: onChanged,
      children: [
        for (var index = 0; index < count; index++)
          Center(child: Text(text(index))),
      ],
    );
  }

  void _settleStart() {
    if (_end >= _start) return;
    _end = _start;
    _endController.animateToItem(
      _end - 1,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _settleEnd() {
    if (_end >= _start) return;
    _start = _end;
    _startController.animateToItem(
      _start - 1,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }
}

class _EditorValueTile extends StatelessWidget {
  const _EditorValueTile(
      {required this.icon,
      required this.label,
      required this.value,
      required this.onTap,
      this.trailing});
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            FocusManager.instance.primaryFocus?.unfocus();
            onTap();
          },
          child: SizedBox(
            height: _editorRowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  _EditorRowLeading(icon: icon, label: label),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: _editorValueStyle(colors.textSecondary),
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    trailing!,
                  ],
                  const SizedBox(width: 5),
                  Icon(Icons.chevron_right, size: 18, color: colors.textMuted),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EditorTextTile extends StatelessWidget {
  const _EditorTextTile(
      {required this.icon,
      required this.label,
      required this.hint,
      required this.controller,
      this.keyboardType});
  final IconData icon;
  final String label;
  final String hint;
  final TextEditingController controller;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    const noBorder = InputBorder.none;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: SizedBox(
        height: _editorRowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              _EditorRowLeading(icon: icon, label: label),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: controller,
                  onTapOutside: (_) =>
                      FocusManager.instance.primaryFocus?.unfocus(),
                  keyboardType: keyboardType,
                  textAlign: TextAlign.end,
                  style: _editorValueStyle(colors.textPrimary),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: _editorValueStyle(colors.textMuted),
                    border: noBorder,
                    enabledBorder: noBorder,
                    focusedBorder: noBorder,
                    disabledBorder: noBorder,
                    errorBorder: noBorder,
                    focusedErrorBorder: noBorder,
                    filled: false,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditorFieldGroup extends StatelessWidget {
  const _EditorFieldGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(children: children),
    );
  }
}

class _EditorRowLeading extends StatelessWidget {
  const _EditorRowLeading({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return SizedBox(
      width: 82,
      child: Row(
        children: [
          Icon(icon, size: 20, color: colors.textTertiary),
          const SizedBox(width: 12),
          Text(
            label,
            style: ShuYoTextStyles.theme.titleSmall!.copyWith(
              color: colors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _EditorHeaderAction extends StatelessWidget {
  const _EditorHeaderAction({
    required this.label,
    required this.onTap,
    this.color,
  });

  final String label;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap == null
            ? null
            : () {
                FocusManager.instance.primaryFocus?.unfocus();
                onTap!();
              },
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          child: Text(
            label,
            style: ShuYoTextStyles.theme.labelLarge!.copyWith(
              color: color ?? colors.accent,
            ),
          ),
        ),
      ),
    );
  }
}

const _editorRowHeight = 48.0;

TextStyle _editorValueStyle(Color color) {
  return ShuYoTextStyles.bodyCompact(
    color: color,
    size: 14.5,
    height: 1.25,
  );
}

String _formatWeeks(Set<int> weeks, int maxWeek) {
  final sorted = weeks.toList()..sort();
  if (sorted.isEmpty) return '必填';
  if (sorted.length == maxWeek && sorted.first == 1 && sorted.last == maxWeek) {
    return '1-$maxWeek周';
  }
  final odd = [for (var i = 1; i <= maxWeek; i += 2) i];
  final even = [for (var i = 2; i <= maxWeek; i += 2) i];
  if (_listEquals(sorted, odd)) return '单周';
  if (_listEquals(sorted, even)) return '双周';
  final ranges = <String>[];
  var start = sorted.first;
  var previous = sorted.first;
  for (final week in sorted.skip(1)) {
    if (week == previous + 1) {
      previous = week;
      continue;
    }
    ranges.add(start == previous ? '$start周' : '$start-$previous周');
    start = previous = week;
  }
  ranges.add(start == previous ? '$start周' : '$start-$previous周');
  final text = ranges.join('，');
  return text.length > 14 ? '点击查看' : text;
}

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _weekdayName(int weekday) => switch (weekday) {
      1 => '周一',
      2 => '周二',
      3 => '周三',
      4 => '周四',
      5 => '周五',
      6 => '周六',
      7 => '周日',
      _ => '',
    };

String _weekdayShortName(int weekday) => switch (weekday) {
      1 => '一',
      2 => '二',
      3 => '三',
      4 => '四',
      5 => '五',
      6 => '六',
      7 => '日',
      _ => '',
    };

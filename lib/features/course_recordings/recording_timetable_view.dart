import 'package:flutter/material.dart';

import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/schedule_week_switcher.dart';
import 'recording_course_title.dart';
import 'recording_lesson_selection.dart';
import 'recording_status_icon.dart';
import 'recording_timetable_data.dart';
import 'recording_timetable_slot.dart';

class RecordingTimetableView extends StatefulWidget {
  const RecordingTimetableView({
    super.key,
    required this.data,
    required this.loading,
    required this.refreshEnabled,
    required this.onRefresh,
    required this.onLessonSelected,
    this.canSelectLesson,
    this.failedCourseCount = 0,
  });

  final RecordingTimetableData data;
  final bool loading;
  final bool refreshEnabled;
  final Future<void> Function() onRefresh;
  final ValueChanged<RecordingTimetableEntry> onLessonSelected;
  final bool Function(RecordingTimetableEntry)? canSelectLesson;
  final int failedCourseCount;

  @override
  State<RecordingTimetableView> createState() => _RecordingTimetableViewState();
}

class _RecordingTimetableViewState extends State<RecordingTimetableView> {
  final _pageStorage = PageStorageBucket();
  late DateTime _selectedDate;
  late DateTime _pageOrigin;
  late PageController _pageController;
  bool _userSelected = false;
  int? _animatedTarget;
  int _selectionRevision = 0;

  int get _week =>
      widget.data.weekFor(_selectedDate).clamp(1, widget.data.maxWeek);

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.data.dateFor(
      widget.data.initialWeek,
      widget.data.initialWeekday,
    );
    _pageOrigin = _weekStart(_selectedDate);
    _pageController = PageController(
      initialPage: _initialPage(),
      keepPage: false,
    );
  }

  @override
  void didUpdateWidget(covariant RecordingTimetableView oldWidget) {
    super.didUpdateWidget(oldWidget);
    var selectedDate = _selectedDate;
    if (!_userSelected) {
      selectedDate = widget.data.dateFor(
        widget.data.initialWeek,
        widget.data.initialWeekday,
      );
    }
    final first = widget.data.firstWeekMonday;
    final last = widget.data.dateFor(widget.data.maxWeek, DateTime.sunday);
    if (selectedDate.isBefore(first)) selectedDate = first;
    if (selectedDate.isAfter(last)) selectedDate = last;
    // A refresh may advance "today" or move the selected date out of the
    // selectable past; never keep a future day selected.
    final latest =
        widget.data.today.isBefore(first) ? first : widget.data.today;
    if (selectedDate.isAfter(latest)) selectedDate = latest;
    final origin = _weekStart(selectedDate);
    final originChanged = !DateUtils.isSameDay(_pageOrigin, origin);
    final selectionChanged = !DateUtils.isSameDay(_selectedDate, selectedDate);
    _selectedDate = selectedDate;
    if (originChanged) {
      _replacePageController(origin);
    } else if (selectionChanged) {
      final controller = _pageController;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            identical(controller, _pageController) &&
            controller.hasClients) {
          _animatedTarget = null;
          controller.jumpToPage(_initialPage());
        }
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  int _pageIndex(DateTime date) => date.weekday - DateTime.monday;

  DateTime _dateAt(int page) =>
      DateTime(_pageOrigin.year, _pageOrigin.month, _pageOrigin.day + page);

  /// Pages from this week's Monday up to the last day that has arrived.
  int _availablePages() {
    var pages = 1;
    for (var index = 0; index < DateTime.daysPerWeek; index++) {
      if (widget.data.dateHasArrived(_dateAt(index))) pages = index + 1;
    }
    return pages;
  }

  int _initialPage() {
    final pages = _availablePages();
    final page = _pageIndex(_selectedDate);
    return page < pages ? page : pages - 1;
  }

  DateTime _weekStart(DateTime date) => DateTime(
      date.year, date.month, date.day + DateTime.monday - date.weekday);

  void _replacePageController(DateTime origin) {
    final previousController = _pageController;
    _pageOrigin = origin;
    _animatedTarget = null;
    _selectionRevision++;
    _pageController = PageController(
      initialPage: _initialPage(),
      keepPage: false,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previousController.dispose();
    });
  }

  void _selectDate(DateTime date) {
    if (!widget.data.dateHasArrived(date)) return;
    _userSelected = true;
    if (DateUtils.isSameDay(date, _selectedDate)) return;
    final origin = _weekStart(date);
    if (!DateUtils.isSameDay(origin, _pageOrigin)) {
      setState(() {
        _selectedDate = date;
        _replacePageController(origin);
      });
      return;
    }
    final page = _pageIndex(date);
    final revision = ++_selectionRevision;
    final controller = _pageController;
    setState(() {
      _selectedDate = date;
      _animatedTarget = page;
    });
    if (MediaQuery.disableAnimationsOf(context)) {
      controller.jumpToPage(page);
      _animatedTarget = null;
    } else {
      controller
          .animateToPage(
        page,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      )
          .whenComplete(() {
        if (mounted &&
            revision == _selectionRevision &&
            identical(controller, _pageController) &&
            _animatedTarget == page) {
          _animatedTarget = null;
        }
      });
    }
  }

  void _selectWeek(int week) {
    if (!widget.data.weekHasArrived(week)) return;
    final target = widget.data.dateFor(week, _selectedDate.weekday);
    _selectDate(target.isAfter(widget.data.today) ? widget.data.today : target);
  }

  void _onPageChanged(int page) {
    if (_animatedTarget != null && _animatedTarget != page) return;
    _animatedTarget = null;
    final date = _dateAt(page);
    if (!widget.data.dateHasArrived(date)) return;
    if (DateUtils.isSameDay(date, _selectedDate)) return;
    setState(() {
      _selectedDate = date;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final week = _week;
    final pageController = _pageController;
    return Column(
      children: [
        ScheduleWeekSwitcher(
          week: week,
          maxWeek: widget.data.maxWeek,
          enableQuickSwitch: false,
          onPrevious: week > 1 ? () => _selectWeek(week - 1) : null,
          onNext:
              week < widget.data.maxWeek && widget.data.weekHasArrived(week + 1)
                  ? () => _selectWeek(week + 1)
                  : null,
          onQuickWeekSelected: _selectWeek,
        ),
        _weekdays(context, week),
        if (widget.failedCourseCount > 0)
          Padding(
            key: const ValueKey('timetable-load-warning'),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
            child: Text(
              '${widget.failedCourseCount} 门课程课次暂未加载，下拉重试',
              textAlign: TextAlign.center,
              style: ShuYoTextStyles.meta(color: colors.textSecondary),
            ),
          ),
        Expanded(
          child: PageStorage(
            bucket: _pageStorage,
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification.metrics.axis == Axis.horizontal) {
                  if (notification is ScrollStartNotification &&
                      notification.dragDetails != null) {
                    _selectionRevision++;
                    _animatedTarget = null;
                    _userSelected = true;
                  } else if (notification is ScrollEndNotification &&
                      _animatedTarget == null &&
                      _pageController.hasClients) {
                    _onPageChanged(_pageController.page!.round());
                  }
                }
                return false;
              },
              child: KeyedSubtree(
                key: ValueKey('timetable-origin-${_dateKey(_pageOrigin)}'),
                child: PageView.builder(
                  key: const ValueKey('timetable-pageview'),
                  controller: pageController,
                  itemCount: _availablePages(),
                  onPageChanged: (page) {
                    if (identical(pageController, _pageController)) {
                      _onPageChanged(page);
                    }
                  },
                  itemBuilder: (context, index) {
                    final date = _dateAt(index);
                    return _TimetableDayPage(
                      key: ValueKey('timetable-page-${_dateKey(date)}'),
                      date: date,
                      entries: widget.data.entriesFor(date),
                      loading: widget.loading,
                      refreshEnabled: widget.refreshEnabled,
                      hasLoadFailures: widget.failedCourseCount > 0,
                      onRefresh: widget.onRefresh,
                      onLessonSelected: widget.onLessonSelected,
                      canSelectLesson: widget.canSelectLesson,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _weekdays(BuildContext context, int week) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.shuyoColors;
    final today = widget.data.today;
    const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.25,
      child: Padding(
        key: const ValueKey('timetable-weekdays'),
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
        child: Row(
          children: [
            for (var weekday = DateTime.monday;
                weekday <= DateTime.sunday;
                weekday++)
              Expanded(
                child: Builder(builder: (context) {
                  final date = widget.data.dateFor(week, weekday);
                  final selected = DateUtils.isSameDay(date, _selectedDate);
                  final isToday = DateUtils.isSameDay(date, today);
                  final arrived = widget.data.dateHasArrived(date);
                  final foreground = selected
                      ? scheme.onPrimary
                      : !arrived
                          ? colors.textMuted
                          : isToday
                              ? scheme.primary
                              : colors.textSecondary;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Semantics(
                      selected: selected,
                      button: arrived,
                      enabled: arrived,
                      onTap: arrived ? () => _selectDate(date) : null,
                      label:
                          '${date.year}年${date.month}月${date.day}日 ${labels[weekday - 1]}${isToday ? '，今天' : ''}${arrived ? '' : '，未到'}',
                      excludeSemantics: true,
                      child: Material(
                        color: selected ? scheme.primary : Colors.transparent,
                        borderRadius: BorderRadius.circular(24),
                        child: InkWell(
                          key: ValueKey('timetable-day-${_dateKey(date)}'),
                          borderRadius: BorderRadius.circular(24),
                          onTap: arrived ? () => _selectDate(date) : null,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                vertical: 9, horizontal: 1),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(labels[weekday - 1],
                                      style: ShuYoTextStyles.meta(
                                          size: 12,
                                          color: foreground,
                                          weight: selected || isToday
                                              ? FontWeight.w600
                                              : FontWeight.w400)),
                                ),
                                const SizedBox(height: 4),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text('${date.month}-${date.day}',
                                      style: ShuYoTextStyles.meta(
                                          size: 11, color: foreground)),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
          ],
        ),
      ),
    );
  }
}

class _TimetableDayPage extends StatelessWidget {
  const _TimetableDayPage({
    super.key,
    required this.date,
    required this.entries,
    required this.loading,
    required this.refreshEnabled,
    required this.hasLoadFailures,
    required this.onRefresh,
    required this.onLessonSelected,
    required this.canSelectLesson,
  });

  final DateTime date;
  final List<RecordingTimetableEntry> entries;
  final bool loading;
  final bool refreshEnabled;
  final bool hasLoadFailures;
  final Future<void> Function() onRefresh;
  final ValueChanged<RecordingTimetableEntry> onLessonSelected;
  final bool Function(RecordingTimetableEntry)? canSelectLesson;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final slots = recordingTimetableSlots(entries);
    return RefreshIndicator(
      notificationPredicate: (notification) =>
          refreshEnabled && defaultScrollNotificationPredicate(notification),
      onRefresh: onRefresh,
      child: CustomScrollView(
        key: PageStorageKey('timetable-list-${_dateKey(date)}'),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (slots.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: loading
                  ? const SizedBox.shrink()
                  : Center(
                      child: Text(
                        hasLoadFailures ? '当天暂无已加载课程' : '当天暂无课程',
                        textAlign: TextAlign.center,
                        style: ShuYoTextStyles.bodyCompact(
                            color: colors.textMuted),
                      ),
                    ),
            )
          else ...[
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            for (var index = 0; index < slots.length; index++)
              _slotGroup(slots[index], last: index == slots.length - 1),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ],
      ),
    );
  }

  Widget _slotGroup(RecordingTimetableSlot slot, {required bool last}) =>
      SliverMainAxisGroup(slivers: [
        SliverCrossAxisGroup(slivers: [
          SliverConstrainedCrossAxis(
            maxExtent: 68,
            sliver: SliverPersistentHeader(
              pinned: true,
              delegate: _TimetableSlotHeader(slot),
            ),
          ),
          SliverCrossAxisExpanded(
            flex: 1,
            sliver: SliverList.builder(
              itemCount: slot.entries.length,
              itemBuilder: (context, index) {
                final entry = slot.entries[index];
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  _TimetableEntryTile(
                    entry: entry,
                    onTap: canSelectLesson?.call(entry) == false
                        ? null
                        : () => onLessonSelected(entry),
                  ),
                  if (!last || index < slot.entries.length - 1)
                    const Divider(indent: 16, endIndent: 16),
                ]);
              },
            ),
          ),
        ]),
      ]);
}

class _TimetableSlotHeader extends SliverPersistentHeaderDelegate {
  _TimetableSlotHeader(this.slot);

  final RecordingTimetableSlot slot;

  @override
  double get minExtent => 68;

  @override
  double get maxExtent => minExtent;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final colors = context.shuyoColors;
    return Semantics(
      header: true,
      label: '${slot.sectionLabel} ${slot.timeLabel}',
      excludeSemantics: true,
      child: ColoredBox(
        key: ValueKey('timetable-slot-${slot.key}'),
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 4, 8),
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.3,
            child: Column(children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(slot.sectionLabel,
                    style: ShuYoTextStyles.meta(
                        color: colors.textPrimary, weight: FontWeight.w600)),
              ),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(slot.timeLabel,
                    style: ShuYoTextStyles.meta(
                        size: 12, color: colors.textSecondary)),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_TimetableSlotHeader oldDelegate) =>
      oldDelegate.slot.sectionLabel != slot.sectionLabel ||
      oldDelegate.slot.timeLabel != slot.timeLabel;
}

class _TimetableEntryTile extends StatelessWidget {
  const _TimetableEntryTile({
    required this.entry,
    required this.onTap,
  });

  final RecordingTimetableEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final primary = Theme.of(context).colorScheme.primary;
    final lesson = entry.lesson;
    final enabled = recordingLessonCanSelect(lesson) && onTap != null;
    final secondary = enabled ? colors.textSecondary : colors.textMuted;
    final classroom = lesson.classroom.trim();
    final section = lesson.sectionLabel.trim();
    final title = RecordingCourseTitle(
      course: entry.course,
      maxNameLines: 2,
      missingTeacherLabel: '教师信息暂未提供',
      description: Text.rich(
        TextSpan(children: [
          if (classroom.isNotEmpty) ...[
            TextSpan(
                text: classroom,
                style: TextStyle(color: enabled ? primary : secondary)),
            const TextSpan(text: ' · '),
          ],
          if (section.isNotEmpty) ...[
            TextSpan(
                text: section,
                style:
                    TextStyle(color: enabled ? colors.textPrimary : secondary)),
            const TextSpan(text: ' · '),
          ],
          TextSpan(
              text: '第 ${entry.number} 集',
              style:
                  TextStyle(color: enabled ? colors.textPrimary : secondary)),
        ]),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: ShuYoTextStyles.meta(color: secondary),
      ),
    );
    return ListTile(
      key: ValueKey(
          'timetable-entry-${entry.course.teachingClassId}-${lesson.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      enabled: enabled,
      leading: RecordingStatusIcon(
          isLive: lesson.isLive,
          isGenerating: recordingLessonIsGenerating(lesson),
          enabled: enabled,
          disabledColor: colors.textMuted),
      title: enabled
          ? title
          : ColorFiltered(
              colorFilter: ColorFilter.mode(colors.textMuted, BlendMode.srcIn),
              child: title,
            ),
      trailing: Icon(Icons.chevron_right,
          color: enabled ? colors.textMuted : Theme.of(context).disabledColor),
      onTap: enabled ? onTap : null,
    );
  }
}

String _dateKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

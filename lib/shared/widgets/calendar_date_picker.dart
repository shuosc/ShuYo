import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:table_calendar/table_calendar.dart';

/// Uses the same platform feedback policy as Flutter's [CalendarDatePicker].
void shuYoDatePickerFeedback(BuildContext context) {
  switch (Theme.of(context).platform) {
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.windows:
      HapticFeedback.vibrate();
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      break;
  }
}

/// A shared calendar for both a single date and a date range.
///
/// The caller owns the selected date or range. Choosing a year only changes the
/// displayed month; a date is selected only when the user chooses a day.
class ShuYoCalendarDatePicker extends StatefulWidget {
  const ShuYoCalendarDatePicker({
    super.key,
    required this.firstDate,
    required this.lastDate,
    required this.focusedDate,
    required this.onDateChanged,
    this.selectedDate,
    this.rangeStart,
    this.rangeEnd,
    this.onDisplayedMonthChanged,
    this.selectableDayPredicate,
  });

  final DateTime firstDate;
  final DateTime lastDate;
  final DateTime focusedDate;
  final ValueChanged<DateTime> onDateChanged;
  final DateTime? selectedDate;
  final DateTime? rangeStart;
  final DateTime? rangeEnd;
  final ValueChanged<DateTime>? onDisplayedMonthChanged;
  final SelectableDayPredicate? selectableDayPredicate;

  @override
  State<ShuYoCalendarDatePicker> createState() =>
      _ShuYoCalendarDatePickerState();
}

class _ShuYoCalendarDatePickerState extends State<ShuYoCalendarDatePicker> {
  late DateTime _focusedDay;
  bool _yearMode = false;
  int _viewGeneration = 0;
  String? _announcement;

  DateTime get _firstDate => DateUtils.dateOnly(widget.firstDate);
  DateTime get _lastDate => DateUtils.dateOnly(widget.lastDate);

  @override
  void initState() {
    super.initState();
    assert(!_lastDate.isBefore(_firstDate));
    _focusedDay = _clamp(widget.focusedDate);
  }

  @override
  void didUpdateWidget(ShuYoCalendarDatePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(!_lastDate.isBefore(_firstDate));
    if (!_sameMonth(oldWidget.focusedDate, widget.focusedDate)) {
      _focusedDay = _clamp(widget.focusedDate);
      _yearMode = false;
      _viewGeneration++;
      _announcement = null;
    } else {
      _focusedDay = _clamp(_focusedDay);
    }
  }

  bool _sameMonth(DateTime left, DateTime right) =>
      left.year == right.year && left.month == right.month;

  DateTime _clamp(DateTime value) {
    final day = DateUtils.dateOnly(value);
    if (day.isBefore(_firstDate)) return _firstDate;
    if (day.isAfter(_lastDate)) return _lastDate;
    return day;
  }

  bool _isSelectable(DateTime value) {
    final day = DateUtils.dateOnly(value);
    return !day.isBefore(_firstDate) &&
        !day.isAfter(_lastDate) &&
        (widget.selectableDayPredicate?.call(day) ?? true);
  }

  void _selectDate(DateTime value) {
    final day = DateUtils.dateOnly(value);
    if (!_isSelectable(day)) return;
    // TableCalendar uses a GestureDetector, so provide the tap feedback that
    // Flutter's date-cell InkResponse normally supplies.
    Feedback.forTap(context);
    shuYoDatePickerFeedback(context);
    final localizations = MaterialLocalizations.of(context);
    setState(() {
      _focusedDay = day;
      _announcement = '${localizations.selectedDateLabel} '
          '${localizations.formatFullDate(day)}';
    });
    widget.onDateChanged(day);
  }

  void _showMonth(DateTime value) {
    if (_yearMode) return;
    final day = _clamp(value);
    final changed = !_sameMonth(day, _focusedDay);
    setState(() {
      _focusedDay = day;
      _announcement = MaterialLocalizations.of(context).formatMonthYear(day);
    });
    if (changed) {
      widget.onDisplayedMonthChanged?.call(DateTime(day.year, day.month));
    }
  }

  void _toggleYearMode() {
    shuYoDatePickerFeedback(context);
    final localizations = MaterialLocalizations.of(context);
    setState(() {
      _yearMode = !_yearMode;
      _viewGeneration++;
      _announcement = _yearMode
          ? localizations.formatYear(_focusedDay)
          : localizations.formatMonthYear(_focusedDay);
    });
  }

  void _selectYear(DateTime value) {
    shuYoDatePickerFeedback(context);
    setState(() {
      _yearMode = false;
      _viewGeneration++;
    });
    _showMonth(DateTime(value.year, _focusedDay.month));
  }

  Widget _fadeTransition(Widget child, Animation<double> animation) =>
      FadeTransition(opacity: animation, child: child);

  Widget _viewLayout(Widget? currentChild, List<Widget> previousChildren) =>
      Stack(
        fit: StackFit.expand,
        children: [
          for (final previous in previousChildren)
            IgnorePointer(
              child: ExcludeSemantics(child: previous),
            ),
          if (currentChild != null) currentChild,
        ],
      );

  String _selectionLabel(MaterialLocalizations localizations) {
    if (widget.selectedDate case final selected?) {
      return '${localizations.selectedDateLabel} '
          '${localizations.formatFullDate(selected)}';
    }
    return [
      if (widget.rangeStart case final start?)
        '${localizations.dateRangeStartLabel} '
            '${localizations.formatFullDate(start)}',
      if (widget.rangeEnd case final end?)
        '${localizations.dateRangeEndLabel} '
            '${localizations.formatFullDate(end)}',
    ].join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pickerTheme = DatePickerTheme.of(context);
    final defaults = DatePickerTheme.defaults(context);
    final localizations = MaterialLocalizations.of(context);
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final scaledText =
        MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 3).scale(14) /
            14;
    final rowHeight = (theme.useMaterial3 && portrait ? 48.0 : 42.0) +
        (scaledText > 1.3 ? (scaledText - 1) * 8 : 0);
    final month = DateTime(_focusedDay.year, _focusedDay.month);
    final firstMonth = DateTime(_firstDate.year, _firstDate.month);
    final lastMonth = DateTime(_lastDate.year, _lastDate.month);
    final headerColor = pickerTheme.subHeaderForegroundColor ??
        defaults.subHeaderForegroundColor;
    final weekdayStyle = pickerTheme.weekdayStyle ?? defaults.weekdayStyle;
    final transitionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    final viewGeneration = _viewGeneration;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      liveRegion: true,
      label: _announcement ?? _selectionLabel(localizations),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(start: 16, end: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      button: true,
                      label: localizations.selectYearSemanticsLabel,
                      child: InkWell(
                        onTap: _toggleYearMode,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            children: [
                              Flexible(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: AlignmentDirectional.centerStart,
                                  child: Text(
                                    localizations.formatMonthYear(_focusedDay),
                                    maxLines: 1,
                                    softWrap: false,
                                    style: (pickerTheme.toggleButtonTextStyle ??
                                            defaults.toggleButtonTextStyle)
                                        ?.copyWith(color: headerColor),
                                  ),
                                ),
                              ),
                              AnimatedSwitcher(
                                duration: transitionDuration,
                                reverseDuration: transitionDuration,
                                switchInCurve: Curves.easeInOut,
                                switchOutCurve: Curves.easeInOut,
                                transitionBuilder: _fadeTransition,
                                child: Icon(
                                  _yearMode
                                      ? Icons.arrow_drop_up
                                      : Icons.arrow_drop_down,
                                  key: ValueKey(_yearMode),
                                  color: headerColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  IgnorePointer(
                    ignoring: _yearMode,
                    child: ExcludeSemantics(
                      excluding: _yearMode,
                      child: AnimatedOpacity(
                        opacity: _yearMode ? 0 : 1,
                        duration: transitionDuration,
                        curve: Curves.easeInOut,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: localizations.previousMonthTooltip,
                              onPressed: month.isAfter(firstMonth)
                                  ? () => _showMonth(
                                        DateTime(month.year, month.month - 1),
                                      )
                                  : null,
                              color: headerColor,
                              icon: const Icon(Icons.chevron_left),
                            ),
                            IconButton(
                              tooltip: localizations.nextMonthTooltip,
                              onPressed: month.isBefore(lastMonth)
                                  ? () => _showMonth(
                                        DateTime(month.year, month.month + 1),
                                      )
                                  : null,
                              color: headerColor,
                              icon: const Icon(Icons.chevron_right),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            height: rowHeight * 7,
            child: AnimatedSwitcher(
              key: const ValueKey('shuyo-calendar-mode-switcher'),
              duration: transitionDuration,
              reverseDuration: transitionDuration,
              switchInCurve: Curves.easeInOut,
              switchOutCurve: Curves.easeInOut,
              transitionBuilder: _fadeTransition,
              layoutBuilder: _viewLayout,
              child: _yearMode
                  ? _InitialYearPickerViewport(
                      key: const ValueKey('shuyo-calendar-year-view'),
                      child: YearPicker(
                        firstDate: _firstDate,
                        lastDate: _lastDate,
                        selectedDate: _focusedDay,
                        onChanged: (value) {
                          if (_yearMode && viewGeneration == _viewGeneration) {
                            _selectYear(value);
                          }
                        },
                      ),
                    )
                  : TableCalendar<void>(
                      key: const ValueKey('shuyo-calendar-day-view'),
                      firstDay: _firstDate,
                      lastDay: _lastDate,
                      focusedDay: _focusedDay,
                      locale: Localizations.localeOf(context).toString(),
                      startingDayOfWeek: StartingDayOfWeek
                          .values[(localizations.firstDayOfWeekIndex + 6) % 7],
                      headerVisible: false,
                      sixWeekMonthsEnforced: true,
                      rowHeight: rowHeight,
                      daysOfWeekHeight: rowHeight,
                      calendarFormat: CalendarFormat.month,
                      availableGestures: AvailableGestures.horizontalSwipe,
                      pageAnimationEnabled:
                          !MediaQuery.disableAnimationsOf(context),
                      pageAnimationDuration:
                          MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 300),
                      rangeSelectionMode: RangeSelectionMode.disabled,
                      rangeStartDay: widget.rangeStart,
                      rangeEndDay: widget.rangeEnd,
                      selectedDayPredicate: (day) =>
                          isSameDay(day, widget.selectedDate),
                      enabledDayPredicate: _isSelectable,
                      onDaySelected: (day, _) {
                        if (!_yearMode && viewGeneration == _viewGeneration) {
                          _selectDate(day);
                        }
                      },
                      onPageChanged: (day) {
                        if (!_yearMode && viewGeneration == _viewGeneration) {
                          _showMonth(day);
                        }
                      },
                      calendarStyle: CalendarStyle(
                        outsideDaysVisible: false,
                        cellMargin: const EdgeInsets.all(4),
                        tablePadding:
                            EdgeInsets.symmetric(horizontal: portrait ? 12 : 8),
                        rangeHighlightColor:
                            pickerTheme.rangeSelectionBackgroundColor ??
                                defaults.rangeSelectionBackgroundColor!,
                      ),
                      calendarBuilders: CalendarBuilders<void>(
                        dowBuilder: (_, day) => ExcludeSemantics(
                          child: Center(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                localizations.narrowWeekdays[day.weekday % 7],
                                maxLines: 1,
                                softWrap: false,
                                style: weekdayStyle,
                              ),
                            ),
                          ),
                        ),
                        defaultBuilder: (_, day, __) => _calendarDay(day),
                        selectedBuilder: (_, day, __) => _calendarDay(day),
                        todayBuilder: (_, day, __) => _calendarDay(day),
                        disabledBuilder: (_, day, __) =>
                            _calendarDay(day, disabled: true),
                        withinRangeBuilder: (_, day, __) => _calendarDay(day),
                        rangeStartBuilder: (_, day, __) => _calendarDay(day),
                        rangeEndBuilder: (_, day, __) => _calendarDay(day),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _calendarDay(DateTime day, {bool disabled = false}) {
    final theme = DatePickerTheme.of(context);
    final defaults = DatePickerTheme.defaults(context);
    final today = isSameDay(day, DateTime.now());
    final selected = isSameDay(day, widget.selectedDate) ||
        isSameDay(day, widget.rangeStart) ||
        isSameDay(day, widget.rangeEnd);
    final states = <WidgetState>{
      if (disabled) WidgetState.disabled,
      if (selected) WidgetState.selected,
    };
    final foreground = today
        ? theme.todayForegroundColor?.resolve(states) ??
            defaults.todayForegroundColor?.resolve(states)
        : theme.dayForegroundColor?.resolve(states) ??
            defaults.dayForegroundColor?.resolve(states);
    final background = today
        ? theme.todayBackgroundColor?.resolve(states) ??
            defaults.todayBackgroundColor?.resolve(states)
        : theme.dayBackgroundColor?.resolve(states) ??
            defaults.dayBackgroundColor?.resolve(states);
    final shape =
        theme.dayShape?.resolve(states) ?? defaults.dayShape!.resolve(states)!;
    return Padding(
      key: ValueKey<DateTime>(DateUtils.dateOnly(day)),
      padding: const EdgeInsets.all(4),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: background,
          shape: today
              ? shape.copyWith(
                  side: (theme.todayBorder ?? defaults.todayBorder!)
                      .copyWith(color: foreground),
                )
              : shape,
        ),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              MaterialLocalizations.of(context).formatDecimal(day.day),
              maxLines: 1,
              softWrap: false,
              style: (theme.dayStyle ?? defaults.dayStyle)
                  ?.copyWith(color: foreground),
            ),
          ),
        ),
      ),
    );
  }
}

/// Prepares the native year grid before exposing its first painted frame.
///
/// Flutter's YearPicker estimates its initial offset without the viewport's
/// scroll bounds. Near the first or last year that estimate can be outside the
/// range, causing a visible spring animation even with reduced motion enabled.
/// This instance belongs to one switcher entry: later user scrolling keeps the
/// platform's normal physics and is never clamped by this listener.
class _InitialYearPickerViewport extends StatefulWidget {
  const _InitialYearPickerViewport({super.key, required this.child});

  final Widget child;

  @override
  State<_InitialYearPickerViewport> createState() =>
      _InitialYearPickerViewportState();
}

class _InitialYearPickerViewportState
    extends State<_InitialYearPickerViewport> {
  bool _ready = false;

  bool _prepareInitialPosition(ScrollMetricsNotification notification) {
    if (_ready || !mounted || notification.depth != 0) return false;
    final notificationContext = notification.context;
    final position = Scrollable.maybeOf(notificationContext)?.position;
    if (position == null || !position.hasContentDimensions) return false;
    final initialOffset = position.pixels
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (position.pixels != initialOffset) position.jumpTo(initialOffset);
    // Metrics arrive after layout. Keep this prepared frame transparent, then
    // reveal the grid together with the next layout at its corrected offset.
    setState(() => _ready = true);
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: _prepareInitialPosition,
        child: IgnorePointer(
          ignoring: !_ready,
          child: ExcludeSemantics(
            excluding: !_ready,
            child: Opacity(
              key: const ValueKey('shuyo-calendar-year-ready-opacity'),
              opacity: _ready ? 1 : 0,
              child: widget.child,
            ),
          ),
        ),
      );
}

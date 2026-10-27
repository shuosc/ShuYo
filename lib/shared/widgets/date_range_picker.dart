import 'package:flutter/material.dart';

import '../shuyo_text_styles.dart';
import '../theme/shuyo_theme.dart';
import 'calendar_date_picker.dart';
import 'date_picker_dialog.dart';

/// Shows a calendar-only date range picker using the project's date picker UI.
Future<DateTimeRange?> showShuYoDateRangePicker({
  required BuildContext context,
  DateTimeRange? initialRange,
  required DateTime firstDate,
  required DateTime lastDate,
  String title = '选择日期范围',
}) {
  final first = DateUtils.dateOnly(firstDate);
  final last = DateUtils.dateOnly(lastDate);
  assert(!last.isBefore(first));
  return showDialog<DateTimeRange>(
    context: context,
    builder: (_) => _DateRangePicker(
      initialRange: initialRange,
      firstDate: first,
      lastDate: last,
      title: title,
    ),
  );
}

class _DateRangePicker extends StatefulWidget {
  const _DateRangePicker({
    this.initialRange,
    required this.firstDate,
    required this.lastDate,
    required this.title,
  });

  final DateTimeRange? initialRange;
  final DateTime firstDate;
  final DateTime lastDate;
  final String title;

  @override
  State<_DateRangePicker> createState() => _DateRangePickerState();
}

class _DateRangePickerState extends State<_DateRangePicker> {
  DateTime? _start;
  DateTime? _end;
  late DateTime _focusedDay;
  bool _selectingEnd = false;
  bool _editingEndpoint = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialRange;
    if (initial != null) {
      _start = _clamp(initial.start);
      _end = _clamp(initial.end);
    }
    _focusedDay = _start ?? widget.lastDate;
  }

  DateTime _clamp(DateTime value) {
    final day = DateUtils.dateOnly(value);
    if (day.isBefore(widget.firstDate)) return widget.firstDate;
    if (day.isAfter(widget.lastDate)) return widget.lastDate;
    return day;
  }

  void _selectDate(DateTime value) {
    final day = DateUtils.dateOnly(value);
    setState(() {
      if (_selectingEnd && _start != null) {
        if (day.isBefore(_start!)) {
          _end = _start;
          _start = day;
        } else {
          _end = day;
        }
        _selectingEnd = false;
      } else {
        _start = day;
        if (!_editingEndpoint || _end == null || _end!.isBefore(day)) {
          _end = null;
        }
        _selectingEnd = true;
      }
      _editingEndpoint = false;
      _focusedDay = day;
    });
  }

  void _activateEndpoint(bool end) {
    if (_selectingEnd == end && _editingEndpoint) return;
    shuYoDatePickerFeedback(context);
    setState(() {
      _selectingEnd = end;
      _editingEndpoint = true;
      _focusedDay = (end ? _end : _start) ?? _focusedDay;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ShuYoDatePickerDialog(
      title: widget.title,
      headerTrailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _endpoint('开始日期', _start, end: false),
          Text('—',
              style:
                  ShuYoTextStyles.meta(color: context.shuyoColors.textMuted)),
          _endpoint('结束日期', _end, end: true),
        ],
      ),
      onConfirm: _start == null || _end == null
          ? null
          : () => Navigator.of(context)
              .pop(DateTimeRange(start: _start!, end: _end!)),
      child: ShuYoCalendarDatePicker(
        firstDate: widget.firstDate,
        lastDate: widget.lastDate,
        focusedDate: _focusedDay,
        rangeStart: _start,
        rangeEnd: _end,
        onDateChanged: _selectDate,
        onDisplayedMonthChanged: (date) => setState(() => _focusedDay = date),
      ),
    );
  }

  Widget _endpoint(String label, DateTime? value, {required bool end}) {
    final colors = context.shuyoColors;
    final selected = _selectingEnd == end;
    final color = selected ? colors.accent : colors.textTertiary;
    final semanticValue = value == null
        ? '未选择'
        : MaterialLocalizations.of(context).formatFullDate(value);
    return Semantics(
      button: true,
      selected: selected,
      label: '$label，$semanticValue',
      onTap: () => _activateEndpoint(end),
      excludeSemantics: true,
      child: TextButton(
        key: ValueKey(end ? 'date-range-end' : 'date-range-start'),
        onPressed: () => _activateEndpoint(end),
        style: TextButton.styleFrom(
          foregroundColor: color,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          minimumSize: const Size(0, 28),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          alignment: AlignmentDirectional.centerEnd,
        ),
        child: Text(
          value == null ? '未选择' : '${value.year}/${value.month}/${value.day}',
          maxLines: 1,
          softWrap: false,
          style: ShuYoTextStyles.meta(color: color)
              .copyWith(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

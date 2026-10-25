import 'package:flutter/material.dart';

import 'calendar_date_picker.dart';
import 'date_picker_dialog.dart';

Future<DateTime?> showShuYoDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  String title = '选择日期',
  SelectableDayPredicate? selectableDayPredicate,
}) {
  final initialDay = DateUtils.dateOnly(initialDate);
  final firstDay = DateUtils.dateOnly(firstDate);
  final lastDay = DateUtils.dateOnly(lastDate);
  assert(!lastDay.isBefore(firstDay));
  assert(!initialDay.isBefore(firstDay) && !initialDay.isAfter(lastDay));
  assert(selectableDayPredicate?.call(initialDay) ?? true);

  return showDialog<DateTime>(
    context: context,
    builder: (context) => _DatePickerDialog(
      initialDate: initialDay,
      firstDate: firstDay,
      lastDate: lastDay,
      title: title,
      selectableDayPredicate: selectableDayPredicate,
    ),
  );
}

class _DatePickerDialog extends StatefulWidget {
  const _DatePickerDialog({
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
    required this.title,
    this.selectableDayPredicate,
  });

  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;
  final String title;
  final SelectableDayPredicate? selectableDayPredicate;

  @override
  State<_DatePickerDialog> createState() => _DatePickerDialogState();
}

class _DatePickerDialogState extends State<_DatePickerDialog> {
  late DateTime _selectedDate = widget.initialDate;
  late DateTime _focusedDate = widget.initialDate;

  @override
  Widget build(BuildContext context) {
    return ShuYoDatePickerDialog(
      title: widget.title,
      onConfirm: () => Navigator.of(context).pop(_selectedDate),
      child: ShuYoCalendarDatePicker(
        firstDate: widget.firstDate,
        lastDate: widget.lastDate,
        focusedDate: _focusedDate,
        selectedDate: _selectedDate,
        selectableDayPredicate: widget.selectableDayPredicate,
        onDateChanged: (date) {
          setState(() {
            _selectedDate = date;
            _focusedDate = date;
          });
        },
        onDisplayedMonthChanged: (date) => _focusedDate = date,
      ),
    );
  }
}

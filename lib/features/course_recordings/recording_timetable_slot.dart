import '../../data/models/course_recording.dart';
import '../../data/repositories/academic_schedule_repository.dart';
import 'recording_timetable_data.dart';

class RecordingTimetableSlot {
  const RecordingTimetableSlot({
    required this.key,
    required this.sectionLabel,
    required this.timeLabel,
    required this.entries,
  });

  final String key;
  final String sectionLabel;
  final String timeLabel;
  final List<RecordingTimetableEntry> entries;
}

final _sectionPattern =
    RegExp(r'^第?\s*(\d{1,2})(?:\s*[-–—~～至]\s*(\d{1,2}))?\s*节(?:课)?$');

List<RecordingTimetableSlot> recordingTimetableSlots(
    List<RecordingTimetableEntry> entries) {
  final slotsByKey = <String, _SlotGroup>{};
  for (final indexedEntry in entries.indexed) {
    final slot = _slotFor(indexedEntry.$2.lesson);
    slotsByKey.putIfAbsent(slot.key, () => slot).entries.add(indexedEntry);
  }
  final slots = slotsByKey.values.toList()
    ..sort((first, second) {
      final byMinute = first.minute.compareTo(second.minute);
      return byMinute == 0 ? first.key.compareTo(second.key) : byMinute;
    });
  return List.unmodifiable([
    for (final slot in slots)
      RecordingTimetableSlot(
        key: slot.key,
        sectionLabel: slot.sectionLabel,
        timeLabel: slot.timeLabel,
        entries: List.unmodifiable((slot.entries..sort(_compareEntries))
            .map((indexedEntry) => indexedEntry.$2)),
      ),
  ]);
}

class _SlotGroup {
  _SlotGroup({
    required this.key,
    required this.sectionLabel,
    required this.timeLabel,
    required this.minute,
  });

  final String key;
  final String sectionLabel;
  final String timeLabel;
  final int minute;
  final entries = <(int, RecordingTimetableEntry)>[];
}

_SlotGroup _slotFor(VodLesson lesson) {
  final schoolTime = _schoolTime(lesson.beginTime);
  var section = _sectionFor(lesson.sectionLabel);
  if (section == null && schoolTime != null) {
    final minute = schoolTime.hour * 60 + schoolTime.minute;
    for (final entry in AcademicScheduleRepository.sectionTimes.entries) {
      final range = entry.value;
      if (minute >= range.$1 * 60 + range.$2 &&
          minute < range.$3 * 60 + range.$4) {
        section = entry.key;
        break;
      }
    }
  }
  if (section != null) {
    final firstSection = (section - 1) ~/ 2 * 2 + 1;
    final range = AcademicScheduleRepository.sectionTimes[firstSection]!;
    return _SlotGroup(
      key: '$firstSection-${firstSection + 1}',
      sectionLabel: '$firstSection-${firstSection + 1}节',
      timeLabel: _timeLabel(range.$1, range.$2),
      minute: range.$1 * 60 + range.$2,
    );
  }
  return _SlotGroup(
    key: schoolTime == null
        ? 'time-unknown'
        : 'time-${schoolTime.hour.toString().padLeft(2, '0')}${schoolTime.minute.toString().padLeft(2, '0')}',
    sectionLabel: '其他时段',
    timeLabel: schoolTime == null
        ? '待定'
        : _timeLabel(schoolTime.hour, schoolTime.minute),
    minute:
        schoolTime == null ? 24 * 60 : schoolTime.hour * 60 + schoolTime.minute,
  );
}

int? _sectionFor(String label) {
  final match = _sectionPattern.firstMatch(label.trim());
  if (match == null) return null;
  final first = int.parse(match[1]!);
  final last = int.parse(match[2] ?? match[1]!);
  return first >= 1 && last >= first && last <= 12 ? first : null;
}

DateTime? _schoolTime(DateTime? date) {
  if (date == null) return null;
  if (date.isUtc) return date.add(const Duration(hours: 8));
  return DateTime.utc(date.year, date.month, date.day, date.hour, date.minute,
      date.second, date.millisecond, date.microsecond);
}

String _timeLabel(int hour, int minute) =>
    '$hour:${minute.toString().padLeft(2, '0')}';

int _compareEntries((int, RecordingTimetableEntry) first,
    (int, RecordingTimetableEntry) second) {
  final firstTime = _schoolTime(first.$2.lesson.beginTime);
  final secondTime = _schoolTime(second.$2.lesson.beginTime);
  if (firstTime == null && secondTime != null) return 1;
  if (secondTime == null && firstTime != null) return -1;
  final byTime = firstTime?.compareTo(secondTime!) ?? 0;
  return byTime == 0 ? first.$1.compareTo(second.$1) : byTime;
}

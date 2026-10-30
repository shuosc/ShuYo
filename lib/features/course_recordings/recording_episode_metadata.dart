import '../../data/models/course_recording.dart';

String recordingEpisodeHeading(VodLesson lesson) {
  final date = lesson.beginTime;
  const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  final week = [
    if (lesson.weekNumber > 0) '第${lesson.weekNumber}周',
    if (date != null) weekdays[date.weekday - 1],
  ].join(' ');
  return [
    if (week.isNotEmpty) week,
    if (lesson.sectionLabel.trim().isNotEmpty) lesson.sectionLabel.trim(),
  ].join(' · ');
}

String recordingEpisodeTime(VodLesson lesson) {
  final begin = lesson.beginTime;
  final end = lesson.endTime;
  String format(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  final sameDay = begin != null &&
      end != null &&
      end.year == begin.year &&
      end.month == begin.month &&
      end.day == begin.day &&
      end.isAfter(begin);
  return begin == null
      ? ''
      : sameDay
          ? '${format(begin)}-${format(end)}'
          : format(begin);
}

String recordingEpisodeDateTime(VodLesson lesson) {
  final date = lesson.beginTime;
  final time = recordingEpisodeTime(lesson);
  return [
    if (date != null)
      '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
    if (time.isNotEmpty) time,
  ].join(' ');
}

String recordingEpisodeDetails(VodLesson lesson) {
  final dateAndTime = recordingEpisodeDateTime(lesson);
  return [
    if (lesson.classroom.trim().isNotEmpty) lesson.classroom.trim(),
    if (dateAndTime.isNotEmpty) dateAndTime,
  ].join(' · ');
}

String recordingFullscreenEpisodeHeading(VodLesson lesson) {
  final heading = recordingEpisodeHeading(lesson);
  final time = recordingEpisodeTime(lesson);
  return [if (heading.isNotEmpty) heading, if (time.isNotEmpty) '($time)']
      .join(' ');
}

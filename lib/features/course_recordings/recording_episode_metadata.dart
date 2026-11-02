import '../../data/models/course_recording.dart';

/// Text that depends only on immutable lesson metadata, shared by the course
/// list and fullscreen panel rather than formatted during each widget build.
class RecordingEpisodeMetadata {
  factory RecordingEpisodeMetadata(VodLesson lesson) =>
      _byLesson[lesson] ??= RecordingEpisodeMetadata._fromLesson(lesson);

  factory RecordingEpisodeMetadata._fromLesson(VodLesson lesson) {
    final heading = _heading(lesson);
    final time = _time(lesson);
    final date = lesson.beginTime;
    final dateAndTime = [
      if (date != null)
        '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
      if (time.isNotEmpty) time,
    ].join(' ');
    final classroom = lesson.classroom.trim();
    return RecordingEpisodeMetadata._(
      heading: heading,
      classroom: classroom,
      time: time,
      dateAndTime: dateAndTime,
      details: [
        if (classroom.isNotEmpty) classroom,
        if (dateAndTime.isNotEmpty) dateAndTime,
      ].join(' · '),
      fullscreenHeading: [
        if (heading.isNotEmpty) heading,
        if (time.isNotEmpty) '($time)',
      ].join(' '),
    );
  }

  const RecordingEpisodeMetadata._({
    required this.heading,
    required this.classroom,
    required this.time,
    required this.dateAndTime,
    required this.details,
    required this.fullscreenHeading,
  });

  // Lesson fields are immutable. Expando keys do not retain old catalogs, and
  // fullscreen/control rebuilds can reuse the same prepared display strings.
  static final _byLesson = Expando<RecordingEpisodeMetadata>();

  final String heading;
  final String classroom;
  final String time;
  final String dateAndTime;
  final String details;
  final String fullscreenHeading;
}

String _heading(VodLesson lesson) {
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

String _time(VodLesson lesson) {
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

String recordingEpisodeHeading(VodLesson lesson) =>
    RecordingEpisodeMetadata(lesson).heading;

String recordingEpisodeTime(VodLesson lesson) =>
    RecordingEpisodeMetadata(lesson).time;

String recordingEpisodeDateTime(VodLesson lesson) =>
    RecordingEpisodeMetadata(lesson).dateAndTime;

String recordingEpisodeDetails(VodLesson lesson) =>
    RecordingEpisodeMetadata(lesson).details;

String recordingFullscreenEpisodeHeading(VodLesson lesson) =>
    RecordingEpisodeMetadata(lesson).fullscreenHeading;

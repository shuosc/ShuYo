import '../../data/models/course_recording.dart';
import 'recording_course_schedule.dart';
import 'recording_episode_metadata.dart';

typedef RecordingEpisodeIdentity = ({int id, bool isLive});
typedef RecordingEpisodeMonthKey = (int, int)?;

/// A catalog revision's presentation data. All sorting, grouping, text and
/// timetable derivation happens once, outside the widgets that render it.
class RecordingEpisodeCatalog {
  factory RecordingEpisodeCatalog({
    required Iterable<VodLesson> lessons,
    required int teachingClassId,
  }) {
    final ordered = <VodLesson>[
      for (final lesson in lessons)
        if ((lesson.isLive || lesson.canPlay) &&
            lesson.teachingClassId == teachingClassId)
          lesson,
    ]..sort((first, second) {
        final time = (second.beginTime?.millisecondsSinceEpoch ?? 0)
            .compareTo(first.beginTime?.millisecondsSinceEpoch ?? 0);
        return time == 0 ? second.id.compareTo(first.id) : time;
      });
    final byRoom = <String, List<VodLesson>>{};
    final byIdentity = <RecordingEpisodeIdentity, VodLesson>{};
    final metadata = <VodLesson, RecordingEpisodeMetadata>{};
    for (final lesson in ordered) {
      byRoom.putIfAbsent(lesson.classroom.trim(), () => []).add(lesson);
      byIdentity
          .putIfAbsent((id: lesson.id, isLive: lesson.isLive), () => lesson);
      metadata[lesson] = RecordingEpisodeMetadata(lesson);
    }
    final classrooms = byRoom.keys.toList()
      ..sort((first, second) => first.isEmpty
          ? 1
          : second.isEmpty
              ? -1
              : first.compareTo(second));
    return RecordingEpisodeCatalog._(
      lessons: List.unmodifiable(ordered),
      classrooms: List.unmodifiable(classrooms),
      byRoom: Map.unmodifiable({
        for (final entry in byRoom.entries)
          entry.key: RecordingClassroomEpisodes._fromLessons(entry.value),
      }),
      byIdentity: Map.unmodifiable(byIdentity),
      metadata: Map.unmodifiable(metadata),
    );
  }

  const RecordingEpisodeCatalog._({
    required this.lessons,
    required this.classrooms,
    required Map<String, RecordingClassroomEpisodes> byRoom,
    required Map<RecordingEpisodeIdentity, VodLesson> byIdentity,
    required Map<VodLesson, RecordingEpisodeMetadata> metadata,
  })  : _byRoom = byRoom,
        _byIdentity = byIdentity,
        _metadata = metadata;

  /// Newest first, including valid recordings with stale platform flags.
  final List<VodLesson> lessons;
  final List<String> classrooms;
  final Map<String, RecordingClassroomEpisodes> _byRoom;
  final Map<RecordingEpisodeIdentity, VodLesson> _byIdentity;
  final Map<VodLesson, RecordingEpisodeMetadata> _metadata;

  VodLesson selectionFor(VodLesson current) =>
      _byIdentity[(id: current.id, isLive: current.isLive)] ?? current;

  String? activeClassroom({String? selected, required VodLesson current}) {
    if (_byRoom.containsKey(selected)) return selected;
    final currentRoom = selectionFor(current).classroom.trim();
    return _byRoom.containsKey(currentRoom)
        ? currentRoom
        : classrooms.firstOrNull;
  }

  RecordingClassroomEpisodes classroom(String? room) =>
      _byRoom[room] ?? RecordingClassroomEpisodes.empty;

  RecordingEpisodeMetadata? metadataFor(VodLesson lesson) => _metadata[lesson];
}

/// Own this alongside the loading controller. A UI update against the same
/// immutable repository catalog must never sort or parse its lessons again.
class RecordingEpisodeCatalogCache {
  List<VodLesson>? _source;
  int? _teachingClassId;
  RecordingEpisodeCatalog? _catalog;

  RecordingEpisodeCatalog resolve({
    required List<VodLesson> lessons,
    required int teachingClassId,
  }) {
    if (identical(_source, lessons) && _teachingClassId == teachingClassId) {
      return _catalog!;
    }
    final catalog = RecordingEpisodeCatalog(
        lessons: lessons, teachingClassId: teachingClassId);
    _source = lessons;
    _teachingClassId = teachingClassId;
    return _catalog = catalog;
  }
}

class RecordingClassroomEpisodes {
  factory RecordingClassroomEpisodes._fromLessons(List<VodLesson> lessons) {
    final newest = List<VodLesson>.unmodifiable(lessons);
    final oldest = List<VodLesson>.unmodifiable(lessons.reversed);
    return RecordingClassroomEpisodes._(
      newestFirst: newest,
      oldestFirst: oldest,
      episodeNumbers: Map.unmodifiable({
        for (var index = 0; index < lessons.length; index++)
          lessons[index].id: lessons.length - index,
      }),
      overviewDays: recordingCourseDays(lessons),
      newestMonths: _months(newest),
      oldestMonths: _months(oldest),
    );
  }

  const RecordingClassroomEpisodes._({
    required this.newestFirst,
    required this.oldestFirst,
    required this.episodeNumbers,
    required this.overviewDays,
    required this.newestMonths,
    required this.oldestMonths,
  });

  static const empty = RecordingClassroomEpisodes._(
    newestFirst: [],
    oldestFirst: [],
    episodeNumbers: {},
    overviewDays: [],
    newestMonths: [],
    oldestMonths: [],
  );

  final List<VodLesson> newestFirst;
  final List<VodLesson> oldestFirst;
  final Map<int, int> episodeNumbers;
  final List<RecordingCourseDay> overviewDays;
  final List<RecordingEpisodeMonth> newestMonths;
  final List<RecordingEpisodeMonth> oldestMonths;

  static List<RecordingEpisodeMonth> _months(List<VodLesson> lessons) {
    final groups = <RecordingEpisodeMonthKey, List<VodLesson>>{};
    for (final lesson in lessons) {
      final date = lesson.beginTime;
      final month = date == null ? null : (date.year, date.month);
      groups.putIfAbsent(month, () => []).add(lesson);
    }
    return List.unmodifiable([
      for (final entry in groups.entries)
        RecordingEpisodeMonth._(
          month: entry.key,
          lessons: List.unmodifiable(entry.value),
          indexByLessonId: Map.unmodifiable({
            for (var index = 0; index < entry.value.length; index++)
              entry.value[index].id: index,
          }),
        ),
    ]);
  }
}

class RecordingEpisodeMonth {
  const RecordingEpisodeMonth._({
    required this.month,
    required this.lessons,
    required this.indexByLessonId,
  });

  final RecordingEpisodeMonthKey month;
  final List<VodLesson> lessons;
  final Map<int, int> indexByLessonId;
}

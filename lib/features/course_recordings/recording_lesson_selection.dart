import '../../data/models/course_recording.dart';

bool recordingLessonIsGenerating(VodLesson lesson) =>
    !lesson.isLive && lesson.isGenerating;

bool recordingLessonCanSelect(VodLesson lesson) =>
    lesson.canPlay && !recordingLessonIsGenerating(lesson);

/// A course's lesson request settled (succeeded or failed) and is not queued.
bool recordingCourseHasCompleteAvailability({
  required bool lessonsLoaded,
  required bool requested,
  required bool pending,
}) =>
    lessonsLoaded && requested && !pending;

/// A course has at least one playable recording or a live lesson that is on
/// air right now.
bool recordingCourseHasPlayable({
  required bool hasPlayableLessons,
  required VodLesson? liveLesson,
}) =>
    hasPlayableLessons ||
    (liveLesson?.isLiveAvailable == true && liveLesson!.id > 0);

/// Shared availability contract for catalog rows, timetable entries and the
/// player.
bool recordingCourseCanOpen({
  required bool lessonsLoaded,
  required bool requested,
  required bool pending,
  required bool hasPlayableLessons,
  required VodLesson? liveLesson,
}) =>
    recordingCourseHasCompleteAvailability(
      lessonsLoaded: lessonsLoaded,
      requested: requested,
      pending: pending,
    ) &&
    recordingCourseHasPlayable(
      hasPlayableLessons: hasPlayableLessons,
      liveLesson: liveLesson,
    );

/// Deterministic default selection for a course: keep the lesson that is
/// already playing, then an available live lesson, then a playable recording,
/// then any selectable lesson.
VodLesson? preferredRecordingLesson(
  Iterable<VodLesson> lessons, {
  int? currentId,
  bool? currentIsLive,
  bool includeLive = true,
}) {
  VodLesson? first(bool Function(VodLesson lesson) test) {
    for (final lesson in lessons) {
      if (lesson.id > 0 && recordingLessonCanSelect(lesson) && test(lesson)) {
        return lesson;
      }
    }
    return null;
  }

  if (currentId != null) {
    for (final lesson in lessons) {
      if (lesson.id == currentId &&
          (currentIsLive == null || lesson.isLive == currentIsLive) &&
          recordingLessonCanSelect(lesson)) {
        return lesson;
      }
    }
  }
  return first((lesson) => lesson.isLiveAvailable) ??
      first((lesson) => !lesson.isLive && lesson.isPlayable) ??
      first((lesson) => includeLive || !lesson.isLive);
}

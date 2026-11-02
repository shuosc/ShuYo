import '../../data/models/course_recording.dart';

bool recordingLessonIsGenerating(VodLesson lesson) =>
    !lesson.isLive && lesson.isGenerating;

bool recordingLessonCanSelect(VodLesson lesson) =>
    lesson.canPlay && !recordingLessonIsGenerating(lesson);

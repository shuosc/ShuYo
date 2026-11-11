import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/models/vod_search_result.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/features/course_recordings/recording_search_controller.dart';

VodCourse _course(int id) =>
    VodCourse(teachingClassId: id, termId: 7, name: '课程 $id');

VodLesson _recording(int id) =>
    VodLesson(id: id, teachingClassId: id, name: '课次 $id', isPlayable: true);

VodLesson _live(int id) => VodLesson(
    id: 100 + id,
    teachingClassId: id,
    name: '直播 $id',
    isPlayable: true,
    isLive: true,
    liveEndTime: DateTime.now().add(const Duration(hours: 1)));

class _Repository extends VodRepository {
  _Repository(this.hits);

  final List<VodSearchResult> hits;
  final preview = <int, Completer<List<VodLesson>>>{};
  final liveChecks = <int, Completer<bool>>{};
  final previewCalls = <int>[];
  final generatingCalls = <int>[];
  final liveCalls = <int>[];
  var searches = 0;

  @override
  Future<List<VodSearchResult>> searchLessons(
      {required int termId, required String keyword}) async {
    searches++;
    return hits;
  }

  @override
  Future<List<VodLesson>> resolveSearchLessons(
      VodCourse course, List<VodLesson> seeds,
      {bool forceRefresh = false,
      List<VodLesson>? previewCatalog,
      required bool Function() isCurrent}) {
    previewCalls.add(course.teachingClassId);
    return (preview[course.teachingClassId] ??= Completer<List<VodLesson>>())
        .future;
  }

  @override
  Future<List<VodLesson>> loadGeneratingLessons(VodCourse course,
      {bool forceRefresh = false}) async {
    generatingCalls.add(course.teachingClassId);
    return const [];
  }

  @override
  Future<bool> verifyLiveSearchLesson(VodCourse course, VodLesson lesson) {
    liveCalls.add(course.teachingClassId);
    return (liveChecks[course.teachingClassId] ??= Completer<bool>()).future;
  }
}

Future<void> _drain() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.value();
  }
}

List<int> _visible(RecordingSearchController controller) =>
    RecordingSearchViewData(controller)
        .courses
        .map((course) => course.teachingClassId)
        .toList();

void main() {
  test('late preview live moves ahead in stable source order', () async {
    final repository = _Repository([
      for (var id = 1; id <= 5; id++)
        VodSearchResult(course: _course(id), lesson: _recording(id)),
    ]);
    final controller = RecordingSearchController(repository, selectedTermId: 7);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);

    final search = controller.search('课程');
    await _drain();
    expect(repository.previewCalls, [1, 2, 3]);
    for (var id = 1; id <= 3; id++) {
      repository.preview[id]!.complete([_recording(id)]);
    }
    await _drain();
    expect(_visible(controller), [1, 2, 3]);
    expect(repository.previewCalls, [1, 2, 3, 4, 5]);

    repository.preview[5]!.complete([_live(5)]);
    await _drain();
    expect(_visible(controller), [5, 1, 2, 3]);
    repository.preview[4]!.complete([_live(4)]);
    await search;
    expect(_visible(controller), [4, 5, 1, 2, 3]);
    expect(controller.availableCourseCount, 5);
    expect(repository.searches, 1);
    expect(repository.previewCalls, [1, 2, 3, 4, 5]);
    expect(repository.generatingCalls, hasLength(5));
    expect(repository.liveCalls, isEmpty);
  });

  test('unverified hints do not rise; validated hints use source order',
      () async {
    final repository = _Repository([
      for (var id = 1; id <= 4; id++)
        VodSearchResult(
            course: _course(id), lesson: id == 1 ? _recording(id) : _live(id)),
    ]);
    final controller = RecordingSearchController(repository, selectedTermId: 7);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);

    final search = controller.search('课程');
    await _drain();
    expect(repository.previewCalls, [2, 3, 4]);
    expect(repository.liveCalls, [2, 3, 4]);
    for (final id in [2, 3, 4]) {
      repository.preview[id]!.complete([]);
    }
    await _drain();
    repository.preview[1]!.complete([_recording(1)]);
    await _drain();
    expect(_visible(controller), [1, 2, 3, 4]);
    expect(controller.availableCourseCount, 1);
    repository.liveChecks[3]!.complete(false);
    repository.liveChecks[4]!.complete(true);
    await _drain();
    expect(_visible(controller), [4, 1, 2, 3]);
    expect(controller.courseLessons[(7, 3)], isEmpty);
    repository.liveChecks[2]!.complete(true);
    await search;
    expect(_visible(controller), [2, 4, 1, 3]);
    expect(controller.availableCourseCount, 3);
    expect(controller.courseLessons[(7, 3)], isEmpty);
    expect(repository.searches, 1);
    expect(repository.previewCalls, [2, 3, 4, 1]);
    expect(repository.generatingCalls, hasLength(4));
    expect(repository.liveCalls, [2, 3, 4]);
  });
}

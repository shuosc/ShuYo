import '../../data/models/course_recording.dart';

/// A revision of fullscreen episode navigation, independent of player ticks.
/// The input sequence is already newest first; its numbers remain stable when
/// the panel order changes, and adjacent playback obeys the classroom filter.
class RecordingEpisodeNavigation {
  RecordingEpisodeNavigation._({
    required List<VodLesson> lessons,
    required List<VodLesson>? episodeLessons,
    required int? selectedLessonId,
    required bool newestFirst,
  }) {
    final all = List<VodLesson>.unmodifiable(lessons);
    final numbered = List<VodLesson>.unmodifiable(episodeLessons ?? all);
    panelLessons = newestFirst
        ? numbered
        : List<VodLesson>.unmodifiable(numbered.reversed);
    final numbers = <int, int>{};
    for (var index = 0; index < numbered.length; index++) {
      numbers.putIfAbsent(numbered[index].id, () => numbered.length - index);
    }
    episodeNumbers = Map.unmodifiable(numbers);
    final panelIndexes = <int, int>{};
    for (var index = 0; index < panelLessons.length; index++) {
      panelIndexes.putIfAbsent(panelLessons[index].id, () => index);
    }
    panelIndexByLessonId = Map.unmodifiable(panelIndexes);
    final selectedIndex =
        all.indexWhere((lesson) => lesson.id == selectedLessonId);
    selectedLesson = selectedIndex < 0 ? null : all[selectedIndex];
    if (selectedIndex < 0) {
      _olderCandidates = const [];
      _newerCandidates = const [];
      return;
    }
    final allowed = episodeLessons == null ? null : numbers.keys.toSet();
    bool included(VodLesson lesson) =>
        allowed == null || allowed.contains(lesson.id);
    _olderCandidates = [
      for (var index = selectedIndex + 1; index < all.length; index++)
        if (included(all[index])) all[index],
    ];
    _newerCandidates = [
      for (var index = selectedIndex - 1; index >= 0; index--)
        if (included(all[index])) all[index],
    ];
  }

  late final List<VodLesson> panelLessons;
  late final Map<int, int> episodeNumbers;
  late final Map<int, int> panelIndexByLessonId;
  late final VodLesson? selectedLesson;
  late final List<VodLesson> _olderCandidates;
  late final List<VodLesson> _newerCandidates;
  int _olderIndex = 0;
  int _newerIndex = 0;

  bool get hasCurrent => selectedLesson != null;

  // Recordings have immutable eligibility. Live eligibility can expire without
  // a new catalog: advance the cursor once when that happens instead of
  // scanning the source catalog again on every playback/UI update.
  VodLesson? get older {
    while (_olderIndex < _olderCandidates.length) {
      final candidate = _olderCandidates[_olderIndex];
      if (candidate.canPlay) return candidate;
      _olderIndex++;
    }
    return null;
  }

  VodLesson? get newer {
    while (_newerIndex < _newerCandidates.length) {
      final candidate = _newerCandidates[_newerIndex];
      if (candidate.canPlay) return candidate;
      _newerIndex++;
    }
    return null;
  }
}

class RecordingEpisodeNavigationCache {
  List<VodLesson>? _lessons;
  List<VodLesson>? _episodeLessons;
  int? _selectedLessonId;
  bool? _newestFirst;
  RecordingEpisodeNavigation? _navigation;

  RecordingEpisodeNavigation resolve({
    required List<VodLesson> lessons,
    required List<VodLesson>? episodeLessons,
    required int? selectedLessonId,
    required bool newestFirst,
  }) {
    if (identical(_lessons, lessons) &&
        identical(_episodeLessons, episodeLessons) &&
        _selectedLessonId == selectedLessonId &&
        _newestFirst == newestFirst) {
      return _navigation!;
    }
    final navigation = RecordingEpisodeNavigation._(
      lessons: lessons,
      episodeLessons: episodeLessons,
      selectedLessonId: selectedLessonId,
      newestFirst: newestFirst,
    );
    _lessons = lessons;
    _episodeLessons = episodeLessons;
    _selectedLessonId = selectedLessonId;
    _newestFirst = newestFirst;
    return _navigation = navigation;
  }
}

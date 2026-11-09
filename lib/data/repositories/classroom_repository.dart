import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/classroom.dart';
import '../models/common.dart';
import '../services/classroom_api_client.dart';

class ClassroomSectionRange {
  const ClassroomSectionRange({
    required this.start,
    required this.end,
  });

  final int start;
  final int end;

  String get label => start == end ? '$start节' : '$start-$end节';

  bool contains(int section) => section >= start && section <= end;

  @override
  bool operator ==(Object other) =>
      other is ClassroomSectionRange &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

class ClassroomAvailabilityQuery {
  const ClassroomAvailabilityQuery({
    required this.building,
    required this.date,
    required this.startSection,
    required this.endSection,
  });

  final ClassroomBuilding building;
  final DateTime date;
  final int startSection;
  final int endSection;
}

class ClassroomRepository {
  ClassroomRepository({
    ClassroomApiClient? apiClient,
    Future<SharedPreferences> Function()? preferencesLoader,
    this.optionsCacheDuration = const Duration(days: 7),
    this.scheduleCacheDuration = const Duration(minutes: 10),
  })  : _apiClient = apiClient,
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const _optionsCacheKey = 'classroom.options.cache';
  static const _optionsLastRefreshKey = 'classroom.options.lastRefreshAt';

  ClassroomApiClient? _apiClient;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final Duration optionsCacheDuration;
  final Duration scheduleCacheDuration;

  ClassroomSearchOptions? _memoryOptions;
  final _scheduleCache = <String, _CachedClassroomSchedule>{};

  /// The options already held in memory from an earlier [loadOptions].
  ///
  /// A page opened right after a previous visit can paint them on its first
  /// frame instead of flashing the loading state while [loadOptions] resolves
  /// from the same entry.
  ClassroomSearchOptions? get optionsSnapshot => _memoryOptions;

  ClassroomApiClient get _client => _apiClient ??= ClassroomApiClient();

  Future<ClassroomSearchOptions> loadOptions({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _memoryOptions != null) {
      return _memoryOptions!;
    }
    final cached = await _loadCachedOptions();
    if (!forceRefresh && cached != null && !await _optionsCacheExpired()) {
      _memoryOptions = cached;
      return cached;
    }
    try {
      final options = await _client.fetchSearchOptions();
      await _saveOptions(options);
      return options;
    } on Object {
      if (cached != null) {
        _memoryOptions = cached;
        return cached;
      }
      rethrow;
    }
  }

  Future<ClassroomAvailabilityResult> search(
    ClassroomAvailabilityQuery query, {
    bool forceRefresh = false,
  }) async {
    final schedule = await _loadBuildingSchedule(
      building: query.building,
      date: query.date,
      forceRefresh: forceRefresh,
    );
    final floors = schedule.floors.map((floor) {
      final available = floor.rooms
          .where((room) => room.isFreeFor(query.startSection, query.endSection))
          .toList(growable: false);
      return ClassroomFloorAvailability(
        floor: floor,
        rooms: floor.rooms,
        availableRooms: available,
      );
    }).toList(growable: false);
    return ClassroomAvailabilityResult(
      building: query.building,
      date: query.date,
      startSection: query.startSection,
      endSection: query.endSection,
      floors: floors,
    );
  }

  Future<ClassroomBuildingSchedule> _loadBuildingSchedule({
    required ClassroomBuilding building,
    required DateTime date,
    bool forceRefresh = false,
  }) async {
    final key = '${building.id}:${date.year}-${date.month}-${date.day}';
    final cached = _scheduleCache[key];
    if (!forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.createdAt) < scheduleCacheDuration) {
      return cached.schedule;
    }
    final schedule = await _client.fetchBuildingSchedule(
      building: building,
      date: date,
    );
    _scheduleCache[key] = _CachedClassroomSchedule(
      schedule: schedule,
      createdAt: DateTime.now(),
    );
    return schedule;
  }

  /// Reads one building's whole-day timetable.
  ///
  /// Unlike [search] this keeps every course of the day, which is what the
  /// room timetable and the keyword search need.
  Future<ClassroomBuildingSchedule> loadBuildingDay({
    required ClassroomBuilding building,
    required DateTime date,
    bool forceRefresh = false,
  }) =>
      _loadBuildingSchedule(
        building: building,
        date: date,
        forceRefresh: forceRefresh,
      );

  /// Reads several buildings for the same day with a small request window.
  ///
  /// Buildings share one HTTP connection pool, so running all of them at once
  /// only queues the requests while making cancellation and progress harder.
  /// Three in flight keeps the first rows arriving almost immediately.
  Future<List<ClassroomBuildingSchedule>> loadBuildingDays({
    required List<ClassroomBuilding> buildings,
    required DateTime date,
    bool forceRefresh = false,
    int concurrency = 3,
    void Function(int completed, int total)? onProgress,
    void Function(ClassroomBuildingSchedule schedule)? onLoaded,
    bool Function()? isCancelled,
  }) async {
    final results = <ClassroomBuildingSchedule>[];
    var next = 0;
    var completed = 0;
    final total = buildings.length;
    final limit = concurrency < 1 ? 1 : concurrency;
    onProgress?.call(completed, total);

    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() ?? false) {
          return;
        }
        final index = next++;
        if (index >= total) {
          return;
        }
        final schedule = await loadBuildingDay(
          building: buildings[index],
          date: date,
          forceRefresh: forceRefresh,
        );
        if (isCancelled?.call() ?? false) {
          return;
        }
        results.add(schedule);
        completed++;
        onLoaded?.call(schedule);
        onProgress?.call(completed, total);
      }
    }

    await Future.wait([
      for (var i = 0; i < limit && i < total; i++) worker(),
    ]);
    return results;
  }

  /// The section range a course starting at [section] belongs to.
  ClassroomSectionRange? rangeForSection(
    int section,
    List<ClassroomSectionRange> ranges,
  ) {
    for (final range in ranges) {
      if (range.contains(section)) {
        return range;
      }
    }
    return null;
  }

  List<ClassroomSectionRange> defaultRanges(List<ClassroomSection> sections) {
    final maxSection = sections.isEmpty
        ? 12
        : sections.map((section) => section.index).reduce(
              (a, b) => a > b ? a : b,
            );
    final ranges = <ClassroomSectionRange>[];
    for (var start = 1; start <= maxSection; start += 2) {
      final end = start + 1 <= maxSection ? start + 1 : start;
      ranges.add(ClassroomSectionRange(start: start, end: end));
    }
    return ranges;
  }

  ClassroomSectionRange defaultRangeFor(
    ClassroomSearchOptions options, {
    DateTime? now,
  }) {
    final ranges = defaultRanges(options.sections);
    if (ranges.isEmpty) {
      return const ClassroomSectionRange(start: 1, end: 2);
    }
    final section = _sectionFromTime(options.sections, now ?? DateTime.now());
    if (section != null) {
      return ranges.firstWhere(
        (range) => range.contains(section.index),
        orElse: () => ranges.first,
      );
    }
    return ranges.firstWhere(
      (range) => range.start == 3 && range.end == 4,
      orElse: () => ranges.first,
    );
  }

  DateTime defaultDateFor(
    ClassroomSearchOptions options, {
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    final minutes = current.hour * 60 + current.minute;
    final endMinutes = options.sections
        .map((section) => _minutes(section.endTime))
        .whereType<int>()
        .fold<int?>(null, (latest, value) {
      if (latest == null || value > latest) {
        return value;
      }
      return latest;
    });
    if (endMinutes != null && minutes > endMinutes) {
      return DateTime(current.year, current.month, current.day + 1);
    }
    return DateTime(current.year, current.month, current.day);
  }

  Future<ClassroomSearchOptions?> _loadCachedOptions() async {
    final prefs = await _preferencesLoader();
    final raw = prefs.getString(_optionsCacheKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! JsonMap) {
      return null;
    }
    final options = ClassroomSearchOptions.fromJson(decoded);
    if (options.buildings.isEmpty || options.sections.isEmpty) {
      return null;
    }
    return options;
  }

  Future<bool> _optionsCacheExpired() async {
    final prefs = await _preferencesLoader();
    final raw = prefs.getString(_optionsLastRefreshKey);
    final lastRefresh = raw == null ? null : DateTime.tryParse(raw);
    if (lastRefresh == null) {
      return true;
    }
    return DateTime.now().difference(lastRefresh) >= optionsCacheDuration;
  }

  Future<void> _saveOptions(ClassroomSearchOptions options) async {
    _memoryOptions = options;
    final prefs = await _preferencesLoader();
    await prefs.setString(_optionsCacheKey, jsonEncode(options.toJson()));
    await prefs.setString(
      _optionsLastRefreshKey,
      DateTime.now().toIso8601String(),
    );
  }

  ClassroomSection? _sectionFromTime(
    List<ClassroomSection> sections,
    DateTime now,
  ) {
    final minutes = now.hour * 60 + now.minute;
    for (final section in sections) {
      final start = _minutes(section.startTime);
      final end = _minutes(section.endTime);
      if (start == null || end == null) {
        continue;
      }
      if (minutes >= start && minutes <= end) {
        return section;
      }
    }
    for (final section in sections) {
      final start = _minutes(section.startTime);
      if (start != null && minutes < start) {
        return section;
      }
    }
    return null;
  }

  int? _minutes(String time) {
    final parts = time.split(':');
    if (parts.length != 2) {
      return null;
    }
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) {
      return null;
    }
    return hour * 60 + minute;
  }
}

class _CachedClassroomSchedule {
  const _CachedClassroomSchedule({
    required this.schedule,
    required this.createdAt,
  });

  final ClassroomBuildingSchedule schedule;
  final DateTime createdAt;
}

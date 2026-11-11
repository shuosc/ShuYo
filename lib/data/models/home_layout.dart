enum HomeModule {
  todayCourse('today_course', '今日课程', 'overview'),
  campusCard('campus_card', '校园卡', 'overview'),
  announcements('announcements', '通知公告', 'overview'),
  emptyClassroom('empty_classroom', '空教室', 'overview'),
  courseRecordings('course_recordings', '课程录播', 'overview'),
  libraryBooking('library_booking', '图书馆预约', 'overview'),
  campusMap('campus_map', '校园地图', 'overview'),
  otp('otp', '动态口令', 'services');

  const HomeModule(this.id, this.title, this.defaultGroupId);

  final String id;
  final String title;
  final String defaultGroupId;

  static HomeModule? byId(Object? id) {
    for (final module in values) {
      if (module.id == id) return module;
    }
    return null;
  }
}

class HomeLayoutEntry {
  const HomeLayoutEntry.module(HomeModule value, {this.enabled = true})
      : module = value,
        groupId = null,
        dividerId = null;

  const HomeLayoutEntry.group(String id)
      : module = null,
        groupId = id,
        dividerId = null,
        enabled = true;

  const HomeLayoutEntry.divider(String id)
      : module = null,
        groupId = null,
        dividerId = id,
        enabled = true;

  final HomeModule? module;
  final String? groupId;
  final String? dividerId;
  final bool enabled;

  bool get isModule => module != null;
  bool get isGroup => groupId != null;
  bool get isDivider => dividerId != null;
  String get key => isGroup
      ? 'group:$groupId'
      : isDivider
          ? 'divider:$dividerId'
          : 'module:${module!.id}';

  Map<String, Object> toJson() => isGroup
      ? {'type': 'group', 'id': groupId!}
      : isDivider
          ? {'type': 'divider', 'id': dividerId!}
          : {'type': 'module', 'id': module!.id, 'enabled': enabled};
}

class HomeLayoutGroup {
  HomeLayoutGroup(this.id, Iterable<HomeLayoutEntry> entries)
      : entries = List.unmodifiable(entries);

  final String id;
  final List<HomeLayoutEntry> entries;

  List<HomeModule> get modules => entries
      .where((entry) => entry.isModule)
      .map((entry) => entry.module!)
      .toList();
}

/// Group markers and modules share one sequence, so a marker can be moved to
/// split a card without changing any module's identity or visibility.
class HomeLayout {
  HomeLayout(Iterable<HomeLayoutEntry> entries)
      : entries = List.unmodifiable(entries);

  final List<HomeLayoutEntry> entries;

  factory HomeLayout.defaults() => HomeLayout([
        const HomeLayoutEntry.group('overview'),
        for (final module in HomeModule.values
            .where((module) => module.defaultGroupId == 'overview')) ...[
          HomeLayoutEntry.module(module),
          if (module == HomeModule.todayCourse)
            const HomeLayoutEntry.divider('overview-divider'),
        ],
        const HomeLayoutEntry.group('services'),
        for (final module in HomeModule.values
            .where((module) => module.defaultGroupId == 'services'))
          HomeLayoutEntry.module(module),
      ]);

  factory HomeLayout.fromJson(Object? json) {
    if (json is! Map || json['version'] != 1 || json['entries'] is! List) {
      return HomeLayout.defaults();
    }
    final entries = <HomeLayoutEntry>[];
    final modules = <HomeModule>{};
    final groupIds = <String>{};
    final dividerIds = <String>{};
    for (final value in json['entries'] as List) {
      if (value is! Map) continue;
      if (value['type'] == 'module') {
        final module = HomeModule.byId(value['id']);
        if (module == null || !modules.add(module)) continue;
        entries.add(HomeLayoutEntry.module(module,
            enabled:
                value['enabled'] is bool ? value['enabled'] as bool : true));
      } else if (value['type'] == 'group') {
        final id = value['id'];
        if (id is! String || id.trim().isEmpty || !groupIds.add(id)) {
          continue;
        }
        entries.add(HomeLayoutEntry.group(id));
      } else if (value['type'] == 'divider') {
        final id = value['id'];
        if (id is! String || id.trim().isEmpty || !dividerIds.add(id)) {
          continue;
        }
        entries.add(HomeLayoutEntry.divider(id));
      }
    }
    if (modules.isEmpty) return HomeLayout.defaults();

    // Newly introduced modules join the end of their default group, while
    // existing order and hidden modules remain intact.
    for (final module in HomeModule.values.where((m) => !modules.contains(m))) {
      final groupIndex = entries.indexWhere(
          (entry) => entry.isGroup && entry.groupId == module.defaultGroupId);
      var insertAt = entries.length;
      if (groupIndex >= 0) {
        final nextGroup =
            entries.indexWhere((entry) => entry.isGroup, groupIndex + 1);
        if (nextGroup >= 0) insertAt = nextGroup;
      }
      entries.insert(insertAt, HomeLayoutEntry.module(module));
    }
    return HomeLayout(entries);
  }

  Map<String, Object> toJson() => {
        'version': 1,
        'entries': entries.map((entry) => entry.toJson()).toList(),
      };

  List<HomeLayoutGroup> get visibleGroups {
    final groups = <HomeLayoutGroup>[];
    var groupId = 'ungrouped';
    var contents = <HomeLayoutEntry>[];
    for (final entry in entries) {
      if (entry.isGroup) {
        if (contents.any((entry) => entry.isModule)) {
          groups.add(HomeLayoutGroup(groupId, contents));
        }
        groupId = entry.groupId!;
        contents = [];
      } else if (entry.enabled) {
        contents.add(entry);
      }
    }
    if (contents.any((entry) => entry.isModule)) {
      groups.add(HomeLayoutGroup(groupId, contents));
    }
    return groups;
  }

  HomeLayout setEnabled(HomeModule module, bool enabled) => HomeLayout([
        for (final entry in entries)
          if (entry.module == module)
            HomeLayoutEntry.module(module, enabled: enabled)
          else
            entry,
      ]);

  /// [newIndex] is the final index, as supplied by onReorderItem.
  HomeLayout move(int oldIndex, int newIndex) {
    final updated = entries.toList();
    updated.insert(newIndex, updated.removeAt(oldIndex));
    return HomeLayout(updated);
  }

  HomeLayout addGroup(String id) =>
      HomeLayout([...entries, HomeLayoutEntry.group(id)]);

  HomeLayout removeGroup(String id) => HomeLayout(
      entries.where((entry) => !entry.isGroup || entry.groupId != id));

  HomeLayout addDivider(String id) =>
      HomeLayout([...entries, HomeLayoutEntry.divider(id)]);

  HomeLayout removeDivider(String id) =>
      HomeLayout(entries.where((entry) => entry.dividerId != id));
}

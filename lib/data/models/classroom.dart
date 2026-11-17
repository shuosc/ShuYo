import 'common.dart';

class ClassroomCampus {
  static const defaultName = '宝山';

  /// 空教室系统把东区单列成一个校区，但楼宇都在宝山范围内。
  /// 展示时统一并回宝山，只保留三个校区。
  static const knownNames = ['宝山', '延长', '嘉定'];
}

class ClassroomBuilding {
  const ClassroomBuilding({
    required this.id,
    required this.name,
    required this.campusId,
    required this.campusName,
    this.fullName = '',
    this.code = '',
  });

  /// 学校名称与楼宇惯用叫法不一致，或该楼没有开放空教室数据。
  /// 这里按楼 id 归一化，避免依赖随接口变动的中文名。
  static const _displayNames = <int, String>{
    476: '经管楼',
    477: '材料楼',
    478: '计算机/通信楼',
  };

  /// 该楼没有开放空教室数据，不参与查询。
  static const _hiddenIds = <int>{
    884, // 计算机大楼
  };

  final int id;
  final String name;
  final int campusId;
  final String campusName;
  final String fullName;
  final String code;

  /// 是否出现在空教室的可选楼宇里。
  static bool isSelectable(int id) => !_hiddenIds.contains(id);

  /// 把接口返回的名称换成楼宇惯用名。
  static String displayNameFor(int id, String fallback) =>
      _displayNames[id] ?? fallback;

  JsonMap toJson() {
    return {
      'id': id,
      'name': name,
      'campusId': campusId,
      'campusName': campusName,
      'fullName': fullName,
      'code': code,
    };
  }

  factory ClassroomBuilding.fromJson(JsonMap json) {
    final id = intValue(json['id']);
    final name = displayNameFor(
      id,
      stringValue(json['name'] ?? json['text']),
    );
    final campusId = intValue(json['campusId'] ?? json['parentNodeId']);
    return ClassroomBuilding(
      id: id,
      name: name,
      campusId: campusId,
      campusName: _campusName(
        campusId,
        stringValue(json['fullName']),
        stringValue(json['campusName']),
      ),
      fullName: _displayFullName(stringValue(json['fullName']), name),
      code: stringValue(json['code'] ?? json['roomCode']),
    );
  }
}

/// 让 `上海大学/宝山东区/商管大楼` 的末段与 [ClassroomBuilding.name] 一致。
String _displayFullName(String fullName, String name) {
  if (fullName.isEmpty) {
    return fullName;
  }
  final index = fullName.lastIndexOf('/');
  if (index < 0) {
    return fullName;
  }
  return '${fullName.substring(0, index + 1)}$name';
}

class ClassroomSection {
  const ClassroomSection({
    required this.index,
    required this.startTime,
    required this.endTime,
  });

  final int index;
  final String startTime;
  final String endTime;

  String get label => '$index节 $startTime-$endTime';

  JsonMap toJson() {
    return {
      'index': index,
      'startTime': startTime,
      'endTime': endTime,
    };
  }

  factory ClassroomSection.fromJson(JsonMap json) {
    return ClassroomSection(
      index: intValue(json['index'] ?? json['sectionIndex']),
      startTime: stringValue(json['startTime']),
      endTime: stringValue(json['endTime']),
    );
  }
}

class ClassroomSearchOptions {
  const ClassroomSearchOptions({
    required this.buildings,
    required this.sections,
    this.currentSection = 0,
  });

  final List<ClassroomBuilding> buildings;
  final List<ClassroomSection> sections;
  final int currentSection;

  List<String> get campusNames {
    final names = <String>[];
    for (final building in buildings) {
      if (!names.contains(building.campusName)) {
        names.add(building.campusName);
      }
    }
    return names;
  }

  JsonMap toJson() {
    return {
      'buildings': buildings.map((building) => building.toJson()).toList(),
      'sections': sections.map((section) => section.toJson()).toList(),
      'currentSection': currentSection,
    };
  }

  factory ClassroomSearchOptions.fromJson(JsonMap json) {
    return ClassroomSearchOptions(
      buildings: (json['buildings'] as List? ?? const [])
          .whereType<JsonMap>()
          .map(ClassroomBuilding.fromJson)
          .where((building) =>
              building.id > 0 &&
              building.name.isNotEmpty &&
              ClassroomBuilding.isSelectable(building.id))
          .toList(growable: false),
      sections: (json['sections'] as List? ?? const [])
          .whereType<JsonMap>()
          .map(ClassroomSection.fromJson)
          .where((section) => section.index > 0)
          .toList(growable: false),
      currentSection: intValue(json['currentSection']),
    );
  }
}

class ClassroomCourse {
  const ClassroomCourse({
    required this.courseName,
    required this.teacherName,
    required this.startSection,
    required this.endSection,
    this.source = '',
  });

  final String courseName;
  final String teacherName;
  final int startSection;
  final int endSection;
  final String source;

  String get sectionText => '$startSection-$endSection节';

  bool overlaps(int start, int end) {
    return startSection <= end && endSection >= start;
  }

  factory ClassroomCourse.fromJson(JsonMap json) {
    return ClassroomCourse(
      courseName: stringValue(json['courseName']),
      teacherName: stringValue(json['teacherName']),
      startSection: intValue(json['startSection']),
      endSection: intValue(json['endSection']),
      source: stringValue(json['sjly']),
    );
  }
}

class ClassroomRoom {
  const ClassroomRoom({
    required this.id,
    required this.name,
    required this.floorName,
    required this.fullName,
    required this.courses,
  });

  final int id;
  final String name;
  final String floorName;
  final String fullName;
  final List<ClassroomCourse> courses;

  bool isFreeFor(int startSection, int endSection) {
    return courses
        .every((course) => !course.overlaps(startSection, endSection));
  }

  List<ClassroomCourse> coursesFor(int startSection, int endSection) {
    return courses
        .where((course) => course.overlaps(startSection, endSection))
        .toList(growable: false);
  }

  factory ClassroomRoom.fromJson(JsonMap json, {required String floorName}) {
    return ClassroomRoom(
      id: intValue(json['id']),
      name: stringValue(json['name'] ?? json['text']),
      floorName: floorName,
      fullName: stringValue(json['fullName']),
      courses: (json['roomCourseList'] as List? ?? const [])
          .whereType<JsonMap>()
          .map(ClassroomCourse.fromJson)
          .where((course) =>
              course.startSection > 0 &&
              course.endSection >= course.startSection)
          .toList(growable: false),
    );
  }
}

class ClassroomFloor {
  const ClassroomFloor({
    required this.id,
    required this.name,
    required this.rooms,
  });

  final int id;
  final String name;
  final List<ClassroomRoom> rooms;

  factory ClassroomFloor.fromJson(JsonMap json) {
    final name = stringValue(json['name'] ?? json['text']);
    return ClassroomFloor(
      id: intValue(json['id']),
      name: name,
      rooms: (json['children'] as List? ?? const [])
          .whereType<JsonMap>()
          .map((room) => ClassroomRoom.fromJson(room, floorName: name))
          .where((room) => room.id > 0 && room.name.isNotEmpty)
          .toList(growable: false),
    );
  }
}

class ClassroomBuildingSchedule {
  const ClassroomBuildingSchedule({
    required this.building,
    required this.floors,
  });

  final ClassroomBuilding building;
  final List<ClassroomFloor> floors;

  Iterable<ClassroomRoom> get rooms sync* {
    for (final floor in floors) {
      yield* floor.rooms;
    }
  }
}

class ClassroomAvailabilityResult {
  const ClassroomAvailabilityResult({
    required this.building,
    required this.date,
    required this.startSection,
    required this.endSection,
    required this.floors,
  });

  final ClassroomBuilding building;
  final DateTime date;
  final int startSection;
  final int endSection;
  final List<ClassroomFloorAvailability> floors;

  int get totalRooms => floors.fold(0, (sum, floor) => sum + floor.totalRooms);

  int get availableCount =>
      floors.fold(0, (sum, floor) => sum + floor.availableRooms.length);

  List<CourseLocationMatch> courseMatches(String keyword) {
    final normalized = keyword.trim().toLowerCase();
    if (normalized.isEmpty) {
      return const <CourseLocationMatch>[];
    }
    final matches = <CourseLocationMatch>[];
    for (final floor in floors) {
      for (final room in floor.rooms) {
        for (final course in room.courses) {
          final haystack =
              '${course.courseName} ${course.teacherName} ${room.name}'
                  .toLowerCase();
          if (haystack.contains(normalized)) {
            matches.add(CourseLocationMatch(room: room, course: course));
          }
        }
      }
    }
    return matches;
  }
}

class ClassroomFloorAvailability {
  const ClassroomFloorAvailability({
    required this.floor,
    required this.rooms,
    required this.availableRooms,
  });

  final ClassroomFloor floor;
  final List<ClassroomRoom> rooms;
  final List<ClassroomRoom> availableRooms;

  int get totalRooms => rooms.length;
}

class CourseLocationMatch {
  const CourseLocationMatch({
    required this.room,
    required this.course,
  });

  final ClassroomRoom room;
  final ClassroomCourse course;
}

class ClassroomSemesterInfo {
  const ClassroomSemesterInfo({
    required this.week,
    this.realDate,
  });

  final int week;
  final DateTime? realDate;

  factory ClassroomSemesterInfo.fromJson(JsonMap json) {
    final rawDate = stringValue(json['realDate']);
    DateTime? parsedDate;
    if (rawDate.isNotEmpty) {
      final parsed = DateTime.tryParse(rawDate);
      if (parsed != null) {
        final shanghai = parsed.toUtc().add(const Duration(hours: 8));
        parsedDate = DateTime(shanghai.year, shanghai.month, shanghai.day);
      }
    }
    return ClassroomSemesterInfo(
      week: intValue(json['week']),
      realDate: parsedDate,
    );
  }

  /// 计算指定日期所属的教学周；若无基准日期或周次无效则返回 null。
  int? weekForDate(DateTime date, {DateTime? now}) {
    if (week <= 0) return null;
    final anchor = realDate ??
        () {
          final current = now ?? DateTime.now();
          return DateTime(current.year, current.month, current.day);
        }();
    final target = DateTime(date.year, date.month, date.day);
    final anchorMonday = anchor.subtract(Duration(days: anchor.weekday - 1));
    final targetMonday = target.subtract(Duration(days: target.weekday - 1));
    final deltaWeeks = targetMonday.difference(anchorMonday).inDays ~/ 7;
    return week + deltaWeeks;
  }
}

class ClassroomEsCourseHit {
  const ClassroomEsCourseHit({
    required this.courseName,
    required this.teacherName,
    required this.roomName,
    required this.dayInWeek,
    required this.startSection,
    required this.endSection,
    required this.startWeek,
    required this.endWeek,
    this.source = '',
  });

  final String courseName;
  final String teacherName;
  final String roomName;
  final int dayInWeek;
  final int startSection;
  final int endSection;
  final int startWeek;
  final int endWeek;
  final String source;

  String get sectionText => startSection == endSection
      ? '$startSection节'
      : '$startSection-$endSection节';

  bool matchesDate(DateTime date, {int? targetWeek}) {
    if (dayInWeek > 0 && dayInWeek != date.weekday) {
      return false;
    }
    if (targetWeek != null && startWeek > 0 && endWeek > 0) {
      return targetWeek >= startWeek && targetWeek <= endWeek;
    }
    return true;
  }

  /// 按 ES 返回的 `roomName` 推断所属教学楼。
  ClassroomBuilding? matchBuilding(List<ClassroomBuilding> buildings) {
    final normalized = roomName.trim();
    if (normalized.isEmpty) return null;
    final upper = normalized.toUpperCase();
    final prefix = normalized.contains('/')
        ? normalized.split('/').first.trim()
        : normalized;

    ClassroomBuilding? findById(int id) {
      for (final building in buildings) {
        if (building.id == id) return building;
      }
      return null;
    }

    ClassroomBuilding? findByNames(List<String> keywords) {
      for (final keyword in keywords) {
        for (final building in buildings) {
          if (building.name.contains(keyword) ||
              building.fullName.contains(keyword)) {
            return building;
          }
        }
      }
      return null;
    }

    // 东区大楼与命名归一化后的楼宇优先按关键词匹配。
    if (prefix.contains('信息大楼') || prefix.contains('计算机')) {
      return findById(478) ?? findByNames(const ['计算机/通信楼', '信息大楼']);
    }
    if (prefix.contains('材料') || prefix.contains('17号楼')) {
      return findById(477) ?? findByNames(const ['材料楼', '材料大楼']);
    }
    if (prefix.contains('商管') || prefix.contains('经管')) {
      return findById(476) ?? findByNames(const ['经管楼', '商管大楼']);
    }

    // 宝山主楼与阶梯楼：双字母前缀必须在单字母之前匹配。
    const codePrefixes = <(String prefix, int id, List<String> names)>[
      ('AJ', 325, ['AJ楼']),
      ('BJ', 328, ['BJ楼']),
      ('CJ', 262, ['CJ楼']),
      ('DJ', 208, ['DJ楼']),
      ('EJ', 220, ['EJ楼']),
      ('FJ', 221, ['FJ楼']),
      ('GA', 930, ['GA楼']),
      ('GJ', 222, ['GJ楼']),
      ('A', 303, ['A楼']),
      ('B', 122, ['B楼']),
      ('C', 528, ['C楼']),
      ('D', 164, ['D楼']),
      ('J', 700, ['J楼']),
    ];
    for (final entry in codePrefixes) {
      if (upper.startsWith(entry.$1)) {
        return findById(entry.$2) ?? findByNames(entry.$3);
      }
    }

    // 延长 / 嘉定等校区按楼名或常见简称匹配。
    for (final building in buildings) {
      if (prefix.contains(building.name) ||
          normalized.contains(building.name)) {
        return building;
      }
    }
    const shortAliases = <(String alias, int id)>[
      ('行健', 399),
      ('四教', 422),
      ('仪表', 449),
      ('一教', 607),
      ('二教', 575),
      ('文达', 759),
    ];
    for (final alias in shortAliases) {
      if (normalized.contains(alias.$1)) {
        return findById(alias.$2);
      }
    }
    return null;
  }

  factory ClassroomEsCourseHit.fromJson(JsonMap json) {
    final start = intValue(json['startSection']);
    final end = intValue(json['endSection']);
    return ClassroomEsCourseHit(
      courseName: stringValue(json['courseName']),
      teacherName: stringValue(json['teacherName']),
      roomName: stringValue(json['roomName']),
      dayInWeek: intValue(json['dayinweek'] ?? json['dayInWeek']),
      startSection: start,
      endSection: end >= start ? end : start,
      startWeek: intValue(json['startWeek']),
      endWeek: intValue(json['endWeek']),
      source: stringValue(json['sjly']),
    );
  }
}

class ClassroomCourseSearchResult {
  const ClassroomCourseSearchResult({
    required this.totalHits,
    required this.hits,
  });

  final int totalHits;
  final List<ClassroomEsCourseHit> hits;
}

String _campusName(int campusId, String fullName, String cachedName) {
  final knownName = switch (campusId) {
    // 东区（475）在宝山校区内，展示时并入宝山。
    3 || 475 => '宝山',
    398 => '延长',
    574 => '嘉定',
    _ => null,
  };
  if (knownName != null) {
    return knownName;
  }
  if (cachedName.isNotEmpty) {
    return cachedName;
  }
  final parts = fullName.split('/').where((part) => part.isNotEmpty).toList();
  if (parts.length >= 2) {
    return parts[1].replaceAll('校区', '');
  }
  return '其它';
}

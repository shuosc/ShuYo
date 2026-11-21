import 'common.dart';

class ClassroomCampus {
  static const defaultName = '宝山';
  static const knownNames = ['宝山', '延长', '宝山东区', '嘉定'];
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

  final int id;
  final String name;
  final int campusId;
  final String campusName;
  final String fullName;
  final String code;

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
    final campusId = intValue(json['campusId'] ?? json['parentNodeId']);
    final fullName = stringValue(json['fullName']);
    return ClassroomBuilding(
      id: intValue(json['id']),
      name: stringValue(json['name']),
      campusId: campusId,
      campusName: _campusName(
        campusId,
        fullName,
        stringValue(json['campusName']),
      ),
      fullName: fullName,
      code: stringValue(json['code'] ?? json['roomCode']),
    );
  }
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
          .where((building) => building.id > 0 && building.name.isNotEmpty)
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

  String get sectionText => startSection == endSection
      ? '$startSection节'
      : '$startSection–$endSection节';

  bool overlapsSections(Set<int> sections) => sections
      .any((section) => section >= startSection && section <= endSection);

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

  bool isFreeFor(Set<int> sections) =>
      sections.isNotEmpty &&
      !courses.any((course) => course.overlapsSections(sections));

  List<ClassroomCourse> coursesFor(Set<int> sections) => courses
      .where((course) => course.overlapsSections(sections))
      .toList(growable: false);

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

class ClassroomBuildingAvailability {
  ClassroomBuildingAvailability(
      ClassroomBuildingSchedule schedule, Set<int> sections)
      : building = schedule.building,
        floors = [
          for (final floor in schedule.floors)
            ClassroomFloorAvailability(floor, sections),
        ];

  final ClassroomBuilding building;
  final List<ClassroomFloorAvailability> floors;

  int get totalRooms => floors.fold(0, (sum, floor) => sum + floor.totalRooms);

  int get availableCount =>
      floors.fold(0, (sum, floor) => sum + floor.availableRooms.length);
}

class ClassroomFloorAvailability {
  ClassroomFloorAvailability(this.floor, Set<int> sections)
      : availableRooms = floor.rooms
            .where((room) => room.isFreeFor(sections))
            .toList(growable: false);

  final ClassroomFloor floor;
  final List<ClassroomRoom> availableRooms;

  int get totalRooms => floor.rooms.length;
}

String _campusName(int campusId, String fullName, String cachedName) {
  final knownName = switch (campusId) {
    3 => '宝山',
    398 => '延长',
    475 => '宝山东区',
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

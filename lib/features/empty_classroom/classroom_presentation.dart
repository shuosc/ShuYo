import '../../data/models/classroom.dart';

/// 校区展示顺序。空教室接口把东区单列，[ClassroomBuilding] 已把它并回宝山。
const classroomCampusOrder = <String>['宝山', '延长', '嘉定'];

/// 筛选器里并排同一行的楼：主楼与它对应的阶梯楼。
///
/// 顺序就是这个顺序：A/AJ、B/BJ、C/CJ、D/DJ、GA/GJ、EJ/FJ，其余楼排在后面。
const classroomBuildingPairNames = <List<String>>[
  ['A楼', 'AJ楼'],
  ['B楼', 'BJ楼'],
  ['C楼', 'CJ楼'],
  ['D楼', 'DJ楼'],
  ['GA楼', 'GJ楼'],
  ['EJ楼', 'FJ楼'],
];

/// 宝山教学楼的人工顺序。
///
/// 按名字排序会把「AJ楼」排在「A楼」前面，而主楼与阶梯楼本来就该相邻，
/// 所以这里显式列出；未列出的楼排在后面，再按名称比较。
const _buildingOrder = <int, int>{
  303: 0, // A楼
  325: 1, // AJ楼
  122: 2, // B楼
  328: 3, // BJ楼
  528: 4, // C楼
  262: 5, // CJ楼
  164: 6, // D楼
  208: 7, // DJ楼
  220: 8, // EJ楼
  221: 9, // FJ楼
  222: 10, // GJ楼
  476: 11, // 经管楼
  478: 12, // 计算机/通信楼
  477: 13, // 材料楼
};

int _campusRank(String campus) {
  final index = classroomCampusOrder.indexOf(campus);
  return index < 0 ? classroomCampusOrder.length : index;
}

/// 校区优先、其次人工楼序、最后按名称，供列表与筛选器共用。
int compareClassroomBuildings(ClassroomBuilding a, ClassroomBuilding b) {
  final campus = _campusRank(a.campusName).compareTo(_campusRank(b.campusName));
  if (campus != 0) {
    return campus;
  }
  final order =
      (_buildingOrder[a.id] ?? 1000).compareTo(_buildingOrder[b.id] ?? 1000);
  if (order != 0) {
    return order;
  }
  return a.name.compareTo(b.name);
}

/// 可参与查询的楼宇，按展示顺序排列。
List<ClassroomBuilding> selectableBuildings(ClassroomSearchOptions options) {
  final list = options.buildings
      .where((building) => ClassroomBuilding.isSelectable(building.id))
      .toList(growable: false);
  return [...list]..sort(compareClassroomBuildings);
}

/// 按校区把楼宇分组，保持 [classroomCampusOrder] 的顺序。
List<({String campus, List<ClassroomBuilding> buildings})>
    groupBuildingsByCampus(List<ClassroomBuilding> buildings) {
  final groups = <String, List<ClassroomBuilding>>{};
  for (final building in buildings) {
    groups.putIfAbsent(building.campusName, () => []).add(building);
  }
  final names = groups.keys.toList()
    ..sort((a, b) => _campusRank(a).compareTo(_campusRank(b)));
  return [
    for (final name in names) (campus: name, buildings: groups[name]!),
  ];
}

/// 校区筛选的默认值：首选校区的全部楼宇；首选校区不存在时退回第一个校区。
Set<int> defaultBuildingSelection(
  ClassroomSearchOptions options, {
  required String preferredCampus,
}) {
  final buildings = selectableBuildings(options);
  final campus = buildings.any((item) => item.campusName == preferredCampus)
      ? preferredCampus
      : (buildings.isEmpty ? null : buildings.first.campusName);
  if (campus == null) {
    return <int>{};
  }
  return {
    for (final building in buildings)
      if (building.campusName == campus) building.id,
  };
}

/// 把勾选结果还原成楼宇对象，顺序与列表一致。
List<ClassroomBuilding> selectedBuildingsOf(
  ClassroomSearchOptions options,
  Set<int> ids,
) =>
    [
      for (final building in selectableBuildings(options))
        if (ids.contains(building.id)) building,
    ];

/// 把一栋校区的楼排成筛选器的行：配对的楼并排，其余楼各自一行。
List<List<ClassroomBuilding>> classroomBuildingRows(
  List<ClassroomBuilding> buildings,
) {
  final byName = <String, ClassroomBuilding>{
    for (final building in buildings) building.name: building,
  };
  final rows = <List<ClassroomBuilding>>[];
  final used = <int>{};
  for (final pair in classroomBuildingPairNames) {
    final row = [
      for (final name in pair)
        if (byName[name] != null) byName[name]!,
    ];
    if (row.isEmpty) continue;
    used.addAll(row.map((building) => building.id));
    rows.add(row);
  }
  final rest = [
    for (final building in buildings)
      if (!used.contains(building.id)) building,
  ]..sort(compareClassroomBuildings);
  rows.addAll([
    for (final building in rest) [building],
  ]);
  return rows;
}

ClassroomSection? classroomSectionOf(
  List<ClassroomSection> sections,
  int index,
) {
  for (final section in sections) {
    if (section.index == index) {
      return section;
    }
  }
  return null;
}

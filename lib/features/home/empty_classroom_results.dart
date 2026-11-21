part of 'empty_classroom_page.dart';

enum _ClassroomView { available, arrangements }

enum _ArrangementScope {
  fullDay('全天'),
  selection('所选节次');

  const _ArrangementScope(this.label);

  final String label;
}

const _arrangementTitleWeight = FontWeight.w500;

class _BuildingLoad {
  _BuildingLoad(this.building);

  final ClassroomBuilding building;
  ClassroomBuildingSchedule? schedule;
  ClassroomApiException? error;

  bool get pending => schedule == null && error == null;
}

class _ClassroomResults extends StatelessWidget {
  const _ClassroomResults({
    required this.loads,
    required this.view,
    required this.sections,
    required this.scope,
    required this.keyword,
    required this.onlyArranged,
  });

  final List<_BuildingLoad> loads;
  final _ClassroomView view;
  final Set<int> sections;
  final _ArrangementScope scope;
  final String keyword;
  final bool onlyArranged;

  bool get _allLoaded => loads.every((load) => load.schedule != null);

  @override
  Widget build(BuildContext context) => SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        sliver: SliverList.list(
          children: switch (view) {
            _ClassroomView.available => _availableRows(context),
            _ClassroomView.arrangements => _arrangementRows(),
          },
        ),
      );

  List<Widget> _availableRows(BuildContext context) {
    final availability = {
      for (final load in loads)
        if (load.schedule case final schedule?)
          load.building.id: ClassroomBuildingAvailability(schedule, sections),
    };
    final availableCount = availability.values.fold(
      0,
      (sum, building) => sum + building.availableCount,
    );
    final totalRooms = availability.values.fold(
      0,
      (sum, building) => sum + building.totalRooms,
    );
    return [
      if (availableCount > 0)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            _allLoaded
                ? '空闲 $availableCount / $totalRooms 间'
                : '空闲 $availableCount 间',
            style:
                ShuYoTextStyles.meta(color: context.shuyoColors.textSecondary),
          ),
        ),
      for (final load in loads)
        if (availability[load.building.id] case final building?) ...[
          if (building.availableCount > 0) ...[
            if (loads.length > 1) _BuildingLabel(building.building.name),
            for (final floor in building.floors)
              if (floor.availableRooms.isNotEmpty)
                _AvailableFloor(building: building.building, floor: floor),
          ],
        ] else
          _BuildingStatus(load: load),
      if (availableCount == 0 && _allLoaded) const _ResultMessage('没有空教室'),
    ];
  }

  List<Widget> _arrangementRows() {
    final rows = <Widget>[];
    for (final load in loads) {
      final schedule = load.schedule;
      if (schedule == null) {
        rows.add(_BuildingStatus(
          load: load,
          titleWeight: _arrangementTitleWeight,
        ));
        continue;
      }
      final buildingRows = <Widget>[];
      for (final floor in schedule.floors) {
        final roomRows = <Widget>[];
        for (final room in floor.rooms) {
          final courses = _arrangementsFor(schedule.building, room);
          if (courses == null) continue;
          roomRows.add(_RoomScheduleRow(
            key: ValueKey((schedule.building.id, room.id)),
            building: schedule.building,
            room: room,
            courses: courses,
          ));
        }
        if (roomRows.isNotEmpty) {
          buildingRows.addAll([_FloorLabel(floor.name), ...roomRows]);
        }
      }
      if (buildingRows.isNotEmpty) {
        if (loads.length > 1) {
          rows.add(_BuildingLabel(
            schedule.building.name,
            weight: _arrangementTitleWeight,
          ));
        }
        rows.addAll(buildingRows);
      }
    }
    if (rows.isEmpty) rows.add(const _ResultMessage('没有匹配结果'));
    return rows;
  }

  List<ClassroomCourse>? _arrangementsFor(
      ClassroomBuilding building, ClassroomRoom room) {
    final courses = scope == _ArrangementScope.fullDay
        ? room.courses
        : room.coursesFor(sections);
    if (onlyArranged && courses.isEmpty) return null;
    if (keyword.isEmpty ||
        '${building.name} ${room.name}'.toLowerCase().contains(keyword)) {
      return _orderedCourses(courses);
    }
    final matches = courses.where((course) =>
        '${course.courseName} ${course.teacherName}'
            .toLowerCase()
            .contains(keyword));
    return matches.isEmpty ? null : _orderedCourses(matches);
  }
}

class _BuildingLabel extends StatelessWidget {
  const _BuildingLabel(this.name, {this.weight});

  final String name;
  final FontWeight? weight;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(name,
            style: ShuYoTextStyles.sectionTitle().copyWith(fontWeight: weight)),
      );
}

class _BuildingStatus extends StatelessWidget {
  const _BuildingStatus({required this.load, this.titleWeight});

  final _BuildingLoad load;
  final FontWeight? titleWeight;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
              child: Text(load.building.name,
                  style: ShuYoTextStyles.sectionTitle()
                      .copyWith(fontWeight: titleWeight))),
          if (load.pending)
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, semanticsLabel: '正在加载'),
            )
          else
            Text('未加载',
                style: ShuYoTextStyles.meta(color: colors.textSecondary)),
        ],
      ),
    );
  }
}

class _FloorLabel extends StatelessWidget {
  const _FloorLabel(this.name);

  final String name;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 2),
        child: Text(name,
            style:
                ShuYoTextStyles.meta(color: context.shuyoColors.textSecondary)),
      );
}

class _AvailableFloor extends StatelessWidget {
  const _AvailableFloor({required this.building, required this.floor});

  final ClassroomBuilding building;
  final ClassroomFloorAvailability floor;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 6),
          child: Text(
            floor.floor.name,
            style: ShuYoTextStyles.meta(
              color: colors.textSecondary,
              weight: FontWeight.w500,
            ),
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            const gap = 8.0;
            final minWidth = _AvailableRoomTile.minimumWidth(
              MediaQuery.textScalerOf(context),
            );
            final columns = ((constraints.maxWidth + gap) / (minWidth + gap))
                .floor()
                .clamp(1, 3);
            final width =
                (constraints.maxWidth - (columns - 1) * gap) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final room in floor.availableRooms)
                  SizedBox(
                    width: width,
                    child: _AvailableRoomTile(building: building, room: room),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _AvailableRoomTile extends StatelessWidget {
  const _AvailableRoomTile({required this.building, required this.room});

  static const _labelSize = 14.0;
  static const _labelWidthInEms = 4;
  static const _iconSize = 17.0;
  static const _iconGap = 7.0;
  static const _padding = EdgeInsets.symmetric(horizontal: 10, vertical: 8);

  static double minimumWidth(TextScaler scaler) =>
      _padding.horizontal +
      _iconSize +
      _iconGap +
      _labelWidthInEms * scaler.scale(_labelSize);

  final ClassroomBuilding building;
  final ClassroomRoom room;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return OutlinedButton(
      onPressed: () => _showRoomSchedule(context, building, room),
      style: OutlinedButton.styleFrom(
        backgroundColor: colors.surface,
        foregroundColor: colors.textPrimary,
        textStyle: ShuYoTextStyles.label(size: _labelSize).copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        minimumSize: const Size(0, 44),
        padding: _padding,
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide(color: colors.borderStrong),
      ),
      child: Row(
        children: [
          Icon(Icons.meeting_room_outlined,
              size: _iconSize, color: colors.accent),
          const SizedBox(width: _iconGap),
          Flexible(
            child:
                Text(room.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

class _RoomScheduleRow extends StatelessWidget {
  const _RoomScheduleRow(
      {super.key,
      required this.building,
      required this.room,
      required this.courses});

  final ClassroomBuilding building;
  final ClassroomRoom room;
  final List<ClassroomCourse> courses;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Column(
      children: [
        InkWell(
          onTap: () => _showRoomSchedule(context, building, room),
          child: Container(
            alignment: Alignment.centerLeft,
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                      child: Text(room.name,
                          style: ShuYoTextStyles.sectionTitle()
                              .copyWith(fontWeight: _arrangementTitleWeight))),
                  if (courses.isEmpty) ...[
                    Text('无安排',
                        style:
                            ShuYoTextStyles.meta(color: colors.textSecondary)),
                    const SizedBox(width: 6),
                  ],
                  Icon(Icons.chevron_right,
                      size: 19, color: colors.textTertiary),
                ]),
                for (final course in courses)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: _CourseLine(course),
                  ),
              ],
            ),
          ),
        ),
        const Divider(),
      ],
    );
  }
}

class _CourseLine extends StatelessWidget {
  const _CourseLine(this.course);

  final ClassroomCourse course;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final name = course.courseName.trim();
    final teacher = course.teacherName.trim();
    final borrowed = course.source == '借';
    final details = [
      if (teacher.isNotEmpty) teacher,
      if (borrowed && name.isNotEmpty) '借用',
    ].join(' · ');
    final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 56 * scale,
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(course.sectionText,
                style: ShuYoTextStyles.meta(
                    color: colors.textSecondary, size: 12)),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name.isNotEmpty ? name : (borrowed ? '借用' : '占用'),
                  style: ShuYoTextStyles.bodyCompact()),
              if (details.isNotEmpty)
                Text(details,
                    style: ShuYoTextStyles.meta(color: colors.textSecondary)),
            ],
          ),
        ),
      ],
    );
  }
}

class _ResultMessage extends StatelessWidget {
  const _ResultMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: ShuYoTextStyles.bodyCompact(
              color: context.shuyoColors.textSecondary),
        ),
      );
}

List<ClassroomCourse> _orderedCourses(Iterable<ClassroomCourse> courses) =>
    courses.toList()..sort((a, b) => a.startSection.compareTo(b.startSection));

Future<void> _showRoomSchedule(
    BuildContext context, ClassroomBuilding building, ClassroomRoom room) {
  final courses = _orderedCourses(room.courses);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) {
      final colors = context.shuyoColors;
      return SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                  child: Text(room.name, style: ShuYoTextStyles.pageTitle())),
              Text('全天',
                  style: ShuYoTextStyles.meta(color: colors.textSecondary)),
            ]),
            Text('${building.name} · ${room.floorName}',
                style: ShuYoTextStyles.meta(color: colors.textSecondary)),
            const SizedBox(height: 12),
            const Divider(),
            if (courses.isEmpty)
              const _ResultMessage('无安排')
            else
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final course in courses)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: _CourseLine(course),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

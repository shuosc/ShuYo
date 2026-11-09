import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/models/classroom.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/calendar_date_picker.dart';
import '../../shared/widgets/date_picker_dialog.dart';
import 'classroom_presentation.dart';

/// 顶右滑出的筛选浮层，和录播搜索的学期菜单、校园卡的时间菜单同款。
Future<T?> _showTopRightMenu<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  required String barrierLabel,
  double widthFactor = .68,
  double maxWidth = 264,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: barrierLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (menuContext, animation, secondaryAnimation) {
      final size = MediaQuery.sizeOf(menuContext);
      return SafeArea(
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(top: kToolbarHeight + 8, right: 12),
            child: SizedBox(
              width: math.min(maxWidth, size.width * widthFactor),
              child: builder(menuContext),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(.18, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

enum _DatePreset { today, tomorrow, custom }

/// 今天 / 明天 / 自定时间。选择「自定时间」后接着弹出与课表同款的日历。
Future<DateTime?> showClassroomDateMenu(
  BuildContext context, {
  required DateTime selectedDate,
  DateTime? today,
}) async {
  final now = DateUtils.dateOnly(today ?? DateTime.now());
  final selected = DateUtils.dateOnly(selectedDate);
  final preset = await _showTopRightMenu<_DatePreset>(
    context,
    barrierLabel: '关闭时间筛选',
    builder: (menuContext) {
      final colors = menuContext.shuyoColors;
      final current = switch (selected) {
        final value when value == now => _DatePreset.today,
        final value when value == now.add(const Duration(days: 1)) =>
          _DatePreset.tomorrow,
        _ => null,
      };
      Widget option(_DatePreset value, String label) => ListTile(
            key: ValueKey('classroom-date-${value.name}'),
            selected: current == value,
            title: Text(label),
            trailing: current == value ? const Icon(Icons.check) : null,
            onTap: () => Navigator.of(menuContext).pop(value),
          );
      return Material(
        key: const ValueKey('classroom-date-menu'),
        elevation: 12,
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            option(_DatePreset.today, '今天'),
            option(_DatePreset.tomorrow, '明天'),
            option(_DatePreset.custom, '自定时间'),
          ],
        ),
      );
    },
  );
  if (preset == null || !context.mounted) {
    return null;
  }
  return switch (preset) {
    _DatePreset.today => now,
    _DatePreset.tomorrow => now.add(const Duration(days: 1)),
    _DatePreset.custom => await _showDatePicker(
        context,
        initialDate: selected,
        today: now,
      ),
  };
}

Future<DateTime?> _showDatePicker(
  BuildContext context, {
  required DateTime initialDate,
  required DateTime today,
}) {
  return showDialog<DateTime>(
    context: context,
    builder: (_) => _DatePickerDialog(
      initialDate: DateUtils.dateOnly(initialDate),
      firstDate: today.subtract(const Duration(days: 30)),
      lastDate: today.add(const Duration(days: 120)),
    ),
  );
}

class _DatePickerDialog extends StatefulWidget {
  const _DatePickerDialog({
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
  });

  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<_DatePickerDialog> createState() => _DatePickerDialogState();
}

class _DatePickerDialogState extends State<_DatePickerDialog> {
  late DateTime _selected = widget.initialDate;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return ShuYoDatePickerDialog(
      title: '选择日期',
      headerTrailing: Text(
        '${_selected.year}/${_selected.month}/${_selected.day}',
        style: ShuYoTextStyles.meta(color: colors.accent)
            .copyWith(fontWeight: FontWeight.w600),
      ),
      onConfirm: () => Navigator.of(context).pop(_selected),
      child: ShuYoCalendarDatePicker(
        firstDate: widget.firstDate,
        lastDate: widget.lastDate,
        focusedDate: _selected,
        selectedDate: _selected,
        onDateChanged: (date) => setState(() => _selected = date),
      ),
    );
  }
}

/// 校区 / 教室筛选。与公告搜索的部门筛选同款：分组头是「三态勾选框 + 折叠箭头」，
/// 每栋楼一行带勾选框；勾选立即生效，关闭浮层时把结果交回去。
Future<Set<int>?> showClassroomBuildingMenu(
  BuildContext context, {
  required List<ClassroomBuilding> buildings,
  required Set<int> selectedIds,
  String? expandedCampus,
}) async {
  var selection = {...selectedIds};
  await _showTopRightMenu<void>(
    context,
    barrierLabel: '关闭教室筛选',
    builder: (_) => _ClassroomBuildingMenu(
      buildings: buildings,
      selectedIds: selectedIds,
      expandedCampus: expandedCampus,
      onChanged: (ids) => selection = ids,
    ),
  );
  return selection;
}

class _ClassroomBuildingMenu extends StatefulWidget {
  const _ClassroomBuildingMenu({
    required this.buildings,
    required this.selectedIds,
    required this.onChanged,
    this.expandedCampus,
  });

  final List<ClassroomBuilding> buildings;
  final Set<int> selectedIds;

  /// 打开时展开的校区；为 null 时展开第一个校区。
  final String? expandedCampus;
  final ValueChanged<Set<int>> onChanged;

  @override
  State<_ClassroomBuildingMenu> createState() => _ClassroomBuildingMenuState();
}

const _campusHeaderExtent = 56.0;

class _ClassroomBuildingMenuState extends State<_ClassroomBuildingMenu> {
  late final Set<int> _selected = {...widget.selectedIds};
  late final Set<String> _collapsedCampuses = _initialCollapsedCampuses();
  final _scrollController = ScrollController();

  /// 默认只展开一个校区，其余两个收起。
  Set<String> _initialCollapsedCampuses() {
    if (widget.buildings.length <= 1) return <String>{};
    final groups = groupBuildingsByCampus(widget.buildings);
    final open = groups.any((group) => group.campus == widget.expandedCampus)
        ? widget.expandedCampus!
        : groups.first.campus;
    return {
      for (final group in groups)
        if (group.campus != open) group.campus,
    };
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _notify() => widget.onChanged({..._selected});

  bool? _groupValue(List<ClassroomBuilding> buildings) {
    final count = buildings.where((item) => _selected.contains(item.id)).length;
    if (count == 0) return false;
    if (count == buildings.length) return true;
    return null;
  }

  void _toggleGroup(List<ClassroomBuilding> buildings) {
    final ids = [for (final building in buildings) building.id];
    final all = ids.every(_selected.contains);
    setState(() {
      if (all) {
        _selected.removeAll(ids);
      } else {
        _selected.addAll(ids);
      }
    });
    _notify();
  }

  void _toggleBuilding(int id) {
    setState(() {
      if (!_selected.add(id)) {
        _selected.remove(id);
      }
    });
    _notify();
  }

  void _toggleExpanded(String campus) {
    setState(() {
      if (!_collapsedCampuses.add(campus)) {
        _collapsedCampuses.remove(campus);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final groups = groupBuildingsByCampus(widget.buildings);
    return Material(
      key: const ValueKey('classroom-building-menu'),
      elevation: 12,
      color: colors.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .72,
        ),
        child: Scrollbar(
          controller: _scrollController,
          thumbVisibility: true,
          child: CustomScrollView(
            key: const ValueKey('classroom-building-menu-scroll'),
            controller: _scrollController,
            shrinkWrap: true,
            slivers: [
              const SliverToBoxAdapter(child: SizedBox(height: 8)),
              for (final group in groups)
                SliverMainAxisGroup(
                  slivers: [
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _CampusHeaderDelegate(
                        campus: group.campus,
                        expanded: !_collapsedCampuses.contains(group.campus),
                        value: _groupValue(group.buildings),
                        onToggleGroup: () => _toggleGroup(group.buildings),
                        onToggleExpanded: () => _toggleExpanded(group.campus),
                      ),
                    ),
                    if (!_collapsedCampuses.contains(group.campus))
                      SliverList.list(children: [
                        for (final row
                            in classroomBuildingRows(group.buildings))
                          _buildingRow(row),
                      ]),
                  ],
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 8)),
            ],
          ),
        ),
      ),
    );
  }

  /// 配对的楼并排放在同一行，其余楼各自一行。
  Widget _buildingRow(List<ClassroomBuilding> row) {
    return Row(
      children: [
        for (final building in row)
          Expanded(child: _buildingTile(building, singleLine: row.length > 1)),
      ],
    );
  }

  Widget _buildingTile(ClassroomBuilding building, {bool singleLine = false}) {
    final selected = _selected.contains(building.id);
    return ListTile(
      key: ValueKey('classroom-building-${building.id}'),
      contentPadding: const EdgeInsets.only(left: 16, right: 12),
      // 并排时单元格只有半宽，中英混排的楼名（GA楼）会在字间折行，因此只留一行。
      horizontalTitleGap: singleLine ? 8 : null,
      title: Text(
        building.name,
        maxLines: singleLine ? 1 : 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => _toggleBuilding(building.id),
      trailing: Checkbox(
        key: ValueKey('classroom-building-check-${building.id}'),
        value: selected,
        onChanged: (_) => _toggleBuilding(building.id),
      ),
    );
  }
}

/// 分组头：和公告搜索的菜单分组头一样，整行可点折叠，勾选框单独管全组。
class _CampusHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _CampusHeaderDelegate({
    required this.campus,
    required this.expanded,
    required this.value,
    required this.onToggleGroup,
    required this.onToggleExpanded,
  });

  final String campus;
  final bool expanded;
  final bool? value;
  final VoidCallback onToggleGroup;
  final VoidCallback onToggleExpanded;

  @override
  double get minExtent => _campusHeaderExtent;

  @override
  double get maxExtent => _campusHeaderExtent;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Material(
      key: ValueKey('classroom-sticky-campus-$campus'),
      color: Theme.of(context).colorScheme.surface,
      child: ListTile(
        key: ValueKey('classroom-campus-$campus'),
        contentPadding: const EdgeInsets.only(left: 16, right: 12),
        title: Text(
          '$campus校区',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              key: ValueKey('classroom-campus-check-$campus'),
              tristate: true,
              value: value,
              onChanged: (_) => onToggleGroup(),
            ),
            Icon(expanded ? Icons.expand_less : Icons.expand_more),
          ],
        ),
        onTap: onToggleExpanded,
      ),
    );
  }

  @override
  bool shouldRebuild(_CampusHeaderDelegate oldDelegate) =>
      campus != oldDelegate.campus ||
      expanded != oldDelegate.expanded ||
      value != oldDelegate.value;
}

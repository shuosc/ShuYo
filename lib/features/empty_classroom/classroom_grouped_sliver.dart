import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';

/// 一个二级分组的标题与内容。
class ClassroomRangeGroup {
  const ClassroomRangeGroup({
    required this.label,
    required this.children,
  });

  final String label;
  final List<Widget> children;
}

const _buildingRowExtent = 38.0;
const _rangeRowExtent = 26.0;
const _headerExtent = _buildingRowExtent + _rangeRowExtent;

/// 两级吸顶的分组：一级是「宝山校区 A楼」，二级是「1-2节」。
///
/// 两级合成同一个 pinned header —— 两条连续的 pinned header 在内容很短时
/// 会让 paintExtent 小于 layoutExtent，撞上 sliver geometry 断言。视觉上仍
/// 分两级：二级行被下一个分组顶走时向上平移，与公告搜索的月份头一致。
class ClassroomGroupedSliver extends StatefulWidget {
  const ClassroomGroupedSliver({
    super.key,
    required this.title,
    required this.groups,
  });

  /// 一级吸顶文案，例如「宝山校区 A楼」。
  final String title;
  final List<ClassroomRangeGroup> groups;

  @override
  State<ClassroomGroupedSliver> createState() => _ClassroomGroupedSliverState();
}

class _ClassroomGroupedSliverState extends State<ClassroomGroupedSliver> {
  late List<_RowSpec> _rows;
  late List<int> _groupOfRow;
  late Set<int> _groupStarts;
  late final ValueNotifier<_RangeViewport> _viewport;
  _RangeViewport? _pendingViewport;
  bool _viewportScheduled = false;

  @override
  void initState() {
    super.initState();
    _readGroups();
    _viewport = ValueNotifier((index: 0, pushOffset: 0));
  }

  @override
  void didUpdateWidget(covariant ClassroomGroupedSliver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groups != widget.groups || oldWidget.title != widget.title) {
      _readGroups();
    }
  }

  @override
  void dispose() {
    _viewport.dispose();
    super.dispose();
  }

  void _readGroups() {
    final rows = <_RowSpec>[];
    final groupOfRow = <int>[];
    final starts = <int>{};
    for (var index = 0; index < widget.groups.length; index++) {
      final group = widget.groups[index];
      if (index > 0) {
        // 第一个分组由吸顶条的二级行呈现，列表里不再重复。
        starts.add(rows.length);
        rows.add(_RowSpec.header(index));
        groupOfRow.add(index);
      }
      for (final child in group.children) {
        rows.add(_RowSpec.child(child));
        groupOfRow.add(index);
      }
    }
    _rows = rows;
    _groupOfRow = groupOfRow;
    _groupStarts = starts;
  }

  void _reportViewport(_RangeViewport next) {
    if (next == _viewport.value) {
      _pendingViewport = null;
      return;
    }
    if (next == _pendingViewport) return;
    _pendingViewport = next;
    if (_viewportScheduled) return;
    _viewportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportScheduled = false;
      if (!mounted) return;
      final value = _pendingViewport;
      _pendingViewport = null;
      if (value == null) return;
      _viewport.value = value;
    });
  }

  Widget _buildRow(int index) {
    final row = _rows[index];
    if (row.child != null) {
      return row.child!;
    }
    final group = widget.groups[row.group];
    return SizedBox(
      key: ValueKey('classroom-group-range-${group.label}'),
      height: _rangeRowExtent,
      // 当前分组由吸顶条显示，列表里的同名标题留空，避免重复绘制。
      child: ValueListenableBuilder<_RangeViewport>(
        valueListenable: _viewport,
        builder: (context, value, child) => value.index == row.group
            ? const SizedBox.shrink()
            : _RangeRowView(label: group.label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SliverMainAxisGroup(
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _GroupedHeaderDelegate(
            title: widget.title,
            groups: widget.groups,
            viewport: _viewport,
          ),
        ),
        _TrackingList(
          groupOfRow: _groupOfRow,
          groupStarts: _groupStarts,
          onViewport: _reportViewport,
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildRow(index),
            childCount: _rows.length,
          ),
        ),
      ],
    );
  }
}

class _RowSpec {
  _RowSpec.child(Widget this.child) : group = 0;
  _RowSpec.header(this.group) : child = null;

  final Widget? child;
  final int group;
}

/// 一级：主要文字色、字号 15 / w600，不再用主题色染色。
class _BuildingRowView extends StatelessWidget {
  const _BuildingRowView({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _buildingRowExtent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 9, 16, 3),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ShuYoTextStyles.meta(
              color: context.shuyoColors.textPrimary,
              size: 15,
              weight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// 二级：次要色、字号 12.5 / w500，明显轻于一级。
class _RangeRowView extends StatelessWidget {
  const _RangeRowView({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return SizedBox(
      height: _rangeRowExtent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 1, 16, 7),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ShuYoTextStyles.meta(
              color: colors.textSecondary,
              size: 12.5,
              weight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

typedef _RangeViewport = ({int index, double pushOffset});

class _GroupedHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _GroupedHeaderDelegate({
    required this.title,
    required this.groups,
    required this.viewport,
  });

  final String title;
  final List<ClassroomRangeGroup> groups;
  final ValueNotifier<_RangeViewport> viewport;

  @override
  double get minExtent => _headerExtent;

  @override
  double get maxExtent => _headerExtent;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Material(
      key: ValueKey('classroom-sticky-$title'),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BuildingRowView(title: title),
          Expanded(
            child: ClipRect(
              child: ValueListenableBuilder<_RangeViewport>(
                valueListenable: viewport,
                builder: (context, value, child) {
                  final index = value.index;
                  if (index < 0 || index >= groups.length) {
                    return const SizedBox.expand();
                  }
                  final group = groups[index];
                  return Transform.translate(
                    offset: Offset(0, value.pushOffset),
                    child: _RangeRowView(label: group.label),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_GroupedHeaderDelegate oldDelegate) =>
      title != oldDelegate.title ||
      groups != oldDelegate.groups ||
      viewport != oldDelegate.viewport;
}

/// [SliverList]，同时把“当前二级分组 + 顶走偏移”回报给上层。
class _TrackingList extends SliverList {
  const _TrackingList({
    required super.delegate,
    required this.groupOfRow,
    required this.groupStarts,
    required this.onViewport,
  });

  final List<int> groupOfRow;
  final Set<int> groupStarts;
  final ValueChanged<_RangeViewport> onViewport;

  @override
  RenderSliverList createRenderObject(BuildContext context) =>
      _RenderTrackingList(
        childManager: context as SliverMultiBoxAdaptorElement,
        groupOfRow: groupOfRow,
        groupStarts: groupStarts,
        onViewport: onViewport,
      );

  @override
  void updateRenderObject(
      BuildContext context, covariant _RenderTrackingList renderObject) {
    renderObject
      ..groupOfRow = groupOfRow
      ..groupStarts = groupStarts
      ..onViewport = onViewport
      ..markNeedsLayout();
  }
}

class _RenderTrackingList extends RenderSliverList {
  _RenderTrackingList({
    required super.childManager,
    required this.groupOfRow,
    required this.groupStarts,
    required this.onViewport,
  });

  List<int> groupOfRow;
  Set<int> groupStarts;
  ValueChanged<_RangeViewport> onViewport;

  @override
  void performLayout() {
    super.performLayout();
    if (firstChild == null ||
        geometry!.paintExtent == 0 ||
        groupOfRow.isEmpty) {
      return;
    }
    // 下一个二级标题碰到吸顶条二级行的顶部时才换分组；在那之前先把旧行顶出去。
    final threshold = constraints.scrollOffset +
        math.max(0, constraints.overlap - _headerExtent);
    var child = firstChild;
    var index = groupOfRow[indexOf(child!)];
    var pushOffset = 0.0;
    while (child != null) {
      final row = indexOf(child);
      final offset =
          (child.parentData! as SliverMultiBoxAdaptorParentData).layoutOffset!;
      if (offset <= threshold) {
        index = groupOfRow[row];
      } else if (groupStarts.contains(row)) {
        pushOffset = math.max(
          -_rangeRowExtent,
          math.min(0.0, offset - threshold - _buildingRowExtent),
        );
        break;
      }
      child = childAfter(child);
    }
    onViewport((index: index, pushOffset: pushOffset));
  }
}

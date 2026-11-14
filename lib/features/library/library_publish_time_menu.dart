import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/models/library_book_item.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/date_range_picker.dart';

/// 搜索图书页右上角“出版/发行时间”筛选弹窗：
/// 完全参照校园卡历史记录 `_chooseTime` 的 `showGeneralDialog` 菜单 + `showShuYoDateRangePicker` 日期范围选择器实现。
Future<LibraryPublishTimeFilter?> showLibraryPublishTimeMenu(
  BuildContext context, {
  required LibraryPublishTimeFilter selectedFilter,
}) async {
  final preset = await showGeneralDialog<LibraryPublishTimePreset>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭出版时间筛选',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (context, animation, secondaryAnimation) {
      final colors = context.shuyoColors;
      final size = MediaQuery.sizeOf(context);
      return SafeArea(
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(top: kToolbarHeight + 8, right: 12),
            child: SizedBox(
              width: math.min(264, size.width * .68),
              child: Material(
                key: const ValueKey('library-publish-time-menu'),
                elevation: 12,
                color: colors.surface,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: size.height * .72),
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      for (final option in LibraryPublishTimePreset.values)
                        ListTile(
                          key: ValueKey(
                            'library-publish-time-option:${option.name}',
                          ),
                          selected: selectedFilter.preset == option,
                          title: Text(option.label),
                          onTap: () => Navigator.of(context).pop(option),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position:
            Tween(begin: const Offset(.18, 0), end: Offset.zero).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        ),
        child: child,
      ),
    ),
  );

  if (preset == null || !context.mounted) return null;
  if (preset == LibraryPublishTimePreset.all) {
    return const LibraryPublishTimeFilter.all();
  }
  if (preset != LibraryPublishTimePreset.custom) {
    return LibraryPublishTimeFilter.preset(preset);
  }

  final today = DateUtils.dateOnly(DateTime.now());
  final years = selectedFilter.resolveYears(now: today);
  final initialStartYear = int.tryParse(years.begin ?? '') ?? today.year - 1;
  final initialEndYear = int.tryParse(years.end ?? '') ?? today.year;
  final initialRange = DateTimeRange(
    start: DateTime(initialStartYear.clamp(1900, today.year)),
    end: DateTime(
      initialEndYear.clamp(1900, today.year),
      today.month,
      today.day,
    ),
  );

  final range = await showShuYoDateRangePicker(
    context: context,
    title: '自定义出版日期',
    firstDate: DateTime(1900),
    lastDate: today,
    initialRange: initialRange,
  );
  if (range == null || !context.mounted) return null;

  return LibraryPublishTimeFilter.custom(
    beginYear: range.start.year,
    endYear: range.end.year,
  );
}

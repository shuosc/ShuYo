import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/models/library_loan_item.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/date_range_picker.dart';

/// 借阅记录子页右上角时间筛选菜单：
/// 参照 `CampusCardHistoryPage._chooseTime` 与 `showLibraryPublishTimeMenu` 实现。
Future<LibraryLoanTimeFilter?> showLibraryLoanTimeMenu(
  BuildContext context, {
  required LibraryLoanTimeFilter selectedFilter,
  DateTime? now,
}) async {
  final preset = await showGeneralDialog<LibraryLoanTimePreset>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭借阅时间筛选',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (menuContext, animation, secondaryAnimation) {
      final colors = menuContext.shuyoColors;
      final size = MediaQuery.sizeOf(menuContext);
      return SafeArea(
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(top: kToolbarHeight + 8, right: 12),
            child: SizedBox(
              width: math.min(264, size.width * .68),
              child: Material(
                key: const ValueKey('library-loan-time-menu'),
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
                      for (final option in LibraryLoanTimePreset.values)
                        ListTile(
                          key: ValueKey('library-loan-time-${option.name}'),
                          selected: selectedFilter.preset == option,
                          title: Text(option.label),
                          onTap: () => Navigator.of(menuContext).pop(option),
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
        position: Tween(begin: const Offset(.18, 0), end: Offset.zero).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        ),
        child: child,
      ),
    ),
  );

  if (preset == null || !context.mounted) return null;
  if (preset == LibraryLoanTimePreset.all) {
    return const LibraryLoanTimeFilter.all();
  }
  if (preset != LibraryLoanTimePreset.custom) {
    return LibraryLoanTimeFilter.preset(preset);
  }

  final today = DateUtils.dateOnly((now ?? DateTime.now()).toLocal());
  final initialRange = selectedFilter.resolveRange(now: today) ??
      LibraryLoanTimeFilter.preset(LibraryLoanTimePreset.year)
          .resolveRange(now: today);
  final range = await showShuYoDateRangePicker(
    context: context,
    title: '自定义借阅日期',
    firstDate: DateTime(1900),
    lastDate: today,
    initialRange: initialRange,
  );
  if (range == null || !context.mounted) return null;
  return LibraryLoanTimeFilter.custom(range);
}

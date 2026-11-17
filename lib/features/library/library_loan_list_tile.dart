import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../data/models/library_loan_item.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/custom_background.dart';
import '../../shared/theme/shuyo_theme.dart';

/// 单条借阅记录列表项（首页「我的借阅」与历史子页共用）。
///
/// 对齐 [LibraryBookingListTile] 与校园卡消费行风格：不展示图书封面，
/// 左侧为书名 + 馆藏/时间子标题，右侧为语义状态（含图标）与进入箭头。
class LibraryLoanListTile extends StatefulWidget {
  const LibraryLoanListTile({
    super.key,
    required this.index,
    required this.loan,
    required this.onTap,
    this.animate = true,
    this.now,
  });

  final int index;
  final LibraryLoanItem loan;
  final VoidCallback? onTap;
  final bool animate;
  final DateTime? now;

  @override
  State<LibraryLoanListTile> createState() => _LibraryLoanListTileState();
}

class _LibraryLoanListTileState extends State<LibraryLoanListTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  Timer? _entranceTimer;
  bool _startedAnimation = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_startedAnimation) return;
    _startedAnimation = true;
    if (!widget.animate || MediaQuery.disableAnimationsOf(context)) {
      _entrance.value = 1;
      return;
    }
    _entranceTimer = Timer(
      Duration(milliseconds: (widget.index % 6) * 55),
      () {
        if (mounted) _entrance.forward();
      },
    );
  }

  @override
  void dispose() {
    _entranceTimer?.cancel();
    _entrance.dispose();
    super.dispose();
  }

  String _metaLine() {
    final parts = <String>[
      if (widget.loan.author != null && widget.loan.author!.isNotEmpty)
        widget.loan.author!,
      if (widget.loan.callNo != null && widget.loan.callNo!.isNotEmpty)
        widget.loan.callNo!,
      if (widget.loan.displayLocation != null) widget.loan.displayLocation!,
    ];
    return parts.join(' · ');
  }

  String _timeLine() {
    final loan = widget.loan;
    if (loan.isHistory) {
      final borrowDate = loan.loanDateText ?? '—';
      if (loan.returnDateText != null) {
        return '$borrowDate 借 · ${loan.returnDateText} 还';
      }
      return '借于 $borrowDate';
    }
    final parts = <String>[
      '借于 ${loan.loanDateText ?? '—'} · 应还 ${loan.dueDateText ?? '—'}',
      if (loan.canRenewAt(now: widget.now))
        '可续借'
      else if (loan.isRequested)
        '他人预约中',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final status = widget.loan.statusAt(now: widget.now);
    final statusLabel = widget.loan.statusLabel(now: widget.now);
    final statusVisual = libraryLoanStatusVisual(status, colors);
    final metaLine = _metaLine();
    final timeLine = _timeLine();

    final row = InkWell(
      onTap: widget.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.loan.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (metaLine.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        metaLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: colors.textTertiary),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      timeLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints:
                    BoxConstraints(maxWidth: constraints.maxWidth * 0.42),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (statusVisual.icon != null) ...[
                      Icon(
                        statusVisual.icon,
                        size: 15,
                        color: statusVisual.color,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        statusLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: statusVisual.color,
                              fontWeight: statusVisual.emphasized
                                  ? FontWeight.w600
                                  : null,
                            ),
                      ),
                    ),
                    if (widget.onTap != null) ...[
                      const SizedBox(width: 2),
                      Icon(
                        Icons.chevron_right,
                        color: statusVisual.emphasized
                            ? statusVisual.color
                            : colors.textMuted,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (!widget.animate) return row;

    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0.12, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic)),
      child: FadeTransition(
        opacity: _entrance,
        child: row,
      ),
    );
  }
}

/// 将借阅状态映射到主题语义色、字重和状态图标，确保不只靠颜色区分状态。
({Color color, IconData? icon, bool emphasized}) libraryLoanStatusVisual(
  LibraryLoanStatus status,
  ShuYoColors colors,
) =>
    switch (status) {
      LibraryLoanStatus.overdue => (
          color: colors.danger,
          icon: Icons.warning_amber_rounded,
          emphasized: true,
        ),
      LibraryLoanStatus.dueSoon => (
          color: colors.warning,
          icon: Icons.schedule,
          emphasized: true,
        ),
      LibraryLoanStatus.borrowed => (
          color: colors.accent,
          icon: Icons.auto_stories_outlined,
          emphasized: true,
        ),
      LibraryLoanStatus.returned => (
          color: colors.textSecondary,
          icon: Icons.check_circle_outline,
          emphasized: false,
        ),
    };

/// 借阅列表分隔线（自定义背景启用时隐藏分隔线，保持视觉呼吸感）。
class LibraryLoanSeparator extends StatelessWidget {
  const LibraryLoanSeparator({super.key});

  @override
  Widget build(BuildContext context) =>
      CustomBackgroundScope.maybeOf(context) != null
          ? const SizedBox.shrink()
          : Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              color: context.shuyoColors.border,
            );
}

/// 构建带「年月吸顶（SliverPersistentHeader）」的借阅记录分组 slivers。
///
/// 对齐 `campusCardBillSlivers`：要求调用方传入已按时间顺序排序的列表。
List<Widget> libraryLoanSlivers(
  List<LibraryLoanItem> loans, {
  required BuildContext context,
  required ValueChanged<LibraryLoanItem> onTapItem,
  int animationEpoch = 0,
  DateTime? now,
}) {
  final scaledFontSize = MediaQuery.textScalerOf(context).scale(12.5);
  final headerExtent = scaledFontSize > 12.5 ? scaledFontSize * 1.3 + 22 : 38.0;
  final groups = <({DateTime? month, List<LibraryLoanItem> items})>[];
  for (final item in loans) {
    final month = item.groupMonth;
    if (groups.isEmpty || groups.last.month != month) {
      groups.add((month: month, items: <LibraryLoanItem>[]));
    }
    groups.last.items.add(item);
  }

  final slivers = <Widget>[];
  var precedingCount = 0;
  for (final group in groups) {
    final firstIndex = precedingCount;
    precedingCount += group.items.length;
    final occurrenceCounts = <String, int>{};
    final keys = <ValueKey<String>>[
      for (final item in group.items)
        ValueKey<String>(
          '$animationEpoch:${item.stableKey}:${occurrenceCounts.update(item.stableKey, (v) => v + 1, ifAbsent: () => 0)}',
        ),
    ];
    final keyIndexes = {
      for (var i = 0; i < keys.length; i++) keys[i]: i,
    };

    slivers.add(
      SliverMainAxisGroup(
        key: ValueKey<DateTime?>(group.month),
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate:
                _LibraryLoanMonthHeaderDelegate(group.month, headerExtent),
          ),
          SliverList.separated(
            itemCount: group.items.length,
            findItemIndexCallback: (key) =>
                key is ValueKey<String> ? keyIndexes[key] : null,
            itemBuilder: (context, index) {
              final item = group.items[index];
              return LibraryLoanListTile(
                key: keys[index],
                index: firstIndex + index,
                loan: item,
                now: now,
                onTap: () => onTapItem(item),
              );
            },
            separatorBuilder: (context, index) => const LibraryLoanSeparator(),
          ),
        ],
      ),
    );
  }
  return slivers;
}

class _LibraryLoanMonthHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _LibraryLoanMonthHeaderDelegate(this.month, this.extent);

  final DateTime? month;
  final double extent;

  @override
  double get minExtent => maxExtent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) =>
      _LibraryLoanMonthHeader(
        month: month,
        overlapsContent: overlapsContent,
      );

  @override
  bool shouldRebuild(_LibraryLoanMonthHeaderDelegate oldDelegate) =>
      month != oldDelegate.month || extent != oldDelegate.extent;
}

class _LibraryLoanMonthHeader extends StatelessWidget {
  const _LibraryLoanMonthHeader({
    required this.month,
    required this.overlapsContent,
  });

  final DateTime? month;
  final bool overlapsContent;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final hasCustomBackground = CustomBackgroundScope.maybeOf(context) != null;
    final date = month;
    final label = date == null ? '日期未知' : '${date.year}年${date.month}月';
    final id = date == null
        ? 'unknown'
        : '${date.year}-${date.month.toString().padLeft(2, '0')}';

    final bgColor = hasCustomBackground
        ? (overlapsContent
            ? colors.surface.withValues(alpha: 0.92)
            : Colors.transparent)
        : Theme.of(context).scaffoldBackgroundColor;

    return Material(
      key: ValueKey('library-loan-month-$id'),
      color: bgColor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
        child: Text(
          label,
          style: ShuYoTextStyles.meta(
            color: colors.textSecondary,
            size: 12.5,
            weight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

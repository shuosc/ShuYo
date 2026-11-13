import 'package:material_ui/material_ui.dart';

import '../../data/models/course_review.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';

String rateScoreText(double? average) =>
    average == null ? '暂无评价' : average.toStringAsFixed(1);

/// Card surface shared by every course review screen: surface fill, 1px
/// border, radius 12.
class RateCard extends StatelessWidget {
  const RateCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(14),
    this.width,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return SizedBox(
      width: width,
      child: Material(
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Five stars for a 6.0–10.0 average, with half stars.
class RateStars extends StatelessWidget {
  const RateStars({super.key, required this.average, this.size = 14});

  final double? average;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final stars = average == null ? 0.0 : (average! - 5).clamp(0, 5);
    final rounded = (stars * 2).round() / 2;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(
            rounded >= i
                ? Icons.star_rounded
                : rounded >= i - 0.5
                    ? Icons.star_half_rounded
                    : Icons.star_outline_rounded,
            size: size,
            color: rounded >= i - 0.5 ? colors.accent : colors.borderStrong,
          ),
      ],
    );
  }
}

/// Score with review count, right-aligned in list rows.
class RateScoreTrailing extends StatelessWidget {
  const RateScoreTrailing(
      {super.key, required this.average, required this.count});

  final double? average;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    if (average == null) {
      return Text('暂无评价',
          style: ShuYoTextStyles.meta(color: colors.textTertiary));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          rateScoreText(average),
          style: ShuYoTextStyles.title(
              color: colors.textPrimary, size: 17, weight: FontWeight.w500),
        ),
        const SizedBox(height: 2),
        Text('$count 份评价',
            style:
                ShuYoTextStyles.meta(color: colors.textTertiary, size: 11.5)),
      ],
    );
  }
}

/// A list row inside a card: title, subtitle, and score.
class RateListTile extends StatelessWidget {
  const RateListTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.average,
    required this.count,
    this.badge,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final double? average;
  final int count;
  final String? badge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: ShuYoTextStyles.title(
                              color: colors.textPrimary, size: 15.5),
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 6),
                        RateTag(text: badge!),
                      ],
                    ],
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ShuYoTextStyles.meta(color: colors.textTertiary),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            RateScoreTrailing(average: average, count: count),
          ],
        ),
      ),
    );
  }
}

/// Rows separated by hairlines inside one card.
class RateListCard extends StatelessWidget {
  const RateListCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return RateCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                  height: 1, thickness: 1, color: colors.border, indent: 14),
            children[i],
          ],
        ],
      ),
    );
  }
}

class RateTag extends StatelessWidget {
  const RateTag({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text,
          style: ShuYoTextStyles.meta(color: colors.textSecondary, size: 11)),
    );
  }
}

class RateSectionTitle extends StatelessWidget {
  const RateSectionTitle({super.key, required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: Text(title,
                style: ShuYoTextStyles.title(
                    color: colors.textPrimary,
                    size: 15.5,
                    weight: FontWeight.w500)),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

class RateMoreButton extends StatelessWidget {
  const RateMoreButton(
      {super.key, required this.onPressed, this.label = '查看全部'});

  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 32),
        foregroundColor: colors.textSecondary,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: ShuYoTextStyles.meta(color: colors.textSecondary)),
          Icon(Icons.chevron_right, size: 16, color: colors.textSecondary),
        ],
      ),
    );
  }
}

/// A compact card for horizontal rows: course, teacher, score.
class RateUnitCard extends StatelessWidget {
  const RateUnitCard({
    super.key,
    required this.unit,
    required this.onTap,
    this.rank,
    this.width = 156,
  });

  final RateUnit unit;
  final VoidCallback onTap;
  final int? rank;
  final double width;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return RateCard(
      width: width,
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 40,
            child: Text(
              rank == null ? unit.course.name : '$rank  ${unit.course.name}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ShuYoTextStyles.title(
                  color: colors.textPrimary, size: 14.5, height: 1.35),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            unit.teacher.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ShuYoTextStyles.meta(color: colors.textSecondary),
          ),
          const Spacer(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                rateScoreText(unit.average),
                style: unit.average == null
                    ? ShuYoTextStyles.meta(color: colors.textTertiary)
                    : ShuYoTextStyles.title(
                        color: colors.textPrimary,
                        size: 18,
                        weight: FontWeight.w500),
              ),
              if (unit.average != null) ...[
                const SizedBox(width: 6),
                Text('${unit.reviewCount} 份',
                    style: ShuYoTextStyles.meta(
                        color: colors.textTertiary, size: 11.5)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// The underline search field used on the empty classroom page.
class RateSearchField extends StatefulWidget {
  const RateSearchField({
    super.key,
    this.controller,
    this.autofocus = false,
    this.readOnly = false,
    this.onTap,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController? controller;
  final bool autofocus;
  final bool readOnly;
  final VoidCallback? onTap;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<RateSearchField> createState() => _RateSearchFieldState();
}

class _RateSearchFieldState extends State<RateSearchField> {
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() => setState(() {});

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final focused = _focusNode.hasFocus;
    return Container(
      height: 52,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: focused ? colors.accent : colors.borderStrong,
            width: focused ? 1.5 : 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 12),
            child: Icon(Icons.search, size: 20, color: colors.textSecondary),
          ),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focusNode,
              autofocus: widget.autofocus,
              readOnly: widget.readOnly,
              onTap: widget.onTap,
              onTapOutside: (_) => _focusNode.unfocus(),
              decoration: const InputDecoration(
                hintText: '搜索课程、教师或课程号',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isCollapsed: true,
              ),
              textInputAction: TextInputAction.search,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
            ),
          ),
        ],
      ),
    );
  }
}

class RateLoadError extends StatelessWidget {
  const RateLoadError({super.key, required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.cloud_off_outlined,
      title: '加载失败',
      message: error?.toString() ?? '请稍后再试',
      action: TextButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh),
        label: const Text('重试'),
      ),
    );
  }
}

class RateFeedbackLink extends StatelessWidget {
  const RateFeedbackLink({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Center(
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(foregroundColor: colors.textTertiary),
        child: Text('信息有误？反馈给我们',
            style: ShuYoTextStyles.meta(color: colors.textTertiary)),
      ),
    );
  }
}

void showRateSnack(BuildContext context, String message,
    {SnackBarAction? action}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), action: action));
}

import 'package:material_ui/material_ui.dart';

import '../../data/models/course_review.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'rate_widgets.dart';

/// Large five-star picker for the overall question.
class RateOverallPicker extends StatelessWidget {
  const RateOverallPicker({
    super.key,
    required this.question,
    required this.value,
    required this.onChanged,
  });

  final RateQuestion question;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final label = value >= 1 && value <= question.options.length
        ? question.options[value - 1].label
        : '点击星星评分';
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var star = 1; star <= 5; star++)
              Semantics(
                button: true,
                selected: value == star,
                label: '$star 星',
                child: IconButton(
                  iconSize: 40,
                  onPressed: () => onChanged(star),
                  icon: Icon(
                    star <= value
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    color: star <= value ? colors.accent : colors.borderStrong,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(label,
            style: ShuYoTextStyles.body(
                color: value == 0 ? colors.textTertiary : colors.textPrimary,
                size: 15.5)),
        if (value > 0)
          Text('${value + 5} 分',
              style: ShuYoTextStyles.meta(color: colors.textTertiary)),
      ],
    );
  }
}

/// Two equal columns of options. Selecting changes only the border color
/// and the check icon; the cell keeps its size.
class RateOptionGrid extends StatelessWidget {
  const RateOptionGrid({
    super.key,
    required this.question,
    required this.selected,
    required this.onChanged,
  });

  final RateQuestion question;
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;

  void _toggle(BuildContext context, String key) {
    if (selected.contains(key)) {
      onChanged(selected.where((item) => item != key).toList());
      return;
    }
    if (question.multiple) {
      final limit = question.maxSelections;
      if (limit != null && selected.toSet().length >= limit) {
        showRateSnack(context, '最多选择$limit项');
        return;
      }
      onChanged([...selected, key]);
    } else {
      onChanged([key]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      const gap = 10.0;
      final width = (constraints.maxWidth - gap) / 2;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final option in question.options)
            SizedBox(
              width: width,
              height: 52,
              child: _OptionCell(
                label: option.label,
                selected: selected.contains(option.key),
                onTap: () => _toggle(context, option.key),
              ),
            ),
        ],
      );
    });
  }
}

class _OptionCell extends StatelessWidget {
  const _OptionCell({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          // Same width in both states so the cell never shifts.
          side: BorderSide(
              color: selected ? colors.accent : colors.border, width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            children: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: Text(
                    label,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: ShuYoTextStyles.bodyCompact(
                        color: colors.textPrimary, size: 14),
                  ),
                ),
              ),
              Positioned(
                top: 6,
                right: 6,
                child: Icon(
                  Icons.check_circle_rounded,
                  size: 16,
                  color: selected ? colors.accent : Colors.transparent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

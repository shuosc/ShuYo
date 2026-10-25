import 'package:flutter/material.dart';

import '../shuyo_text_styles.dart';
import '../theme/shuyo_theme.dart';

class ShuYoDatePickerDialog extends StatelessWidget {
  const ShuYoDatePickerDialog({
    super.key,
    required this.title,
    required this.child,
    required this.onConfirm,
    this.headerTrailing,
  });

  final String title;
  final Widget child;
  final VoidCallback? onConfirm;
  final Widget? headerTrailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxWidth: 400),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
                child: _header(context),
              ),
              child,
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: onConfirm,
                      child: const Text('确定'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final titleWidget = Text(
      title,
      style:
          ShuYoTextStyles.sectionTitle(color: context.shuyoColors.textPrimary),
    );
    final trailing = headerTrailing;
    if (trailing == null) return titleWidget;
    return Row(
      children: [
        Expanded(
          flex: 4,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: titleWidget,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 5,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerEnd,
            child: trailing,
          ),
        ),
      ],
    );
  }
}

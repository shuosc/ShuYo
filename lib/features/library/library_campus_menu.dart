import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/models/library_book_item.dart';

/// 仿“课程录播”学期筛选弹窗 UI 的校区筛选弹窗
Future<NewBookCampus?> showLibraryCampusMenu(
  BuildContext context, {
  required NewBookCampus selectedCampus,
}) {
  return showGeneralDialog<NewBookCampus>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭校区菜单',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 200),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.18, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        )),
        child: FadeTransition(opacity: animation, child: child),
      );
    },
    pageBuilder: (menuContext, animation, secondaryAnimation) => SafeArea(
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.only(top: kToolbarHeight + 8, right: 12),
          child: _LibraryCampusMenu(
            selectedCampus: selectedCampus,
            onSelect: (campus) => Navigator.of(menuContext).pop(campus),
          ),
        ),
      ),
    ),
  );
}

class _LibraryCampusMenu extends StatelessWidget {
  const _LibraryCampusMenu({
    required this.selectedCampus,
    required this.onSelect,
  });

  final NewBookCampus selectedCampus;
  final ValueChanged<NewBookCampus> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.colorScheme.surface;
    final primary = theme.colorScheme.primary;

    return SizedBox(
      key: const ValueKey('library-campus-menu'),
      width: math.min(220.0, MediaQuery.sizeOf(context).width * 0.6),
      child: Material(
        elevation: 12,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        color: surface,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            for (final campus in NewBookCampus.values)
              ListTile(
                key: ValueKey('library-campus-option:${campus.name}'),
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: Text(
                  campus.label,
                  style: TextStyle(
                    fontWeight: campus == selectedCampus
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: campus == selectedCampus ? primary : null,
                  ),
                ),
                trailing: campus == selectedCampus
                    ? Icon(Icons.check, color: primary, size: 20)
                    : null,
                onTap: () => onSelect(campus),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

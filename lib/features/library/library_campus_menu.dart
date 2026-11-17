import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../data/models/library_book_item.dart';
import '../../shared/theme/shuyo_theme.dart';

/// 右上角滑入式多选校区弹窗，样式对齐校园卡历史记录 / 课程录播右上角筛选菜单。
/// 支持实时切换勾选（或点击后直接返回最新选中集合），去掉 ALL。
Future<Set<LibraryCampusFilter>?> showLibraryCampusMenu(
  BuildContext context, {
  required Set<LibraryCampusFilter> selectedCampuses,
}) async {
  var latest = Set<LibraryCampusFilter>.of(selectedCampuses);
  var changed = false;

  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭校区菜单',
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
                key: const ValueKey('library-campus-menu'),
                elevation: 12,
                color: colors.surface,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: size.height * .72),
                  child: _LibraryCampusMenuBody(
                    initialSelected: latest,
                    onChanged: (next) {
                      latest = next;
                      changed = true;
                    },
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

  if (!changed) return null;
  if (latest.length == selectedCampuses.length &&
      latest.containsAll(selectedCampuses)) {
    return null;
  }
  return Set<LibraryCampusFilter>.unmodifiable(latest);
}

class _LibraryCampusMenuBody extends StatefulWidget {
  const _LibraryCampusMenuBody({
    required this.initialSelected,
    required this.onChanged,
  });

  final Set<LibraryCampusFilter> initialSelected;
  final ValueChanged<Set<LibraryCampusFilter>> onChanged;

  @override
  State<_LibraryCampusMenuBody> createState() => _LibraryCampusMenuBodyState();
}

class _LibraryCampusMenuBodyState extends State<_LibraryCampusMenuBody> {
  late final Set<LibraryCampusFilter> _selected = {
    ...widget.initialSelected,
  };

  void _toggle(LibraryCampusFilter campus) {
    setState(() {
      if (!_selected.add(campus)) {
        _selected.remove(campus);
      }
    });
    widget.onChanged(Set<LibraryCampusFilter>.of(_selected));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final campus in LibraryCampusFilter.values)
          CheckboxListTile(
            key: ValueKey('library-campus-option:${campus.name}'),
            controlAffinity: ListTileControlAffinity.trailing,
            value: _selected.contains(campus),
            selected: _selected.contains(campus),
            title: Text(campus.label),
            onChanged: (_) => _toggle(campus),
          ),
      ],
    );
  }
}

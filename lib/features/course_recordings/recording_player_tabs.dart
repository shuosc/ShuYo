import 'package:flutter/material.dart';

/// Compact introduction and notes tabs below the portrait player.
///
/// The layout and typography follow material titleSmall metrics with a 13px
/// font size, keeping the note count inline with the label.
class RecordingPlayerTabs extends StatelessWidget
    implements PreferredSizeWidget {
  const RecordingPlayerTabs({
    super.key,
    required this.controller,
    required this.noteCount,
  }) : assert(noteCount == null || noteCount >= 0);

  final TabController controller;

  /// Null until the number of notes has been established by a successful load.
  final int? noteCount;

  @override
  Size get preferredSize => const Size.fromHeight(45);

  /// Shared typography for the player tabs and the note detail title.
  static TextStyle labelStyleOf(BuildContext context) {
    final theme = Theme.of(context);
    // Use Material 3 titleSmall metrics at 13px so the inline count matches
    // the tab label weight and height.
    return (TabBarTheme.of(context).labelStyle ??
            Typography.dense2021.titleSmall!)
        .copyWith(
      fontSize: 13,
      fontFamily: theme.textTheme.titleSmall?.fontFamily,
      fontFamilyFallback: theme.textTheme.titleSmall?.fontFamilyFallback,
      inherit: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = labelStyleOf(context);
    return DecoratedBox(
      key: const ValueKey('recording-player-tabs'),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: theme.dividerColor.withValues(alpha: .1),
          ),
        ),
      ),
      child: SizedBox(
        height: preferredSize.height,
        child: Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 192),
            child: TabBar(
              controller: controller,
              padding: EdgeInsets.zero,
              labelPadding: EdgeInsets.zero,
              dividerHeight: 0,
              dividerColor: Colors.transparent,
              labelStyle: labelStyle,
              tabs: [
                const Tab(
                  child: Text(
                    '简介',
                    softWrap: false,
                    overflow: TextOverflow.visible,
                  ),
                ),
                Tab(
                  child: Text(
                    noteCount == null ? '笔记' : '笔记 $noteCount',
                    key: const ValueKey('recording-notes-tab-label'),
                    softWrap: false,
                    overflow: TextOverflow.visible,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

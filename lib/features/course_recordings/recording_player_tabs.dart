// Matches PiliPlus's GPL-3.0 video detail tab bar, using Flutter's public APIs:
// https://github.com/bggRGjQaUbCoE/PiliPlus/blob/main/lib/pages/video/view.dart
// See the repository LICENSE for the GNU General Public License, version 3.

import 'package:flutter/material.dart';

/// The compact introduction and notes tabs below the portrait player.
class RecordingPlayerTabs extends StatelessWidget
    implements PreferredSizeWidget {
  const RecordingPlayerTabs({
    super.key,
    required this.controller,
    required this.noteCount,
  }) : assert(noteCount >= 0);

  final TabController controller;
  final int noteCount;

  @override
  Size get preferredSize => const Size.fromHeight(45);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // PiliPlus uses the Material 3 titleSmall metrics with a 13-pixel override.
    // Its count is part of the same Text, rather than a smaller numeric badge.
    final labelStyle =
        (TabBarTheme.of(context).labelStyle ?? Typography.dense2021.titleSmall!)
            .copyWith(
      fontSize: 13,
      fontFamily: theme.textTheme.titleSmall?.fontFamily,
      fontFamilyFallback: theme.textTheme.titleSmall?.fontFamilyFallback,
      inherit: true,
    );
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
                    noteCount > 0 ? '笔记 $noteCount' : '笔记',
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

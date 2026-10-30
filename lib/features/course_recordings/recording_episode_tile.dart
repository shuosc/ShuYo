import 'package:flutter/material.dart';

import '../../data/models/course_recording.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'recording_episode_metadata.dart';
import 'recording_status_icon.dart';

class RecordingEpisodeTile extends StatelessWidget {
  const RecordingEpisodeTile({
    super.key,
    required this.tileKey,
    required this.lesson,
    required this.number,
    required this.selected,
    required this.onTap,
    this.dark = false,
  });

  final Key tileKey;
  final VodLesson lesson;
  final int number;
  final bool selected;
  final VoidCallback? onTap;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final primary = Theme.of(context).colorScheme.primary;
    final enabled = lesson.canPlay;
    final unavailableColor = dark ? Colors.white38 : colors.textMuted;
    final titleColor = !enabled
        ? unavailableColor
        : selected
            ? primary
            : dark
                ? Colors.white
                : colors.textPrimary;
    final secondaryColor = !enabled
        ? unavailableColor
        : dark
            ? Colors.white70
            : colors.textSecondary;
    final heading = recordingEpisodeHeading(lesson);
    final classroom = lesson.classroom.trim();
    final dateAndTime = recordingEpisodeDateTime(lesson);
    final status = lesson.isLive || !enabled ? lesson.statusLabel : null;
    return ListTile(
      key: tileKey,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      minLeadingWidth: 24,
      horizontalTitleGap: 12,
      selected: selected,
      enabled: enabled,
      selectedTileColor: primary.withValues(alpha: dark ? .2 : .08),
      leading: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          RecordingStatusIcon(
              isLive: lesson.isLive,
              enabled: enabled,
              disabledColor: unavailableColor),
          const SizedBox(width: 8),
          Semantics(
            label: '第 $number 集',
            excludeSemantics: true,
            child: Text('$number',
                style: ShuYoTextStyles.bodyCompact(
                    color: enabled ? primary : unavailableColor,
                    weight: FontWeight.w600)),
          ),
        ]),
      ),
      title: Text(heading.isEmpty ? '课次信息暂无' : heading,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: ShuYoTextStyles.bodyCompact(
              color: titleColor,
              weight: selected ? FontWeight.w600 : FontWeight.w400)),
      subtitle: classroom.isEmpty && dateAndTime.isEmpty
          ? null
          : Text.rich(
              TextSpan(children: [
                if (classroom.isNotEmpty)
                  TextSpan(
                      text: classroom,
                      style:
                          TextStyle(color: enabled ? primary : secondaryColor)),
                if (classroom.isNotEmpty && dateAndTime.isNotEmpty)
                  const TextSpan(text: ' · '),
                if (dateAndTime.isNotEmpty) TextSpan(text: dateAndTime),
              ]),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ShuYoTextStyles.meta(color: secondaryColor)),
      trailing: selected || status != null
          ? Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                  if (selected)
                    Text('当前', style: ShuYoTextStyles.meta(color: primary)),
                  if (status != null)
                    Text(status,
                        style: ShuYoTextStyles.meta(
                            color: enabled ? primary : secondaryColor)),
                ])
          : null,
      onTap: onTap,
    );
  }
}

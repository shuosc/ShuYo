import 'package:flutter/material.dart';

import '../../data/models/course_recording.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/course_color_label.dart';

class RecordingCourseTitle extends StatelessWidget {
  const RecordingCourseTitle({
    super.key,
    required this.course,
    this.maxNameLines,
    this.missingTeacherLabel,
    this.large = false,
    this.description,
    this.enabled = true,
  });

  final VodCourse course;
  final int? maxNameLines;
  final String? missingTeacherLabel;
  final bool large;
  final Widget? description;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final disabledColor = Theme.of(context).disabledColor;
    final titleColor = enabled ? colors.textPrimary : disabledColor;
    final metadataColor = enabled ? colors.textSecondary : disabledColor;
    final code = course.code.trim();
    final teacher = course.teacherLabel.trim();
    final metadata = [
      if (code.isNotEmpty) code,
      if (teacher.isNotEmpty)
        teacher
      else if (missingTeacherLabel != null)
        missingTeacherLabel!,
    ].join(' · ');
    final title = Text(course.name,
        style: large
            ? ShuYoTextStyles.pageTitle(color: titleColor)
            : ShuYoTextStyles.title(color: titleColor),
        maxLines: maxNameLines,
        overflow: maxNameLines == null ? null : TextOverflow.ellipsis);
    return CourseColorLabel(
      code: course.code,
      name: course.name,
      color: enabled ? null : disabledColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          title,
          if (metadata.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: large ? 4 : 2),
              child: Text(metadata,
                  style: ShuYoTextStyles.meta(
                      color: metadataColor, size: large ? 14 : 12.5),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
          if (description != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: description!,
            ),
        ],
      ),
    );
  }
}

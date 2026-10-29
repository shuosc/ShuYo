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
  });

  final VodCourse course;
  final int? maxNameLines;
  final String? missingTeacherLabel;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final code = course.code.trim();
    final teacher = course.teacherLabel.trim();
    final metadata = [
      if (code.isNotEmpty) code,
      if (teacher.isNotEmpty)
        teacher
      else if (missingTeacherLabel != null)
        missingTeacherLabel!,
    ].join(' · ');
    return CourseColorLabel(
      code: course.code,
      name: course.name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(course.name,
              style: large
                  ? ShuYoTextStyles.pageTitle(color: colors.textPrimary)
                  : ShuYoTextStyles.title(color: colors.textPrimary),
              maxLines: maxNameLines,
              overflow: maxNameLines == null ? null : TextOverflow.ellipsis),
          if (metadata.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: large ? 4 : 2),
              child: Text(metadata,
                  style: ShuYoTextStyles.meta(
                      color: colors.textSecondary, size: large ? 14 : 12.5),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
    );
  }
}

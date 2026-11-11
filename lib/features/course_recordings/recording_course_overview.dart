import 'package:flutter/material.dart';

import '../../data/models/course_recording.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'recording_course_schedule.dart';

export 'recording_course_schedule.dart';

const _weekdays = {
  DateTime.monday: '周一',
  DateTime.tuesday: '周二',
  DateTime.wednesday: '周三',
  DateTime.thursday: '周四',
  DateTime.friday: '周五',
};

class RecordingCourseOverview extends StatelessWidget {
  const RecordingCourseOverview({
    super.key,
    required this.days,
    this.term,
  });

  final List<RecordingCourseDay> days;
  final VodTerm? term;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      key: const ValueKey('recording-course-overview'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(key: const ValueKey('recording-course-overview-header'), children: [
          Text('概览',
              style: ShuYoTextStyles.sectionTitle(color: colors.textPrimary)),
          if (term case final selectedTerm?) ...[
            const SizedBox(width: 12),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text.rich(
                  key: const ValueKey('recording-course-overview-term'),
                  TextSpan(children: [
                    if (selectedTerm.academicYear.isEmpty)
                      TextSpan(text: selectedTerm.name)
                    else ...[
                      TextSpan(text: '${selectedTerm.academicYear} 学年 '),
                      TextSpan(
                        text: selectedTerm.seasonLabel,
                        style: TextStyle(color: primary),
                      ),
                    ],
                  ]),
                  maxLines: 1,
                  style: ShuYoTextStyles.bodyCompact(color: colors.textPrimary)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ]),
        const SizedBox(height: 12),
        Row(key: const ValueKey('recording-course-overview-times'), children: [
          const SizedBox(width: 40),
          for (var block = 0; block < 6; block++)
            Expanded(
                child: Padding(
              padding: EdgeInsets.only(right: block < 5 ? 4 : 0),
              child: Text('${block * 2 + 1}–${block * 2 + 2}',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: colors.textSecondary)),
            )),
        ]),
        for (final day in days)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              SizedBox(
                  width: 40,
                  child: Text(_weekdays[day.weekday]!,
                      style: TextStyle(
                          fontSize: 12, color: colors.textSecondary))),
              for (var block = 0; block < 6; block++)
                Expanded(
                    child: Padding(
                  padding: EdgeInsets.only(right: block < 5 ? 4 : 0),
                  child: Container(
                    key:
                        ValueKey('recording-course-slot-${day.weekday}-$block'),
                    height: 18,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                    ),
                    foregroundDecoration: BoxDecoration(
                      border: Border.all(color: colors.border),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Row(children: [
                      for (var half = 0; half < 2; half++)
                        Expanded(
                            child: Semantics(
                          label:
                              '${_weekdays[day.weekday]} 第${block * 2 + half + 1}节 ${day.sections.contains(block * 2 + half + 1) ? '有课' : '无课'}',
                          child: ColoredBox(
                            key: ValueKey(
                                'recording-course-section-${day.weekday}-${block * 2 + half + 1}'),
                            color: day.sections.contains(block * 2 + half + 1)
                                ? primary
                                : Colors.transparent,
                            child: const SizedBox.expand(),
                          ),
                        )),
                    ]),
                  ),
                )),
            ]),
          ),
      ],
    );
  }
}

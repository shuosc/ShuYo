import 'package:flutter/material.dart';

import '../../data/models/course_recording.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';

typedef RecordingCourseDay = ({int weekday, Set<int> sections});

const _weekdays = {
  DateTime.monday: '周一',
  DateTime.tuesday: '周二',
  DateTime.wednesday: '周三',
  DateTime.thursday: '周四',
  DateTime.friday: '周五',
};
final _sectionPattern =
    RegExp(r'^第?\s*(\d{1,2})(?:\s*[-–—~～至]\s*(\d{1,2}))?\s*节(?:课)?$');

List<RecordingCourseDay> recordingCourseDays(Iterable<VodLesson> lessons) {
  final days = <int, Set<int>>{};
  for (final lesson in lessons) {
    final begin = lesson.beginTime;
    final match = _sectionPattern.firstMatch(lesson.sectionLabel.trim());
    if (begin == null || match == null) continue;
    final first = int.parse(match[1]!);
    final last = int.parse(match[2] ?? match[1]!);
    if (first < 1 || last < first || last > 12) continue;
    final schoolDate =
        begin.isUtc ? begin.add(const Duration(hours: 8)) : begin;
    if (schoolDate.weekday > DateTime.friday) continue;
    final sections = days.putIfAbsent(schoolDate.weekday, () => <int>{});
    for (var section = first; section <= last; section++) {
      sections.add(section);
    }
  }
  final weekdays = days.keys.toList()..sort();
  return List.unmodifiable([
    for (final weekday in weekdays)
      (weekday: weekday, sections: Set<int>.unmodifiable(days[weekday]!)),
  ]);
}

class RecordingCourseOverview extends StatelessWidget {
  const RecordingCourseOverview({super.key, required this.days});

  final List<RecordingCourseDay> days;

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
          SizedBox(
            width: 40,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text('概览',
                  style:
                      ShuYoTextStyles.sectionTitle(color: colors.textPrimary)),
            ),
          ),
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

import 'package:flutter/material.dart';

import '../../data/models/classroom.dart';
import '../../shared/theme/shuyo_theme.dart';

/// 教室当天课表。形态与空教室主页点开教室卡片时完全一致：
/// 教室名 + 全名，接着是「X-Y节空闲 / 已有安排」，最后列出当天所有课程。
Future<void> showClassroomRoomSheet(
  BuildContext context, {
  required ClassroomRoom room,
  required int startSection,
  required int endSection,
}) {
  final selectedCourses = room.coursesFor(startSection, endSection);
  final courses = [...room.courses]
    ..sort((a, b) => a.startSection.compareTo(b.startSection));
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      final colors = sheetContext.shuyoColors;
      return SafeArea(
        top: false,
        bottom: false,
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            20 + MediaQuery.of(sheetContext).viewPadding.bottom,
          ),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                room.name,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (room.fullName.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  room.fullName,
                  style: TextStyle(color: colors.textTertiary),
                ),
              ],
              const SizedBox(height: 14),
              Text(
                selectedCourses.isEmpty
                    ? '$startSection-$endSection节空闲'
                    : '$startSection-$endSection节已有安排',
                style: TextStyle(
                  color: colors.accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              if (courses.isEmpty)
                Text(
                  '当天没有课程安排',
                  style: TextStyle(color: colors.textSecondary),
                )
              else
                for (final course in courses)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: Text(
                      '${course.sectionText} · ${course.courseName}'
                      '${course.teacherName.isEmpty ? '' : ' · ${course.teacherName}'}',
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 14.5,
                        height: 1.46,
                      ),
                    ),
                  ),
            ],
          ),
        ),
      );
    },
  );
}

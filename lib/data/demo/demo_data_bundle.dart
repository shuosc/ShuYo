import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/academic_schedule.dart';
import '../models/announcement.dart';
import '../models/classroom.dart';
import '../models/common.dart';
import '../services/classroom_api_client.dart';

/// All data used by the App Store demo is loaded from bundled assets.
///
/// This class deliberately does not expose any HTTP client. Keeping the demo
/// data in one immutable bundle makes it harder for a demo-only code path to
/// accidentally fall back to a live repository.
class DemoDataBundle {
  const DemoDataBundle({
    required this.schedule,
    required this.announcements,
    required this.announcementDetails,
    required this.classroomOptions,
    required this.classroomSchedule,
  });

  final AcademicSchedule schedule;
  final List<AnnouncementListItem> announcements;
  final Map<String, AnnouncementDetail> announcementDetails;
  final ClassroomSearchOptions classroomOptions;
  final ClassroomBuildingSchedule classroomSchedule;

  static final previewTime = DateTime(2026, 9, 1, 7, 55);

  static Future<DemoDataBundle> load({AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;
    final schedule = AcademicScheduleParser.parse(
      await _json(assets, 'assets/demo/academic/schedule.raw.json'),
      fetchedAt: DateTime(2026, 9, 1),
    );

    final announcementJson =
        await _json(assets, 'assets/demo/announcements/announcements.json');
    final announcementItems = (announcementJson['items'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((item) => AnnouncementListItem.fromJson(item))
        .toList(growable: false);
    final details = <String, AnnouncementDetail>{};
    for (final item in announcementJson['items'] as List? ?? const []) {
      if (item is! Map<String, dynamic>) continue;
      final detail = item['detail'];
      if (detail is! Map<String, dynamic>) continue;
      final blocks = (detail['blocks'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(AnnouncementContentBlock.fromJson)
          .toList(growable: false);
      details[item['title']?.toString() ?? ''] = AnnouncementDetail(
        title: item['title']?.toString() ?? '',
        url: item['url']?.toString() ?? '',
        dateText: item['dateText']?.toString() ?? '',
        publishedAt: dateValue(item['publishedAt']),
        author: stringValue(detail['author']),
        department: stringValue(detail['department']),
        blocks: blocks,
      );
    }

    final classroomRaw = await Future.wait([
      _json(assets, 'assets/demo/classroom/options.json'),
      _json(assets, 'assets/demo/classroom/sections.json'),
    ]);
    final classroomOptions = ClassroomApiClient.parseSearchOptions(
      classroomRaw[0],
      classroomRaw[1],
    );
    final building = classroomOptions.buildings.firstWhere(
      (item) => item.name == 'GA楼',
      orElse: () => classroomOptions.buildings.first,
    );
    final classroomSchedule = ClassroomApiClient.parseBuildingSchedule(
      await _json(assets, 'assets/demo/classroom/schedule-2026-09-01.json'),
      building: building,
    );

    return DemoDataBundle(
      schedule: schedule,
      announcements: announcementItems,
      announcementDetails: details,
      classroomOptions: ClassroomSearchOptions(
        buildings: [building],
        sections: classroomOptions.sections,
        currentSection: classroomOptions.currentSection,
      ),
      classroomSchedule: classroomSchedule,
    );
  }

  static Future<JsonMap> _json(AssetBundle bundle, String path) async {
    final decoded = jsonDecode(await bundle.loadString(path));
    if (decoded is! JsonMap) {
      throw FormatException('Invalid demo fixture: $path');
    }
    return decoded;
  }
}

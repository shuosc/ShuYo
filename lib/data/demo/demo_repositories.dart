import '../models/academic_schedule.dart';
import '../models/academic_progress.dart';
import '../models/academic_ranking.dart';
import '../models/academic_student_profile.dart';
import '../models/announcement.dart';
import '../models/announcement_source.dart';
import '../models/classroom.dart';
import '../models/otp_token.dart';
import '../repositories/academic_schedule_repository.dart';
import '../repositories/academic_progress_repository.dart';
import '../repositories/academic_ranking_repository.dart';
import '../repositories/academic_student_profile_repository.dart';
import '../repositories/announcement_repository.dart';
import '../repositories/classroom_repository.dart';
import '../repositories/otp_token_repository.dart';

class DemoAcademicScheduleRepository extends AcademicScheduleRepository {
  DemoAcademicScheduleRepository(this.schedule);

  final AcademicSchedule schedule;

  @override
  Future<AcademicSchedule?> loadCachedSchedule() async => schedule;

  @override
  Future<AcademicSchedule> refreshSchedule() async => schedule;

  @override
  Future<void> saveCachedSchedule(AcademicSchedule schedule) async {}
}

class DemoAcademicProgressRepository extends AcademicProgressRepository {
  DemoAcademicProgressRepository()
      : progress = AcademicProgress(
          studentId: 'DEMO0001',
          gpa: '3.65',
          plannedCourses: 40,
          passedCourses: 16,
          ongoingCourses: 5,
          notTakenCourses: 19,
          fetchedAt: DateTime(2026, 9, 1),
          nodes: const [
            AcademicProgressNode(
              id: 'demo-main',
              parentId: '',
              name: '主修',
              requiredCredits: 160,
              earnedCredits: 62,
              passed: false,
              courseKind: '',
              isLeaf: false,
            ),
            AcademicProgressNode(
              id: 'demo-basic',
              parentId: 'demo-main',
              name: '公共基础课程',
              requiredCredits: 72,
              earnedCredits: 36,
              passed: false,
              courseKind: '1',
              isLeaf: true,
              courses: [
                AcademicProgressCourse(
                  id: 'DEMO101',
                  code: 'DEMO101',
                  name: '大学英语',
                  status: '4',
                  credits: '2.0',
                  grade: '88',
                  gradePoint: '3.7',
                  academicYear: '2025-2026',
                  term: '秋',
                  suggestedYear: '2025-2026',
                  suggestedTerm: '秋',
                  nature: '公共基础课',
                  category: '',
                  hours: '理论(2.0)',
                ),
                AcademicProgressCourse(
                  id: 'DEMO102',
                  code: 'DEMO102',
                  name: '计算思维',
                  status: '1',
                  credits: '3.0',
                  grade: '',
                  gradePoint: '',
                  academicYear: '2026-2027',
                  term: '秋',
                  suggestedYear: '2026-2027',
                  suggestedTerm: '秋',
                  nature: '公共基础课',
                  category: '',
                  hours: '理论(2.0)-上机(1.0)',
                ),
                AcademicProgressCourse(
                  id: 'DEMO103',
                  code: 'DEMO103',
                  name: '程序设计基础',
                  status: '3',
                  credits: '3.0',
                  grade: '',
                  gradePoint: '',
                  academicYear: '',
                  term: '',
                  suggestedYear: '2027-2028',
                  suggestedTerm: '秋',
                  nature: '公共基础课',
                  category: '',
                  hours: '理论(2.0)-上机(1.0)',
                ),
              ],
            ),
            AcademicProgressNode(
              id: 'zgzsxx',
              parentId: '',
              name: '资格证书信息',
              requiredCredits: null,
              earnedCredits: null,
              passed: null,
              courseKind: 'certificate',
              isLeaf: true,
            ),
          ],
        );

  final AcademicProgress progress;

  @override
  Future<AcademicProgress?> loadCachedProgress() async => progress;

  @override
  Future<AcademicProgress> refreshProgress() async => progress;
}

class DemoAcademicRankingRepository extends AcademicRankingRepository {
  DemoAcademicRankingRepository()
      : ranking = AcademicRanking(
          studentId: 'DEMO0001',
          academicYear: '2026-2027',
          term: '秋',
          collegeName: '示例学院',
          majorName: '示例专业',
          collegeRank: 42,
          collegeCount: 260,
          majorRank: 12,
          majorCount: 80,
          fetchedAt: DateTime(2026, 9, 1),
        );

  final AcademicRanking ranking;

  @override
  Future<AcademicRanking?> loadCachedRanking() async => ranking;

  @override
  Future<AcademicRanking> refreshRanking() async => ranking;
}

class DemoAcademicStudentProfileRepository
    extends AcademicStudentProfileRepository {
  static const profile = AcademicStudentProfile(
    studentId: 'DEMO0001',
    studentName: '示例同学',
    grade: '2025',
    collegeName: '示例学院',
    majorName: '示例专业',
    academicLevel: '本科',
  );

  @override
  Future<AcademicStudentProfile?> loadCachedProfile() async => profile;

  @override
  Future<AcademicStudentProfile> refreshProfile() async => profile;
}

class DemoAnnouncementRepository extends AnnouncementRepository {
  DemoAnnouncementRepository({
    required this.items,
    required this.details,
  });

  final List<AnnouncementListItem> items;
  final Map<String, AnnouncementDetail> details;

  @override
  Future<List<AnnouncementListItem>> loadCachedAnnouncements({
    AnnouncementSource? source,
  }) async =>
      items;

  @override
  Future<AnnouncementSource> defaultSource() async =>
      AnnouncementSource.official;

  @override
  Future<void> setDefaultSource(AnnouncementSource source) async {}

  @override
  Future<List<AnnouncementListItem>> fetchAnnouncements(
          {AnnouncementSource? source, bool forceRefresh = false}) async =>
      items;

  @override
  Future<AnnouncementDetail> fetchDetail(AnnouncementListItem item) async =>
      details[item.title] ??
      AnnouncementDetail(title: item.title, url: item.url, blocks: const []);

  @override
  Future<String?> loadPreview(AnnouncementListItem item) async {
    if (item.summary.isNotEmpty) return item.summary;
    for (final block
        in details[item.title]?.blocks ?? const <AnnouncementContentBlock>[]) {
      if (block.isText && block.value.trim().isNotEmpty) {
        return block.value.trim();
      }
    }
    return null;
  }

  @override
  Future<AnnouncementHomeSummary> homeSummary() async => items.isEmpty
      ? const AnnouncementHomeSummary('点击查看通知公告')
      : AnnouncementHomeSummary(items.first.title);
}

class DemoClassroomRepository extends ClassroomRepository {
  DemoClassroomRepository({
    required this.options,
    required this.schedule,
  });

  final ClassroomSearchOptions options;
  final ClassroomBuildingSchedule schedule;

  @override
  ClassroomSearchOptions? get optionsSnapshot => options;

  @override
  Future<ClassroomSearchOptions> loadOptions(
          {bool forceRefresh = false}) async =>
      options;

  @override
  Future<ClassroomAvailabilityResult> search(ClassroomAvailabilityQuery query,
      {bool forceRefresh = false}) async {
    final supported = query.building.id == schedule.building.id &&
        query.date.year == 2026 &&
        query.date.month == 9 &&
        query.date.day == 1;
    if (!supported) {
      return ClassroomAvailabilityResult(
        building: query.building,
        date: query.date,
        startSection: query.startSection,
        endSection: query.endSection,
        floors: const [],
      );
    }
    final floors = schedule.floors.map((floor) {
      final available = floor.rooms
          .where((room) => room.isFreeFor(query.startSection, query.endSection))
          .toList(growable: false);
      return ClassroomFloorAvailability(
          floor: floor, rooms: floor.rooms, availableRooms: available);
    }).toList(growable: false);
    return ClassroomAvailabilityResult(
        building: query.building,
        date: query.date,
        startSection: query.startSection,
        endSection: query.endSection,
        floors: floors);
  }
}

class DemoOtpTokenRepository extends OtpTokenRepository {
  DemoOtpTokenRepository({DateTime Function()? now})
      : _now = now ?? DateTime.now;

  static const period = 30;

  final DateTime Function() _now;

  /// Keeps the same code for one rotation window and counts the window down,
  /// so the demo page behaves like the real one without hitting the network.
  @override
  Future<OtpToken> fetchToken() async {
    final now = _now();
    final rotation = now.millisecondsSinceEpoch ~/ (period * 1000);
    final remaining = period - (now.millisecondsSinceEpoch ~/ 1000) % period;
    return OtpToken(
      code: (rotation % 1000000).toString().padLeft(6, '0'),
      account: 'DEMO0001',
      remaining: remaining,
      period: period,
    );
  }
}

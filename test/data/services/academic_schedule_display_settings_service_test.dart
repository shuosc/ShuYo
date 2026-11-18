import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/academic_schedule.dart';
import 'package:shuyo/data/services/academic_schedule_display_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('schedule display settings use expected defaults', () async {
    final service = AcademicScheduleDisplaySettingsService();

    final settings = await service.loadSettings();

    expect(settings.colorful, isTrue);
    expect(settings.showTeacher, isTrue);
    expect(settings.showCredit, isFalse);
    expect(settings.showNote, isFalse);
    expect(settings.showNonCurrentWeekCourses, isTrue);
  });

  test('schedule display settings are persisted', () async {
    final service = AcademicScheduleDisplaySettingsService();

    await service.saveSettings(
      const AcademicScheduleDisplaySettings(
        colorful: false,
        showTeacher: false,
        showCredit: true,
        showNote: true,
        showNonCurrentWeekCourses: false,
      ),
    );
    final settings = await service.loadSettings();

    expect(settings.colorful, isFalse);
    expect(settings.showTeacher, isFalse);
    expect(settings.showCredit, isTrue);
    expect(settings.showNote, isTrue);
    expect(settings.showNonCurrentWeekCourses, isFalse);
  });

  test('the same course code keeps separate colors by account and term',
      () async {
    final service = AcademicScheduleDisplaySettingsService();
    final autumn = _term();
    final winter = _term(termCode: '12');

    await service.saveCourseColor(autumn, 'CS101', 0xFF6C96CA);
    await service.saveCourseColors(winter, {'CS101': 0xFF4A826D});

    expect(await service.loadCourseColors(autumn), {'CS101': 0xFF6C96CA});
    expect(await service.loadCourseColors(winter), {'CS101': 0xFF4A826D});
    expect(await service.loadCourseColors(_term(yearCode: '2025')), isEmpty);
    expect(await service.loadCourseColors(_term(studentId: 'other')), isEmpty);
  });

  test('editing one term preserves legacy colors for untouched terms',
      () async {
    const legacy = {'CS101': 0xFF6C96CA, 'CS102': 0xFF4A826D};
    SharedPreferences.setMockInitialValues({
      'academic.schedule.display.courseColors': jsonEncode(legacy),
    });
    final service = AcademicScheduleDisplaySettingsService();
    final autumn = _term();
    final winter = _term(termCode: '12');

    expect((await service.loadState(term: autumn)).courseColorValues, legacy);
    await service.saveCourseColor(autumn, 'CS101', 0xFF8877CC);

    expect(await service.loadCourseColors(autumn), {
      ...legacy,
      'CS101': 0xFF8877CC,
    });
    expect(await service.loadCourseColors(winter), legacy);
    expect((await service.loadState()).courseColorValues, legacy);
  });

  test('demo colors do not override campus colors for the same term', () async {
    final term = _term();
    final campus = AcademicScheduleDisplaySettingsService();
    final demo = AcademicScheduleDisplaySettingsService(scope: 'demo');

    await campus.saveCourseColor(term, 'CS101', 0xFF6C96CA);
    await demo.saveCourseColor(term, 'CS101', 0xFF4A826D);

    expect(await campus.loadCourseColors(term), {'CS101': 0xFF6C96CA});
    expect(await demo.loadCourseColors(term), {'CS101': 0xFF4A826D});
  });
}

AcademicTerm _term({
  String yearCode = '2026',
  String termCode = '3',
  String studentId = 'student',
}) =>
    AcademicTerm(
      yearCode: yearCode,
      termCode: termCode,
      academicYearName: '',
      termName: '',
      studentName: '',
      studentId: studentId,
      className: '',
    );

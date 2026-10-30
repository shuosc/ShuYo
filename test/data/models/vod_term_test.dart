import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';

void main() {
  for (final year in ['2023-2024', '2024-2025']) {
    test('$year uses the historical four-term seasons and teaching weeks', () {
      final terms = [
        for (var number = 1; number <= 4; number++)
          VodTerm(
            id: number,
            name: '第$number学期',
            academicYear: year,
            termNumber: number,
          ),
      ];
      expect(terms.map((term) => term.seasonLabel),
          ['秋季学期', '冬季学期', '春季学期', '夏季学期']);
      expect(terms.map((term) => term.teachingWeekCount), [10, 10, 10, null]);
    });
  }

  for (final year in ['2025-2026', '2026-2027']) {
    test('$year keeps the current three-term seasons and teaching weeks', () {
      final terms = [
        for (var number = 1; number <= 4; number++)
          VodTerm(
            id: number,
            name: '第$number学期',
            academicYear: year,
            termNumber: number,
          ),
      ];
      expect(terms.map((term) => term.seasonLabel),
          ['秋季学期', '春季学期', '夏季学期', '第4学期']);
      expect(terms.map((term) => term.teachingWeekCount), [16, 16, null, null]);
    });
  }

  test('unknown years retain the existing season fallback', () {
    for (final year in ['', '未知学年']) {
      expect(
        VodTerm(id: 2, name: '第二学期', academicYear: year, termNumber: 2)
            .seasonLabel,
        '春季学期',
      );
    }
    for (final year in ['2024-2025', '2025-2026']) {
      for (final number in [-1, 0, 5]) {
        final term = VodTerm(
          id: number,
          name: '其他学期',
          academicYear: year,
          termNumber: number,
        );
        expect(term.seasonLabel, '其他学期');
        expect(term.teachingWeekCount, isNull);
      }
    }
  });

  test('unknown academic years never infer teaching week counts', () {
    for (final year in ['', ' ', '未知学年', 'unknown-2025']) {
      for (final number in [-1, 0, 1, 2, 3, 4, 5]) {
        expect(
          VodTerm(
            id: number,
            name: '其他学期',
            academicYear: year,
            termNumber: number,
          ).teachingWeekCount,
          isNull,
        );
      }
    }
  });

  test('direct academic years trim before selecting the term scheme', () {
    const historical = VodTerm(
      id: 42,
      name: '第二学期',
      academicYear: ' \t2024-2025 \n',
      termNumber: 2,
    );
    const current = VodTerm(
      id: 52,
      name: '第二学期',
      academicYear: ' \t2025-2026 \n',
      termNumber: 2,
    );
    expect(historical.seasonLabel, '冬季学期');
    expect(historical.teachingWeekCount, 10);
    expect(current.seasonLabel, '春季学期');
    expect(current.teachingWeekCount, 16);
  });

  test('JSON academic years select the correct side of the scheme boundary',
      () {
    final historical = VodTerm.fromJson({
      'id': 42,
      'acyeCode': ' 2024-2025 ',
      'acteTerm': 2,
    });
    final current = VodTerm.fromJson({
      'id': 52,
      'acyeCode': '2025-2026',
      'acteTerm': 2,
    });
    expect(historical.academicYear, '2024-2025');
    expect(historical.seasonLabel, '冬季学期');
    expect(historical.teachingWeekCount, 10);
    expect(historical.academicYearLabel, '24-25学年');
    expect(current.seasonLabel, '春季学期');
    expect(current.teachingWeekCount, 16);
  });
}

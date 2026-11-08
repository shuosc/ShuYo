import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/shared/time_format.dart';

void main() {
  group('TimeFormat.relativeDate', () {
    final now = DateTime(2026, 11, 8, 12);
    const relativeCases = [
      (Duration.zero, '刚刚'),
      (Duration(seconds: 59), '刚刚'),
      (Duration(minutes: 1), '1分钟前'),
      (Duration(minutes: 59, seconds: 59), '59分钟前'),
      (Duration(hours: 1), '1小时前'),
      (Duration(hours: 23, minutes: 59, seconds: 59), '23小时前'),
      (Duration(days: 1), '1天前'),
      (Duration(days: 6, hours: 23, minutes: 59, seconds: 59), '6天前'),
      (Duration(days: 7), '11月1日'),
      (Duration(days: 8), '10月31日'),
    ];
    for (final (age, expected) in relativeCases) {
      test('$age ago displays $expected', () {
        expect(TimeFormat.relativeDate(now.subtract(age), now: now), expected);
      });
    }

    test('clock skew never produces a negative relative time', () {
      expect(
          TimeFormat.relativeDate(now.add(const Duration(hours: 2)), now: now),
          '刚刚');
    });

    test('crossing New Year within one year still omits the year', () {
      expect(
          TimeFormat.relativeDate(DateTime(2025, 12, 10, 12),
              now: DateTime(2026, 1, 10, 12)),
          '12月10日');
    });

    test('just before one calendar year omits the year', () {
      expect(
          TimeFormat.relativeDate(DateTime(2025, 11, 8, 12, 0, 0, 0, 1),
              now: now),
          '11月8日');
    });

    test('at one calendar year includes the year', () {
      expect(TimeFormat.relativeDate(DateTime(2025, 11, 8, 12), now: now),
          '2025年11月8日');
    });

    test('older dates include the year', () {
      expect(
          TimeFormat.relativeDate(DateTime(2024, 9, 1), now: now), '2024年9月1日');
    });

    test('a leap day does not turn 365 days into a full calendar year', () {
      expect(
          TimeFormat.relativeDate(DateTime(2023, 3, 1, 12),
              now: DateTime(2024, 2, 29, 12)),
          '3月1日');
    });

    test('a leap-day anniversary falls on March 1 in a non-leap year', () {
      final syncedAt = DateTime(2024, 2, 29, 12);
      expect(TimeFormat.relativeDate(syncedAt, now: DateTime(2025, 2, 28, 12)),
          '2月29日');
      expect(TimeFormat.relativeDate(syncedAt, now: DateTime(2025, 3, 1, 12)),
          '2024年2月29日');
    });

    test('UTC timestamps use the local date', () {
      expect(
          TimeFormat.relativeDate(DateTime(2026, 10, 1, 0, 30).toUtc(),
              now: now.toUtc()),
          '10月1日');
    });
  });
}

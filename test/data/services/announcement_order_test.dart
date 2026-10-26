import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/services/announcement_order.dart';

AnnouncementListItem _item(String title, [DateTime? date]) =>
    AnnouncementListItem(
      title: title,
      url: 'https://example.org/$title',
      publishedAt: date,
    );

void main() {
  test('current external links retain their slots above dated history', () {
    final items = [
      _item('pinned old notice', DateTime(2020)),
      _item('current WeChat notice'),
      _item('new notice', DateTime(2026, 10, 26)),
      _item('current external attachment'),
      for (var year = 2025; year >= 2000; year--)
        _item('history $year', DateTime(year)),
    ];
    final ordered = orderAnnouncements(items);
    expect(ordered.take(4).map((item) => item.title), [
      'new notice',
      'current WeChat notice',
      'history 2025',
      'current external attachment',
    ]);
    expect(ordered, hasLength(items.length));
    expect(items.first.title, 'pinned old notice');
    expect(
        ordered.every((item) =>
            !item.title.startsWith('current') || item.publishedAt == null),
        isTrue);
  });

  test('known dates descend stably and repeated ordering is idempotent', () {
    final items = [
      _item('first same date', DateTime(2026, 10, 20)),
      _item('newest', DateTime(2026, 10, 26)),
      _item('second same date', DateTime(2026, 10, 20)),
    ];
    final ordered = orderAnnouncements(items);
    expect(ordered.map((item) => item.title),
        ['newest', 'first same date', 'second same date']);
    expect(orderAnnouncements(ordered), ordered);
  });

  test('an entirely undated page keeps every original link and its order', () {
    final items = [_item('first'), _item('second'), _item('third')];
    expect(orderAnnouncements(items), items);
    expect(orderAnnouncements(const []), isEmpty);
  });
}

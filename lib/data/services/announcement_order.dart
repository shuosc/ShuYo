import '../models/announcement.dart';

/// Sorts verified dates while retaining undated notices in their source slots.
///
/// An external link can be a current announcement without exposing a publication
/// date. Moving every undated item behind the dated cache hides such links below
/// years of history. Keep their positions and only sort the dated slots, without
/// inventing dates for ordering. Equal dates retain their original order.
List<AnnouncementListItem> orderAnnouncements(
    Iterable<AnnouncementListItem> items) {
  final sourceOrder = items.toList(growable: false);
  final dated = sourceOrder
      .asMap()
      .entries
      .where((entry) => entry.value.publishedAt != null)
      .toList();
  dated.sort((left, right) {
    final comparison =
        right.value.publishedAt!.compareTo(left.value.publishedAt!);
    return comparison != 0 ? comparison : left.key.compareTo(right.key);
  });
  var nextDated = 0;
  return [
    for (final item in sourceOrder)
      item.publishedAt == null ? item : dated[nextDated++].value,
  ];
}

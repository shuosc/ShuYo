import '../models/announcement.dart';

/// Estimates ordering dates for undated Film Academy links from their position
/// between dated entries in the original list. The visible date stays empty so
/// the estimate is never presented as a verified publication date.
List<AnnouncementListItem> inferFilmNoticeDates(
    List<AnnouncementListItem> sourceOrder) {
  final datedIndices = <int>[
    for (var index = 0; index < sourceOrder.length; index++)
      if (sourceOrder[index].dateText.isNotEmpty &&
          sourceOrder[index].publishedAt != null)
        index,
  ];
  if (datedIndices.isEmpty) return sourceOrder;

  final result = List<AnnouncementListItem>.of(sourceOrder);
  var nextDated = 0;
  for (var index = 0; index < result.length; index++) {
    final item = result[index];
    if (item.dateText.isNotEmpty) continue;
    while (nextDated < datedIndices.length && datedIndices[nextDated] < index) {
      nextDated++;
    }
    final previousIndex = nextDated > 0 ? datedIndices[nextDated - 1] : null;
    final followingIndex =
        nextDated < datedIndices.length ? datedIndices[nextDated] : null;
    final previousDate =
        previousIndex == null ? null : sourceOrder[previousIndex].publishedAt;
    final followingDate =
        followingIndex == null ? null : sourceOrder[followingIndex].publishedAt;

    DateTime? estimate;
    if (previousDate != null &&
        followingDate != null &&
        previousDate.isAfter(followingDate)) {
      final gap = previousDate.microsecondsSinceEpoch -
          followingDate.microsecondsSinceEpoch;
      final position = index - previousIndex!;
      final span = followingIndex! - previousIndex;
      estimate = DateTime.fromMicrosecondsSinceEpoch(
        previousDate.microsecondsSinceEpoch - gap * position ~/ span,
      );
    } else if (previousDate != null && followingDate != null) {
      // Pinned posts can make the known dates conflict with source order.
      // Keep an undated link close to the preceding item in that case.
      estimate = previousDate;
    } else if (previousDate != null) {
      estimate = previousDate.subtract(Duration(days: index - previousIndex!));
    } else if (followingDate != null) {
      estimate = followingDate.add(Duration(days: followingIndex! - index));
    }
    if (estimate == null || estimate == item.publishedAt) continue;
    result[index] = AnnouncementListItem(
      title: item.title,
      url: item.url,
      summary: item.summary,
      dateText: item.dateText,
      publishedAt: estimate,
      sourceId: item.sourceId,
      column: item.column,
    );
  }
  return result;
}

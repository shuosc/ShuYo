/// Matches literal search terms using offsets in the original article text.
RegExp? announcementSearchPattern(String query) {
  final seen = <String>{};
  final terms = query
      .trim()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty && seen.add(term.toLowerCase()))
      .toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  if (terms.isEmpty) return null;
  return RegExp(
    terms.map(RegExp.escape).join('|'),
    caseSensitive: false,
    unicode: true,
  );
}

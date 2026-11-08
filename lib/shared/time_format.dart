class TimeFormat {
  const TimeFormat._();

  static String compact(
    DateTime? value, {
    DateTime? now,
    bool relativeWithinDay = false,
  }) {
    if (value == null) {
      return '';
    }
    final local = value.toLocal();
    final current = (now ?? DateTime.now()).toLocal();
    final diff = current.difference(local);

    if (!diff.isNegative) {
      if (diff.inMinutes < 1) {
        return '刚刚';
      }
      if (diff.inHours < 1) {
        return '${diff.inMinutes}分钟前';
      }
      if (relativeWithinDay && diff.inHours < 24) {
        return '${diff.inHours}小时前';
      }
    }

    final time = '${_two(local.hour)}:${_two(local.minute)}';
    if (_sameDate(local, current)) {
      return time;
    }
    final date = local.year == current.year
        ? '${local.month}/${local.day}'
        : '${local.year}/${local.month}/${local.day}';
    return '$date $time';
  }

  /// Uses relative time for the past week and dates for older values.
  /// Dates at least one calendar year old include the year.
  static String relativeDate(DateTime value, {DateTime? now}) {
    final local = value.toLocal();
    final current = (now ?? DateTime.now()).toLocal();
    final diff = current.difference(local);

    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';

    final date = '${local.month}月${local.day}日';
    final anniversary = DateTime(
      local.year + 1,
      local.month,
      local.day,
      local.hour,
      local.minute,
      local.second,
      local.millisecond,
      local.microsecond,
    );
    return current.isBefore(anniversary) ? date : '${local.year}年$date';
  }

  static bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _two(int value) => value.toString().padLeft(2, '0');
}

/// Whether an earlier confirmation still covers another identical action.
///
/// Callers use this to avoid asking the same question over and over while the
/// user is still doing the same thing, e.g. re-rolling something a few times.
///
/// A clock that moved backwards counts as "not fresh", so the confirmation
/// errs on the side of being shown at least once.
bool isConfirmationFresh({
  required DateTime? confirmedAt,
  required DateTime now,
  required Duration window,
}) {
  if (confirmedAt == null) return false;
  final elapsed = now.difference(confirmedAt);
  return !elapsed.isNegative && elapsed < window;
}

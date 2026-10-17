/// A dynamic password read from the school token page
/// (`https://otp.shu.edu.cn/`).
///
/// The value is whatever the server rendered for this request; the app never
/// derives it from a seed, so the code it shows cannot drift from the one the
/// school expects.
class OtpToken {
  const OtpToken({
    required this.code,
    this.account = '',
    required this.remaining,
    required this.period,
  });

  /// The code the token page currently shows, as digits.
  final String code;

  /// Account name printed next to the code; empty when the page omits it.
  final String account;

  /// Seconds left in the rotation, as reported by the server response.
  final int remaining;

  /// Full rotation length in seconds.
  final int period;

  /// Code split as `xxx xxx`, which is easier to read out and to type back.
  String get groupedCode =>
      code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;
}

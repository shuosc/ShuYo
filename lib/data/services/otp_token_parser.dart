import '../models/otp_token.dart';

/// Parses the token page into an [OtpToken].
///
/// The page is an ASP.NET WebForms single page that renders the code into a
/// `<span>` (see the school POC for the live structure):
///
/// - code: `id="DataList1_LabelNum_0"`, e.g. `956370`;
/// - account: `id="DataList1_LabelAccount_0"`;
/// - remaining seconds: `Refresh` header *and* `let remainingSeconds = N;`;
/// - rotation period: `const totalSeconds = 30;`.
class OtpTokenParser {
  const OtpTokenParser._();

  /// Length of a valid code, in digits.
  static const codeLength = 6;

  /// Fallback rotation period used when the page does not state one.
  static const defaultPeriod = 30;

  /// The patterns accept either quote style and extra attributes, so a styling
  /// change on the school side does not break parsing.
  static final _codePattern =
      RegExp(r'''id=["']DataList1_LabelNum_\d+["'][^>]*>\s*(\d{4,8})\s*<''');
  static final _accountPattern =
      RegExp(r'''id=["']DataList1_LabelAccount_\d+["'][^>]*>\s*([^<]*?)\s*<''');
  static final _remainingScriptPattern =
      RegExp(r'let\s+remainingSeconds\s*=\s*(\d+)\s*;');
  static final _periodScriptPattern =
      RegExp(r'const\s+totalSeconds\s*=\s*(\d+)\s*;');

  /// Returns null when the code node is missing, which is what a session that
  /// fell back to the login guide looks like.
  ///
  /// [refreshHeader] is the `Refresh` response header value and wins over the
  /// inline script when both are present, matching the server behaviour
  /// observed on the live page.
  static OtpToken? parse(
    String html, {
    String? refreshHeader,
    int fallbackPeriod = defaultPeriod,
  }) {
    final code = _codePattern.firstMatch(html)?.group(1);
    if (code == null || code.length != codeLength) {
      return null;
    }

    final period =
        int.tryParse(_periodScriptPattern.firstMatch(html)?.group(1) ?? '') ??
            fallbackPeriod;
    final headerSeconds = int.tryParse((refreshHeader ?? '').trim());
    final scriptSeconds =
        int.tryParse(_remainingScriptPattern.firstMatch(html)?.group(1) ?? '');

    return OtpToken(
      code: code,
      account: _accountPattern.firstMatch(html)?.group(1)?.trim() ?? '',
      remaining: (headerSeconds ?? scriptSeconds ?? period).clamp(0, period),
      period: period,
    );
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/otp_token.dart';
import 'package:shuyo/data/services/otp_token_parser.dart';

const _page = '<html><body><div class="list">'
    '<span id="DataList1_LabelAccount_0" class="x">2512XXXX</span>'
    '<span id="DataList1_LabelNum_0" class="num">956370</span>'
    '<script>let remainingSeconds = 14; const totalSeconds = 30;</script>'
    '</div></body></html>';

void main() {
  test('parses the code, account, remaining seconds and period', () {
    final token = OtpTokenParser.parse(_page)!;

    expect(token.code, '956370');
    expect(token.account, '2512XXXX');
    expect(token.remaining, 14);
    expect(token.period, 30);
  });

  test('the Refresh header wins over the inline script', () {
    final token = OtpTokenParser.parse(_page, refreshHeader: '11')!;

    expect(token.remaining, 11);
  });

  test('falls back to the period when no countdown is reported', () {
    final html = '<span id="DataList1_LabelNum_0">685970</span>';

    final token = OtpTokenParser.parse(html, refreshHeader: 'not-a-number')!;

    expect(token.code, '685970');
    expect(token.account, '');
    expect(token.remaining, OtpTokenParser.defaultPeriod);
    expect(token.period, OtpTokenParser.defaultPeriod);
  });

  test('tolerates attribute order and quote style', () {
    final html = "<span id='DataList1_LabelNum_0' style='color:red'> 792919 "
        '</span>';

    expect(OtpTokenParser.parse(html)!.code, '792919');
  });

  test('returns null when the code node is missing', () {
    const loginGuide = '<html><body>请登录统一身份认证</body></html>';

    expect(OtpTokenParser.parse(loginGuide), isNull);
    expect(OtpTokenParser.parse(''), isNull);
  });

  test('rejects a code whose length is not six digits', () {
    final html = '<span id="DataList1_LabelNum_0">12345678</span>';

    expect(OtpTokenParser.parse(html), isNull);
  });

  test('groups a six-digit code for readability', () {
    const token = OtpToken(
      code: '956370',
      remaining: 30,
      period: 30,
    );

    expect(token.groupedCode, '956 370');
  });
}

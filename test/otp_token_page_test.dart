import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/otp_token.dart';
import 'package:shuyo/data/repositories/otp_token_repository.dart';
import 'package:shuyo/data/services/otp_token_api_client.dart';
import 'package:shuyo/features/home/otp_token_page.dart';

OtpToken _token({String code = '956370', int remaining = 30}) => OtpToken(
      code: code,
      account: '2512XXXX',
      remaining: remaining,
      period: 30,
    );

class _FakeRepository extends OtpTokenRepository {
  _FakeRepository({this.token, this.error});

  final OtpToken? token;
  final Object? error;
  int calls = 0;

  @override
  Future<OtpToken> fetchToken() async {
    calls++;
    if (error != null) throw error!;
    return token!;
  }
}

class _RotatingRepository extends OtpTokenRepository {
  int calls = 0;

  @override
  Future<OtpToken> fetchToken() async {
    calls++;
    return calls == 1 ? _token(remaining: 1) : _token(code: '685970');
  }
}

/// Serves one good read, then fails every time.
class _FlakyRepository extends OtpTokenRepository {
  int calls = 0;

  static const goodReads = 1;

  @override
  Future<OtpToken> fetchToken() async {
    calls++;
    if (calls > goodReads) {
      throw const OtpTokenException(
        OtpTokenException.networkError,
        '网络连接失败，请检查网络后重试',
      );
    }
    return _token();
  }
}

void main() {
  testWidgets('shows the code and copies it to the clipboard', (tester) async {
    final repository = _FakeRepository(token: _token());
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await tester.pumpWidget(
      MaterialApp(home: OtpTokenPage(repository: repository)),
    );
    await tester.pump();

    expect(find.text('956 370'), findsOneWidget);
    expect(find.textContaining('2512XXXX'), findsNothing);
    expect(find.textContaining('秒后自动更新'), findsOneWidget);

    await tester.tap(find.text('复制口令'));
    await tester.pump();

    expect(copied, ['956370']);
    expect(find.text('已复制动态口令'), findsOneWidget);
  });

  testWidgets('re-reads the code every second instead of counting down locally',
      (tester) async {
    final repository = _RotatingRepository();

    await tester.pumpWidget(
      MaterialApp(home: OtpTokenPage(repository: repository)),
    );
    await tester.pump();
    expect(find.text('956 370'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(repository.calls, greaterThanOrEqualTo(2));
    expect(find.text('685 970'), findsOneWidget);
    expect(find.text('956 370'), findsNothing);
  });

  testWidgets('one dropped read keeps the code and reports the reason',
      (tester) async {
    final repository = _FlakyRepository();

    await tester.pumpWidget(
      MaterialApp(home: OtpTokenPage(repository: repository)),
    );
    await tester.pump();
    expect(find.text('956 370'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(repository.calls, greaterThanOrEqualTo(2));
    // The code stays put and the reason arrives as one bar across the bottom.
    expect(find.text('956 370'), findsOneWidget);
    expect(find.text('网络连接失败，请检查网络后重试'), findsOneWidget);
    expect(find.text('复制口令'), findsOneWidget);
    expect(find.text('重新加载'), findsNothing);
  });

  testWidgets('a persistent failure keeps the last code instead of blanking it',
      (tester) async {
    final repository = _FlakyRepository();

    await tester.pumpWidget(
      MaterialApp(home: OtpTokenPage(repository: repository)),
    );
    await tester.pump();

    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    }

    expect(find.text('956 370'), findsOneWidget);
    expect(find.text('网络连接失败，请检查网络后重试'), findsOneWidget);
    expect(find.text('复制口令'), findsOneWidget);
    expect(find.text('重新加载'), findsNothing);
  });

  testWidgets('polling stops in the background and resumes immediately',
      (tester) async {
    final repository = _FakeRepository(token: _token());

    await tester.pumpWidget(
      MaterialApp(home: OtpTokenPage(repository: repository)),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final whileVisible = repository.calls;
    expect(whileVisible, greaterThanOrEqualTo(2));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 5));
    expect(repository.calls, whileVisible);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(repository.calls, whileVisible + 1);
  });

  testWidgets('an expired campus session asks for a new login', (tester) async {
    final repository = _FakeRepository(
      error: const OtpTokenException(
        OtpTokenException.sessionNotReused,
        '会话失效',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(home: OtpTokenPage(repository: repository)),
    );
    await tester.pump();

    expect(find.text('校园登录状态已失效，请回到首页重新登录后再试。'), findsOneWidget);
    expect(find.text('复制口令'), findsNothing);
    expect(find.text('重新加载'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('a rejected WebVPN token asks the shell to recover the session',
      (tester) async {
    final repository = _FakeRepository(
      error: const OtpTokenException(
        OtpTokenException.webVpnLoginRequired,
        'WebVPN登录已失效',
      ),
    );
    var recoveries = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: OtpTokenPage(
          repository: repository,
          onWebVpnExpired: () async => recoveries++,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('WebVPN 连接已失效，请在账号管理里恢复后重试。'), findsOneWidget);
    expect(recoveries, 1);
  });

  testWidgets('other failures never request WebVPN recovery', (tester) async {
    final repository = _FakeRepository(
      error: const OtpTokenException(
        OtpTokenException.networkError,
        '网络连接失败',
      ),
    );
    var recoveries = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: OtpTokenPage(
          repository: repository,
          onWebVpnExpired: () async => recoveries++,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('网络连接失败'), findsOneWidget);
    expect(recoveries, 0);
  });

  testWidgets('a failed read reports the reason without a retry control',
      (tester) async {
    final repository = _FakeRepository(
      error: const OtpTokenException('networkError', '网络连接失败，请检查网络后重试'),
    );

    await tester.pumpWidget(
      MaterialApp(home: OtpTokenPage(repository: repository)),
    );
    await tester.pump();

    // The reason is a bar across the bottom, not page content, and recovering
    // is the page's own job: polling simply keeps trying.
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('网络连接失败，请检查网络后重试'), findsOneWidget);
    expect(find.text('重新加载'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(repository.calls, 2);
  });
}

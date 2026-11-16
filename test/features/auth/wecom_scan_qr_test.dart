import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shuyo/core/wecom_constants.dart';
import 'package:shuyo/data/services/wecom_auth_service.dart';
import 'package:shuyo/features/auth/wecom_scan_page.dart';

const _session = WeComQrSession(
  key: 'test-session',
  confirmUrl: 'https://example.invalid/confirm?k=test-session',
  wxWorkSchemeUrl: 'wxwork://test',
);

class _WaitingWeComAuthService extends WeComAuthService {
  final result = Completer<WeComScanResult>();

  @override
  Future<WeComScanResult> waitForScan(
    String key, {
    Duration timeout = WeComAuthService.scanTimeout,
    void Function(WeComScanStatus status)? onStatusChanged,
    bool Function()? isCancelled,
  }) =>
      result.future;
}

void main() {
  testWidgets('generates the confirmation QR locally without a network image',
      (tester) async {
    final service = _WaitingWeComAuthService();
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      home: WeComScanPage(
        session: _session,
        authService: service,
        target: WeComOAuthTarget.academic,
      ),
    ));
    await tester.pump();

    final qr = tester.widget<QrImageView>(find.byType(QrImageView));
    final paint = tester.widget<CustomPaint>(find.descendant(
      of: find.byType(QrImageView),
      matching: find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is QrPainter,
      ),
    ));
    final expected = QrPainter(
      data: _session.confirmUrl,
      version: qr.version,
      errorCorrectionLevel: qr.errorCorrectionLevel,
      gapless: qr.gapless,
      eyeStyle: qr.eyeStyle,
      dataModuleStyle: qr.dataModuleStyle,
    );
    await tester.runAsync(() async {
      final actual = await (paint.painter! as QrPainter).toImageData(180);
      final want = await expected.toImageData(180);
      expect(actual!.buffer.asUint8List(), want!.buffer.asUint8List());
    });
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    service.result.complete(const WeComScanResult.expired());
    await tester.pump();
  });

  for (final (name, finish, message) in [
    (
      'polling failure returns and shows an error SnackBar',
      (Completer<WeComScanResult> result) =>
          result.completeError(StateError('test poll error')),
      '无法连接企业微信服务，请稍后再试',
    ),
    (
      'expiration returns with a notice',
      (Completer<WeComScanResult> result) =>
          result.complete(const WeComScanResult.expired()),
      '二维码已过期或已取消，请重新尝试',
    ),
  ]) {
    testWidgets(name, (tester) async {
      final service = _WaitingWeComAuthService();
      addTearDown(service.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => WeComScanPage(
                    session: _session,
                    authService: service,
                    target: WeComOAuthTarget.academic,
                  ),
                ),
              ),
              child: const Text('进入扫码页'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('进入扫码页'));
      await tester.pumpAndSettle();
      finish(service.result);
      await tester.pumpAndSettle();
      expect(find.byType(WeComScanPage), findsNothing);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(message),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shuyo/features/settings/recommend_shuyo_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

const _androidUrl = 'https://download.shuyo.work/latest.apk';
const _testFlightUrl = 'https://testflight.apple.com/join/aENUC3G3';

void main() {
  testWidgets('platform tabs show the matching QR code and installation link',
      (tester) async {
    await _pumpPage(tester);

    expect(find.byIcon(Icons.android), findsOneWidget);
    expect(find.byIcon(Icons.apple), findsOneWidget);
    expect(_qrImage(_androidUrl), findsOneWidget);
    expect(_qrImage(_testFlightUrl), findsNothing);
    expect(
        tester
            .widget<QrImageView>(_qrImage(_androidUrl))
            .dataModuleStyle
            .dataModuleShape,
        QrDataModuleShape.circle);
    expect(find.widgetWithText(SelectableText, _androidUrl), findsOneWidget);
    expect(find.widgetWithText(SelectableText, _testFlightUrl), findsNothing);
    expect(find.textContaining('TestFlight'), findsNothing);
    _expectLinkBetweenQrAndInstructions(
      tester,
      _androidUrl,
      find.textContaining('APK'),
    );

    await tester.tap(find.text('iOS/iPadOS'));
    await tester.pumpAndSettle();

    expect(_qrImage(_testFlightUrl), findsOneWidget);
    expect(_qrImage(_androidUrl), findsNothing);
    expect(
        tester
            .widget<QrImageView>(_qrImage(_testFlightUrl))
            .dataModuleStyle
            .dataModuleShape,
        QrDataModuleShape.circle);
    expect(find.widgetWithText(SelectableText, _testFlightUrl), findsOneWidget);
    expect(find.widgetWithText(SelectableText, _androidUrl), findsNothing);
    expect(find.textContaining('TestFlight'), findsOneWidget);
    _expectLinkBetweenQrAndInstructions(
      tester,
      _testFlightUrl,
      find.textContaining('TestFlight'),
    );

    await tester.tap(find.text('Android'));
    await tester.pumpAndSettle();

    expect(_qrImage(_androidUrl), findsOneWidget);
    expect(find.widgetWithText(SelectableText, _androidUrl), findsOneWidget);
    expect(find.textContaining('TestFlight'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all themes keep round QR modules dark with sufficient contrast',
      (tester) async {
    for (final theme in ShuYoThemes.all) {
      await _pumpPage(tester, themeId: theme.id);
      for (final platform in [
        (label: 'Android', url: _androidUrl),
        (label: 'iOS/iPadOS', url: _testFlightUrl),
      ]) {
        final tab = find.text(platform.label);
        await tester.ensureVisible(tab);
        await tester.tap(tab);
        await tester.pumpAndSettle();
        final qr = tester.widget<QrImageView>(_qrImage(platform.url));
        final foreground = qr.dataModuleStyle.color!;
        final background = qr.backgroundColor;
        final reason = '${theme.id}: ${platform.label}';

        expect(qr.dataModuleStyle.dataModuleShape, QrDataModuleShape.circle,
            reason: reason);
        expect(qr.eyeStyle.eyeShape, QrEyeShape.square, reason: reason);
        expect(qr.eyeStyle.color, foreground, reason: reason);
        expect(foreground.a, 1, reason: reason);
        expect(background.a, 1, reason: reason);
        expect(foreground.computeLuminance(),
            lessThan(background.computeLuminance()),
            reason: reason);
        final contrast = (background.computeLuminance() + 0.05) /
            (foreground.computeLuminance() + 0.05);
        expect(contrast, greaterThanOrEqualTo(4.5), reason: reason);
        expect(tester.takeException(), isNull, reason: reason);
      }
    }
  });

  testWidgets(
      'both platforms remain usable on a small dark phone with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpPage(tester, dark: true, textScale: 2);
    expect(Theme.of(tester.element(find.byType(TabBar))).brightness,
        Brightness.dark);
    expect(tester.takeException(), isNull);

    for (final platform in [
      (label: 'Android', url: _androidUrl),
      (label: 'iOS/iPadOS', url: _testFlightUrl),
    ]) {
      final tab = find.text(platform.label);
      await tester.ensureVisible(tab);
      await tester.tap(tab);
      await tester.pumpAndSettle();
      expect(_qrImage(platform.url), findsOneWidget);
      expect(find.widgetWithText(SelectableText, platform.url), findsOneWidget);

      final link = find.widgetWithText(SelectableText, platform.url);
      await tester.scrollUntilVisible(
        link,
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(link.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}

Future<void> _pumpPage(
  WidgetTester tester, {
  bool dark = false,
  double textScale = 1,
  String? themeId,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: ShuYoThemes.byId(
      themeId ?? (dark ? ShuYoThemes.systemDarkId : ShuYoThemes.defaultId),
    ).themeData(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    home: const RecommendShuyoPage(),
  ));
  await tester.pumpAndSettle();
}

Finder _qrImage(String url) => find.byWidgetPredicate(
      (widget) => widget is QrImageView && widget.semanticsLabel.contains(url),
      description: 'QR code for $url',
    );

void _expectLinkBetweenQrAndInstructions(
  WidgetTester tester,
  String url,
  Finder instructions,
) {
  final link = find.widgetWithText(SelectableText, url);
  expect(
    tester.getTopLeft(link).dy,
    greaterThan(tester.getBottomLeft(_qrImage(url)).dy),
  );
  expect(
    tester.getBottomLeft(link).dy,
    lessThan(tester.getTopLeft(instructions).dy),
  );
}

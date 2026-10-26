import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/core/client_app_info.dart';
import 'package:shuyo/features/settings/third_party_licenses_page.dart';
import 'package:shuyo/shared/navigation/shuyo_route.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

void main() {
  testWidgets(
      'keeps the application header and first package while grouping licenses',
      (tester) async {
    final licenses = StreamController<LicenseEntry>();
    addTearDown(() => unawaited(licenses.close()));
    var calls = 0;
    await _pumpPage(tester, () {
      calls++;
      return licenses.stream;
    });
    expect(find.text('第三方开源许可'), findsOneWidget);
    expect(find.text(ClientAppInfo.appName), findsOneWidget);
    expect(
      find.text('版本 ${ClientAppInfo.version}（${ClientAppInfo.buildNumber}）'),
      findsOneWidget,
    );
    expect(find.image(const AssetImage('assets/images/icon_light.png')),
        findsOneWidget);
    expect(find.text('Powered by Flutter'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    licenses.add(const _License(
      ['zebra', 'alpha'],
      [LicenseParagraph('Shared license body', 0)],
    ));
    licenses.add(const _License(
      ['alpha'],
      [LicenseParagraph('Additional alpha license', 0)],
    ));
    licenses.add(const _License(
      ['middle'],
      [LicenseParagraph('Middle license body', 0)],
    ));
    unawaited(licenses.close());
    await tester.pumpAndSettle();

    final packageNames = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((tile) => (tile.title! as Text).data)
        .toList();
    expect(packageNames, ['zebra', 'alpha', 'middle']);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(calls, 1);
  });

  testWidgets('opens selectable complete licenses in a shared subwindow',
      (tester) async {
    var calls = 0;
    await _pumpPage(tester, () {
      calls++;
      return Stream.fromIterable(const [
        _License(
          ['alpha', 'zebra'],
          [
            LicenseParagraph(
                'LICENSE HEADING', LicenseParagraph.centeredIndent),
            LicenseParagraph('Full unindented license paragraph.', 0),
            LicenseParagraph('Indented redistribution condition.', 2),
          ],
        ),
        _License(
          ['alpha'],
          [
            LicenseParagraph(
                'Second license, including its final disclaimer.', 0)
          ],
        ),
      ]);
    });
    await tester.pumpAndSettle();

    await tester.tap(find.text('alpha'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'alpha'), findsOneWidget);
    expect(find.text('2 项许可'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.widgetWithText(AppBar, 'alpha'),
        matching: find.byType(ShuYoRouteSurface),
      ),
      findsOneWidget,
    );
    for (final paragraph in const [
      'LICENSE HEADING',
      'Full unindented license paragraph.',
      'Indented redistribution condition.',
      'Second license, including its final disclaimer.',
    ]) {
      expect(find.text(paragraph), findsOneWidget);
      expect(_isSelectable(paragraph), isTrue, reason: paragraph);
    }
    final centered = tester.widget<SelectableText>(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText && widget.data == 'LICENSE HEADING',
      ),
    );
    expect(centered.textAlign, TextAlign.center);
    expect(
      tester.getTopLeft(find.text('Indented redistribution condition.')).dx,
      greaterThan(
        tester.getTopLeft(find.text('Full unindented license paragraph.')).dx,
      ),
    );

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('第三方开源许可'), findsOneWidget);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('zebra'), findsOneWidget);
    expect(calls, 1);

    await tester.tap(find.text('zebra'));
    await tester.pumpAndSettle();
    expect(find.text('Full unindented license paragraph.'), findsOneWidget);
    expect(
      find.text('Second license, including its final disclaimer.'),
      findsNothing,
    );
    expect(calls, 1);
  });

  testWidgets('failed license loading can be retried', (tester) async {
    var calls = 0;
    await _pumpPage(tester, () {
      calls++;
      if (calls == 1) {
        return Stream<LicenseEntry>.error(StateError('fixture failure'));
      }
      return Stream.value(const _License(
        ['recovered_package'],
        [LicenseParagraph('Recovered license.', 0)],
      ));
    });
    await tester.pumpAndSettle();
    expect(find.text('许可信息加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('recovered_package'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(calls, 2);
  });

  testWidgets('empty license registry finishes without a loading spinner',
      (tester) async {
    await _pumpPage(tester, () => const Stream<LicenseEntry>.empty());
    await tester.pumpAndSettle();
    expect(find.text('第三方开源许可'), findsOneWidget);
    expect(find.text('暂无第三方许可'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(ListTile), findsNothing);
    expect(find.text('重试'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long license text remains readable on a narrow large-text page',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final longText = List.filled(
      30,
      'Redistribution is permitted when the copyright notice is preserved.',
    ).join(' ');
    await _pumpPage(
      tester,
      () => Stream.value(_License(
        const ['long_package'],
        [
          LicenseParagraph(longText, 0),
          const LicenseParagraph('END OF LICENSE', 0),
        ],
      )),
      textScaler: TextScaler.linear(2),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('long_package'));
    await tester.pumpAndSettle();
    expect(find.text(longText), findsOneWidget);
    expect(_isSelectable(longText), isTrue);

    await tester.scrollUntilVisible(
      find.text('END OF LICENSE'),
      400,
      maxScrolls: 40,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('END OF LICENSE').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  Stream<LicenseEntry> Function() loader, {
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return tester.pumpWidget(MaterialApp(
    theme: ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: ThirdPartyLicensesPage(licenseLoader: loader),
  ));
}

bool _isSelectable(String text) {
  return find
          .ancestor(
            of: find.text(text),
            matching: find.byType(SelectionArea),
          )
          .evaluate()
          .isNotEmpty ||
      find
          .byWidgetPredicate(
            (widget) => widget is SelectableText && widget.data == text,
          )
          .evaluate()
          .isNotEmpty;
}

class _License extends LicenseEntry {
  const _License(this.packages, this.paragraphs);

  @override
  final List<String> packages;

  @override
  final List<LicenseParagraph> paragraphs;
}

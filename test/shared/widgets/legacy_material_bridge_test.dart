// This import models third-party packages that have not migrated yet.
// ignore: deprecated_member_use
import 'package:flutter/material.dart' as legacy;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shuyo/shared/widgets/legacy_material_bridge.dart';

const _probeKey = ValueKey('legacy-material-probe');

void main() {
  testWidgets('keeps modern and legacy Chinese localizations available',
      (tester) async {
    await _pumpBridge(tester, theme: ThemeData());

    final context = tester.element(find.byKey(_probeKey));
    final modernLocalizations = MaterialLocalizations.of(context);
    final legacyLocalizations = legacy.MaterialLocalizations.of(context);

    expect(Localizations.localeOf(context), const Locale('zh', 'CN'));
    expect(modernLocalizations.cutButtonLabel, '剪切');
    expect(legacyLocalizations.cutButtonLabel, '剪切');
    expect(legacyLocalizations.copyButtonLabel, '复制');
    expect(legacyLocalizations.pasteButtonLabel, '粘贴');
    expect(legacyLocalizations.selectAllButtonLabel, '全选');
  });

  testWidgets('updates legacy theme and locale with the parent app',
      (tester) async {
    for (final (brightness, locale, cutLabel) in [
      (Brightness.dark, const Locale('zh', 'CN'), '剪切'),
      (Brightness.light, const Locale('en'), 'Cut'),
    ]) {
      final theme = ThemeData(
        platform: TargetPlatform.iOS,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5B4BFF),
          brightness: brightness,
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontSize: 19),
        ),
      );
      await _pumpBridge(tester, theme: theme, locale: locale);

      final context = tester.element(find.byKey(_probeKey));
      final legacyTheme = legacy.Theme.of(context);

      expect(Theme.of(context).colorScheme, theme.colorScheme);
      expect(legacyTheme.brightness, brightness);
      expect(legacyTheme.platform, theme.platform);
      expect(legacyTheme.colorScheme.primary, theme.colorScheme.primary);
      expect(legacyTheme.colorScheme.onSurface, theme.colorScheme.onSurface);
      expect(legacyTheme.textTheme.bodyMedium?.fontSize, 19);
      expect(MaterialLocalizations.of(context).cutButtonLabel, cutLabel);
      expect(legacy.MaterialLocalizations.of(context).cutButtonLabel, cutLabel);
    }
  });
}

Future<void> _pumpBridge(
  WidgetTester tester, {
  required ThemeData theme,
  Locale locale = const Locale('zh', 'CN'),
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: theme,
    locale: locale,
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: const LegacyMaterialBridge(
      child: SizedBox(key: _probeKey),
    ),
  ));
  await tester.pumpAndSettle();
}

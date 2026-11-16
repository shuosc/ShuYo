import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shuyo/shared/navigation/shuyo_route.dart';
import 'package:shuyo/shared/theme/custom_background.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('uses the native iOS route with swipe-back support', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    final route = shuyoRoute<void>(builder: (_) => const SizedBox());

    expect(route, isA<CupertinoPageRoute<void>>());
  });

  test('keeps the existing custom route on Android', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    final route = shuyoRoute<void>(builder: (_) => const SizedBox());

    expect(route, isA<PageRouteBuilder<void>>());
  });

  test('supports an immediate route without transition animation', () {
    final route = shuyoRoute<void>(
      animated: false,
      builder: (_) => const SizedBox(),
    ) as PageRouteBuilder<void>;

    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
  });

  testWidgets('custom background travels with the incoming route',
      (tester) async {
    const background = CustomBackground(
      imagePath: 'assets/images/icon.png',
      opacity: 50,
      background: Color(0xFFFAFAFA),
      surface: Colors.white,
      text: Color(0xFF171717),
      accent: Color(0xFF3478D4),
    );
    await tester.pumpWidget(MaterialApp(
      theme: background.theme.themeData(),
      builder: (context, child) => CustomBackgroundScope(
        settings: background,
        child: CustomBackgroundLayer(
          settings: background,
          child: child!,
        ),
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              shuyoRoute(builder: (_) => const Scaffold(body: Text('新页面'))),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(
      find.descendant(
        of: find.byType(ShuYoRouteSurface),
        matching: find.byType(CustomBackgroundLayer),
      ),
      findsOneWidget,
    );
  });
}

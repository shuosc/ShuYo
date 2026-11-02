import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/shared/theme/custom_background.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

void main() {
  test('old transparency values migrate to their former visible photo share',
      () {
    const settings = CustomBackground(
      imagePath: 'unused.png',
      opacity: 50,
      background: Colors.white,
      surface: Colors.white,
      text: Colors.black,
      accent: Colors.blue,
    );
    expect(settings.toJson().containsKey('transparency'), isFalse);
    expect(settings.toJson()['opacity'], 50);
    for (final entry in {0: 45, 25: 34, 50: 23, 75: 11, 100: 0}.entries) {
      final oldJson = Map<String, dynamic>.from(settings.toJson())
        ..remove('opacity')
        ..['transparency'] = entry.key;
      expect(CustomBackground.fromJson(oldJson)?.opacity, entry.value);
    }
    expect(CustomBackground.fromJson(settings.toJson())?.opacity, 50);
    expect(CustomBackground.fromJson({...settings.toJson(), 'opacity': 101}),
        isNull);
  });

  testWidgets('photo opacity reaches both exact endpoints', (tester) async {
    const settings = CustomBackground(
      imagePath: 'assets/images/icon.png',
      opacity: 0,
      background: Colors.white,
      surface: Colors.white,
      text: Colors.black,
      accent: Colors.blue,
    );
    Widget frame(CustomBackground value) => MaterialApp(
          home: CustomBackgroundLayer(
            settings: value,
            child: const SizedBox.expand(),
          ),
        );

    await tester.pumpWidget(frame(settings));
    expect(
        find.descendant(
          of: find.byType(CustomBackgroundLayer),
          matching: find.byType(Opacity),
        ),
        findsNothing);

    await tester.pumpWidget(frame(settings.copyWith(opacity: 100)));
    final image = find.descendant(
      of: find.byType(CustomBackgroundLayer),
      matching: find.byType(Image),
    );
    expect(image, findsOneWidget);
    expect(tester.widget<Image>(image).opacity!.value, 1);
    expect(
        find.descendant(
            of: find.byType(CustomBackgroundLayer),
            matching: find.byType(Opacity)),
        findsNothing);
    expect(
        find.descendant(
          of: find.byType(CustomBackgroundLayer),
          matching: find.byType(ColoredBox),
        ),
        findsOneWidget);
    await tester.pumpWidget(frame(settings.copyWith(opacity: 37)));
    expect(tester.widget<Image>(image).opacity!.value, .37);
  });

  test('only custom theme strengthens small text colors', () {
    const settings = CustomBackground(
      imagePath: 'unused.png',
      opacity: 50,
      background: Color(0xFFF8F8F8),
      surface: Colors.white,
      text: Color(0xFF242424),
      accent: Colors.blue,
    );
    expect(settings.theme.colors.textTertiary, settings.text);
    expect(settings.theme.colors.textMuted, settings.text);
    expect(
      ShuYoThemes.byId(ShuYoThemes.defaultId).colors.textTertiary,
      const Color(0xFF667587),
    );
  });

  test('custom theme can exist without a photo', () {
    final settings = CustomBackground.withoutPhoto(
      ShuYoThemes.byId(ShuYoThemes.defaultId).colors,
    );
    expect(settings.hasPhoto, isFalse);
    expect(settings.opacity, 0);
    expect(settings.theme.name, '自定义主题');
    expect(CustomBackground.fromJson(settings.toJson())?.hasPhoto, isFalse);
  });

  test('default light empty cell keeps its previous visible gray', () {
    final colors = ShuYoThemes.byId(ShuYoThemes.defaultId).colors;
    expect(colors.scheduleEmptyCell.toARGB32() >> 24, lessThan(255));
    expect(
      Color.alphaBlend(colors.scheduleEmptyCell, colors.background).toARGB32(),
      0xFFEBEBEB,
    );
  });

  testWidgets('photo generates an editable custom theme with transparent pages',
      (tester) async {
    final file = File('assets/images/icon.png');
    final settings = (await tester.runAsync(() async {
      return CustomBackground.fromImage(
        imagePath: file.path,
        provider: MemoryImage(await file.readAsBytes()),
      );
    }))!;

    expect(settings.opacity, 50);
    expect(settings.theme.id, ShuYoThemes.customBackgroundId);
    expect(
        settings.theme.themeData().scaffoldBackgroundColor, Colors.transparent);
    expect(settings.theme.themeData().bottomNavigationBarTheme.elevation, 0);
    expect(settings.copyWith(opacity: 37).opacity, 37);
    expect(settings.theme.colors.scheduleEmptyCell.toARGB32() >> 24,
        lessThan(255));
    final adjusted = settings.withBackgroundColor(const Color(0xFF333333));
    expect(adjusted.surface, isNot(settings.surface));
    expect(adjusted.background, const Color(0xFF333333));
    expect(adjusted.text, settings.text);
    expect(
        settings
            .copyWith(accent: const Color(0xFF777777))
            .theme
            .colors
            .onAccent,
        Colors.black);
  });
}

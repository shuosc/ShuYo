import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

void main() {
  test('light themes use white untinted selection menus and sheets', () {
    for (final spec in ShuYoThemes.all
        .where((spec) => spec.colors.brightness == Brightness.light)) {
      final theme = spec.themeData();
      expect(theme.popupMenuTheme.color, Colors.white, reason: spec.id);
      expect(theme.popupMenuTheme.surfaceTintColor, Colors.transparent,
          reason: spec.id);
      expect(theme.bottomSheetTheme.backgroundColor, Colors.white,
          reason: spec.id);
      expect(theme.bottomSheetTheme.modalBackgroundColor, Colors.white,
          reason: spec.id);
      expect(theme.bottomSheetTheme.surfaceTintColor, Colors.transparent,
          reason: spec.id);
    }
  });

  test('dark themes keep untinted theme surfaces for selection menus', () {
    for (final spec in ShuYoThemes.all
        .where((spec) => spec.colors.brightness == Brightness.dark)) {
      final theme = spec.themeData();
      expect(theme.popupMenuTheme.color, spec.colors.surface, reason: spec.id);
      expect(theme.bottomSheetTheme.backgroundColor, spec.colors.surface,
          reason: spec.id);
      expect(theme.bottomSheetTheme.modalBackgroundColor, spec.colors.surface,
          reason: spec.id);
      expect(theme.popupMenuTheme.surfaceTintColor, Colors.transparent,
          reason: spec.id);
      expect(theme.bottomSheetTheme.surfaceTintColor, Colors.transparent,
          reason: spec.id);
    }
  });
}

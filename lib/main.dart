import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';
import 'package:media_kit/media_kit.dart';

import 'app/shuyo_app.dart';
import 'data/services/app_data_migration_service.dart';
import 'data/services/academic_schedule_widget_service.dart';
import 'data/services/client_settings_service.dart';
import 'shared/theme/shuyo_theme.dart';
import 'shared/theme/custom_background.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  if (!kIsWeb && Platform.isIOS) {
    try {
      await HomeWidget.setAppGroupId(
        AcademicScheduleWidgetService.iosAppGroupId,
      );
    } on Object {
      // Widget setup must not prevent the main application from starting.
    }
  }
  final initialThemeSettings = await _loadInitialThemeSettings();
  runApp(
    ShuYoApp(
      initialThemeId: initialThemeSettings.themeId,
      initialFollowSystemTheme: initialThemeSettings.followSystemTheme,
      initialCustomBackground: initialThemeSettings.customBackground,
    ),
  );
}

Future<_InitialThemeSettings> _loadInitialThemeSettings() async {
  try {
    // Theme preferences must be read after the migration, since the migration
    // can intentionally clear the complete preferences store.
    await AppDataMigrationService().migrateIfNeeded();
    final settingsService = ClientSettingsService();
    return _InitialThemeSettings(
      themeId: await settingsService.loadThemeId() ?? ShuYoThemes.defaultId,
      followSystemTheme: await settingsService.loadFollowSystemTheme(),
      customBackground: await settingsService.loadCustomBackground(),
    );
  } on Object {
    // Keep startup recoverable if a platform preference or migration service
    // is temporarily unavailable. ShuYoApp will still surface startup errors.
    return const _InitialThemeSettings(
      themeId: ShuYoThemes.defaultId,
      followSystemTheme: false,
    );
  }
}

class _InitialThemeSettings {
  const _InitialThemeSettings({
    required this.themeId,
    required this.followSystemTheme,
    this.customBackground,
  });

  final String themeId;
  final bool followSystemTheme;
  final CustomBackground? customBackground;
}

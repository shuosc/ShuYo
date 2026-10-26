import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/app_tab.dart';
import 'package:shuyo/data/services/client_settings_service.dart';
import 'package:shuyo/data/services/academic_native_auth_service.dart';
import 'package:shuyo/data/services/verification_delivery_service.dart';
import 'package:shuyo/shared/theme/custom_background.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

void main() {
  test('custom theme without a photo survives restart', () async {
    SharedPreferences.setMockInitialValues({});
    final service = ClientSettingsService();
    final settings = CustomBackground.withoutPhoto(
      ShuYoThemes.byId(ShuYoThemes.defaultId).colors,
    );
    await service.saveCustomBackground(settings);
    await service.saveThemeId(ShuYoThemes.customBackgroundId);

    final restored = await service.loadCustomBackground();
    expect(restored?.hasPhoto, isFalse);
    expect(restored?.opacity, 0);
    expect(await service.loadThemeId(), ShuYoThemes.customBackgroundId);
  });

  test('custom background keeps edits across theme changes and missing photos',
      () async {
    SharedPreferences.setMockInitialValues({});
    final directory =
        await Directory.systemTemp.createTemp('shuyo_theme_test_');
    addTearDown(() => directory.delete(recursive: true));
    final photo = File('${directory.path}/custom_background_123.png');
    await photo.writeAsBytes([1, 2, 3]);
    final service = ClientSettingsService(
      supportDirectoryLoader: () async => directory,
    );
    final settings = CustomBackground(
      imagePath: photo.path,
      opacity: 75,
      background: const Color(0xFFFAFAFA),
      surface: Colors.white,
      text: const Color(0xFF101010),
      accent: const Color(0xFF35458A),
    );

    await service.saveCustomBackground(settings);
    await service.saveThemeId('paper_light');
    final prefs = await SharedPreferences.getInstance();
    expect(
      jsonDecode(prefs.getString(ClientSettingsService.customBackgroundKey)!)[
          'imagePath'],
      'custom_background_123.png',
    );
    final restored = await service.loadCustomBackground();
    expect(restored?.imagePath, photo.path);
    expect(restored?.opacity, 75);
    expect(restored?.accent, settings.accent);

    final oldJson = Map<String, dynamic>.from(settings.toJson())
      ..remove('opacity')
      ..['transparency'] = 50;
    await prefs.setString(
      ClientSettingsService.customBackgroundKey,
      jsonEncode(oldJson),
    );
    expect((await service.loadCustomBackground())?.opacity, 23);

    await photo.delete();
    final withoutPhoto = await service.loadCustomBackground();
    expect(withoutPhoto?.hasPhoto, isFalse);
    expect(withoutPhoto?.opacity, 23);
    expect(withoutPhoto?.background, settings.background);
    expect(withoutPhoto?.surface, settings.surface);
    expect(withoutPhoto?.text, settings.text);
    expect(withoutPhoto?.accent, settings.accent);
  });

  for (final legacyAbsolutePath in [false, true]) {
    test(
        'custom background survives container changes with ${legacyAbsolutePath ? 'a legacy absolute path' : 'a relative path'}',
        () async {
      final root = await _themeDirectory();
      final oldDirectory =
          await Directory('${root.path}/old-container').create();
      final oldPhoto = File('${oldDirectory.path}/custom_background_123.png');
      await oldPhoto.writeAsBytes([1, 2, 3]);
      final settings = _backgroundWithPhoto(oldPhoto.path);
      final service = ClientSettingsService(
        supportDirectoryLoader: () async => oldDirectory,
      );
      SharedPreferences.setMockInitialValues({
        if (legacyAbsolutePath)
          ClientSettingsService.customBackgroundKey:
              jsonEncode(settings.toJson()),
      });
      if (!legacyAbsolutePath) await service.saveCustomBackground(settings);

      final newDirectory =
          await oldDirectory.rename('${root.path}/new-container');
      expect(await oldPhoto.exists(), isFalse);
      final upgradedService = ClientSettingsService(
        supportDirectoryLoader: () async => newDirectory,
      );
      final restored = await upgradedService.loadCustomBackground();

      expect(restored?.imagePath,
          '${newDirectory.path}/custom_background_123.png');
      expect(await File(restored!.imagePath).readAsBytes(), [1, 2, 3]);
      expect(restored.opacity, settings.opacity);
      expect(restored.background, settings.background);
      expect(restored.surface, settings.surface);
      expect(restored.text, settings.text);
      expect(restored.accent, settings.accent);

      await upgradedService.saveCustomBackground(restored);
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(prefs.getString(ClientSettingsService.customBackgroundKey)!)[
            'imagePath'],
        'custom_background_123.png',
      );
    });
  }

  test('missing background keeps its stored reference for a later retry',
      () async {
    final directory = await _themeDirectory();
    final photo = File('${directory.path}/custom_background_123.png');
    final settings = _backgroundWithPhoto(photo.path);
    final stored = jsonEncode(settings.toJson());
    SharedPreferences.setMockInitialValues({
      ClientSettingsService.customBackgroundKey: stored,
      ClientSettingsService.themeIdKey: ShuYoThemes.customBackgroundId,
    });
    final service = ClientSettingsService(
      supportDirectoryLoader: () async => directory,
    );

    final withoutPhoto = await service.loadCustomBackground();
    expect(withoutPhoto?.hasPhoto, isFalse);
    expect(withoutPhoto?.opacity, settings.opacity);
    expect(withoutPhoto?.accent, settings.accent);
    expect(await service.loadThemeId(), ShuYoThemes.customBackgroundId);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ClientSettingsService.customBackgroundKey), stored);

    await photo.writeAsBytes([1, 2, 3]);
    expect((await service.loadCustomBackground())?.imagePath, photo.path);
  });

  test('an unavailable background directory preserves the theme', () async {
    final settings = _backgroundWithPhoto('custom_background_123.png');
    SharedPreferences.setMockInitialValues({
      ClientSettingsService.customBackgroundKey: jsonEncode(settings.toJson()),
    });
    final service = ClientSettingsService(
      supportDirectoryLoader: () async =>
          throw const FileSystemException('unavailable'),
    );

    final restored = await service.loadCustomBackground();
    expect(restored?.hasPhoto, isFalse);
    expect(restored?.opacity, settings.opacity);
    expect(restored?.background, settings.background);
    expect(restored?.surface, settings.surface);
    expect(restored?.text, settings.text);
    expect(restored?.accent, settings.accent);
  });

  test('replacing and clearing backgrounds removes only unused app photos',
      () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await _themeDirectory();
    final service = ClientSettingsService(
      supportDirectoryLoader: () async => directory,
    );
    final oldPhoto = File('${directory.path}/custom_background_123.png');
    await oldPhoto.writeAsBytes([1]);
    await service.saveCustomBackground(_backgroundWithPhoto(oldPhoto.path));

    final newPhoto = File('${directory.path}/custom_background_456.png');
    final orphan = File('${directory.path}/custom_background_789.png');
    final unrelated = File('${directory.path}/other-image.png');
    final unrelatedPrefixed =
        File('${directory.path}/custom_background_notes.png');
    final nested =
        await Directory('${directory.path}/custom_background_999.png').create();
    final nestedPhoto = File('${nested.path}/custom_background_111.png');
    await newPhoto.writeAsBytes([2]);
    await orphan.writeAsBytes([3]);
    await unrelated.writeAsBytes([4]);
    await unrelatedPrefixed.writeAsBytes([5]);
    await nestedPhoto.writeAsBytes([6]);
    final settings = _backgroundWithPhoto(newPhoto.path);

    await service.saveCustomBackground(settings);
    expect(await oldPhoto.exists(), isFalse);
    expect(await orphan.exists(), isFalse);
    expect(await newPhoto.readAsBytes(), [2]);
    expect((await service.loadCustomBackground())?.imagePath, newPhoto.path);
    expect(await unrelated.exists(), isTrue);
    expect(await unrelatedPrefixed.exists(), isTrue);
    expect(await nestedPhoto.exists(), isTrue);

    final cleared = settings.copyWith(imagePath: '', opacity: 0);
    await service.saveCustomBackground(cleared);
    expect(await newPhoto.exists(), isFalse);
    expect((await service.loadCustomBackground())?.hasPhoto, isFalse);
    expect((await service.loadCustomBackground())?.accent, settings.accent);
    expect(await unrelated.exists(), isTrue);
    expect(await unrelatedPrefixed.exists(), isTrue);
    expect(await nestedPhoto.exists(), isTrue);
  });

  test(
      'pending imports survive cleanup by another service until saved or discarded',
      () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await _themeDirectory();
    final service = ClientSettingsService(
      supportDirectoryLoader: () async => directory,
    );
    final savingService = ClientSettingsService(
      supportDirectoryLoader: () async => directory,
    );
    final original = await service.createCustomBackgroundPhoto([1]);
    final settings = _backgroundWithPhoto(original.path);
    await savingService.saveCustomBackground(settings);
    final pending = await service.createCustomBackgroundPhoto([2]);

    await savingService.saveCustomBackground(settings.copyWith(opacity: 30));
    expect(await original.readAsBytes(), [1]);
    expect(await pending.readAsBytes(), [2]);
    await service.discardCustomBackgroundPhoto(pending);
    expect(await pending.exists(), isFalse);
    await service.discardCustomBackgroundPhoto(original);
    expect(await original.readAsBytes(), [1]);
  });

  test('pending photo ownership survives equivalent directory and file paths',
      () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await _themeDirectory();
    final importingService = ClientSettingsService(
      supportDirectoryLoader: () async => Directory('${directory.path}/.'),
    );
    final savingService = ClientSettingsService(
      supportDirectoryLoader: () async => directory,
    );
    final pending = await importingService.createCustomBackgroundPhoto([1, 2]);

    await savingService.saveCustomBackground(CustomBackground.withoutPhoto(
      ShuYoThemes.byId(ShuYoThemes.defaultId).colors,
    ));
    expect(await pending.readAsBytes(), [1, 2]);

    final equivalent = File.fromUri(pending.absolute.uri.normalizePath());
    await importingService.discardCustomBackgroundPhoto(equivalent);
    expect(await pending.exists(), isFalse);
  });

  test('overlapping saves across services retain the last background photo',
      () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await _themeDirectory();
    final service = ClientSettingsService(
      supportDirectoryLoader: () async => directory,
    );
    final first = await service.createCustomBackgroundPhoto([1]);
    final last = await service.createCustomBackgroundPhoto([2]);
    final otherService = ClientSettingsService(
      supportDirectoryLoader: () async => directory,
    );

    await Future.wait([
      service.saveCustomBackground(_backgroundWithPhoto(first.path)),
      otherService.saveCustomBackground(_backgroundWithPhoto(last.path)),
    ]);
    expect(await first.exists(), isFalse);
    expect(await last.readAsBytes(), [2]);
    expect((await service.loadCustomBackground())?.imagePath, last.path);
  });

  for (final clearPhoto in [false, true]) {
    test(
        'a failed ${clearPhoto ? 'clear' : 'replacement'} keeps the previous background',
        () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await _themeDirectory();
      final oldPhoto = File('${directory.path}/custom_background_123.png');
      await oldPhoto.writeAsBytes([1]);
      final service = ClientSettingsService(
        supportDirectoryLoader: () async => directory,
      );
      final original = _backgroundWithPhoto(oldPhoto.path);
      await service.saveCustomBackground(original);
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(ClientSettingsService.customBackgroundKey);
      final rejectingPreferences = _RejectingPreferences(prefs);
      final failingService = ClientSettingsService(
        preferencesLoader: () async => rejectingPreferences,
        supportDirectoryLoader: () async => directory,
      );
      final newPhoto = clearPhoto
          ? null
          : await failingService.createCustomBackgroundPhoto([2]);

      await expectLater(
        failingService.saveCustomBackground(original.copyWith(
          imagePath: newPhoto?.path ?? '',
        )),
        throwsStateError,
      );
      expect(await oldPhoto.readAsBytes(), [1]);
      expect(
          prefs.getString(ClientSettingsService.customBackgroundKey), stored);
      expect((await service.loadCustomBackground())?.imagePath, oldPhoto.path);
      expect((await failingService.loadCustomBackground())?.imagePath,
          oldPhoto.path);
      rejectingPreferences.rejectWrites = false;
      await failingService.saveCustomBackground(original);
      if (newPhoto != null) {
        expect(await newPhoto.readAsBytes(), [2]);
        await failingService.discardCustomBackgroundPhoto(newPhoto);
        expect(await newPhoto.exists(), isFalse);
        expect(await oldPhoto.exists(), isTrue);
      }
    });
  }

  test('cleanup failures are retried after the next successful save', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await _themeDirectory();
    final photo = File('${directory.path}/custom_background_123.png');
    await photo.writeAsBytes([1]);
    final service = ClientSettingsService(
      supportDirectoryLoader: () async => directory,
    );
    final settings = _backgroundWithPhoto(photo.path);
    await service.saveCustomBackground(settings);
    final unavailableService = ClientSettingsService(
      supportDirectoryLoader: () async =>
          throw const FileSystemException('unavailable'),
    );
    final cleared = settings.copyWith(imagePath: '');

    await unavailableService.saveCustomBackground(cleared);
    expect((await service.loadCustomBackground())?.hasPhoto, isFalse);
    expect(await photo.exists(), isTrue);
    await service.saveCustomBackground(cleared);
    expect(await photo.exists(), isFalse);
  });

  test('background paths cannot escape the application support directory',
      () async {
    final root = await _themeDirectory();
    final directory = await Directory('${root.path}/support').create();
    final outsidePhoto = File('${root.path}/custom_background_123.png');
    await outsidePhoto.writeAsBytes([1]);
    final service = ClientSettingsService(
      supportDirectoryLoader: () async => directory,
    );

    for (final path in [outsidePhoto.path, '../custom_background_123.png']) {
      SharedPreferences.setMockInitialValues({
        ClientSettingsService.customBackgroundKey:
            jsonEncode(_backgroundWithPhoto(path).toJson()),
      });
      expect((await service.loadCustomBackground())?.hasPhoto, isFalse);
    }
    await service.saveCustomBackground(_backgroundWithPhoto(''));
    expect(await outsidePhoto.readAsBytes(), [1]);
  });

  test('WebVPN is disabled by default and preserves an explicit opt-in',
      () async {
    SharedPreferences.setMockInitialValues({});
    final service = ClientSettingsService();

    expect((await service.loadNetworkSettings()).webVpnEnabled, isFalse);

    await service.saveNetworkSettings(
      const ClientNetworkSettings(webVpnEnabled: true),
    );
    expect((await service.loadNetworkSettings()).webVpnEnabled, isTrue);
  });

  test('startup onboarding completion is stored independently', () async {
    SharedPreferences.setMockInitialValues({});
    final service = ClientSettingsService();

    expect(await service.loadStartupOnboardingCompleted(), isFalse);
    await service.saveStartupOnboardingCompleted(true);
    expect(await service.loadStartupOnboardingCompleted(), isTrue);
  });

  test('startup display defaults to home and stores stable tab IDs', () async {
    SharedPreferences.setMockInitialValues({});
    final service = ClientSettingsService();

    expect(await service.loadStartupTab(), AppTab.home);
    await service.saveStartupTab(AppTab.progress);
    expect(await service.loadStartupTab(), AppTab.progress);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ClientSettingsService.startupTabKey), 'progress');
    await prefs.setString(ClientSettingsService.startupTabKey, 'removed-tab');
    expect(await service.loadStartupTab(), AppTab.home);
  });

  test('verification delivery alternates methods between login flows',
      () async {
    SharedPreferences.setMockInitialValues({});
    final service = VerificationDeliveryService();
    const methods = AcademicVerificationMethod.values;

    expect(
      await service.preferredMethod(methods),
      AcademicVerificationMethod.wecom,
    );
    await service.markSent(AcademicVerificationMethod.wecom);
    expect(
      await service.preferredMethod(methods),
      AcademicVerificationMethod.sms,
    );
    expect(
      await service.remainingCooldown(AcademicVerificationMethod.wecom),
      greaterThan(Duration.zero),
    );
  });
}

Future<Directory> _themeDirectory() async {
  final directory = await Directory.systemTemp.createTemp('shuyo_theme_test_');
  addTearDown(() => directory.delete(recursive: true));
  return directory;
}

CustomBackground _backgroundWithPhoto(String path) => CustomBackground(
      imagePath: path,
      opacity: 75,
      background: const Color(0xFFFAFAFA),
      surface: Colors.white,
      text: const Color(0xFF101010),
      accent: const Color(0xFF35458A),
    );

class _RejectingPreferences implements SharedPreferences {
  _RejectingPreferences(this.delegate);

  final SharedPreferences delegate;
  bool rejectWrites = true;
  String? _rejectedKey;
  String? _rejectedValue;

  @override
  String? getString(String key) =>
      key == _rejectedKey ? _rejectedValue : delegate.getString(key);

  @override
  Future<bool> setString(String key, String value) async {
    if (!rejectWrites) return delegate.setString(key, value);
    _rejectedKey = key;
    _rejectedValue = value;
    return false;
  }

  @override
  Future<void> reload() async {
    await delegate.reload();
    _rejectedKey = null;
    _rejectedValue = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

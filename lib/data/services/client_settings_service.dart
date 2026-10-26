import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_tab.dart';
import '../models/announcement_source.dart';
import '../models/home_layout.dart';
import '../../shared/theme/custom_background.dart';

class ClientNotificationSettings {
  const ClientNotificationSettings({
    required this.scheduleEnabled,
  });

  final bool scheduleEnabled;

  ClientNotificationSettings copyWith({
    bool? scheduleEnabled,
  }) {
    return ClientNotificationSettings(
      scheduleEnabled: scheduleEnabled ?? this.scheduleEnabled,
    );
  }
}

class ClientNetworkSettings {
  const ClientNetworkSettings({
    required this.webVpnEnabled,
  });

  final bool webVpnEnabled;

  ClientNetworkSettings copyWith({
    bool? webVpnEnabled,
  }) {
    return ClientNetworkSettings(
      webVpnEnabled: webVpnEnabled ?? this.webVpnEnabled,
    );
  }
}

class ClientSettingsService {
  ClientSettingsService({
    Future<SharedPreferences> Function()? preferencesLoader,
    Future<Directory> Function()? supportDirectoryLoader,
  })  : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
        _supportDirectoryLoader =
            supportDirectoryLoader ?? getApplicationSupportDirectory;

  static const scheduleNotificationsEnabledKey =
      'client.notifications.schedule.enabled';
  static const webVpnEnabledKey = 'client.network.webvpn.enabled';
  static const startupOnboardingCompletedKey =
      'client.onboarding.startup.completed';
  static const themeIdKey = 'client.theme.id';
  static const followSystemThemeKey = 'client.theme.follow_system';
  static const customBackgroundKey = 'client.theme.custom_background';
  static const startupTabKey = 'client.startup.tab';
  static const defaultAnnouncementSourceKey = 'announcements.defaultSource';
  static const homeLayoutKey = 'client.home.layout.v1';
  static const demoHomeLayoutKey = 'demo.home.layout.v1';
  static final _backgroundImageName =
      RegExp(r'^custom_background_[0-9]+\.png$');
  // Imports run in the app shell while commits run in the root app. Share
  // ownership and serialization across their separate settings services.
  static final Set<String> _pendingBackgroundImages = {};
  static Future<void> _backgroundSaveTail = Future<void>.value();

  final Future<SharedPreferences> Function() _preferencesLoader;
  final Future<Directory> Function() _supportDirectoryLoader;

  Future<HomeLayout> loadHomeLayout({bool isDemo = false}) async {
    try {
      final prefs = await _preferencesLoader();
      final raw = prefs.getString(isDemo ? demoHomeLayoutKey : homeLayoutKey);
      return raw == null
          ? HomeLayout.defaults()
          : HomeLayout.fromJson(jsonDecode(raw));
    } on Object {
      return HomeLayout.defaults();
    }
  }

  Future<void> saveHomeLayout(HomeLayout layout, {bool isDemo = false}) async {
    final prefs = await _preferencesLoader();
    final saved = await prefs.setString(
      isDemo ? demoHomeLayoutKey : homeLayoutKey,
      jsonEncode(layout.toJson()),
    );
    if (!saved) throw StateError('首页布局保存失败');
  }

  Future<File> createCustomBackgroundPhoto(List<int> bytes) async {
    final directory = await _supportDirectoryLoader();
    final photo = File(
      '${directory.path}/custom_background_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    _pendingBackgroundImages.add(_backgroundImageKey(photo));
    try {
      await photo.writeAsBytes(bytes, flush: true);
      return photo;
    } on Object {
      await discardCustomBackgroundPhoto(photo);
      rethrow;
    }
  }

  Future<void> discardCustomBackgroundPhoto(File photo) async {
    if (!_pendingBackgroundImages.remove(_backgroundImageKey(photo))) return;
    try {
      await photo.delete();
    } on Object {
      // Retry an unfinished import's file on the next successful theme save.
    }
  }

  Future<AnnouncementSource> loadDefaultAnnouncementSource() async {
    final prefs = await _preferencesLoader();
    return AnnouncementSource.byId(
      prefs.getString(defaultAnnouncementSourceKey),
    );
  }

  Future<void> saveDefaultAnnouncementSource(AnnouncementSource source) async {
    final prefs = await _preferencesLoader();
    await prefs.setString(defaultAnnouncementSourceKey, source.id);
  }

  Future<ClientNotificationSettings> loadNotificationSettings() async {
    final prefs = await _preferencesLoader();
    return ClientNotificationSettings(
      // Course reminders are opt-in. Permission prompts should only happen
      // after the user explicitly enables reminders in settings.
      scheduleEnabled: prefs.getBool(scheduleNotificationsEnabledKey) ?? false,
    );
  }

  Future<ClientNotificationSettings> saveNotificationSettings(
    ClientNotificationSettings settings,
  ) async {
    final prefs = await _preferencesLoader();
    await prefs.setBool(
      scheduleNotificationsEnabledKey,
      settings.scheduleEnabled,
    );
    return settings;
  }

  Future<ClientNetworkSettings> loadNetworkSettings() async {
    final prefs = await _preferencesLoader();
    return ClientNetworkSettings(
      webVpnEnabled: prefs.getBool(webVpnEnabledKey) ?? false,
    );
  }

  Future<ClientNetworkSettings> saveNetworkSettings(
    ClientNetworkSettings settings,
  ) async {
    final prefs = await _preferencesLoader();
    await prefs.setBool(
      webVpnEnabledKey,
      settings.webVpnEnabled,
    );
    return settings;
  }

  Future<String?> loadThemeId() async {
    final prefs = await _preferencesLoader();
    return prefs.getString(themeIdKey);
  }

  Future<void> saveThemeId(String themeId) async {
    final prefs = await _preferencesLoader();
    await prefs.setString(themeIdKey, themeId);
  }

  Future<bool> loadFollowSystemTheme() async {
    final prefs = await _preferencesLoader();
    return prefs.getBool(followSystemThemeKey) ?? false;
  }

  Future<void> saveFollowSystemTheme(bool enabled) async {
    final prefs = await _preferencesLoader();
    await prefs.setBool(followSystemThemeKey, enabled);
  }

  Future<CustomBackground?> loadCustomBackground() async {
    final prefs = await _preferencesLoader();
    final raw = prefs.getString(customBackgroundKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final settings = CustomBackground.fromJson(decoded);
      if (settings == null || !settings.hasPhoto) return settings;
      try {
        final name = _storedBackgroundImageName(settings.imagePath);
        if (name != null) {
          // Older versions stored the absolute iOS container path. Only the
          // filename survives an update; resolve it in the current container.
          final directory = await _supportDirectoryLoader();
          final photo = File('${directory.path}/$name');
          if (await photo.exists()) {
            return settings.copyWith(imagePath: photo.path);
          }
        }
      } on Object {
        // An unavailable photo must not discard the user's theme colors.
      }
      // Keep the stored reference intact so a later load can retry the photo.
      return settings.copyWith(imagePath: '');
    } on Object {
      return null;
    }
  }

  Future<void> saveCustomBackground(CustomBackground settings) {
    // Serialize commits and cleanup so overlapping edits retain the last photo.
    final save =
        _backgroundSaveTail.then((_) => _saveCustomBackground(settings));
    _backgroundSaveTail =
        save.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return save;
  }

  Future<void> _saveCustomBackground(CustomBackground settings) async {
    final prefs = await _preferencesLoader();
    Directory? directory;
    String? imageName;
    if (settings.hasPhoto) {
      imageName = _storedBackgroundImageName(settings.imagePath);
      if (imageName == null) {
        throw ArgumentError.value(settings.imagePath, 'imagePath');
      }
      directory = await _supportDirectoryLoader();
      if (!await File('${directory.path}/$imageName').exists()) {
        throw FileSystemException('背景照片不存在', settings.imagePath);
      }
    }
    final storedSettings = settings.copyWith(imagePath: imageName ?? '');
    try {
      if (!await prefs.setString(
        customBackgroundKey,
        jsonEncode(storedSettings.toJson()),
      )) {
        throw StateError('无法保存自定义主题');
      }
    } on Object {
      // SharedPreferences updates its cache before the platform write succeeds.
      // Restore that cache as well as leaving the previous photo untouched.
      try {
        await prefs.reload();
      } on Object {
        // Preserve the original save error.
      }
      rethrow;
    }
    if (imageName != null) {
      _pendingBackgroundImages.remove(
        _backgroundImageKey(File('${directory!.path}/$imageName')),
      );
    }
    await _removeUnusedBackgroundImages(imageName, directory: directory);
  }

  static String? _storedBackgroundImageName(String path) {
    final file = File(path);
    final segments = file.uri.pathSegments;
    if (segments.isEmpty) return null;
    final name = segments.last;
    if (!_backgroundImageName.hasMatch(name) ||
        (!file.isAbsolute && path != name)) {
      return null;
    }
    return name;
  }

  static String _backgroundImageKey(File file) {
    // File creation and directory enumeration can use different separators on
    // Windows. Compare normalized absolute identities before releasing imports.
    final key = file.absolute.uri.normalizePath().toString();
    return Platform.isWindows ? key.toLowerCase() : key;
  }

  Future<void> _removeUnusedBackgroundImages(
    String? retainedName, {
    Directory? directory,
  }) async {
    try {
      final root = directory ?? await _supportDirectoryLoader();
      await for (final entry in root.list(followLinks: false)) {
        if (entry is! File) continue;
        final name = _storedBackgroundImageName(entry.path);
        if (name == null ||
            name == retainedName ||
            _pendingBackgroundImages.contains(_backgroundImageKey(entry))) {
          continue;
        }
        try {
          await entry.delete();
        } on Object {
          // Retry orphaned photos on the next successful theme save.
        }
      }
    } on Object {
      // Photo cleanup must not roll back a successfully saved theme.
    }
  }

  Future<AppTab> loadStartupTab() async {
    final prefs = await _preferencesLoader();
    return AppTab.fromStorageId(prefs.getString(startupTabKey));
  }

  Future<void> saveStartupTab(AppTab tab) async {
    final prefs = await _preferencesLoader();
    await prefs.setString(startupTabKey, tab.storageId);
  }

  Future<bool> loadStartupOnboardingCompleted() async {
    final prefs = await _preferencesLoader();
    return prefs.getBool(startupOnboardingCompletedKey) ?? false;
  }

  Future<void> saveStartupOnboardingCompleted(bool completed) async {
    final prefs = await _preferencesLoader();
    await prefs.setBool(startupOnboardingCompletedKey, completed);
  }
}

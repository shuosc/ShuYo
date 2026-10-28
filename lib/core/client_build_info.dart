import 'package:flutter/services.dart';

/// The source revision embedded in this installation at native build time.
class ClientBuildInfo {
  const ClientBuildInfo._();

  static const _channel = MethodChannel('work.shuyo.app/build_info');
  static ClientBuildRevision _revision = ClientBuildRevision(
    branch: const String.fromEnvironment('SHUYO_GIT_BRANCH'),
    commitHash: const String.fromEnvironment('SHUYO_GIT_COMMIT'),
  );
  static Future<void>? _loadFuture;

  static String get branch => _revision.branch;
  static String get commitHash => _revision.commitHash;
  static String get shortCommitHash => _revision.shortCommitHash;
  static String get displayLabel => _revision.displayLabel;
  static bool get hasCommit => _revision.hasCommit;
  static Uri? get commitUrl => _revision.commitUrl;

  static Future<void> load() => _loadFuture ??= _loadFromPlatform();

  static Future<void> _loadFromPlatform() async {
    try {
      final metadata = await _channel.invokeMapMethod<String, dynamic>(
        'getBuildInfo',
      );
      if (metadata == null) return;
      _revision = ClientBuildRevision(
        branch:
            metadata['branch'] is String ? metadata['branch'] as String : '',
        commitHash: metadata['commitHash'] is String
            ? metadata['commitHash'] as String
            : '',
      );
    } on MissingPluginException {
      // Other platforms can provide the same values with --dart-define.
    } on PlatformException {
      // Missing metadata must not prevent opening the About page.
    }
  }
}

class ClientBuildRevision {
  ClientBuildRevision({required String branch, required String commitHash})
      : branch = branch.trim(),
        commitHash = _validCommit(commitHash.trim());

  final String branch;
  final String commitHash;

  bool get hasCommit => commitHash.isNotEmpty;
  String get shortCommitHash => hasCommit ? commitHash.substring(0, 7) : '';

  String get displayLabel {
    if (!hasCommit) {
      return branch.isEmpty ? '版本信息不可用' : '$branch · 提交未知';
    }
    return '${branch.isEmpty ? 'detached HEAD' : branch} · $shortCommitHash';
  }

  Uri? get commitUrl => hasCommit
      ? Uri.https('github.com', '/shuosc/ShuYo/commit/$commitHash')
      : null;

  static String _validCommit(String value) {
    return RegExp(r'^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$').hasMatch(value)
        ? value.toLowerCase()
        : '';
  }
}

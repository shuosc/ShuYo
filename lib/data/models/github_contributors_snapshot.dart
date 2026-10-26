import 'github_contributor.dart';

/// The versioned contributor data packaged with each application build.
class GitHubContributorsSnapshot {
  GitHubContributorsSnapshot({
    required DateTime generatedAt,
    required List<GitHubContributor> contributors,
  })  : generatedAt = generatedAt.toUtc(),
        contributors = List<GitHubContributor>.unmodifiable(contributors);

  static const schemaVersion = 1;
  static const repository = 'shuosc/ShuYo';

  final DateTime generatedAt;
  final List<GitHubContributor> contributors;

  factory GitHubContributorsSnapshot.fromJson(Object? json) {
    final snapshot = _object(json, 'snapshot');
    if (snapshot['schemaVersion'] != schemaVersion ||
        snapshot['schemaVersion'] is! int) {
      throw const FormatException('Unsupported contributor snapshot version');
    }
    if (snapshot['repository'] != repository) {
      throw const FormatException('Unexpected contributor repository');
    }
    final generatedAtValue = _string(snapshot['generatedAt'], 'generatedAt');
    final generatedAt = DateTime.tryParse(generatedAtValue);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$')
            .hasMatch(generatedAtValue) ||
        generatedAt == null ||
        !generatedAt.isUtc ||
        generatedAt.toIso8601String().substring(0, 19) !=
            generatedAtValue.substring(0, 19)) {
      throw const FormatException('generatedAt must be an ISO 8601 UTC date');
    }
    final rows = snapshot['contributors'];
    if (rows is! List) {
      throw const FormatException('contributors must be an array');
    }
    final contributors = <GitHubContributor>[];
    final logins = <String>{};
    for (var index = 0; index < rows.length; index++) {
      final row = _object(rows[index], 'contributors[$index]');
      final login = _string(row['login'], 'login');
      if (!logins.add(login.toLowerCase())) {
        throw const FormatException('Contributor logins must be unique');
      }
      final additions = _optionalCount(row['additions'], 'additions');
      final deletions = _optionalCount(row['deletions'], 'deletions');
      if ((additions == null) != (deletions == null)) {
        throw const FormatException('additions and deletions must be paired');
      }
      contributors.add(GitHubContributor(
        login: login,
        name: _optionalString(row['name'], 'name'),
        avatarUrl: _avatarUrl(row['avatarUrl']),
        profileUrl: _string(row['profileUrl'], 'profileUrl'),
        commits: _count(row['commits'], 'commits'),
        additions: additions,
        deletions: deletions,
        statisticsMessage:
            _optionalString(row['statisticsMessage'], 'statisticsMessage'),
      ));
    }
    return GitHubContributorsSnapshot(
      generatedAt: generatedAt,
      contributors: contributors,
    );
  }

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'repository': repository,
        'generatedAt': generatedAt.toIso8601String(),
        'contributors': [
          for (final contributor in contributors)
            {
              'login': contributor.login,
              'name': contributor.name,
              'avatarUrl': contributor.avatarUrl,
              'profileUrl': contributor.profileUrl,
              'commits': contributor.commits,
              'additions': contributor.additions,
              'deletions': contributor.deletions,
              'statisticsMessage': contributor.statisticsMessage,
            },
        ],
      };

  static Map<String, dynamic> _object(Object? value, String field) {
    if (value is! Map<String, dynamic>) {
      throw FormatException('$field must be an object');
    }
    return value;
  }

  static String _string(Object? value, String field) {
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$field must be a nonempty string');
    }
    return value.trim();
  }

  static String? _optionalString(Object? value, String field) {
    if (value == null) return null;
    if (value is! String) throw FormatException('$field must be a string');
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int _count(Object? value, String field) {
    if (value is! int || value < 0) {
      throw FormatException('$field must be a nonnegative integer');
    }
    return value;
  }

  static int? _optionalCount(Object? value, String field) {
    return value == null ? null : _count(value, field);
  }

  static String _avatarUrl(Object? value) {
    final url = _string(value, 'avatarUrl');
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'avatars.githubusercontent.com' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        uri.path.isEmpty ||
        uri.path == '/') {
      throw const FormatException(
          'avatarUrl must be a GitHub avatar HTTPS URL');
    }
    return url;
  }
}

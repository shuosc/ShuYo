class GitHubContributor {
  const GitHubContributor({
    required this.login,
    required this.avatarUrl,
    required this.profileUrl,
    required this.commits,
    this.name,
    this.additions,
    this.deletions,
    this.statisticsMessage,
  });

  final String login;
  final String? name;
  final String avatarUrl;
  final String profileUrl;
  final int commits;

  /// Null means GitHub has not supplied reliable line statistics.
  final int? additions;
  final int? deletions;
  final String? statisticsMessage;

  String get displayName => name ?? login;
}

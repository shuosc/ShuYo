import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:shuyo/data/models/github_contributor.dart';

class GitHubContributorsClientException implements Exception {
  const GitHubContributorsClientException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GitHubContributorsClient {
  GitHubContributorsClient({
    http.Client? httpClient,
    String? token,
    this.requestTimeout = const Duration(seconds: 15),
    this.statsRetryDelay = const Duration(seconds: 1),
    int statsRetryCount = 2,
  })  : _httpClient = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        statsRetryCount = statsRetryCount < 0
            ? 0
            : (statsRetryCount > 2 ? 2 : statsRetryCount),
        _headers = {
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          'User-Agent': 'ShuYo-Contributors-Generator',
          if (token != null && token.trim().isNotEmpty)
            'Authorization': 'Bearer ${token.trim()}',
        };

  static const _repository = '/repos/shuosc/ShuYo';
  final http.Client _httpClient;
  final bool _ownsClient;
  final Map<String, String> _headers;
  final Duration requestTimeout;
  final Duration statsRetryDelay;
  final int statsRetryCount;

  Future<List<GitHubContributor>> fetchContributors({
    List<GitHubContributor> previous = const [],
  }) async {
    final contributors = await _fetchContributorList();
    if (contributors.isEmpty) return const [];
    final namesFuture = _fetchNames(contributors);
    final statistics = await _fetchStatistics();
    final names = await namesFuture;
    final previousByLogin = {
      for (final contributor in previous)
        contributor.login.toLowerCase(): contributor,
    };
    final result = <GitHubContributor>[];
    for (var index = 0; index < contributors.length; index++) {
      final contributor = contributors[index];
      final totals = statistics.totals[contributor.login.toLowerCase()];
      result.add(GitHubContributor(
        login: contributor.login,
        name: names[index] ??
            previousByLogin[contributor.login.toLowerCase()]?.name,
        avatarUrl: contributor.avatarUrl,
        profileUrl: contributor.profileUrl,
        commits: totals?.commits ?? contributor.commits,
        additions: totals?.additions,
        deletions: totals?.deletions,
        statisticsMessage:
            totals == null ? statistics.message ?? 'GitHub 暂未提供此用户的行数统计' : null,
      ));
    }
    return List<GitHubContributor>.unmodifiable(_sortContributors(result));
  }

  Future<List<GitHubContributor>> _fetchContributorList() async {
    final contributors = <GitHubContributor>[];
    for (var page = 1;; page++) {
      final response = await _get('$_repository/contributors', {
        'per_page': '100',
        'page': '$page',
      });
      if (response.statusCode == 204) {
        break;
      }
      _requireSuccess(response);
      final decoded = _decode(response);
      if (decoded is! List) {
        throw const GitHubContributorsClientException('GitHub 返回了无效的贡献者数据');
      }
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) {
          throw const GitHubContributorsClientException('GitHub 返回了无效的贡献者数据');
        }
        final login = _nonEmptyString(item['login']);
        final commits = _nonNegativeInt(item['contributions']);
        if (login == null || commits == null) {
          throw const GitHubContributorsClientException('GitHub 返回的贡献者信息不完整');
        }
        contributors.add(GitHubContributor(
          login: login,
          avatarUrl: _nonEmptyString(item['avatar_url']) ?? '',
          profileUrl:
              _nonEmptyString(item['html_url']) ?? 'https://github.com/$login',
          commits: commits,
        ));
      }
      if (decoded.length < 100) {
        break;
      }
    }
    return _sortContributors(contributors);
  }

  static List<GitHubContributor> _sortContributors(
      List<GitHubContributor> contributors) {
    // Keep GitHub's ordering for contributors with the same commit count.
    final indexed = contributors.asMap().entries.toList();
    indexed.sort((left, right) {
      final comparison = right.value.commits.compareTo(left.value.commits);
      return comparison == 0 ? left.key.compareTo(right.key) : comparison;
    });
    return indexed.map((entry) => entry.value).toList(growable: false);
  }

  Future<_Statistics> _fetchStatistics() async {
    try {
      for (var attempt = 0; attempt <= statsRetryCount; attempt++) {
        final response = await _get('$_repository/stats/contributors');
        if (response.statusCode == 202) {
          if (attempt < statsRetryCount) {
            await Future<void>.delayed(statsRetryDelay);
            continue;
          }
          return const _Statistics.unavailable('GitHub 正在生成行数统计');
        }
        if (response.statusCode == 204) {
          return const _Statistics.unavailable('GitHub 暂未提供行数统计');
        }
        _requireSuccess(response);
        final decoded = _decode(response);
        if (decoded is! List) {
          return const _Statistics.unavailable('GitHub 返回了无效的行数统计');
        }
        final totals = <String, _LineTotals>{};
        var totalCommits = 0;
        for (final item in decoded) {
          if (item is! Map<String, dynamic>) {
            continue;
          }
          final commits = _nonNegativeInt(item['total']);
          totalCommits += commits ?? 0;
          final author = item['author'];
          final login = author is Map<String, dynamic>
              ? _nonEmptyString(author['login'])
              : null;
          final weeks = item['weeks'];
          if (login == null || weeks is! List || weeks.isEmpty) {
            continue;
          }
          var additions = 0;
          var deletions = 0;
          var valid = true;
          for (final week in weeks) {
            if (week is! Map<String, dynamic>) {
              valid = false;
              break;
            }
            final added = _nonNegativeInt(week['a']);
            final deleted = _nonNegativeInt(week['d']);
            if (added == null || deleted == null) {
              valid = false;
              break;
            }
            additions += added;
            deletions += deleted;
          }
          if (valid) {
            totals[login.toLowerCase()] =
                _LineTotals(additions, deletions, commits);
          }
        }
        // GitHub can return zero additions/deletions for every author when the
        // repository has >= 10,000 commits. Do not present withheld data as +0/-0.
        if (totalCommits > 0 &&
            totals.isNotEmpty &&
            totals.values.every(
                (value) => value.additions == 0 && value.deletions == 0)) {
          return const _Statistics.unavailable('GitHub 暂未提供可用的行数统计');
        }
        return _Statistics(totals);
      }
    } on GitHubContributorsClientException catch (error) {
      return _Statistics.unavailable(error.message);
    }
    return const _Statistics.unavailable('GitHub 暂未提供行数统计');
  }

  Future<List<String?>> _fetchNames(
      List<GitHubContributor> contributors) async {
    final names = <String?>[];
    // Run profile lookups independently of statistics, with at most four
    // concurrent requests. Missing profiles retain the contributor's login.
    for (var start = 0; start < contributors.length; start += 4) {
      names.addAll(await Future.wait(contributors
          .skip(start)
          .take(4)
          .map((contributor) => _fetchName(contributor.login))));
    }
    return names;
  }

  Future<String?> _fetchName(String login) async {
    try {
      final response = await _get('/users/$login');
      _requireSuccess(response);
      final decoded = _decode(response);
      if (decoded is Map<String, dynamic>) {
        return _nonEmptyString(decoded['name']);
      }
    } on GitHubContributorsClientException {
      // Profiles are optional; a failed lookup must not hide contributors.
    }
    return null;
  }

  Future<http.Response> _get(
    String path, [
    Map<String, String>? query,
  ]) async {
    try {
      return await _httpClient
          .get(Uri.https('api.github.com', path, query), headers: _headers)
          .timeout(requestTimeout);
    } on TimeoutException {
      throw const GitHubContributorsClientException('GitHub 请求超时，请稍后重试');
    } on http.ClientException {
      throw const GitHubContributorsClientException('无法连接 GitHub，请检查网络后重试');
    } on Exception {
      throw const GitHubContributorsClientException('GitHub 请求失败，请稍后重试');
    }
  }

  static void _requireSuccess(http.Response response) {
    if (response.statusCode == 200) {
      return;
    }
    if (response.statusCode == 429 ||
        (response.statusCode == 403 &&
            response.headers['x-ratelimit-remaining'] == '0')) {
      throw const GitHubContributorsClientException('GitHub 请求次数已达上限，请稍后重试');
    }
    throw GitHubContributorsClientException(
      'GitHub 数据加载失败 (${response.statusCode})，请稍后重试',
    );
  }

  static Object? _decode(http.Response response) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const GitHubContributorsClientException('GitHub 返回了无效数据');
    }
  }

  static String? _nonEmptyString(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      return null;
    }
    return value.trim();
  }

  static int? _nonNegativeInt(Object? value) =>
      value is int && value >= 0 ? value : null;

  void close() {
    if (_ownsClient) {
      _httpClient.close();
    }
  }
}

class _LineTotals {
  const _LineTotals(this.additions, this.deletions, this.commits);

  final int additions;
  final int deletions;
  final int? commits;
}

class _Statistics {
  const _Statistics(this.totals) : message = null;
  const _Statistics.unavailable(this.message) : totals = const {};
  final Map<String, _LineTotals> totals;
  final String? message;
}

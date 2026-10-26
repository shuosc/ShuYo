import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/github_contributor.dart';
import '../models/github_contributors_snapshot.dart';

class GitHubContributorsException implements Exception {
  const GitHubContributorsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads the contributor snapshot included in the installed application.
class GitHubContributorsService {
  GitHubContributorsService({AssetBundle? bundle})
      : _bundle = bundle ?? rootBundle;

  static const assetPath = 'assets/contributors/contributors.json';

  final AssetBundle _bundle;
  Future<List<GitHubContributor>>? _loadFuture;

  Future<List<GitHubContributor>> fetchContributors() async {
    final future = _loadFuture ??= _loadSnapshot();
    try {
      return await future;
    } on Object {
      if (identical(_loadFuture, future)) _loadFuture = null;
      rethrow;
    }
  }

  Future<List<GitHubContributor>> _loadSnapshot() async {
    try {
      final contents = await _bundle.loadString(assetPath, cache: false);
      final snapshot =
          GitHubContributorsSnapshot.fromJson(jsonDecode(contents));
      // Keep the snapshot's order when contributors have the same commit count.
      final indexed = snapshot.contributors.asMap().entries.toList();
      indexed.sort((left, right) {
        final comparison = right.value.commits.compareTo(left.value.commits);
        return comparison == 0 ? left.key.compareTo(right.key) : comparison;
      });
      return List<GitHubContributor>.unmodifiable(
        indexed.map((entry) => entry.value),
      );
    } on FormatException {
      throw const GitHubContributorsException('应用内贡献者数据格式有误，请更新应用后重试');
    } on Object {
      throw const GitHubContributorsException('无法读取应用内贡献者数据，请重试或更新应用');
    }
  }

  // The asset bundle belongs to Flutter or the caller; there is no open client.
  void close() {}
}

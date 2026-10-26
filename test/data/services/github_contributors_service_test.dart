import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/github_contributors_snapshot.dart';
import 'package:shuyo/data/services/github_contributors_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads bundled contributors in stable commit order', () async {
    final bundle = _SnapshotBundle(jsonEncode(_snapshot([
      _contributor('first-tie', commits: 3),
      _contributor('main', commits: 8, name: '中文昵称'),
      _contributor('second-tie', commits: 3),
    ])));
    final service = GitHubContributorsService(bundle: bundle);

    final contributors = await service.fetchContributors();

    expect(contributors.map((item) => item.login),
        ['main', 'first-tie', 'second-tie']);
    expect(contributors.first.displayName, '中文昵称');
    expect(contributors.first.additions, 150);
    expect(contributors.first.deletions, 25);
    expect(contributors.first.avatarUrl,
        'https://avatars.githubusercontent.com/main');
    expect(bundle.keys, [GitHubContributorsService.assetPath]);
    expect(() => contributors.clear(), throwsUnsupportedError);
  });

  test('shares successful asset loading across concurrent and later calls',
      () async {
    final bundle =
        _SnapshotBundle(jsonEncode(_snapshot([_contributor('dev')])));
    final service = GitHubContributorsService(bundle: bundle);

    final responses = await Future.wait([
      service.fetchContributors(),
      service.fetchContributors(),
    ]);
    final repeated = await service.fetchContributors();

    expect(bundle.keys, hasLength(1));
    expect(identical(responses.first, responses.last), isTrue);
    expect(identical(responses.first, repeated), isTrue);
    service.close();
  });

  test('a failed asset load is friendly and can be retried', () async {
    final bundle = _SnapshotBundle(null);
    final service = GitHubContributorsService(bundle: bundle);

    await expectLater(
      () => service.fetchContributors(),
      throwsA(isA<GitHubContributorsException>().having(
        (error) => error.message,
        'message',
        contains('无法读取应用内贡献者数据'),
      )),
    );
    bundle.contents = jsonEncode(_snapshot([_contributor('recovered')]));

    final contributors = await service.fetchContributors();

    expect(contributors.single.login, 'recovered');
    expect(bundle.keys, hasLength(2));
  });

  test('malformed bundled data has a friendly error and remains retryable',
      () async {
    final bundle = _SnapshotBundle('{ invalid json');
    final service = GitHubContributorsService(bundle: bundle);

    await expectLater(
      () => service.fetchContributors(),
      throwsA(isA<GitHubContributorsException>().having(
        (error) => error.message,
        'message',
        contains('数据格式有误'),
      )),
    );
    bundle.contents = jsonEncode(_snapshot([_contributor('recovered')]));

    expect((await service.fetchContributors()).single.login, 'recovered');
    expect(bundle.keys, [
      GitHubContributorsService.assetPath,
      GitHubContributorsService.assetPath
    ]);
  });

  test('snapshot round-trips UTC metadata, nullable statistics and avatar URLs',
      () {
    final snapshot = GitHubContributorsSnapshot.fromJson(_snapshot([
      _contributor('named', name: '昵称'),
      {
        ..._contributor('pending'),
        'name': null,
        'additions': null,
        'deletions': null,
        'statisticsMessage': 'GitHub 暂未提供行数统计',
      },
    ]));
    final restored = GitHubContributorsSnapshot.fromJson(snapshot.toJson());

    expect(restored.generatedAt, DateTime.utc(2026, 10, 26, 12));
    expect(restored.contributors.first.displayName, '昵称');
    expect(restored.contributors.last.displayName, 'pending');
    expect(restored.contributors.last.additions, isNull);
    expect(restored.contributors.last.deletions, isNull);
    expect(restored.contributors.last.statisticsMessage, 'GitHub 暂未提供行数统计');
    expect(restored.contributors.last.avatarUrl,
        'https://avatars.githubusercontent.com/pending');
    expect(() => restored.contributors.clear(), throwsUnsupportedError);
  });

  test('an empty bundled snapshot is a valid empty list', () async {
    final service = GitHubContributorsService(
      bundle: _SnapshotBundle(jsonEncode(_snapshot([]))),
    );

    expect(await service.fetchContributors(), isEmpty);
  });

  test('snapshot rejects wrong schema, repository and timestamp', () {
    for (final json in <Object?>[
      null,
      [],
      {..._snapshot([]), 'schemaVersion': 2},
      {..._snapshot([]), 'schemaVersion': 1.0},
      {..._snapshot([]), 'repository': 'other/repository'},
      {..._snapshot([]), 'generatedAt': '2026-10-26'},
      {..._snapshot([]), 'generatedAt': '2026-10-26T12:00:00+08:00'},
      {..._snapshot([]), 'generatedAt': '2026-02-30T12:00:00Z'},
      {..._snapshot([]), 'contributors': {}},
    ]) {
      expect(() => GitHubContributorsSnapshot.fromJson(json),
          throwsFormatException);
    }
  });

  test(
      'snapshot rejects invalid fields, unpaired statistics and duplicate users',
      () {
    for (final changed in <Map<String, Object?>>[
      {'commits': -1},
      {'commits': 1.5},
      {'commits': '8'},
      {'additions': -2},
      {'deletions': -3},
      {'additions': null},
      {'name': 7},
      {'avatarUrl': 7},
      {'statisticsMessage': false},
      {'login': ''},
    ]) {
      expect(
        () => GitHubContributorsSnapshot.fromJson(_snapshot([
          {..._contributor('dev'), ...changed},
        ])),
        throwsFormatException,
      );
    }
    expect(
      () => GitHubContributorsSnapshot.fromJson(
          _snapshot([_contributor('dev'), _contributor('DEV')])),
      throwsFormatException,
    );
  });

  test('snapshot only accepts GitHub avatar HTTPS URLs', () {
    for (final url in [
      '',
      'assets/images/avatar.png',
      'http://avatars.githubusercontent.com/u/1',
      'https://example.com/avatar.png',
      'https://avatars.githubusercontent.com.example.com/u/1',
      'https://user@avatars.githubusercontent.com/u/1',
      'https://avatars.githubusercontent.com:8443/u/1',
      'https://avatars.githubusercontent.com',
    ]) {
      expect(
        () => GitHubContributorsSnapshot.fromJson(_snapshot([
          {..._contributor('dev'), 'avatarUrl': url},
        ])),
        throwsFormatException,
        reason: url,
      );
    }
  });

  test('the default bundle loads contributors with online avatar URLs',
      () async {
    final contributors = await GitHubContributorsService().fetchContributors();

    expect(contributors, isNotEmpty);
    for (final contributor in contributors) {
      expect(Uri.parse(contributor.profileUrl).host, 'github.com');
      expect(Uri.parse(contributor.avatarUrl).scheme, 'https');
      expect(Uri.parse(contributor.avatarUrl).host,
          'avatars.githubusercontent.com');
    }
  });
}

Map<String, Object?> _snapshot(List<Map<String, Object?>> contributors) => {
      'schemaVersion': GitHubContributorsSnapshot.schemaVersion,
      'repository': GitHubContributorsSnapshot.repository,
      'generatedAt': '2026-10-26T12:00:00.000Z',
      'contributors': contributors,
    };

Map<String, Object?> _contributor(
  String login, {
  int commits = 3,
  String? name,
}) =>
    {
      'login': login,
      'name': name,
      'avatarUrl': 'https://avatars.githubusercontent.com/$login',
      'profileUrl': 'https://github.com/$login',
      'commits': commits,
      'additions': 150,
      'deletions': 25,
      'statisticsMessage': null,
    };

class _SnapshotBundle extends CachingAssetBundle {
  _SnapshotBundle(this.contents);

  String? contents;
  final keys = <String>[];

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    keys.add(key);
    if (contents == null) throw StateError('Asset missing');
    return contents!;
  }

  @override
  Future<ByteData> load(String key) => throw UnimplementedError();
}

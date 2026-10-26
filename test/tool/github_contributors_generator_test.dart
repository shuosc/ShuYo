import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:shuyo/data/models/github_contributor.dart';
import 'package:shuyo/data/models/github_contributors_snapshot.dart';
import '../../tool/src/github_contributors_client.dart';
import '../../tool/update_contributors.dart';

void main() {
  late Directory directory;
  late File snapshotFile;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shuyo-contributors-');
    snapshotFile = File('${directory.path}/contributors.json');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
      'build client sums weekly statistics, retries pending data and keeps names',
      () async {
    var statsRequests = 0;
    var activeProfiles = 0;
    var maximumProfiles = 0;
    final client = GitHubContributorsClient(
      statsRetryDelay: Duration.zero,
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/stats/contributors')) {
          statsRequests++;
          return statsRequests == 1
              ? _json({}, 202)
              : _json([
                  _stats('first', 6, [
                    {'a': 12, 'd': 2},
                    {'a': 8, 'd': 1},
                  ]),
                  _stats('second', 3, [
                    {'a': 2, 'd': 0},
                  ]),
                ]);
        }
        if (request.url.path.startsWith('/users/')) {
          activeProfiles++;
          if (activeProfiles > maximumProfiles) {
            maximumProfiles = activeProfiles;
          }
          await Future<void>.delayed(Duration.zero);
          activeProfiles--;
          return request.url.path.endsWith('/first')
              ? _json({'name': '贡献者昵称'})
              : _json({}, 403);
        }
        return _json([_user('second', 4), _user('first', 7)]);
      }),
    );

    final result = await client.fetchContributors(previous: const [
      GitHubContributor(
        login: 'second',
        name: '已知昵称',
        avatarUrl: 'https://avatars.githubusercontent.com/second',
        profileUrl: 'https://github.com/second',
        commits: 2,
      ),
    ]);

    expect(statsRequests, 2);
    expect(result.map((item) => item.login), ['first', 'second']);
    expect(result.first.displayName, '贡献者昵称');
    expect(result.first.commits, 6);
    expect(result.first.additions, 20);
    expect(result.first.deletions, 3);
    expect(result.last.displayName, '已知昵称');
    expect(maximumProfiles, lessThanOrEqualTo(4));
  });

  test('client caps statistics retries and never fabricates zero line counts',
      () async {
    var statsRequests = 0;
    final client = GitHubContributorsClient(
      statsRetryCount: 999,
      statsRetryDelay: Duration.zero,
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/stats/contributors')) {
          statsRequests++;
          return _json({}, 202);
        }
        if (request.url.path.startsWith('/users/')) return _json({});
        return _json([_user('first', 2)]);
      }),
    );

    final contributor = (await client.fetchContributors()).single;

    expect(statsRequests, 3);
    expect(contributor.commits, 2);
    expect(contributor.additions, isNull);
    expect(contributor.deletions, isNull);
    expect(contributor.statisticsMessage, contains('正在生成'));
  });

  test('generator writes only JSON and check requires no API or auth',
      () async {
    final messages = <String>[];
    final code = await runUpdateContributors(
      ['--output', snapshotFile.path],
      apiHttpClient: _successfulApi(
        expectedAuthorization: 'Bearer test-secret-token',
      ),
      environment: const {'GH_TOKEN': 'test-secret-token'},
      tokenLoader: () async => fail('Environment token must take precedence'),
      now: () => DateTime.utc(2026, 10, 26),
      output: messages.add,
      warning: messages.add,
    );

    expect(code, 0);
    final raw = await snapshotFile.readAsString();
    final snapshot = GitHubContributorsSnapshot.fromJson(jsonDecode(raw));
    expect(snapshot.generatedAt, DateTime.utc(2026, 10, 26));
    expect(snapshot.contributors.single.avatarUrl,
        'https://avatars.githubusercontent.com/first');
    expect((await directory.list().toList()).map((file) => file.uri),
        [snapshotFile.uri]);
    expect(raw, isNot(contains('avatarAsset')));
    expect(raw, isNot(contains('test-secret-token')));
    expect(messages.join('\n'), isNot(contains('test-secret-token')));
    final checked = await runUpdateContributors(
      ['--check', '--output', snapshotFile.path],
      apiHttpClient: MockClient((_) async => fail('Check must not use HTTP')),
      tokenLoader: () async => fail('Check must not read credentials'),
      output: messages.add,
      warning: messages.add,
    );
    expect(checked, 0);
  });

  test('failed API update preserves a complete snapshot without leaking errors',
      () async {
    final original = await _writeSnapshot(snapshotFile);
    final messages = <String>[];
    final code = await runUpdateContributors(
      ['--output', snapshotFile.path],
      apiHttpClient: MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer hidden-token');
        throw http.ClientException('request contained hidden-token');
      }),
      environment: const {'GITHUB_TOKEN': 'hidden-token'},
      output: messages.add,
      warning: messages.add,
    );

    expect(code, 0);
    expect(await snapshotFile.readAsString(), original);
    expect(messages.join('\n'), contains('keeping the existing complete'));
    expect(messages.join('\n'), isNot(contains('hidden-token')));
  });

  test('pending new statistics preserve a complete prior snapshot', () async {
    final original = await _writeSnapshot(snapshotFile);
    final code = await runUpdateContributors(
      ['--output', snapshotFile.path],
      client: GitHubContributorsClient(
        httpClient: _successfulApi(pending: true),
        statsRetryCount: 0,
      ),
      output: (_) {},
      warning: (_) {},
    );

    expect(code, 0);
    expect(await snapshotFile.readAsString(), original);
  });

  test('a new contributor is written without downloading its avatar', () async {
    await _writeSnapshot(snapshotFile);
    final client = GitHubContributorsClient(
      httpClient: MockClient((request) async {
        expect(request.url.host, 'api.github.com');
        if (request.url.path.endsWith('/stats/contributors')) {
          return _json([
            _stats('first', 3, [
              {'a': 20, 'd': 2},
            ]),
            _stats('new-user', 1, [
              {'a': 5, 'd': 1},
            ]),
          ]);
        }
        if (request.url.path.startsWith('/users/')) {
          return _json({'name': '贡献者'});
        }
        return _json([_user('first', 3), _user('new-user', 1)]);
      }),
    );
    final code = await runUpdateContributors(
      ['--output', snapshotFile.path],
      client: client,
      output: (_) {},
      warning: (_) {},
    );

    expect(code, 0);
    final snapshot = GitHubContributorsSnapshot.fromJson(
      jsonDecode(await snapshotFile.readAsString()),
    );
    expect(
        snapshot.contributors.map((item) => item.login), ['first', 'new-user']);
    expect((await directory.list().toList()).map((file) => file.uri),
        [snapshotFile.uri]);
    expect(await _check(snapshotFile), 0);
  });

  test('check rejects missing, malformed, empty and incomplete snapshots',
      () async {
    expect(await _check(snapshotFile), 1);
    await snapshotFile.writeAsString('not JSON');
    expect(await _check(snapshotFile), 1);
    await _writeSnapshot(snapshotFile);
    final json =
        jsonDecode(await snapshotFile.readAsString()) as Map<String, dynamic>;
    (json['contributors'] as List).first['additions'] = null;
    (json['contributors'] as List).first['deletions'] = null;
    await snapshotFile.writeAsString(jsonEncode(json));
    expect(await _check(snapshotFile), 1);
    json['contributors'] = [];
    await snapshotFile.writeAsString(jsonEncode(json));
    expect(await _check(snapshotFile), 1);
  });

  test('an existing gh login authenticates when environment tokens are absent',
      () async {
    var tokenLoads = 0;
    final code = await runUpdateContributors(
      ['--output', snapshotFile.path],
      apiHttpClient: _successfulApi(
        expectedAuthorization: 'Bearer existing-gh-token',
      ),
      environment: const {},
      tokenLoader: () async {
        tokenLoads++;
        return 'existing-gh-token';
      },
      output: (_) {},
      warning: (_) {},
    );

    expect(code, 0);
    expect(tokenLoads, 1);
    expect(await _check(snapshotFile), 0);
  });

  test('first generation fails clearly when no valid fallback is available',
      () async {
    final messages = <String>[];
    final code = await runUpdateContributors(
      ['--output', snapshotFile.path],
      client: GitHubContributorsClient(
        httpClient: MockClient((_) async => _json({}, 403)),
      ),
      output: messages.add,
      warning: messages.add,
    );

    expect(code, 1);
    expect(await snapshotFile.exists(), isFalse);
    expect(messages.join('\n'), contains('no complete local snapshot'));
  });
}

Future<int> _check(File file) => runUpdateContributors(
      ['--check', '--output', file.path],
      tokenLoader: () async => fail('Check cannot read credentials'),
      output: (_) {},
      warning: (_) {},
    );

Future<String> _writeSnapshot(File file) async {
  final snapshot = GitHubContributorsSnapshot(
    generatedAt: DateTime.utc(2026, 10, 25),
    contributors: [
      GitHubContributor(
        login: 'first',
        name: '之前的昵称',
        avatarUrl: 'https://avatars.githubusercontent.com/first',
        profileUrl: 'https://github.com/first',
        commits: 2,
        additions: 10,
        deletions: 1,
      ),
    ],
  );
  final content = jsonEncode(snapshot.toJson());
  await file.writeAsString(content);
  return content;
}

http.Client _successfulApi({
  bool pending = false,
  String? expectedAuthorization,
}) =>
    MockClient((request) async {
      expect(request.url.host, 'api.github.com');
      if (expectedAuthorization != null) {
        expect(request.headers['authorization'], expectedAuthorization);
      }
      if (request.url.path.endsWith('/stats/contributors')) {
        return pending
            ? _json({}, 202)
            : _json([
                _stats('first', 3, [
                  {'a': 20, 'd': 2},
                ]),
              ]);
      }
      if (request.url.path.startsWith('/users/')) return _json({'name': '贡献者'});
      return _json([_user('first', 3)]);
    });

Map<String, Object> _user(String login, int commits) => {
      'login': login,
      'avatar_url': 'https://avatars.githubusercontent.com/$login',
      'html_url': 'https://github.com/$login',
      'contributions': commits,
    };

Map<String, Object> _stats(
  String login,
  int commits,
  List<Map<String, int>> weeks,
) =>
    {
      'author': {'login': login},
      'total': commits,
      'weeks': weeks,
    };

http.Response _json(Object? data, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(data)), status);

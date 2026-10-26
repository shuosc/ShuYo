import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/github_contributor.dart';
import 'package:shuyo/data/services/github_contributors_service.dart';
import 'package:shuyo/features/settings/contributors_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

const _firstContributor = GitHubContributor(
  login: 'shuyo-dev',
  name: 'ShuYo Developer',
  avatarUrl: 'https://avatars.githubusercontent.com/u/1',
  profileUrl: 'https://github.com/shuyo-dev',
  commits: 42,
  additions: 1250,
  deletions: 230,
);

void main() {
  testWidgets('loads names, handles, commits and available line statistics',
      (tester) async {
    final response = Completer<List<GitHubContributor>>();
    final service = _ContributorsService(() => response.future);
    addTearDown(service.close);
    await _pumpPage(tester, service);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    response.complete(const [
      _firstContributor,
      GitHubContributor(
        login: 'another-dev',
        avatarUrl: 'https://avatars.githubusercontent.com/u/2',
        profileUrl: 'https://github.com/another-dev',
        commits: 3,
        statisticsMessage: 'GitHub 正在生成行数统计',
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('ShuYo Developer'), findsOneWidget);
    expect(find.text('@shuyo-dev'), findsOneWidget);
    expect(find.text('42 次提交'), findsOneWidget);
    expect(find.text('+1250'), findsOneWidget);
    expect(find.text('-230'), findsOneWidget);
    expect(find.text('another-dev'), findsOneWidget);
    expect(find.text('@another-dev'), findsOneWidget);
    expect(find.text('3 次提交'), findsOneWidget);
    expect(find.text('GitHub 正在生成行数统计'), findsOneWidget);
    expect(find.text('+0'), findsNothing);
    expect(find.text('-0'), findsNothing);
    expect(tester.getTopLeft(find.text('ShuYo Developer')).dy,
        lessThan(tester.getTopLeft(find.text('another-dev')).dy));

    await tester.pumpWidget(const SizedBox());
    expect(service.closed, isFalse);
  });

  testWidgets('a failed initial request can be retried in the page',
      (tester) async {
    var calls = 0;
    final service = _ContributorsService(() async {
      if (++calls == 1) {
        throw const GitHubContributorsException('贡献者信息读取失败');
      }
      return const [_firstContributor];
    });
    addTearDown(service.close);
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();
    expect(find.text('贡献者加载失败'), findsOneWidget);
    expect(find.text('贡献者信息读取失败'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('ShuYo Developer'), findsOneWidget);
    expect(find.text('贡献者加载失败'), findsNothing);
  });

  testWidgets('scrolling contributors does not request their data again',
      (tester) async {
    var calls = 0;
    final service = _ContributorsService(() async {
      if (++calls > 1) {
        throw const GitHubContributorsException('网络连接失败，请稍后重试');
      }
      return const [_firstContributor];
    });
    addTearDown(service.close);
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('ShuYo Developer'), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsNothing);
    expect(find.text('刷新'), findsNothing);
    expect(find.text('网络连接失败，请稍后重试'), findsNothing);
    expect(find.text('贡献者加载失败'), findsNothing);
  });

  testWidgets('an unavailable online avatar leaves contributor details visible',
      (tester) async {
    // Widget tests return HTTP 400 for images, exercising the avatar fallback.
    final service = _ContributorsService(() async => const [_firstContributor]);
    addTearDown(service.close);
    await _pumpPage(tester, service);
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.person_outline), findsOneWidget);
    expect(find.text('ShuYo Developer'), findsOneWidget);
    expect(find.text('+1250'), findsOneWidget);
    expect(find.text('-230'), findsOneWidget);
    expect(find.text('贡献者加载失败'), findsNothing);
    expect(find.byType(RefreshIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long names and handles fit a narrow screen with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = _ContributorsService(() async => const [
          GitHubContributor(
            login: 'a-very-long-github-contributor-handle',
            name: '一位有很长昵称的 ShuYo 项目贡献者',
            avatarUrl: 'https://avatars.githubusercontent.com/u/1',
            profileUrl: 'https://github.com/example',
            commits: 12345,
            additions: 123456789,
            deletions: 98765432,
          ),
        ]);
    addTearDown(service.close);
    await _pumpPage(tester, service, textScaler: TextScaler.linear(2));
    await tester.pumpAndSettle();

    expect(find.text('一位有很长昵称的 ShuYo 项目贡献者'), findsOneWidget);
    expect(find.text('@a-very-long-github-contributor-handle'), findsOneWidget);
    expect(find.text('+123456789'), findsOneWidget);
    expect(find.text('-98765432'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  GitHubContributorsService service, {
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: ContributorsPage(service: service),
    ),
  );
}

class _ContributorsService extends GitHubContributorsService {
  _ContributorsService(this._fetch);

  final Future<List<GitHubContributor>> Function() _fetch;
  bool closed = false;

  @override
  Future<List<GitHubContributor>> fetchContributors() => _fetch();

  @override
  void close() {
    closed = true;
    super.close();
  }
}

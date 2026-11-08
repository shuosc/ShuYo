import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/classroom_url_resolver.dart';
import 'package:shuyo/data/models/classroom.dart';
import 'package:shuyo/data/models/client_backend.dart';
import 'package:shuyo/data/repositories/classroom_repository.dart';
import 'package:shuyo/data/services/classroom_api_client.dart';
import 'package:shuyo/data/services/unified_account_service.dart';
import 'package:shuyo/features/home/empty_classroom_page.dart';

const _options = ClassroomSearchOptions(
  buildings: [
    ClassroomBuilding(id: 1, name: 'A楼', campusId: 3, campusName: '宝山'),
  ],
  sections: [
    ClassroomSection(index: 1, startTime: '08:00', endTime: '08:45'),
  ],
);

Finder _button(String label) => find
    .ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    )
    .first;

Future<void> _open(
  WidgetTester tester,
  _RoutingRepository repository, {
  Future<WebVpnRecoveryOutcome> Function(bool)? recover,
  WebVpnServiceStatus Function()? health,
  double textScale = 1,
}) async {
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: EmptyClassroomPage(
      repository: repository,
      initialDate: DateTime(2026, 11, 8),
      onWebVpnRecoveryRequired: recover,
      webVpnServiceStatus: health,
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(
        {'client.network.webvpn.enabled': true});
    ClassroomUrlResolver.configure(useWebVpn: true);
  });
  tearDown(() => ClassroomUrlResolver.configure(useWebVpn: false));

  testWidgets(
      'WebVPN timeouts show route-specific copy and both actions below filters',
      (tester) async {
    final repository = _RoutingRepository()
      ..onSearch = (_, __) async => throw TimeoutException('gateway timeout');
    await _open(tester, repository);

    expect(find.textContaining('通过WebVPN连接空教室失败'), findsOneWidget);
    expect(find.textContaining('开启WebVPN'), findsNothing);
    expect(find.text('尝试直连'), findsOneWidget);
    expect(find.text('重试WebVPN'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    await tester.ensureVisible(_button('尝试直连'));
    expect(tester.getRect(_button('尝试直连')).right,
        lessThan(tester.getRect(_button('重试WebVPN')).left));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a late network error keeps the route used before a setting change',
      (tester) async {
    final pending = Completer<ClassroomAvailabilityResult>();
    final repository = _RoutingRepository()
      ..onSearch = (_, __) => pending.future;
    await tester.pumpWidget(
        MaterialApp(home: EmptyClassroomPage(repository: repository)));
    await tester.pump();
    ClassroomUrlResolver.configure(useWebVpn: false);
    pending.completeError(TimeoutException('late gateway timeout'));
    await tester.pumpAndSettle();

    expect(find.textContaining('通过WebVPN连接空教室失败'), findsOneWidget);
    expect(find.text('重试WebVPN'), findsOneWidget);
    expect(find.textContaining('开启WebVPN'), findsNothing);
    expect(ClassroomUrlResolver.usesWebVpn, isFalse);
  });

  testWidgets('direct failures only offer the ordinary retry action',
      (tester) async {
    ClassroomUrlResolver.configure(useWebVpn: false);
    final repository = _RoutingRepository()
      ..onSearch = (_, __) async => throw TimeoutException('direct timeout');
    await _open(tester, repository);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('尝试直连'), findsNothing);
    expect(find.text('重试WebVPN'), findsNothing);
  });

  testWidgets(
      'direct cold retry covers options and query without changing global preferences',
      (tester) async {
    final options = Completer<ClassroomSearchOptions>();
    final repository = _RoutingRepository(hasSnapshot: false)
      ..onLoad = (mode) => mode == ClassroomAccessMode.webVpn
          ? Future.error(TimeoutException('gateway unavailable'))
          : options.future;
    await _open(tester, repository);
    final revision = ClassroomUrlResolver.revision;
    expect(find.text('空教室加载失败'), findsOneWidget);

    await tester.tap(_button('尝试直连'));
    await tester.tap(_button('重试WebVPN'));
    await tester.pump();
    expect(repository.loadModes,
        [ClassroomAccessMode.webVpn, ClassroomAccessMode.direct]);
    expect(tester.widget<ButtonStyleButton>(_button('尝试直连')).onPressed, isNull);
    expect(tester.widget<ButtonStyleButton>(_button('重试WebVPN')).onPressed,
        isNull);
    expect(
        find.descendant(
            of: _button('尝试直连'),
            matching: find.byType(CircularProgressIndicator)),
        findsOneWidget);
    expect(ClassroomUrlResolver.usesWebVpn, isTrue);
    expect(ClassroomUrlResolver.revision, revision);

    options.complete(_options);
    await tester.pumpAndSettle();
    expect(repository.searchModes, [ClassroomAccessMode.direct]);
    expect(repository.loadRefreshes, [false, true]);
    expect(repository.searchRefreshes, [true]);
    expect(find.text('没有空教室'), findsOneWidget);
    expect(
        (await SharedPreferences.getInstance())
            .getBool('client.network.webvpn.enabled'),
        isTrue);
    expect(ClassroomUrlResolver.revision, revision);

    await tester.tap(find.text('明天'));
    await tester.pumpAndSettle();
    expect(repository.searchModes.last, ClassroomAccessMode.webVpn);
  });

  testWidgets(
      'a failed direct cold retry renders the direct error and remains retryable',
      (tester) async {
    final repository = _RoutingRepository(hasSnapshot: false)
      ..onLoad = (_) async => throw TimeoutException('connection failed');
    await _open(tester, repository);
    await tester.tap(_button('尝试直连'));
    await tester.pumpAndSettle();
    expect(find.text('空教室加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('重试WebVPN'), findsNothing);
    expect(find.textContaining('开启WebVPN'), findsNothing);
    await tester.tap(_button('重试'));
    await tester.pumpAndSettle();
    expect(repository.loadModes, [
      ClassroomAccessMode.webVpn,
      ClassroomAccessMode.direct,
      ClassroomAccessMode.direct
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'toolbar refresh is disabled until the current cold load completes',
      (tester) async {
    final options = Completer<ClassroomSearchOptions>();
    final repository = _RoutingRepository(hasSnapshot: false)
      ..onLoad = (_) => options.future;
    await tester.pumpWidget(
        MaterialApp(home: EmptyClassroomPage(repository: repository)));
    await tester.pump();
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '刷新'))
            .onPressed,
        isNull);
    options.complete(_options);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '刷新'))
            .onPressed,
        isNotNull);
    expect(repository.loadModes, hasLength(1));
  });

  testWidgets(
      'toolbar refresh retries the global route and handles a cold-load failure',
      (tester) async {
    final repository = _RoutingRepository(hasSnapshot: false)
      ..onLoad = (_) async => throw TimeoutException('connection failed');
    await _open(tester, repository);
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(repository.loadModes,
        [ClassroomAccessMode.webVpn, ClassroomAccessMode.webVpn]);
    expect(find.text('重试WebVPN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'query fallback preserves selection and ordinary retry stays on the failed direct route',
      (tester) async {
    final repository = _RoutingRepository()
      ..onSearch =
          (_, mode) async => throw TimeoutException('${mode.name} failed');
    await _open(tester, repository);
    final query = repository.queries.single;
    await tester.ensureVisible(_button('尝试直连'));
    await tester.tap(_button('尝试直连'));
    await tester.pumpAndSettle();

    expect(repository.searchModes,
        [ClassroomAccessMode.webVpn, ClassroomAccessMode.direct]);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('重试WebVPN'), findsNothing);
    expect(find.textContaining('开启WebVPN'), findsNothing);
    await tester.ensureVisible(_button('重试'));
    await tester.tap(_button('重试'));
    await tester.pumpAndSettle();
    expect(repository.searchModes.last, ClassroomAccessMode.direct);
    expect(
        repository.queries.every((q) =>
            q.building.id == query.building.id &&
            q.date == query.date &&
            q.startSection == query.startSection &&
            q.endSection == query.endSection),
        isTrue);
    expect(ClassroomUrlResolver.usesWebVpn, isTrue);
  });

  testWidgets('WebVPN retry shows progress and blocks duplicate route requests',
      (tester) async {
    final pending = Completer<ClassroomAvailabilityResult>();
    final repository = _RoutingRepository();
    repository.onSearch = (query, _) => repository.searchModes.length == 1
        ? Future.error(TimeoutException('gateway timeout'))
        : pending.future;
    await _open(tester, repository);
    await tester.ensureVisible(_button('重试WebVPN'));
    await tester.tap(_button('重试WebVPN'));
    await tester.pump();
    expect(tester.widget<ButtonStyleButton>(_button('尝试直连')).onPressed, isNull);
    expect(tester.widget<ButtonStyleButton>(_button('重试WebVPN')).onPressed,
        isNull);
    expect(
        find.descendant(
            of: _button('重试WebVPN'),
            matching: find.byType(CircularProgressIndicator)),
        findsOneWidget);
    expect(repository.searchModes,
        [ClassroomAccessMode.webVpn, ClassroomAccessMode.webVpn]);
    pending.complete(_emptyResult(repository.queries.last));
    await tester.pumpAndSettle();
    expect(find.text('没有空教室'), findsOneWidget);
  });

  for (final outcome in [
    WebVpnRecoveryOutcome.unavailable,
    WebVpnRecoveryOutcome.businessFailure
  ]) {
    testWidgets('recovery $outcome is not reported as an expired login',
        (tester) async {
      var recoveries = 0;
      final repository = _RoutingRepository()
        ..onSearch =
            (_, __) async => throw const ClassroomWebVpnAuthException();
      await _open(tester, repository, recover: (_) async {
        recoveries++;
        return outcome;
      });
      expect(recoveries, 1);
      expect(find.textContaining('需要重新登录'), findsNothing);
      expect(find.text('尝试直连'), findsOneWidget);
      expect(find.text('重试WebVPN'), findsOneWidget);
    });
  }

  testWidgets(
      'confirmed authentication failure exposes login recovery instead of route buttons',
      (tester) async {
    final repository = _RoutingRepository()
      ..onSearch = (_, __) async => throw const ClassroomWebVpnAuthException();
    await _open(tester, repository,
        recover: (_) async => WebVpnRecoveryOutcome.needsAuthentication);
    expect(find.text('恢复WebVPN登录'), findsOneWidget);
    expect(find.text('尝试直连'), findsNothing);
    expect(find.text('重试WebVPN'), findsNothing);
  });

  for (final fresh in [true, false]) {
    testWidgets(
        'provider-outage copy only uses fresh health status: fresh=$fresh',
        (tester) async {
      var recoveries = 0;
      final repository = _RoutingRepository()
        ..onSearch =
            (_, __) async => throw const ClassroomWebVpnAuthException();
      await _open(
        tester,
        repository,
        recover: (_) async {
          recoveries++;
          return WebVpnRecoveryOutcome.unavailable;
        },
        health: () => WebVpnServiceStatus(
          state: WebVpnServiceState.unavailable,
          checkedAt: DateTime.now().subtract(Duration(minutes: fresh ? 0 : 6)),
          statusSince: null,
          lastSuccessAt: null,
          latencyMs: null,
          reason: 'gateway_unavailable',
        ),
      );
      expect(find.textContaining('当前WebVPN服务不可用'),
          fresh ? findsOneWidget : findsNothing);
      expect(recoveries, fresh ? 0 : 1);
      expect(find.text('尝试直连'), findsOneWidget);
      expect(find.textContaining('需要重新登录'), findsNothing);
    });
  }

  testWidgets('small screens and large text stack actions without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _RoutingRepository(hasSnapshot: false)
      ..onLoad = (_) async => throw TimeoutException('gateway timeout');
    await _open(tester, repository, textScale: 2);
    await tester.ensureVisible(_button('重试WebVPN'));
    final direct = tester.getRect(_button('尝试直连'));
    final retry = tester.getRect(_button('重试WebVPN'));
    expect(direct.bottom, lessThan(retry.top));
    expect(direct.left, closeTo(retry.left, 1));
    expect(direct.right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
  });
}

ClassroomAvailabilityResult _emptyResult(ClassroomAvailabilityQuery query) =>
    ClassroomAvailabilityResult(
      building: query.building,
      date: query.date,
      startSection: query.startSection,
      endSection: query.endSection,
      floors: const [],
    );

class _RoutingRepository extends ClassroomRepository {
  _RoutingRepository({this.hasSnapshot = true});
  final bool hasSnapshot;
  Future<ClassroomSearchOptions> Function(ClassroomAccessMode)? onLoad;
  Future<ClassroomAvailabilityResult> Function(
      ClassroomAvailabilityQuery, ClassroomAccessMode)? onSearch;
  final loadModes = <ClassroomAccessMode>[];
  final searchModes = <ClassroomAccessMode>[];
  final loadRefreshes = <bool>[];
  final searchRefreshes = <bool>[];
  final queries = <ClassroomAvailabilityQuery>[];

  @override
  ClassroomSearchOptions? get optionsSnapshot => hasSnapshot ? _options : null;

  @override
  Future<ClassroomSearchOptions> loadOptions(
      {bool forceRefresh = false, ClassroomAccessMode? accessMode}) async {
    final mode = accessMode ?? ClassroomUrlResolver.accessMode;
    loadModes.add(mode);
    loadRefreshes.add(forceRefresh);
    return onLoad == null ? _options : await onLoad!(mode);
  }

  @override
  Future<ClassroomAvailabilityResult> search(
    ClassroomAvailabilityQuery query, {
    bool forceRefresh = false,
    ClassroomAccessMode? accessMode,
  }) async {
    final mode = accessMode ?? ClassroomUrlResolver.accessMode;
    searchModes.add(mode);
    searchRefreshes.add(forceRefresh);
    queries.add(query);
    return onSearch == null
        ? _emptyResult(query)
        : await onSearch!(query, mode);
  }
}

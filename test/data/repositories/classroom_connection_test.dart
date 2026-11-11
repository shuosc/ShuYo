import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/classroom_url_resolver.dart';
import 'package:shuyo/data/models/classroom.dart';
import 'package:shuyo/data/repositories/classroom_repository.dart';
import 'package:shuyo/data/services/classroom_api_client.dart';
import 'package:shuyo/data/services/classroom_auth_service.dart';
import 'package:shuyo/data/services/session_cookie_jar.dart';

const _building = ClassroomBuilding(
  id: 1,
  name: 'A楼',
  campusId: 3,
  campusName: '宝山',
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ClassroomUrlResolver.configure(useWebVpn: true);
  });
  tearDown(() => ClassroomUrlResolver.configure(useWebVpn: false));

  ClassroomRepository repository(List<http.Request> requests) =>
      ClassroomRepository(
        apiClient: ClassroomApiClient(
          authService: ClassroomAuthService(
            cookieLoader: (_) async => const [
              SessionCookie(
                name: 'webvpn-token',
                value: 'gateway',
                domain: 'webvpn.shu.edu.cn',
              ),
            ],
          ),
          httpClient: MockClient((request) async {
            requests.add(request);
            return http.Response('{"code":200,"data":{}}', 200);
          }),
        ),
      );

  ClassroomAvailabilityQuery query() => ClassroomAvailabilityQuery(
        building: _building,
        date: DateTime(2026, 11, 8),
        startSection: 1,
        endSection: 2,
      );

  test('direct override is per operation and caches stay transport-specific',
      () async {
    final requests = <http.Request>[];
    final repo = repository(requests);
    final revision = ClassroomUrlResolver.revision;

    await repo.search(query());
    await repo.search(query(), accessMode: ClassroomAccessMode.direct);
    await repo.search(query());
    await repo.search(query(), accessMode: ClassroomAccessMode.direct);

    expect(requests.map((request) => request.url.host), [
      ClassroomUrlResolver.webVpnHost,
      ClassroomUrlResolver.directHost,
    ]);
    expect(requests.last.headers, isNot(contains('cookie')));
    expect(ClassroomUrlResolver.usesWebVpn, isTrue);
    expect(ClassroomUrlResolver.revision, revision);
  });

  test('explicit retries bypass the chosen transport cache', () async {
    final requests = <http.Request>[];
    final repo = repository(requests);
    await repo.search(query(), accessMode: ClassroomAccessMode.direct);
    await repo.search(query(),
        accessMode: ClassroomAccessMode.direct, forceRefresh: true);
    expect(requests, hasLength(2));
    expect(requests.every((r) => r.url.host == ClassroomUrlResolver.directHost),
        isTrue);
  });

  test('direct cold load uses direct mode for both option endpoints', () async {
    final requests = <http.Request>[];
    final repo = repository(requests);
    await repo.loadOptions(
        forceRefresh: true, accessMode: ClassroomAccessMode.direct);
    expect(requests, hasLength(2));
    expect(requests.every((r) => r.url.host == ClassroomUrlResolver.directHost),
        isTrue);
    expect(ClassroomUrlResolver.usesWebVpn, isTrue);
  });

  test('option load snapshots the mode before preferences resolve', () async {
    final preferences = Completer<SharedPreferences>();
    final requests = <http.Request>[];
    final repo = ClassroomRepository(
      preferencesLoader: () => preferences.future,
      apiClient: ClassroomApiClient(
        authService: ClassroomAuthService(
          cookieLoader: (_) async => const [
            SessionCookie(
              name: 'webvpn-token',
              value: 'gateway',
              domain: 'webvpn.shu.edu.cn',
            ),
          ],
        ),
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('{"code":200,"data":{}}', 200);
        }),
      ),
    );
    final pending = repo.loadOptions();
    ClassroomUrlResolver.configure(useWebVpn: false);
    preferences.complete(await SharedPreferences.getInstance());
    await pending;
    expect(requests, hasLength(2));
    expect(requests.every((r) => r.url.host == ClassroomUrlResolver.webVpnHost),
        isTrue);
    expect(ClassroomUrlResolver.usesWebVpn, isFalse);
  });
}

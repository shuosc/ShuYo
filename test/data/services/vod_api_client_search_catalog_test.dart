import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
import 'package:shuyo/data/services/vod_auth_service.dart';

http.Response _page(List<Object?> records) => http.Response(
      jsonEncode({
        'status': 200,
        'data': {
          'pageIndex': 1,
          'pageCount': records.isEmpty ? 0 : 1,
          'rowCount': records.length,
          'records': records,
        },
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

class _Auth extends VodAuthService {
  final refreshes = <bool>[];
  @override
  Future<void> ensureSession(
          {required bool useWebVpn, bool forceRefresh = false}) async =>
      refreshes.add(forceRefresh);
  @override
  Future<Map<String, String>> headersFor(Uri uri, {bool? useWebVpn}) async =>
      {};
}

void main() {
  for (final sample in [(26854, 282016), (27213, 281778)]) {
    test('independent monitor keeps observed generation item ${sample.$2}',
        () async {
      final api = VodApiClient(
        headersLoader: (_) async => {},
        uriResolver: (path, params) => Uri.https('vod.example', path, params),
        httpClient: MockClient((request) async {
          expect(request.url.path, '/v1/vod/monitor');
          expect(request.method, 'POST');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['teclId'], sample.$1);
          expect(body['page']['pageSize'], 1000);
          return _page([
            for (final (id, status) in [
              (sample.$2, 4),
              (sample.$2 + 1, 6),
              (sample.$2 + 2, 2),
            ])
              {
                'id': id,
                'teclId': sample.$1,
                'acteId': 7,
                'subjName': '大学物理',
                'courBeginTime': '2026-11-02 13:00:00',
                'courEndTime': '2026-11-02 13:45:00',
                'vodStatusShow': status,
                'vodStatus': status,
                'vodEnable': 1,
                'vodDeleteStatus': 0,
              },
          ]);
        }),
      );
      addTearDown(api.dispose);
      final result = await api.fetchGeneratingLessons(
          VodCourse(teachingClassId: sample.$1, termId: 7, name: '大学物理'));
      expect(result.single.id, sample.$2);
      expect(result.single.isGenerating, isTrue);
    });
  }

  test('viewer preview finishes while optional generation request is pending',
      () async {
    final monitor = Completer<http.Response>();
    final api = VodApiClient(
      headersLoader: (_) async => {},
      uriResolver: (path, params) => Uri.https('vod.example', path, params),
      httpClient: MockClient((request) async => request.method == 'POST'
          ? await monitor.future
          : _page([
              {'id': 10, 'teclId': 42, 'acteId': 7, 'subjName': '课程'},
            ])),
    );
    addTearDown(api.dispose);
    const course = VodCourse(teachingClassId: 42, termId: 7, name: '课程');
    final pending = api.fetchGeneratingLessons(course);
    expect((await api.fetchSearchLessons(course)).single.id, 10);
    monitor.complete(_page([]));
    expect(await pending, isEmpty);
  });

  test('optional generation 401 cannot force shared session renewal', () async {
    final auth = _Auth();
    final api = VodApiClient(
      authService: auth,
      uriResolver: (path, params) => Uri.https('vod.example', path, params),
      httpClient: MockClient((_) async => http.Response('expired', 401)),
    );
    addTearDown(api.dispose);
    addTearDown(auth.dispose);
    await expectLater(
        api.fetchGeneratingLessons(
            const VodCourse(teachingClassId: 42, termId: 7, name: '课程')),
        throwsA(isA<VodSessionExpiredException>()));
    expect(auth.refreshes, everyElement(isFalse));
  });

  testWidgets('generation HTTP timeouts keep the actual in-flight budget',
      (tester) async {
    final responses = <Completer<http.Response>>[];
    final api = VodApiClient(
      headersLoader: (_) async => {},
      uriResolver: (path, params) => Uri.https('vod.example', path, params),
      httpClient: MockClient((_) {
        final response = Completer<http.Response>();
        responses.add(response);
        return response.future;
      }),
    );
    addTearDown(api.dispose);
    Future<void> load(int id) async {
      try {
        await api.fetchGeneratingLessons(
            VodCourse(teachingClassId: id, termId: 7, name: '课程'));
      } on VodNetworkException {
        // An unavailable optional status check does not change the preview.
      }
    }

    final initial = Future.wait([load(1), load(2), load(3)]);
    await tester.pump();
    expect(responses, hasLength(3));
    await load(4);
    expect(responses, hasLength(3));
    await tester.pump(const Duration(seconds: 11));
    await initial;
    await load(5);
    expect(responses, hasLength(3));
    responses.first.complete(_page([]));
    await tester.pump();
    final replacement = load(6);
    await tester.pump();
    expect(responses, hasLength(4));
    for (final response in responses.skip(1)) {
      response.complete(_page([]));
    }
    await tester.pump();
    await replacement;
  });
}

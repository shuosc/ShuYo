import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
import 'package:shuyo/data/services/vod_auth_service.dart';

class _SessionAuth extends VodAuthService {
  _SessionAuth({this.onEnsure});

  final Future<void> Function(bool forceRefresh)? onEnsure;
  final ensureCalls = <bool>[];
  int clears = 0;
  String token = 'test-original-token';

  @override
  Future<void> ensureSession({
    required bool useWebVpn,
    bool forceRefresh = false,
  }) async {
    ensureCalls.add(forceRefresh);
    await onEnsure?.call(forceRefresh);
    if (forceRefresh) token = 'test-renewed-token';
  }

  @override
  Future<Map<String, String>> headersFor(Uri uri, {bool? useWebVpn}) async =>
      {'jwt-token': token};

  @override
  Future<void> clearSession({bool? useWebVpn}) async {
    clears++;
    throw StateError('business requests must not clear campus authentication');
  }
}

const _course = VodCourse(
  teachingClassId: 42,
  termId: 7,
  name: '课程甲',
);
const _lesson = VodLesson(
  id: 123,
  teachingClassId: 42,
  name: '课程甲',
  isPlayable: true,
);

http.Response _response(Object? data) => http.Response(
      jsonEncode({'status': 200, 'ok': true, 'dataOk': true, 'data': data}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, Object?> _permission() => {
      'resourceList': [
        {'sign': 'p2-video-page'},
        {'sign': 'p2-video-playback-view'},
      ],
    };

Map<String, Object?> _detail({
  int courseId = 123,
  int teachingClassId = 42,
  int viewCourseId = 123,
  int permission = 1,
}) =>
    {
      'id': courseId,
      'teclId': teachingClassId,
      'lvcrVodStatus': permission,
      'courName': '课程甲',
      'lastPlayTime': 89,
      'voiceChannel': 7,
      'courseVodViewList': [
        {
          'courId': viewCourseId,
          'viewNum': 7,
          'url': 'https://media.example/clip.mp4?auth_key=opaque%2Bsignature',
        },
      ],
    };

VodApiClient _client(
  Future<http.Response> Function(http.Request) handler, {
  int pageSize = 2,
  VodHeadersLoader? mediaHeadersLoader,
}) =>
    VodApiClient(
      httpClient: MockClient(handler),
      headersLoader: (_) async => {'jwt-token': 'test-business-token'},
      mediaHeadersLoader: mediaHeadersLoader ?? (_) async => {},
      uriResolver: (path, parameters) => Uri.https(
        'vod.example',
        path,
        parameters,
      ),
      mediaUrlResolver: Uri.parse,
      pageSize: pageSize,
    );

void main() {
  test('course progress publishes each parsed course before later pages finish',
      () async {
    final secondPage = Completer<http.Response>();
    final secondRequested = Completer<void>();
    final client = _client((request) async {
      final page = int.parse(request.url.queryParameters['page.pageIndex']!);
      if (page == 2) {
        secondRequested.complete();
        return secondPage.future;
      }
      return _response({
        'pageIndex': 1,
        'pageCount': 2,
        'rowCount': 3,
        'records': [
          for (final id in [42, 43])
            {'teclId': id, 'acteId': 7, 'subjName': '课程$id'},
        ],
      });
    });
    addTearDown(client.dispose);
    final snapshots = <List<VodCourse>>[];
    final result = client.fetchCourses(termId: 7, onProgress: snapshots.add);
    await secondRequested.future;
    expect(snapshots.map((snapshot) => snapshot.length), [1, 2]);
    expect(snapshots.first.single.teachingClassId, 42);
    expect(() => snapshots.last.add(_course), throwsUnsupportedError);
    secondPage.complete(_response({
      'pageIndex': 2,
      'pageCount': 2,
      'rowCount': 3,
      'records': [
        {'teclId': 44, 'acteId': 7, 'subjName': '课程44'},
      ],
    }));
    expect(
        (await result).map((course) => course.teachingClassId), [42, 43, 44]);
    expect(snapshots.map((snapshot) => snapshot.length), [1, 2, 3]);
  });

  test('live progress publishes available lessons before later pages finish',
      () async {
    final secondPage = Completer<http.Response>();
    final secondRequested = Completer<void>();
    final client = _client((request) async {
      expect(request.url.path, '/v1/vod_live/t-1');
      final page = int.parse(request.url.queryParameters['page.pageIndex']!);
      if (page == 2) {
        secondRequested.complete();
        return secondPage.future;
      }
      return _response({
        'pageIndex': 1,
        'pageCount': 2,
        'rowCount': 3,
        'records': [
          for (final id in [123, 124])
            {
              'id': id,
              'teclId': 42,
              'acteId': 7,
              'subjName': '课程$id',
              'liveType': 0,
            },
        ],
      });
    });
    addTearDown(client.dispose);
    final snapshots = <List<VodLesson>>[];
    final result =
        client.fetchLiveLessons(termId: 7, onProgress: snapshots.add);
    await secondRequested.future;
    expect(snapshots.map((snapshot) => snapshot.length), [1, 2]);
    expect(() => snapshots.last.add(_lesson), throwsUnsupportedError);
    secondPage.complete(_response({
      'pageIndex': 2,
      'pageCount': 2,
      'rowCount': 3,
      'records': [
        {
          'id': 125,
          'teclId': 42,
          'acteId': 7,
          'subjName': '未开播',
          'liveType': 1,
        },
      ],
    }));
    expect((await result).map((lesson) => lesson.id), [123, 124]);
    expect(snapshots.map((snapshot) => snapshot.length), [1, 2]);
  });

  test('partial course progress never accepts another term', () async {
    final client = _client((_) async => _response({
          'pageCount': 1,
          'rowCount': 2,
          'records': [
            {'teclId': 42, 'acteId': 7, 'subjName': '正确学期'},
            {'teclId': 43, 'acteId': 6, 'subjName': '其他学期'},
          ],
        }));
    addTearDown(client.dispose);
    final snapshots = <List<VodCourse>>[];
    await expectLater(client.fetchCourses(termId: 7, onProgress: snapshots.add),
        throwsA(isA<VodInvalidResponseException>()));
    expect(snapshots, hasLength(1));
    expect(snapshots.single.single.teachingClassId, 42);
  });

  test('term API accepts bare arrays and epoch timestamps', () async {
    final client = _client((request) async => http.Response(
        jsonEncode([
          {
            'id': 6,
            'acyeCode': '2025-2026',
            'acteTerm': 2,
            'currentTerm': false,
          },
          {
            'id': 7,
            'acyeCode': '2026-2027',
            'acteTerm': 1,
            'currentTerm': true,
            'acteBeginDate': 1789344000000,
          },
        ]),
        200));
    addTearDown(client.dispose);

    final terms = await client.fetchTerms();
    expect(terms.map((term) => term.id), [7, 6]);
    expect(terms.first.name, '2026-2027学年第1学期');
    expect(terms.first.academicYear, '2026-2027');
    expect(terms.first.termNumber, 1);
    expect(terms.first.academicYearLabel, '26-27学年');
    expect(terms.first.seasonLabel, '秋季学期');
    expect(terms.first.startDate?.millisecondsSinceEpoch, 1789344000000);
  });

  test('term catalog starts at the first term of 2025-2026', () async {
    final client = _client((request) async => http.Response(
        jsonEncode([
          {
            'id': 99,
            'acyeCode': '2024-2025',
            'acteTerm': 3,
            'currentTerm': true,
          },
          {'id': 98, 'acyeCode': '2023-2024', 'acteTerm': 1},
          {'id': 5, 'acyeCode': '2025-2026', 'acteTerm': 1},
          {'id': 6, 'acyeCode': '2025-2026', 'acteTerm': 2},
          {'id': 7, 'acyeCode': '2026-2027', 'acteTerm': 1},
          {'id': 8, 'acyeCode': '2025-2026', 'acteTerm': 0},
          {'id': 9, 'acteTerm': 1},
        ]),
        200));
    addTearDown(client.dispose);

    final terms = await client.fetchTerms();
    expect(terms.map((term) => term.id), [7, 6, 5]);
    expect(terms.last.name, '2025-2026学年第1学期');
  });

  test('term catalog is empty when all terms predate 2025-2026', () async {
    final client = _client((request) async => http.Response(
        jsonEncode([
          {'id': 4, 'acyeCode': '2024-2025', 'acteTerm': 3},
          {'id': 3, 'acyeCode': '2024-2025', 'acteTerm': 2},
        ]),
        200));
    addTearDown(client.dispose);

    expect(await client.fetchTerms(), isEmpty);
  });

  test('ordinary class catalog follows all pages with no global flags',
      () async {
    final pages = <int>[];
    final client = _client((request) async {
      expect(request.url.path, '/v1/group_subject_vod_list/t-1');
      final query = request.url.queryParameters;
      expect(query['acteId'], '7');
      expect(query.containsKey('isAdmin'), isFalse);
      expect(query.containsKey('showAllVodCourse'), isFalse);
      final page = int.parse(query['page.pageIndex']!);
      pages.add(page);
      return _response({
        'pageIndex': page,
        'pageCount': 2,
        'rowCount': 3,
        'records': [
          for (final id in page == 1 ? [42, 43] : [44])
            {
              'id': 999,
              'teclId': id,
              'acteId': 7,
              'subjName': '课程$id',
              'teacNames': ['教师甲'],
            },
        ],
      });
    });
    addTearDown(client.dispose);

    final courses = await client.fetchCourses(termId: 7);
    expect(pages, [1, 2]);
    expect(courses.map((course) => course.teachingClassId), [42, 43, 44]);
    expect(courses.first.teacherLabel, '教师甲');
  });

  test('missing pages fail instead of returning an incomplete catalog',
      () async {
    final client = _client((request) async => _response({
          'pageIndex':
              int.parse(request.url.queryParameters['page.pageIndex']!),
          'pageCount': 2,
          'rowCount': 3,
          'records': [],
        }));
    addTearDown(client.dispose);
    await expectLater(client.fetchCourses(termId: 7),
        throwsA(isA<VodInvalidResponseException>()));
  });

  test('duplicate page rows cannot masquerade as a complete catalog', () async {
    final client = _client((request) async {
      final page = int.parse(request.url.queryParameters['page.pageIndex']!);
      return _response({
        'pageIndex': page,
        'pageCount': 2,
        'rowCount': 4,
        'records': [
          for (final id in page == 1 ? [42, 43] : [43, 44])
            {'teclId': id, 'acteId': 7, 'subjName': '课程$id'},
        ],
      });
    });
    addTearDown(client.dispose);
    await expectLater(client.fetchCourses(termId: 7),
        throwsA(isA<VodInvalidResponseException>()));
  });

  test('a changed total between pages requires a consistent refresh', () async {
    final client = _client((request) async {
      final page = int.parse(request.url.queryParameters['page.pageIndex']!);
      return _response({
        'pageIndex': page,
        'pageCount': 2,
        'rowCount': page == 1 ? 4 : 3,
        'records': [
          for (final id in page == 1 ? [42, 43] : [44])
            {'teclId': id, 'acteId': 7, 'subjName': '课程$id'},
        ],
      });
    });
    addTearDown(client.dispose);
    await expectLater(client.fetchCourses(termId: 7),
        throwsA(isA<VodInvalidResponseException>()));
  });

  test(
      'lesson list retains unavailable recordings but removes deleted and disabled entries',
      () async {
    final client = _client((request) async {
      if (request.url.path.endsWith('/resources')) {
        return _response(_permission());
      }
      expect(request.url.path, '/v1/subject_vod_list_new');
      expect(request.url.queryParameters['teclIds'], '42');
      expect(request.url.queryParameters['schoolOpenStatusFlag'], 'false');
      return _response({
        'rowCount': 6,
        'pageCount': 1,
        'records': [
          for (var i = 0; i < 6; i++)
            {
              'id': i + 1,
              'teclId': 42,
              'subjName': '课程甲',
              'courBeginTime': '2026-10-20 08:00:00',
              'vodEnable': i == 1 ? 0 : 1,
              'vodClickEnable': i == 2 ? 0 : 1,
              'vodDeleteStatus': i == 3 ? 1 : 0,
              'vodStatus': i == 4 ? 2 : (i == 5 ? 4 : 5),
            },
        ],
      });
    });
    addTearDown(client.dispose);
    final lessons = await client.fetchLessons(_course);
    expect(lessons.map((lesson) => lesson.id), [1, 3, 5, 6]);
    expect(lessons.where((lesson) => lesson.canPlay).map((lesson) => lesson.id),
        [1]);
    expect(lessons.first.beginTime?.hour, 8);
  });

  test('viewer resource permission is required before listing lessons',
      () async {
    final requests = <String>[];
    final client = _client((request) async {
      requests.add(request.url.path);
      return _response({'resourceList': []});
    });
    addTearDown(client.dispose);
    await expectLater(
        client.fetchLessons(_course), throwsA(isA<VodPermissionException>()));
    expect(requests, ['/v1/course-role-permission/teaching-class/resources']);
  });

  test('verify false stops before obtaining any media URL', () async {
    final requests = <String>[];
    final client = _client((request) async {
      requests.add(request.url.path);
      if (request.url.path.endsWith('/resources')) {
        return _response(_permission());
      }
      expect(request.url.path, '/v1/course/verify');
      expect(request.url.queryParameters['courId'], '123');
      return _response({'verify': false});
    });
    addTearDown(client.dispose);
    await expectLater(
      client.fetchPlayback(course: _course, lesson: _lesson),
      throwsA(isA<VodPermissionException>()),
    );
    expect(requests, [
      '/v1/course-role-permission/teaching-class/resources',
      '/v1/course/verify',
    ]);
  });

  test(
      'playback preserves signature and requests target-specific media headers',
      () async {
    final mediaTargets = <Uri>[];
    final client = _client((request) async {
      if (request.url.path.endsWith('/resources')) {
        return _response(_permission());
      }
      if (request.url.path.endsWith('/verify')) {
        return _response({'verify': true});
      }
      expect(request.url.queryParameters['courseId'], '123');
      return _response(_detail());
    }, mediaHeadersLoader: (target) async {
      mediaTargets.add(target);
      return {
        'Cookie': 'webvpn-token=test-gateway',
        'jwt-token': 'must-not-leak',
        'Authorization': 'must-not-leak',
      };
    });
    addTearDown(client.dispose);
    final playback =
        await client.fetchPlayback(course: _course, lesson: _lesson);
    expect(playback.lastPosition, const Duration(seconds: 89));
    expect(playback.views.single.label, '合成画面');
    expect(playback.views.single.url.toString(),
        'https://media.example/clip.mp4?auth_key=opaque%2Bsignature');
    expect(mediaTargets, [playback.views.single.url]);
    expect(playback.views.single.httpHeaders,
        {'Cookie': 'webvpn-token=test-gateway'});
  });

  for (final mismatch in ['course', 'class', 'view', 'permission']) {
    test('playback refuses $mismatch mismatch despite a returned URL',
        () async {
      final client = _client((request) async {
        if (request.url.path.endsWith('/resources')) {
          return _response(_permission());
        }
        if (request.url.path.endsWith('/verify')) {
          return _response({'verify': true});
        }
        return _response(_detail(
          courseId: mismatch == 'course' ? 456 : 123,
          teachingClassId: mismatch == 'class' ? 43 : 42,
          viewCourseId: mismatch == 'view' ? 456 : 123,
          permission: mismatch == 'permission' ? 0 : 1,
        ));
      });
      addTearDown(client.dispose);
      await expectLater(
        client.fetchPlayback(course: _course, lesson: _lesson),
        throwsA(mismatch == 'permission'
            ? isA<VodPermissionException>()
            : isA<VodInvalidResponseException>()),
      );
    });
  }

  for (final response in [
    http.Response('', 401),
    http.Response(jsonEncode({'status': 10013}), 200),
    http.Response('<html>newsso.shu.edu.cn/oauth2/login</html>', 200),
    http.Response('', 302, headers: {'location': 'https://newsso.shu.edu.cn/'}),
  ]) {
    test(
        'session failure is distinct from network failure ${response.statusCode}',
        () async {
      final client = _client((request) async {
        expect(request.followRedirects, isFalse);
        return response;
      });
      addTearDown(client.dispose);
      await expectLater(
          client.fetchTerms(), throwsA(isA<VodSessionExpiredException>()));
    });
  }

  test('network error does not become a session-expired error', () async {
    final client = _client((_) async => throw const SocketException('offline'));
    addTearDown(client.dispose);
    await expectLater(client.fetchTerms(), throwsA(isA<VodNetworkException>()));
  });

  for (final expiredResponse in [
    http.Response('', 401),
    http.Response(jsonEncode({'status': 10013}), 200),
    http.Response('<html>newsso.shu.edu.cn/oauth2/login</html>', 200),
  ]) {
    test(
        'business expiration silently renews once and retries the same request '
        '${expiredResponse.statusCode}', () async {
      final auth = _SessionAuth();
      final requests = <http.Request>[];
      final client = VodApiClient(
        authService: auth,
        httpClient: MockClient((request) async {
          requests.add(request);
          return requests.length == 1
              ? expiredResponse
              : http.Response('[]', 200);
        }),
      );
      addTearDown(client.dispose);
      addTearDown(auth.dispose);
      expect(await client.fetchTerms(), isEmpty);
      expect(auth.ensureCalls, [false, true]);
      expect(auth.clears, 0);
      expect(requests.length, 2);
      expect(requests[1].url, requests[0].url);
      expect(requests[0].headers['jwt-token'], 'test-original-token');
      expect(requests[1].headers['jwt-token'], 'test-renewed-token');
    });
  }

  test('a second business expiration stops instead of looping or expiring SSO',
      () async {
    final auth = _SessionAuth();
    var requests = 0;
    final client = VodApiClient(
      authService: auth,
      httpClient: MockClient((_) async {
        requests++;
        return http.Response('', 401);
      }),
    );
    addTearDown(client.dispose);
    addTearDown(auth.dispose);
    await expectLater(
        client.fetchTerms(),
        throwsA(allOf(
          isA<VodApiException>(),
          isNot(isA<VodSessionExpiredException>()),
        )));
    expect(requests, 2);
    expect(auth.ensureCalls, [false, true]);
    expect(auth.clears, 0);
  });

  for (final result in ['permission', 'server', 'business', 'network']) {
    test('$result failure does not renew or clear the campus account',
        () async {
      final auth = _SessionAuth();
      var requests = 0;
      final client = VodApiClient(
        authService: auth,
        httpClient: MockClient((_) async {
          requests++;
          return switch (result) {
            'permission' => http.Response('', 403),
            'server' => http.Response('', 500),
            'business' => http.Response(jsonEncode({'status': 500}), 200),
            _ => throw const SocketException('offline'),
          };
        }),
      );
      addTearDown(client.dispose);
      addTearDown(auth.dispose);
      await expectLater(
          client.fetchTerms(),
          throwsA(allOf(
            isA<VodApiException>(),
            isNot(isA<VodSessionExpiredException>()),
          )));
      expect(requests, 1);
      expect(auth.ensureCalls, [false]);
      expect(auth.clears, 0);
    });
  }

  test('expired shared SSO during renewal preserves its explicit semantics',
      () async {
    final auth = _SessionAuth(onEnsure: (forceRefresh) async {
      if (forceRefresh) {
        throw const VodCampusAuthRequiredException(ssoExpired: true);
      }
    });
    var requests = 0;
    final client = VodApiClient(
      authService: auth,
      httpClient: MockClient((_) async {
        requests++;
        return http.Response('', 401);
      }),
    );
    addTearDown(client.dispose);
    addTearDown(auth.dispose);
    await expectLater(
        client.fetchTerms(),
        throwsA(
          isA<VodSessionExpiredException>()
              .having((error) => error.ssoExpired, 'ssoExpired', isTrue),
        ));
    expect(requests, 1);
    expect(auth.ensureCalls, [false, true]);
  });

  test('missing campus account is distinct from an expired shared SSO',
      () async {
    final auth = _SessionAuth(onEnsure: (_) async {
      throw const VodCampusAuthRequiredException();
    });
    var requests = 0;
    final client = VodApiClient(
      authService: auth,
      httpClient: MockClient((_) async {
        requests++;
        return http.Response('[]', 200);
      }),
    );
    addTearDown(client.dispose);
    addTearDown(auth.dispose);
    await expectLater(
        client.fetchTerms(),
        throwsA(
          isA<VodSessionExpiredException>()
              .having((error) => error.ssoExpired, 'ssoExpired', isFalse),
        ));
    expect(requests, 0);
    expect(auth.ensureCalls, [false]);
  });

  test('ordinary auth exchange failure remains a safe API error', () async {
    final auth = _SessionAuth(onEnsure: (_) async {
      throw const VodAuthException('录播会话交换暂时不可用，请稍后重试');
    });
    final client = VodApiClient(
      authService: auth,
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    );
    addTearDown(client.dispose);
    addTearDown(auth.dispose);
    await expectLater(
        client.fetchTerms(),
        throwsA(allOf(
          isA<VodApiException>()
              .having((error) => error.message, 'message', '录播会话交换暂时不可用，请稍后重试'),
          isNot(isA<VodSessionExpiredException>()),
        )));
  });

  test('headersLoader mock bypasses the real authentication service', () async {
    final auth = _SessionAuth(onEnsure: (_) async {
      throw StateError('real authentication must not run');
    });
    final client = VodApiClient(
      authService: auth,
      headersLoader: (_) async => {},
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    );
    addTearDown(client.dispose);
    addTearDown(auth.dispose);
    expect(await client.fetchTerms(), isEmpty);
    expect(auth.ensureCalls, isEmpty);
  });
}

import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/vod_constants.dart';
import 'package:shuyo/core/vod_url_resolver.dart';
import 'package:shuyo/data/services/secure_app_store.dart';
import 'package:shuyo/data/services/session_cookie_jar.dart';
import 'package:shuyo/data/services/vod_auth_service.dart';
import 'package:shuyo/data/services/vod_native_session_service.dart';

class _Store extends SecureAppStore {
  final values = <String, String>{};
  final deletes = <String>[];
  Completer<void>? writeStarted;
  Completer<void>? releaseWrite;
  Completer<void>? readStarted;
  Completer<void>? releaseRead;
  String? failDelete;
  @override
  Future<String?> read(String key) async {
    if (readStarted?.isCompleted == false) readStarted!.complete();
    await releaseRead?.future;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (writeStarted?.isCompleted == false) writeStarted!.complete();
    await releaseWrite?.future;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deletes.add(key);
    if (failDelete == key) throw StateError('storage unavailable');
    values.remove(key);
  }
}

class _Native extends VodNativeSessionService {
  _Native({this.load});
  final Future<VodNativeSession> Function(bool vpn, String owner)? load;
  int calls = 0;
  final started = Completer<void>();
  @override
  Future<VodNativeSession> authorize(
      {required bool useWebVpn, required String expectedStudentId}) async {
    calls++;
    if (!started.isCompleted) started.complete();
    if (load != null) return load!(useWebVpn, expectedStudentId);
    return VodNativeSession(jwtToken: useWebVpn ? 'vpn-token' : 'direct-token');
  }
}

http.Response _identity(String id) => http.Response(
    jsonEncode({
      'status': 200,
      'data': {'id': 'internal-id', 'userCode': id},
      'ok': true,
      'dataOk': true,
    }),
    200);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VodAuthService.resetInMemoryStateForTesting();
    VodUrlResolver.configure(useWebVpn: false);
  });
  VodAuthService service(_Store store, _Native native,
          {Future<String?> Function()? owner,
          http.Client? client,
          SessionCookieJar? jar}) =>
      VodAuthService(
        secureStore: store,
        cookieJar: jar ?? SessionCookieJar(),
        nativeSessionService: native,
        studentIdLoader: owner ?? () async => 'A001',
        client: client ?? MockClient((_) async => _identity('A001')),
      );

  test('missing campus account never starts an independent login', () async {
    final native = _Native();
    final auth = service(_Store(), native, owner: () async => null);
    await expectLater(
        auth.ensureSession(useWebVpn: false),
        throwsA(isA<VodCampusAuthRequiredException>()
            .having((e) => e.ssoExpired, 'ssoExpired', false)));
    expect(native.calls, 0);
    auth.dispose();
    native.dispose();
  });

  test('SSO expiration propagates as the unified campus login requirement',
      () async {
    final native = _Native(
        load: (_, __) async =>
            throw const VodCampusAuthRequiredException(ssoExpired: true));
    final auth = service(_Store(), native);
    await expectLater(
        auth.ensureSession(useWebVpn: false),
        throwsA(isA<VodCampusAuthRequiredException>()
            .having((e) => e.ssoExpired, 'ssoExpired', true)));
    expect(await auth.hasSession(), isFalse);
    auth.dispose();
    native.dispose();
  });

  test('verified JWT is bound to the campus ID and reused without OAuth churn',
      () async {
    final store = _Store();
    final native = _Native();
    final headers = <Map<String, String>>[];
    final auth = service(store, native, client: MockClient((request) async {
      headers.add(Map.of(request.headers));
      return _identity('A001');
    }));
    await auth.ensureSession(useWebVpn: false);
    await auth.ensureSession(useWebVpn: false);
    expect(native.calls, 1);
    expect(headers, hasLength(1));
    expect(headers.single.containsKey('cookie'), isFalse);
    expect(
        jsonDecode(store.values[VodConstants.directSessionKey]!)['studentId'],
        'A001');
    expect(await auth.hasSession(useWebVpn: false), isTrue);
    expect(await auth.hasSession(useWebVpn: true), isFalse);
    final api = await auth.headersFor(VodUrlResolver.apiUri('/v1/currentuser'));
    expect(api['jwt-token'], 'direct-token');
    auth.dispose();
    native.dispose();
  });

  test(
      'a different currentuser identity is never stored or returned in headers',
      () async {
    final store = _Store();
    final native = _Native();
    final auth = service(store, native,
        client: MockClient((_) async => _identity('B002')));
    await expectLater(
        auth.ensureSession(useWebVpn: false), throwsA(isA<VodAuthException>()));
    expect(store.values, isEmpty);
    expect(await auth.headersFor(VodUrlResolver.apiUri('/v1/currentuser')),
        isEmpty);
    auth.dispose();
    native.dispose();
  });

  test('transport credentials and signed media headers stay separated',
      () async {
    final jar = SessionCookieJar();
    await jar.setCookie(const SessionCookie(
        name: 'webvpn-token',
        value: 'connection',
        domain: 'webvpn.shu.edu.cn'));
    final native = _Native();
    final auth = service(_Store(), native, jar: jar);
    await auth.ensureSession(useWebVpn: false);
    await auth.ensureSession(useWebVpn: true);
    final media = VodUrlResolver.resolveMediaUrl(
        'https://vrmvod.cc.shu.edu.cn:40443/a.mp4',
        useWebVpn: true);
    expect(await auth.mediaHeadersFor(media, useWebVpn: true),
        {'Cookie': 'webvpn-token=connection'});
    final live = VodUrlResolver.resolveMediaUrl(
        'https://rtc.cc.shu.edu.cn:32001/hls/live/stream.m3u8',
        useWebVpn: true);
    expect(await auth.mediaHeadersFor(live, useWebVpn: true),
        {'Cookie': 'webvpn-token=connection'});
    expect(
        await auth.mediaHeadersFor(
            Uri.parse('https://rtc.cc.shu.edu.cn:32001/hls/live/stream.m3u8')),
        isEmpty);
    expect(
        await auth.headersFor(Uri.parse(
            'https://example.com/jy-application-resourcemanage/v1/currentuser')),
        isEmpty);
    expect(await auth.headersFor(Uri.parse('https://vod.cc.shu.edu.cn/a.mp4')),
        isEmpty);
    expect(
        await auth.mediaHeadersFor(
            Uri.parse('https://vrmvod.cc.shu.edu.cn:40443/a.mp4')),
        isEmpty);
    expect(
        (await auth.headersFor(
            VodUrlResolver.apiUri('/v1/currentuser', useWebVpn: true),
            useWebVpn: true))['jwt-token'],
        'vpn-token');
    auth.dispose();
    native.dispose();
  });

  test('account switching hides a previously bound JWT', () async {
    var owner = 'A001';
    final native = _Native();
    final auth = service(_Store(), native, owner: () async => owner);
    await auth.ensureSession(useWebVpn: false);
    owner = 'B002';
    expect(await auth.hasSession(), isFalse);
    expect(await auth.headersFor(VodUrlResolver.apiUri('/v1/currentuser')),
        isEmpty);
    auth.dispose();
    native.dispose();
  });

  test('late native authorization cannot save after another instance logs out',
      () async {
    final reply = Completer<VodNativeSession>();
    final native = _Native(load: (_, __) => reply.future);
    final store = _Store();
    final auth = service(store, native);
    final logout = service(store, _Native());
    final pending = auth.ensureSession(useWebVpn: false);
    await native.started.future;
    await logout.clearAllSessions();
    reply.complete(const VodNativeSession(jwtToken: 'old-token'));
    await expectLater(pending, throwsA(isA<VodAuthException>()));
    expect(store.values, isEmpty);
    auth.dispose();
    logout.dispose();
    native.dispose();
  });

  test(
      'logout during secure write removes its late value in the serialized queue',
      () async {
    final store = _Store()
      ..writeStarted = Completer<void>()
      ..releaseWrite = Completer<void>();
    final native = _Native();
    final auth = service(store, native);
    final logout = service(store, _Native());
    final pending = auth.ensureSession(useWebVpn: false);
    await store.writeStarted!.future;
    final clearing = logout.clearSession(useWebVpn: false);
    expect(await logout.hasSession(), isFalse);
    store.releaseWrite!.complete();
    await expectLater(pending, throwsA(isA<VodAuthException>()));
    await clearing;
    expect(store.values, isEmpty);
    auth.dispose();
    logout.dispose();
    native.dispose();
  });

  test(
      'failed direct deletion still attempts VPN and tombstones old credentials',
      () async {
    final store = _Store()..failDelete = VodConstants.directSessionKey;
    final record = jsonEncode({'studentId': 'A001', 'jwtToken': 'old'});
    store.values.addAll({
      VodConstants.directSessionKey: record,
      VodConstants.webVpnSessionKey: record
    });
    final native = _Native();
    final auth = service(store, native);
    await expectLater(
        auth.clearAllSessions(), throwsA(isA<VodAuthException>()));
    expect(
        store.deletes,
        containsAll(
            [VodConstants.directSessionKey, VodConstants.webVpnSessionKey]));
    expect(await auth.hasSession(useWebVpn: false), isFalse);
    expect(await auth.hasSession(useWebVpn: true), isFalse);
    expect(await auth.headersFor(VodUrlResolver.apiUri('/v1/currentuser')),
        isEmpty);
    await auth.ensureSession(useWebVpn: false);
    expect(await auth.hasSession(useWebVpn: false), isTrue);
    expect(await auth.hasSession(useWebVpn: true), isFalse);
    auth.dispose();
    native.dispose();
  });

  test(
      'logout during initial account read cannot restart a canceled native attempt',
      () async {
    final read = Completer<String?>();
    final entered = Completer<void>();
    var first = true;
    final store = _Store();
    final native = _Native();
    final auth = service(store, native, owner: () {
      if (first) {
        first = false;
        entered.complete();
        return read.future;
      }
      return Future.value('A001');
    });
    final logout = service(store, _Native());
    final pending = auth.ensureSession(useWebVpn: false);
    await entered.future;
    await logout.clearSession(useWebVpn: false);
    read.complete('A001');
    await expectLater(pending, throwsA(isA<VodAuthException>()));
    expect(native.calls, 0);
    expect(store.values, isEmpty);
    auth.dispose();
    logout.dispose();
    native.dispose();
  });

  test('logout during session read cannot advance the old authorization epoch',
      () async {
    final store = _Store()
      ..readStarted = Completer<void>()
      ..releaseRead = Completer<void>();
    final native = _Native();
    final auth = service(store, native);
    final logout = service(store, _Native());
    final pending = auth.ensureSession(useWebVpn: false);
    await store.readStarted!.future;
    await logout.clearSession(useWebVpn: false);
    store.releaseRead!.complete();
    await expectLater(pending, throwsA(isA<VodAuthException>()));
    expect(native.calls, 0);
    expect(store.values, isEmpty);
    auth.dispose();
    logout.dispose();
    native.dispose();
  });

  test('a rejected stored JWT is renewed once through existing campus SSO',
      () async {
    final store = _Store();
    store.values[VodConstants.directSessionKey] =
        jsonEncode({'studentId': 'A001', 'jwtToken': 'expired-token'});
    final native = _Native();
    var checks = 0;
    final auth = service(store, native, client: MockClient((request) async {
      checks++;
      return request.headers['jwt-token'] == 'expired-token'
          ? http.Response('', 401)
          : _identity('A001');
    }));
    await auth.ensureSession(useWebVpn: false);
    expect(native.calls, 1);
    expect(checks, 2);
    expect(
        (await auth
            .headersFor(VodUrlResolver.apiUri('/v1/currentuser')))['jwt-token'],
        'direct-token');
    await auth.ensureSession(useWebVpn: false);
    expect(checks, 2);
    auth.dispose();
    native.dispose();
  });

  test('concurrent forced renewals share the same native exchange', () async {
    final reply = Completer<VodNativeSession>();
    final native = _Native(load: (_, __) => reply.future);
    final auth = service(_Store(), native);
    final first = auth.ensureSession(useWebVpn: false, forceRefresh: true);
    final second = auth.ensureSession(useWebVpn: false, forceRefresh: true);
    await native.started.future;
    reply.complete(const VodNativeSession(jwtToken: 'renewed-token'));
    await Future.wait([first, second]);
    expect(native.calls, 1);
    expect(await auth.hasSession(useWebVpn: false), isTrue);
    auth.dispose();
    native.dispose();
  });
}

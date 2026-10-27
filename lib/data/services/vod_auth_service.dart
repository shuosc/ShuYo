import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../core/vod_constants.dart';
import '../../core/vod_url_resolver.dart';
import 'academic_account_store.dart';
import 'http_timeout.dart';
import 'secure_app_store.dart';
import 'session_cookie_jar.dart';
import 'vod_auth_exception.dart';
import 'vod_native_session_service.dart';
export 'vod_auth_exception.dart';

class _BoundSession {
  const _BoundSession(this.owner, this.token);
  final String owner;
  final String token;
}

/// Uses only ShuYo's campus account and its existing native newsso session.
/// A VOD token is a transport-specific business credential bound to that ID.
class VodAuthService {
  VodAuthService(
      {SecureAppStore? secureStore,
      SessionCookieJar? cookieJar,
      http.Client? client,
      VodNativeSessionService? nativeSessionService,
      Future<String?> Function()? studentIdLoader})
      : _store = secureStore ?? SecureAppStore(),
        _jar = cookieJar ?? SessionCookieJar.shared,
        _client = client ?? http.Client(),
        _nativeInstance = nativeSessionService,
        _ownsNative = nativeSessionService == null,
        _accountLoader =
            studentIdLoader ?? AcademicAccountStore().loadStudentId;
  final SecureAppStore _store;
  final SessionCookieJar _jar;
  final http.Client _client;
  final Future<String?> Function() _accountLoader;
  VodNativeSessionService? _nativeInstance;
  final bool _ownsNative;
  VodNativeSessionService get _native =>
      _nativeInstance ??= VodNativeSessionService(cookieJar: _jar);
  static final _generation = <bool, int>{};
  static final _mutations = <bool, Future<void>>{};
  static final _blocked = <bool, bool>{};
  static final _validated =
      <bool, ({String owner, String token, int? generation, DateTime until})>{};
  static final _pending = <String, ({Future<void> future, bool force})>{};

  @visibleForTesting
  static void resetInMemoryStateForTesting() {
    _generation.clear();
    _mutations.clear();
    _blocked.clear();
    _validated.clear();
    _pending.clear();
  }

  String _key(bool vpn) =>
      vpn ? VodConstants.webVpnSessionKey : VodConstants.directSessionKey;
  Future<String?> _account() async {
    final id = (await _accountLoader())?.trim();
    return id == null || id.isEmpty ? null : id;
  }

  Future<T> _serialize<T>(bool vpn, Future<T> Function() action) {
    final result =
        (_mutations[vpn] ?? Future<void>.value()).then((_) => action());
    late final Future<void> tail;
    tail = result
        .then<void>((_) {}, onError: (Object _, StackTrace __) {})
        .whenComplete(() {
      if (identical(_mutations[vpn], tail)) _mutations.remove(vpn);
    });
    _mutations[vpn] = tail;
    return result;
  }

  Future<_BoundSession?> _session(bool vpn, {String? owner}) async {
    if (_blocked[vpn] == true) return null;
    await _mutations[vpn];
    final id = owner ?? await _account();
    if (id == null || _blocked[vpn] == true) return null;
    final raw = await _store.read(_key(vpn));
    if (raw == null || _blocked[vpn] == true) return null;
    Object? data;
    try {
      data = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (data is! Map ||
        data['studentId'] != id ||
        data['jwtToken'] is! String ||
        (data['jwtToken'] as String).isEmpty) {
      return null;
    }
    return _BoundSession(id, data['jwtToken'] as String);
  }

  Future<bool> hasSession({bool? useWebVpn}) async =>
      await _session(useWebVpn ?? VodUrlResolver.usesWebVpn) != null;

  Future<void> ensureSession(
      {required bool useWebVpn, bool forceRefresh = false}) async {
    final initialEpoch = _generation[useWebVpn] ?? 0;
    final id = await _account();
    if (id == null) throw const VodCampusAuthRequiredException();
    final key = '$useWebVpn:$id';
    final pending = _pending[key];
    if (pending != null) {
      await pending.future;
      if (forceRefresh && !pending.force) {
        await ensureSession(useWebVpn: useWebVpn, forceRefresh: true);
      }
      return;
    }
    if ((_generation[useWebVpn] ?? 0) != initialEpoch) {
      throw const VodAuthException('校园账户已改变，请重新加载课程录播');
    }
    final operation = _ensure(id, useWebVpn, forceRefresh, initialEpoch);
    _pending[key] = (future: operation, force: forceRefresh);
    try {
      await operation;
    } finally {
      if (identical(_pending[key]?.future, operation)) _pending.remove(key);
    }
  }

  Future<void> _ensure(String id, bool vpn, bool force, int epoch) async {
    final stored = await _session(vpn, owner: id);
    if (!await _current(vpn, epoch, id)) {
      throw const VodAuthException('校园账户已改变，请重新加载课程录播');
    }
    if (!force && stored != null) {
      final cache = _validated[vpn];
      if (cache != null &&
          cache.owner == id &&
          cache.token == stored.token &&
          cache.generation == epoch &&
          cache.until.isAfter(DateTime.now())) {
        return;
      }
      final valid = await _verify(stored.token, id, vpn);
      if (!await _current(vpn, epoch, id)) {
        throw const VodAuthException('校园账户已改变，请重新加载课程录播');
      }
      if (valid) {
        _markValidated(vpn, id, stored.token);
        return;
      }
    }
    if (force || stored != null) {
      await _invalidate(vpn, clearPending: false);
      epoch++;
    }
    if (!await _current(vpn, epoch, id)) {
      throw const VodAuthException('校园账户已改变，请重新加载课程录播');
    }
    final epochNew = epoch + 1;
    _generation[vpn] = epochNew;
    final native =
        await _native.authorize(useWebVpn: vpn, expectedStudentId: id);
    if (!await _current(vpn, epochNew, id)) {
      throw const VodAuthException('校园账户已改变，请重新加载课程录播');
    }
    if (!await _verify(native.jwtToken, id, vpn)) {
      throw const VodAuthException('录播平台返回的登录身份与当前校园账户不一致，请稍后重试');
    }
    final saved = await _serialize(vpn, () async {
      if (!await _current(vpn, epochNew, id)) return false;
      _blocked[vpn] = true;
      await _clearCookies(vpn);
      if (!await _current(vpn, epochNew, id)) return false;
      await _store.write(_key(vpn),
          jsonEncode({'studentId': id, 'jwtToken': native.jwtToken}));
      for (final cookie in native.cookies) {
        if (_hosts(vpn).contains(cookie.domain) &&
            cookie.name != 'webvpn-token') {
          await _jar.setCookie(cookie);
        }
      }
      if (!await _current(vpn, epochNew, id)) {
        await _clearPersistent(vpn);
        return false;
      }
      _blocked[vpn] = false;
      _markValidated(vpn, id, native.jwtToken);
      return true;
    });
    if (!saved) throw const VodAuthException('校园账户已改变，请重新加载课程录播');
  }

  Future<bool> _current(bool vpn, int epoch, String id) async =>
      (_generation[vpn] ?? 0) == epoch &&
      await _account() == id &&
      (_generation[vpn] ?? 0) == epoch;
  void _markValidated(bool vpn, String owner, String token) {
    _validated[vpn] = (
      owner: owner,
      token: token,
      generation: _generation[vpn] ?? 0,
      until: DateTime.now().add(const Duration(minutes: 2))
    );
  }

  Future<Map<String, String>> headersFor(Uri uri, {bool? useWebVpn}) async {
    final vpn = useWebVpn ?? VodUrlResolver.usesWebVpn;
    if (!VodUrlResolver.isBusinessUri(uri, useWebVpn: vpn)) return {};
    final epoch = _generation[vpn];
    final session = await _session(vpn);
    if (session == null || _blocked[vpn] == true) return {};
    final cookies = await _cookieHeaders(uri, vpn);
    if (_blocked[vpn] == true ||
        epoch != _generation[vpn] ||
        await _account() != session.owner) {
      return {};
    }
    return {'jwt-token': session.token, ...cookies};
  }

  Future<Map<String, String>> mediaHeadersFor(Uri uri,
      {bool? useWebVpn}) async {
    final vpn = useWebVpn ?? VodUrlResolver.usesWebVpn;
    if (!vpn ||
        !VodUrlResolver.isProxiedMediaUri(uri) ||
        await _session(vpn) == null) {
      return {};
    }
    return _cookieHeaders(uri, true, gatewayOnly: true);
  }

  Future<Map<String, String>> _cookieHeaders(Uri uri, bool vpn,
      {bool gatewayOnly = false}) async {
    final values = <String, String>{};
    for (final cookie in await _jar.getCookies(domain: uri)) {
      if (gatewayOnly && cookie.name != 'webvpn-token') continue;
      if (cookie.name.isNotEmpty && cookie.value.isNotEmpty) {
        values[cookie.name] = cookie.value;
      }
    }
    if (vpn) {
      for (final cookie in await _jar.getCookies(
          domain: Uri.parse('https://webvpn.shu.edu.cn/'))) {
        if (cookie.name == 'webvpn-token' && cookie.value.isNotEmpty) {
          values[cookie.name] = cookie.value;
        }
      }
    }
    return {
      if (values.isNotEmpty)
        'Cookie': values.entries.map((e) => '${e.key}=${e.value}').join('; ')
    };
  }

  Future<bool> validateSession({bool? useWebVpn}) async {
    final vpn = useWebVpn ?? VodUrlResolver.usesWebVpn;
    final session = await _session(vpn);
    return session != null && await _verify(session.token, session.owner, vpn);
  }

  Future<bool> _verify(String token, String id, bool vpn) async {
    if (token.isEmpty || token.contains(RegExp(r'[\r\n]'))) return false;
    final uri = VodUrlResolver.apiUri('/v1/currentuser', useWebVpn: vpn);
    final request = http.Request('GET', uri)..followRedirects = false;
    request.headers.addAll({
      'Accept': 'application/json',
      'jwt-token': token,
      if (vpn) ...await _cookieHeaders(uri, true, gatewayOnly: true)
    });
    final response = await HttpTimeout.request(http.Response.fromStream(
        await HttpTimeout.request(_client.send(request))));
    if (response.statusCode == 401 || response.statusCode == 403) return false;
    if (response.statusCode != 200) {
      throw const VodAuthException('暂时无法确认录播登录状态，请稍后重试');
    }
    Object? data;
    try {
      data = jsonDecode(response.body);
    } on FormatException {
      return false;
    }
    if (data is! Map ||
        data['status']?.toString() != '200' ||
        data['ok'] == false ||
        data['dataOk'] == false) {
      return false;
    }
    final user = data['data'];
    return user is Map &&
        (user['id']?.toString().isNotEmpty ?? false) &&
        user['userCode']?.toString().trim() == id;
  }

  Set<String> _hosts(bool vpn) => {
        VodUrlResolver.baseUriFor(useWebVpn: vpn).host,
        vpn ? VodUrlResolver.casWebVpnHost : VodConstants.casHost
      };
  Future<void> clearSession({bool? useWebVpn}) async {
    final vpn = useWebVpn ?? VodUrlResolver.usesWebVpn;
    await _invalidate(vpn);
  }

  Future<void> _invalidate(bool vpn, {bool clearPending = true}) async {
    _generation[vpn] = (_generation[vpn] ?? 0) + 1;
    _blocked[vpn] = true;
    _validated.remove(vpn);
    if (clearPending) _pending.removeWhere((key, _) => key.startsWith('$vpn:'));
    await _serialize(vpn, () => _clearPersistent(vpn));
  }

  Future<void> clearAllSessions() async {
    var failed = false;
    await Future.wait([
      for (final vpn in [false, true])
        clearSession(useWebVpn: vpn).catchError((Object _) {
          failed = true;
        })
    ]);
    if (failed) throw const VodAuthException('部分录播登录状态清除失败，请重试退出。');
  }

  Future<void> _clearPersistent(bool vpn) async {
    await _store.delete(_key(vpn));
    await _clearCookies(vpn);
  }

  Future<void> _clearCookies(bool vpn) async {
    for (final host in _hosts(vpn)) {
      for (final cookie in await _jar.getCookiesForDomainTree(domain: host)) {
        if (cookie.domain != host || cookie.name == 'webvpn-token') continue;
        await _jar.setCookie(SessionCookie(
            name: cookie.name,
            value: '',
            domain: cookie.domain,
            path: cookie.path));
      }
    }
  }

  void dispose() {
    _client.close();
    if (_ownsNative) _nativeInstance?.dispose();
  }
}

import 'dart:convert';

import 'secure_app_store.dart';
import 'session_cookie_jar.dart';

/// 图书馆业务会话：服务端签发的 JWT 与它在请求头里使用的名字，
/// 加上图书馆域名下的 Cookie（如负载均衡的 `route`）。
class LibraryStoredSession {
  const LibraryStoredSession({
    required this.jwt,
    required this.jwtHeader,
    this.cookies = const [],
  });

  final String jwt;
  final String jwtHeader;
  final List<SessionCookie> cookies;
}

class LibrarySessionStore {
  LibrarySessionStore({SecureAppStore? secureStore})
      : _store = secureStore ?? SecureAppStore();

  static const storageKey = 'shuyo.library.session.v2';

  final SecureAppStore _store;

  Future<void> saveSession({
    required String studentId,
    required LibraryStoredSession session,
  }) async {
    final payload = {
      'studentId': studentId,
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'jwt': session.jwt,
      'jwtHeader': session.jwtHeader,
      'cookies': [
        for (final cookie in session.cookies)
          {
            'name': cookie.name,
            'value': cookie.value,
            'domain': cookie.domain,
            'path': cookie.path,
          },
      ],
    };
    await _store.write(storageKey, jsonEncode(payload));
  }

  Future<LibraryStoredSession?> loadSession({required String studentId}) async {
    final raw = await _store.read(storageKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['studentId'] != studentId) return null;
      final jwt = json['jwt'];
      final header = json['jwtHeader'];
      if (jwt is! String || jwt.isEmpty) return null;
      if (header is! String || header.isEmpty) return null;
      final cookies = <SessionCookie>[];
      final list = json['cookies'];
      if (list is List) {
        for (final item in list) {
          if (item is! Map) continue;
          final name = item['name'];
          final value = item['value'];
          if (name is! String || value is! String) continue;
          cookies.add(SessionCookie(
            name: name,
            value: value,
            domain: item['domain'] as String? ?? '',
            path: item['path'] as String? ?? '/',
          ));
        }
      }
      return LibraryStoredSession(
        jwt: jwt,
        jwtHeader: header,
        cookies: cookies,
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> clearSession() => _store.delete(storageKey);
}

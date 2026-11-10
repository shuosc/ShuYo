import 'dart:convert';

import 'secure_app_store.dart';
import 'session_cookie_jar.dart';

class LibrarySessionStore {
  LibrarySessionStore({SecureAppStore? secureStore})
      : _store = secureStore ?? SecureAppStore();

  static const storageKey = 'shuyo.library.session.cookies.v1';

  final SecureAppStore _store;

  Future<void> saveCookies({
    required String studentId,
    required List<SessionCookie> cookies,
  }) async {
    final payload = {
      'studentId': studentId,
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'cookies': [
        for (final cookie in cookies)
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

  Future<List<SessionCookie>> loadCookies({required String studentId}) async {
    final raw = await _store.read(storageKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['studentId'] != studentId) {
        return const [];
      }
      final list = json['cookies'];
      if (list is! List) return const [];
      final result = <SessionCookie>[];
      for (final item in list) {
        if (item is Map) {
          final name = item['name'] as String?;
          final value = item['value'] as String?;
          final domain = item['domain'] as String? ?? '';
          final path = item['path'] as String? ?? '/';
          if (name != null && value != null) {
            result.add(
              SessionCookie(
                name: name,
                value: value,
                domain: domain,
                path: path,
              ),
            );
          }
        }
      }
      return result;
    } on FormatException {
      return const [];
    }
  }

  Future<void> clearSession() => _store.delete(storageKey);
}

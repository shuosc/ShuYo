import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/services/library_session_store.dart';
import 'package:shuyo/data/services/secure_app_store.dart';
import 'package:shuyo/data/services/session_cookie_jar.dart';

class _MemorySecureStore extends SecureAppStore {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

void main() {
  late _MemorySecureStore store;
  late LibrarySessionStore sessionStore;

  setUp(() {
    store = _MemorySecureStore();
    sessionStore = LibrarySessionStore(secureStore: store);
  });

  test('saves and loads cookies isolated by student ID', () async {
    const cookies = [
      SessionCookie(
        name: 'token',
        value: 'xyz123',
        domain: 'findshu.libsp.cn',
        path: '/',
      ),
    ];

    await sessionStore.saveCookies(studentId: '25120001', cookies: cookies);

    final loadedSame = await sessionStore.loadCookies(studentId: '25120001');
    expect(loadedSame, hasLength(1));
    expect(loadedSame.first.name, 'token');
    expect(loadedSame.first.value, 'xyz123');
    expect(loadedSame.first.domain, 'findshu.libsp.cn');

    final loadedOther = await sessionStore.loadCookies(studentId: '25120002');
    expect(loadedOther, isEmpty);
  });

  test('clearSession removes the stored session', () async {
    await sessionStore.saveCookies(
      studentId: '25120001',
      cookies: const [
        SessionCookie(name: 'session', value: '1', domain: 'findshu.libsp.cn'),
      ],
    );

    await sessionStore.clearSession();

    final loaded = await sessionStore.loadCookies(studentId: '25120001');
    expect(loaded, isEmpty);
  });

  test('corrupted or invalid payload gracefully returns empty list', () async {
    await store.write(LibrarySessionStore.storageKey, 'not-a-valid-json');
    expect(await sessionStore.loadCookies(studentId: '25120001'), isEmpty);
  });
}

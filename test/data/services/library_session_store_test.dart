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

  test('saves and loads the credentials isolated by student ID', () async {
    await sessionStore.saveSession(
      studentId: '25120001',
      session: const LibraryStoredSession(
        jwt: 'a.b.c',
        jwtHeader: 'jwtOpacAuth',
        cookies: [
          SessionCookie(
            name: 'route',
            value: 'xyz123',
            domain: 'findshu.libsp.cn',
          ),
        ],
      ),
    );

    final loaded = await sessionStore.loadSession(studentId: '25120001');
    expect(loaded, isNotNull);
    expect(loaded!.jwt, 'a.b.c');
    expect(loaded.jwtHeader, 'jwtOpacAuth');
    expect(loaded.cookies.single.name, 'route');
    expect(loaded.cookies.single.domain, 'findshu.libsp.cn');

    expect(await sessionStore.loadSession(studentId: '25120002'), isNull);
  });

  test('clearSession removes the stored session', () async {
    await sessionStore.saveSession(
      studentId: '25120001',
      session: const LibraryStoredSession(jwt: 'a.b.c', jwtHeader: 'h'),
    );

    await sessionStore.clearSession();

    expect(await sessionStore.loadSession(studentId: '25120001'), isNull);
  });

  test('corrupted or incomplete payloads load as no session', () async {
    await store.write(LibrarySessionStore.storageKey, 'not-a-valid-json');
    expect(await sessionStore.loadSession(studentId: '25120001'), isNull);

    await store.write(
      LibrarySessionStore.storageKey,
      '{"studentId":"25120001","cookies":[]}',
    );
    expect(await sessionStore.loadSession(studentId: '25120001'), isNull);
  });
}

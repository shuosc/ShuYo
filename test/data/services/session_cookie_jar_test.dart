import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/services/session_cookie_jar.dart';
import 'package:shuyo/data/services/secure_app_store.dart';

class _CountingStore extends SecureAppStore {
  _CountingStore({this.value, this.pendingRead});

  String? value;
  Completer<String?>? pendingRead;
  int reads = 0;

  @override
  Future<String?> read(String key) async {
    reads++;
    final pending = pendingRead;
    if (pending != null) return pending.future;
    return value;
  }

  @override
  Future<void> write(String key, String value) async => this.value = value;
}

const _storedCookie = '[{"name":"session","value":"synthetic",'
    '"domain":"vod.cc.shu.edu.cn","path":"/"}]';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('returns cookies for the requested host and path scope', () async {
    final jar = SessionCookieJar();
    await jar.setCookie(const SessionCookie(
      name: 'SHU_OAUTH2',
      value: 'sso-session',
      domain: 'newsso.shu.edu.cn',
    ));
    await jar.setCookie(const SessionCookie(
      name: 'JSESSIONID',
      value: 'jwxt-session',
      domain: 'jwxt.shu.edu.cn',
      path: '/jwglxt',
    ));

    final identity = await jar.getCookies(
      domain: Uri.parse('https://newsso.shu.edu.cn/oauth/authorize'),
    );
    expect(identity.map((cookie) => cookie.name), ['SHU_OAUTH2']);

    final menu = await jar.getCookies(
      domain: Uri.parse(
        'https://jwxt.shu.edu.cn/jwglxt/xtgl/index_initMenu.html',
      ),
    );
    expect(menu.map((cookie) => cookie.name), ['JSESSIONID']);

    // A path-scoped cookie must not leak to a request outside its prefix.
    expect(
      await jar.getCookies(domain: Uri.parse('https://jwxt.shu.edu.cn/')),
      isEmpty,
    );
    // Nor may a sibling host inherit another service's identity cookie.
    expect(
      await jar.getCookies(domain: Uri.parse('https://bbs.shu.edu.cn/')),
      isEmpty,
    );
  });

  test('clears only the scope an empty value names', () async {
    final jar = SessionCookieJar();
    const portal = 'webvpn.shu.edu.cn';
    const proxied = 'https-jwxt-shu-edu-cn-443.webvpn.shu.edu.cn';
    await jar.setCookie(
      const SessionCookie(
          name: 'webvpn-token', value: 'portal', domain: portal),
    );
    await jar.setCookie(
      const SessionCookie(
          name: 'webvpn-token', value: 'proxied', domain: proxied),
    );

    await jar.setCookie(
      const SessionCookie(name: 'webvpn-token', value: '', domain: portal),
    );

    expect(
      await jar.getCookies(domain: Uri.parse('https://$portal/site-nav/')),
      isEmpty,
    );
    expect(
      (await jar.getCookies(domain: Uri.parse('https://$proxied/jwglxt/')))
          .single
          .value,
      'proxied',
    );
  });

  test('persists cookies for the next launch', () async {
    final first = SessionCookieJar();
    await first.setCookie(const SessionCookie(
      name: 'webvpn-token',
      value: 'restored-session',
      domain: 'webvpn.shu.edu.cn',
    ));

    final restarted = SessionCookieJar();
    final cookies = await restarted.getCookies(
      domain: Uri.parse('https://webvpn.shu.edu.cn/site-nav/'),
    );

    expect(cookies.single.value, 'restored-session');
  });

  test('accepts the domain forms the platform store used', () async {
    final jar = SessionCookieJar();
    await jar.setCookie(const SessionCookie(
      name: 'route',
      value: 'node-a',
      domain: 'https://jwxt.shu.edu.cn/jwglxt/',
    ));
    await jar.setCookie(const SessionCookie(
      name: 'SHU_OAUTH2',
      value: 'sso-session',
      domain: '.newsso.shu.edu.cn',
    ));

    final academic = await jar.getCookies(
      domain: Uri.parse(
        'https://jwxt.shu.edu.cn/jwglxt/xtgl/index_initMenu.html',
      ),
    );
    expect(academic.single.domain, 'jwxt.shu.edu.cn');
    expect(
      (await jar.getCookies(domain: Uri.parse('https://newsso.shu.edu.cn/')))
          .single
          .domain,
      'newsso.shu.edu.cn',
    );
  });

  test('lists every path in one domain tree without leaking sibling domains',
      () async {
    final jar = SessionCookieJar();
    for (final cookie in [
      const SessionCookie(name: 'root', value: 'a', domain: 'chaoxing.com'),
      const SessionCookie(
          name: 'front',
          value: 'b',
          domain: 'office.chaoxing.com',
          path: '/front'),
      const SessionCookie(
          name: 'data',
          value: 'c',
          domain: 'i.chaoxing.com',
          path: '/data/apps'),
      const SessionCookie(
          name: 'lookalike', value: 'd', domain: 'evilchaoxing.com'),
      const SessionCookie(
          name: 'campus', value: 'e', domain: 'newsso.shu.edu.cn'),
    ]) {
      await jar.setCookie(cookie);
    }

    final listed = await jar.getCookiesForDomainTree(domain: 'chaoxing.com');
    expect(
        listed.map((cookie) => cookie.name).toSet(), {'root', 'front', 'data'});
    expect(listed.map((cookie) => cookie.path).toSet(),
        {'/', '/front', '/data/apps'});
    expect(await jar.getCookiesForDomainTree(domain: ''), isEmpty);

    final restarted = SessionCookieJar();
    expect(
      (await restarted.getCookiesForDomainTree(domain: 'chaoxing.com'))
          .map((cookie) => cookie.name)
          .toSet(),
      {'root', 'front', 'data'},
    );
  });

  test('restores once and keeps subsequent reads and writes in memory',
      () async {
    final store = _CountingStore(value: _storedCookie);
    final jar = SessionCookieJar(secureStore: store);
    final uri = Uri.parse('https://vod.cc.shu.edu.cn/');
    expect((await jar.getCookies(domain: uri)).single.name, 'session');
    await jar.setCookie(const SessionCookie(
        name: 'second', value: 'new', domain: 'vod.cc.shu.edu.cn'));
    expect(await jar.getCookies(domain: uri), hasLength(2));
    expect(await jar.getCookiesForDomainTree(domain: 'vod.cc.shu.edu.cn'),
        hasLength(2));
    expect(store.reads, 1);
  });

  test('concurrent readers share one pending restore', () async {
    final pending = Completer<String?>();
    final store = _CountingStore(pendingRead: pending);
    final jar = SessionCookieJar(secureStore: store);
    final first =
        jar.getCookies(domain: Uri.parse('https://vod.cc.shu.edu.cn/'));
    final second = jar.getCookiesForDomainTree(domain: 'vod.cc.shu.edu.cn');
    expect(store.reads, 1);
    pending.complete(_storedCookie);
    final results = await Future.wait([first, second]);
    expect(
        results.every((cookies) => cookies.single.name == 'session'), isTrue);
    await jar.getCookies(domain: Uri.parse('https://vod.cc.shu.edu.cn/'));
    expect(store.reads, 1);
  });

  // Intentionally reuse one app-like jar across independent widget FakeAsync
  // zones. A completed restore Future from the first zone must not be awaited
  // by the next zone; no extra timer or pump duration should be needed.
  final sharedStore = _CountingStore(value: _storedCookie);
  final sharedJar = SessionCookieJar(secureStore: sharedStore);
  for (final round in [1, 2]) {
    testWidgets('restored jar is readable in independent widget zone $round',
        (tester) async {
      List<SessionCookie>? result;
      unawaited(sharedJar
          .getCookies(domain: Uri.parse('https://vod.cc.shu.edu.cn/'))
          .then((cookies) => result = cookies));
      await tester.pump();
      expect(result?.single.name, 'session');
      expect(sharedStore.reads, 1);
    });
  }
}

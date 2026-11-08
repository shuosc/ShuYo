import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/core/classroom_url_resolver.dart';

void main() {
  tearDown(() {
    ClassroomUrlResolver.configure(useWebVpn: false);
  });

  test('classroom routing switches with WebVPN setting', () {
    ClassroomUrlResolver.configure(useWebVpn: false);
    expect(ClassroomUrlResolver.baseUri.host, ClassroomUrlResolver.directHost);

    ClassroomUrlResolver.configure(useWebVpn: true);
    expect(ClassroomUrlResolver.baseUri.host, ClassroomUrlResolver.webVpnHost);
  });

  test('uses Shanghai time for classroom external access boundaries', () {
    expect(
      ClassroomAccessWindow.isExternalAccessOpen(
        DateTime.utc(2026, 9, 6, 23),
      ),
      isTrue,
    );
    expect(
      ClassroomAccessWindow.isExternalAccessOpen(
        DateTime.utc(2026, 9, 7, 15),
      ),
      isFalse,
    );
  });

  test('closed-window failure explains campus and WebVPN alternatives', () {
    final message = ClassroomAccessWindow.directFailureMessage(
      now: DateTime.utc(2026, 9, 7, 16),
    );

    expect(message, contains('每日23:00至次日07:00'));
    expect(message, contains('校园网'));
    expect(message, contains('开启WebVPN'));
  });

  test('an explicit route never mutates the global setting', () {
    ClassroomUrlResolver.configure(useWebVpn: true);
    final revision = ClassroomUrlResolver.revision;
    final uri = ClassroomUrlResolver.uri('/build/findBuildRoomType',
        accessMode: ClassroomAccessMode.direct);
    expect(uri.host, ClassroomUrlResolver.directHost);
    expect(ClassroomUrlResolver.usesWebVpn, isTrue);
    expect(ClassroomUrlResolver.revision, revision);
  });

  test('WebVPN failures offer direct access during the open window', () {
    final message = ClassroomAccessWindow.webVpnFailureMessage(
      detail: '请求超时',
      now: DateTime.utc(2026, 11, 8, 2),
    );
    expect(message, contains('通过WebVPN连接空教室失败'));
    expect(message, contains('请求超时'));
    expect(message, contains('可尝试直连'));
    expect(message, isNot(contains('开启WebVPN')));
  });

  test('closed-window WebVPN failures explain the direct-access prerequisite',
      () {
    final message = ClassroomAccessWindow.webVpnFailureMessage(
      now: DateTime.utc(2026, 11, 8, 16),
    );
    expect(message, contains('外网关闭时段'));
    expect(message, contains('连接校园网或学校VPN后，可尝试直连'));
    expect(message, isNot(contains('开启WebVPN')));
  });

  test('a confirmed service outage is distinct from an expired login', () {
    final message = ClassroomAccessWindow.webVpnFailureMessage(
      detail: 'WebVPN登录已失效，需要重新登录',
      serviceUnavailable: true,
      now: DateTime.utc(2026, 11, 8, 2),
    );
    expect(message, contains('当前WebVPN服务不可用'));
    expect(message, isNot(contains('重新登录')));
    expect(message, isNot(contains('开启WebVPN')));
  });

  test('a temporary direct failure does not recommend enabling an enabled VPN',
      () {
    final message = ClassroomAccessWindow.directFailureMessage(
      webVpnEnabled: true,
      now: DateTime.utc(2026, 11, 8, 16),
    );
    expect(message, contains('校园网或学校VPN后重试直连'));
    expect(message, isNot(contains('开启WebVPN')));
  });
}

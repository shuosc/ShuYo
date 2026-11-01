import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/shared/widgets/fullscreen_image_page.dart';

void main() {
  late _PendingHttpClient client;

  setUp(() {
    client = _PendingHttpClient();
    PaintingBinding.instance.imageCache.clear();
  });

  void imageTest(
    String description,
    Future<void> Function(WidgetTester) callback,
  ) {
    testWidgets(description, (tester) async {
      debugNetworkImageHttpClientProvider = () => client;
      try {
        await callback(tester);
      } finally {
        debugNetworkImageHttpClientProvider = null;
      }
    });
  }

  tearDown(() {
    debugNetworkImageHttpClientProvider = null;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  Widget page({
    String url = 'https://example.org/ppt.png',
    Future<Map<String, String>> Function(Uri)? headersLoader,
  }) =>
      MaterialApp(
        home: FullscreenImagePage(url: url, headersLoader: headersLoader),
      );

  imageTest('announcement images still load without a credentials loader',
      (tester) async {
    await tester.pumpWidget(page());
    await tester.pump();
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as NetworkImage).headers, isEmpty);
    expect(client.requests, hasLength(1));
    expect(client.requests.single.headers.values, isEmpty);
    expect(tester.takeException(), isNull);
  });

  imageTest('display and size resolution use the target image credentials',
      (tester) async {
    final pending = Completer<Map<String, String>>();
    final targets = <Uri>[];
    await tester.pumpWidget(page(headersLoader: (target) {
      targets.add(target);
      return pending.future;
    }));
    expect(find.byType(Image), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(client.requests, isEmpty);
    pending.complete({'Cookie': 'webvpn-token=example'});
    await tester.pump();
    await tester.pump();
    expect(targets, [Uri.parse('https://example.org/ppt.png')]);
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as NetworkImage).headers,
        {'Cookie': 'webvpn-token=example'});
    expect(client.requests, hasLength(1));
    expect(client.requests.single.headers.values,
        {'cookie': 'webvpn-token=example'});
    expect(tester.takeException(), isNull);
  });

  imageTest('credentials failures expose the existing image retry action',
      (tester) async {
    var attempts = 0;
    await tester.pumpWidget(page(headersLoader: (_) async {
      if (++attempts == 1) throw StateError('expired gateway session');
      return {'Cookie': 'webvpn-token=refreshed'};
    }));
    await tester.pumpAndSettle();
    expect(find.text('图片加载失败'), findsOneWidget);
    expect(client.requests, isEmpty);
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(attempts, 2);
    expect(find.byType(Image), findsOneWidget);
    expect(client.requests.single.headers.values,
        {'cookie': 'webvpn-token=refreshed'});
    expect(tester.takeException(), isNull);
  });

  imageTest('an old loader cannot replace credentials after it changes',
      (tester) async {
    final oldHeaders = Completer<Map<String, String>>();
    final currentHeaders = Completer<Map<String, String>>();
    await tester.pumpWidget(page(headersLoader: (_) => oldHeaders.future));
    await tester.pumpWidget(page(headersLoader: (_) => currentHeaders.future));
    oldHeaders.completeError(StateError('old request failed'));
    await tester.pump();
    expect(find.text('图片加载失败'), findsNothing);
    currentHeaders.complete({'Cookie': 'current-session'});
    await tester.pump();
    await tester.pump();
    expect(client.requests, hasLength(1));
    expect(
        client.requests.single.headers.values, {'cookie': 'current-session'});
    expect(tester.takeException(), isNull);
  });

  imageTest('changing the URL ignores old asynchronous credentials',
      (tester) async {
    final pending = Completer<Map<String, String>>();
    await tester.pumpWidget(page(headersLoader: (_) => pending.future));
    await tester.pumpWidget(page(
      url: 'https://example.org/replacement.png',
      headersLoader: (_) async => {'Cookie': 'replacement-session'},
    ));
    pending.complete({'Cookie': 'old-session'});
    await tester.pump();
    await tester.pump();
    expect(client.requests, hasLength(1));
    expect(client.requests.single.uri.path, '/replacement.png');
    expect(client.requests.single.headers.values,
        {'cookie': 'replacement-session'});
    expect(tester.takeException(), isNull);
  });

  imageTest('a late loader failure is safe after the image page is disposed',
      (tester) async {
    final pending = Completer<Map<String, String>>();
    await tester.pumpWidget(page(headersLoader: (_) => pending.future));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.completeError(StateError('late credentials failure'));
    await tester.pump();
    expect(client.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

class _PendingHttpClient implements HttpClient {
  final requests = <_PendingRequest>[];

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final request = _PendingRequest(url);
    requests.add(request);
    return request;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PendingRequest implements HttpClientRequest {
  _PendingRequest(this.uri);

  @override
  final Uri uri;
  final _response = Completer<HttpClientResponse>();

  @override
  final _Headers headers = _Headers();

  @override
  Future<HttpClientResponse> close() => _response.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  final values = <String, String>{};

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

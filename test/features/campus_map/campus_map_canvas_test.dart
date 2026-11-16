import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shuyo/data/models/campus_map.dart';
import 'package:shuyo/features/campus_map/campus_map_canvas.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _CanvasCall {
  const _CanvasCall(this.method, this.value);

  final String method;
  final Map<String, dynamic> value;
}

class _WebViewPlatform extends WebViewPlatform {
  late _WebViewController controller;
  final widgetParams = <PlatformWebViewWidgetCreationParams>[];

  @override
  PlatformWebViewController createPlatformWebViewController(
      PlatformWebViewControllerCreationParams params) {
    return controller = _WebViewController(params);
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
      PlatformNavigationDelegateCreationParams params) {
    return _NavigationDelegate(params);
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
      PlatformWebViewWidgetCreationParams params) {
    widgetParams.add(params);
    return _WebViewWidget(params);
  }
}

class _WebViewController extends PlatformWebViewController {
  _WebViewController(super.params) : super.implementation();

  final calls = <_CanvasCall>[];
  final channels = <String, JavaScriptChannelParams>{};
  Completer<void>? blockNextLoad;
  Completer<void>? blockNextUpdate;
  int documentLoads = 0;

  List<_CanvasCall> get loads =>
      calls.where((call) => call.method == 'load').toList();
  List<_CanvasCall> get updates =>
      calls.where((call) => call.method == 'update').toList();

  void message(String type, {String? id}) {
    channels['ShuyoMap']!.onMessageReceived(
      JavaScriptMessage(
          message: jsonEncode({'type': type, if (id != null) 'id': id})),
    );
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> addJavaScriptChannel(
      JavaScriptChannelParams javaScriptChannelParams) async {
    channels[javaScriptChannelParams.name] = javaScriptChannelParams;
  }

  @override
  Future<void> setPlatformNavigationDelegate(
      PlatformNavigationDelegate handler) async {}

  @override
  Future<void> loadFlutterAsset(String key) async {
    expect(key, CampusMapCanvas.asset);
    documentLoads++;
  }

  @override
  Future<void> runJavaScript(String javaScript) async {
    final match =
        RegExp(r'^window\.campusMap\.(\w+)\((.*)\);$').firstMatch(javaScript)!;
    final method = match.group(1)!;
    calls.add(_CanvasCall(
        method, jsonDecode(match.group(2)!) as Map<String, dynamic>));
    final block = method == 'load' ? blockNextLoad : blockNextUpdate;
    if (method == 'load') {
      blockNextLoad = null;
    } else {
      blockNextUpdate = null;
    }
    await block?.future;
  }
}

class _NavigationDelegate extends PlatformNavigationDelegate {
  _NavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
      NavigationRequestCallback onNavigationRequest) async {}

  @override
  Future<void> setOnWebResourceError(
      WebResourceErrorCallback onWebResourceError) async {}
}

class _WebViewWidget extends PlatformWebViewWidget {
  _WebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final data = CampusMapData.fromJson(
      jsonDecode(File('assets/campus_map/map_data.json').readAsStringSync())
          as Map<String, dynamic>);
  late _WebViewPlatform platform;

  setUp(() {
    platform = _WebViewPlatform();
    WebViewPlatform.instance = platform;
  });

  CampusMapCanvasConfiguration configuration({
    String campusId = 'baoshan',
    String? selectedId = 'place_baoshan_building-d5',
    int focusRevision = 1,
    double bottomInset = 210,
    Map<String, dynamic>? location,
    CampusMapPoint? focusPoint,
    bool active = true,
  }) =>
      CampusMapCanvasConfiguration(
        campus: data.campusById[campusId]!,
        svg: '<svg xmlns="http://www.w3.org/2000/svg"></svg>',
        places:
            data.places.where((place) => place.campusId == campusId).toList(),
        accent: const Color(0xff3478d4),
        selectedPlaceId: selectedId,
        focusRevision: focusRevision,
        bottomInset: bottomInset,
        location: location,
        focusPoint: focusPoint,
        active: active,
      );

  Future<void> show(
      WidgetTester tester, CampusMapCanvasConfiguration configuration,
      {ValueChanged<String>? onPlaceTap, VoidCallback? onMapTap}) async {
    await tester.pumpWidget(MaterialApp(
      home: CampusMapCanvas(
        configuration: configuration,
        onPlaceTap: onPlaceTap ?? (_) {},
        onMapTap: onMapTap ?? () {},
      ),
    ));
    await tester.pump();
  }

  Future<void> ready(WidgetTester tester) async {
    platform.controller.message('ready');
    await tester.pumpAndSettle();
  }

  testWidgets('Android composition and cache defines reach the canvas',
      (tester) async {
    await show(tester, configuration());
    await ready(tester);
    final params =
        platform.widgetParams.single as AndroidWebViewWidgetCreationParams;
    expect(params.displayWithHybridComposition,
        const bool.fromEnvironment('CAMPUS_MAP_ANDROID_HYBRID_COMPOSITION'));
    expect(params.gestureRecognizers, hasLength(1));
    expect(
        platform.controller.loads.single.value['cachedGestures'],
        const bool.fromEnvironment('CAMPUS_MAP_CACHED_GESTURES',
            defaultValue: true));
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('non Android canvas does not request Android composition',
      (tester) async {
    await show(tester, configuration());
    await ready(tester);
    expect(platform.widgetParams.single,
        isNot(isA<AndroidWebViewWidgetCreationParams>()));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('panel rebuilds reuse the native view and gesture recognizer',
      (tester) async {
    await show(tester, configuration());
    await ready(tester);
    final params = platform.widgetParams.single;
    await show(tester, configuration(bottomInset: 280));
    await tester.pumpAndSettle();
    await show(tester, configuration(bottomInset: 240));
    await tester.pumpAndSettle();
    expect(platform.widgetParams, [params]);
    expect(platform.controller.documentLoads, 1);
  });

  testWidgets(
      'covering and uncovering the map updates activity without reloading',
      (tester) async {
    await show(tester, configuration());
    await ready(tester);
    final controller = platform.controller;
    controller.calls.clear();

    await show(tester, configuration(active: false));
    await tester.pumpAndSettle();
    expect(controller.updates.single.value['active'], isFalse);
    expect(controller.updates.single.value['focus'], isFalse);
    await show(tester, configuration(active: false));
    await tester.pumpAndSettle();
    expect(controller.updates, hasLength(1));

    await show(tester, configuration());
    await tester.pumpAndSettle();
    expect(controller.updates.last.value['active'], isTrue);
    expect(controller.updates.last.value['focus'], isFalse);
    expect(controller.loads, isEmpty);
    expect(controller.documentLoads, 1);
    expect(platform.widgetParams, hasLength(1));
  });

  testWidgets('canvas can load behind search without starting active',
      (tester) async {
    await show(tester, configuration(active: false));
    await ready(tester);
    expect(platform.controller.loads.single.value['active'], isFalse);
    expect(platform.controller.updates.single.value['active'], isFalse);
  });

  testWidgets('covered canvas ignores late tap messages from the platform',
      (tester) async {
    final places = <String>[];
    var backgrounds = 0;
    await show(tester, configuration(active: false),
        onPlaceTap: places.add, onMapTap: () => backgrounds++);
    await ready(tester);
    final controller = platform.controller;
    controller.message('place', id: 'place_baoshan_building-d5');
    controller.message('background');
    expect(places, isEmpty);
    expect(backgrounds, 0);

    await show(tester, configuration(),
        onPlaceTap: places.add, onMapTap: () => backgrounds++);
    await tester.pumpAndSettle();
    controller.message('place', id: 'place_baoshan_building-d5');
    controller.message('background');
    expect(places, ['place_baoshan_building-d5']);
    expect(backgrounds, 1);
  });

  testWidgets('equivalent rebuilds do not send more canvas commands',
      (tester) async {
    await show(
        tester,
        configuration(
            location: {'x': 120.0, 'y': 180.0, 'accuracy': 5.0},
            focusPoint: const CampusMapPoint(120, 180)));
    await ready(tester);
    final controller = platform.controller;
    expect(controller.loads, hasLength(1));
    expect(controller.updates.single.value['focus'], isTrue);
    controller.calls.clear();

    await show(
        tester,
        configuration(
            location: {'x': 120.0, 'y': 180.0, 'accuracy': 5.0},
            focusPoint: const CampusMapPoint(120, 180)));
    await tester.pumpAndSettle();
    expect(controller.calls, isEmpty);
  });

  testWidgets('panel and location updates preserve the focus request',
      (tester) async {
    await show(tester, configuration());
    await ready(tester);
    final controller = platform.controller;
    controller.calls.clear();

    await show(tester, configuration(bottomInset: 280));
    await tester.pumpAndSettle();
    expect(controller.updates.single.value['bottomInset'], 280);
    expect(controller.updates.single.value['focus'], isFalse);
    expect(controller.loads, isEmpty);

    await show(tester,
        configuration(bottomInset: 280, location: {'x': 130.0, 'y': 190.0}));
    await tester.pumpAndSettle();
    expect(controller.updates.last.value['focus'], isFalse);

    await show(
        tester,
        configuration(
            bottomInset: 280,
            location: {'x': 130.0, 'y': 190.0},
            focusRevision: 2));
    await tester.pumpAndSettle();
    expect(controller.updates, hasLength(3));
    expect(controller.updates.last.value['focus'], isTrue);
  });

  testWidgets('busy bridge coalesces updates to the latest selection and inset',
      (tester) async {
    await show(tester, configuration());
    await ready(tester);
    final controller = platform.controller;
    controller.calls.clear();
    final block = Completer<void>();
    controller.blockNextUpdate = block;
    addTearDown(() {
      if (!block.isCompleted) block.complete();
    });

    await show(tester, configuration(bottomInset: 220));
    await show(tester, configuration(bottomInset: 230));
    await show(tester, configuration(bottomInset: 240));
    await show(
        tester,
        configuration(
            selectedId: 'place_baoshan_main-library',
            bottomInset: 300,
            focusRevision: 2));
    expect(controller.updates, hasLength(1));

    block.complete();
    await tester.pumpAndSettle();
    expect(controller.updates, hasLength(2));
    final latest = controller.updates.last.value;
    expect(latest['selectedId'], 'place_baoshan_main-library');
    expect(latest['bottomInset'], 300);
    expect(latest['focus'], isTrue);
    expect(controller.loads, isEmpty);
  });

  testWidgets('campus change during loading skips the obsolete selection',
      (tester) async {
    await show(tester, configuration());
    final controller = platform.controller;
    final block = Completer<void>();
    controller.blockNextLoad = block;
    addTearDown(() {
      if (!block.isCompleted) block.complete();
    });
    controller.message('ready');
    await tester.pump();
    await show(
        tester,
        configuration(
            campusId: 'yanchang',
            selectedId: 'place_yanchang_wenwu-building',
            focusRevision: 2));
    block.complete();
    await tester.pumpAndSettle();

    expect(controller.loads.map((call) => call.value['campusId']),
        ['baoshan', 'yanchang']);
    expect(controller.updates.single.value['selectedId'],
        'place_yanchang_wenwu-building');
    expect(controller.updates.single.value['focus'], isTrue);
  });

  testWidgets('retrying a document resends campus and focus state',
      (tester) async {
    await show(tester, configuration());
    await ready(tester);
    final controller = platform.controller;
    controller.calls.clear();
    controller.message('error');
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新加载'));
    await tester.pump();
    await ready(tester);

    expect(controller.documentLoads, 2);
    expect(controller.loads, hasLength(1));
    expect(controller.updates.single.value['focus'], isTrue);
  });

  testWidgets('disposing during a platform call does not send an update',
      (tester) async {
    await show(tester, configuration());
    final controller = platform.controller;
    final block = Completer<void>();
    controller.blockNextLoad = block;
    addTearDown(() {
      if (!block.isCompleted) block.complete();
    });
    controller.message('ready');
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    block.complete();
    await tester.pump();

    expect(controller.updates, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed obsolete call cannot break a reloaded document',
      (tester) async {
    await show(tester, configuration());
    await ready(tester);
    final controller = platform.controller;
    final block = Completer<void>();
    controller.blockNextUpdate = block;
    addTearDown(() {
      if (!block.isCompleted) block.complete();
    });
    await show(tester, configuration(bottomInset: 280));
    controller.message('error');
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新加载'));
    await tester.pump();
    controller.message('ready');
    controller.calls.clear();
    block.completeError(StateError('The previous document was unloaded'));
    await tester.pumpAndSettle();

    expect(find.text('地图画布加载失败'), findsNothing);
    expect(controller.loads, hasLength(1));
    expect(controller.updates.single.value['bottomInset'], 280);
    expect(controller.updates.single.value['focus'], isTrue);
    expect(tester.takeException(), isNull);
  });
}

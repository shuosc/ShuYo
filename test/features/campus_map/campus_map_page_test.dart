import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/repositories/campus_map_repository.dart';
import 'package:shuyo/data/models/campus_map.dart';
import 'package:shuyo/data/services/campus_map_location_service.dart';
import 'package:shuyo/features/campus_map/campus_map_canvas.dart';
import 'package:shuyo/features/campus_map/campus_map_page.dart';
import 'package:shuyo/features/campus_map/campus_map_place_details.dart';
import 'package:shuyo/features/home/home_dashboard_page.dart';

class _AssetBundle extends CachingAssetBundle {
  final Map<String, String> texts = {
    for (final file in Directory('assets/campus_map')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) =>
            file.path.endsWith('.json') || file.path.endsWith('.svg')))
      file.path.replaceAll(r'\', '/'): file.readAsStringSync(),
  };

  @override
  Future<ByteData> load(String key) async {
    final bytes = Uint8List.fromList(utf8.encode(texts[key]!));
    return ByteData.sublistView(bytes);
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async =>
      texts[key]!;
}

class _LocationService extends CampusMapLocationService {
  final controller = StreamController<CampusMapLocation>.broadcast();
  int calls = 0;
  int watches = 0;
  CampusMapLocationException? failure;

  @override
  Future<CampusMapLocation> locate() async {
    calls++;
    if (failure != null) throw failure!;
    return const CampusMapLocation(
        longitude: 121.3915, latitude: 31.3162, accuracy: 15);
  }

  @override
  Future<bool> canWatch() async => true;

  @override
  Stream<CampusMapLocation> watch() {
    watches++;
    return controller.stream;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CampusMapCanvasConfiguration canvas;
  late _LocationService location;
  late CampusMapRepository repository;
  late ValueChanged<String> selectOnMap;
  late List<CampusMapCanvasConfiguration> canvasUpdates;

  setUp(() {
    location = _LocationService();
    repository = CampusMapRepository(bundle: _AssetBundle());
    canvasUpdates = [];
  });

  tearDown(() async => location.controller.close());

  Widget map({String initialCampus = '宝山校区'}) => CampusMapPage(
        initialCampus: initialCampus,
        repository: repository,
        locationService: location,
        canvasBuilder: (context, configuration, onPlace, onBackground) {
          canvas = configuration;
          canvasUpdates.add(configuration);
          selectOnMap = onPlace;
          return GestureDetector(
            key: const ValueKey('map-canvas'),
            onTap: onBackground,
            child: ColoredBox(
              color: Colors.grey.shade200,
              child: Center(child: Text('底图 ${configuration.campus.name}')),
            ),
          );
        },
      );

  testWidgets('home map row follows library booking and opens without login',
      (tester) async {
    var opened = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HomeDashboardPage(
          hasAcademicAccount: false,
          isAcademicLoginCompleting: false,
          onLogin: () {},
          onOpenAcademicSystem: () {},
          onOpenAnnouncements: () {},
          onOpenEmptyClassroom: () {},
          onOpenCampusMap: () => opened = true,
          onOpenOtp: () {},
          todayCourseContent: '今日无课',
          announcementContent: '查看公告',
        ),
      ),
    ));
    await tester.ensureVisible(find.text('校园地图'));
    expect(tester.getTopLeft(find.text('校园地图')).dy,
        greaterThan(tester.getTopLeft(find.text('图书馆预约')).dy));
    await tester.tap(find.text('校园地图'));
    expect(opened, isTrue);
  });

  testWidgets('selecting a search result focuses the place and exits search',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: map()));
    await tester.pumpAndSettle();
    expect(find.text('底图 宝山校区'), findsOneWidget);
    expect(location.calls, 0);

    await tester.enterText(find.byType(TextField), '文武大楼');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '文武大楼'), findsOneWidget);
    expect(find.text('延长校区 · 建筑'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, '文武大楼'));
    await tester.pumpAndSettle();
    expect(canvas.campus.id, 'yanchang');
    expect(canvas.selectedPlaceId, 'place_yanchang_wenwu-building');
    expect(canvas.bottomInset, greaterThan(0));
    expect(find.text('导航到这里'), findsOneWidget);
    expect(find.byType(CampusMapPlaceDetails), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isFalse);

    await tester.tap(find.byTooltip('关闭地点详情'));
    await tester.pumpAndSettle();
    expect(canvas.selectedPlaceId, isNull);
    expect(find.textContaining('共找到'), findsNothing);
    expect(find.byTooltip('关闭搜索'), findsNothing);
    expect(find.byTooltip('清空搜索'), findsNothing);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.text('输入地点或学院名称查找'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭搜索'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('定位到我的位置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final result in [
    ('D5 楼（文学院）', '文学院', 'place_baoshan_building-d5', 'baoshan'),
    ('文武大楼', '文武大楼', 'place_yanchang_wenwu-building', 'yanchang'),
  ]) {
    testWidgets(
        'keyboard resizing retains the selected target and sheet inset for ${result.$4}',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);

      await tester.pumpWidget(MaterialApp(home: map()));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), result.$2);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, result.$1));
      await tester.pump(const Duration(milliseconds: 80));
      expect(canvas.selectedPlaceId, result.$3);
      final revision = canvas.focusRevision;

      for (final inset in [200.0, 100.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 16));
        expect(canvas.selectedPlaceId, result.$3);
        expect(canvas.focusRevision, revision);
      }
      await tester.pumpAndSettle();

      expect(canvas.campus.id, result.$4);
      expect(canvas.focusPoint, isNull);
      expect(canvas.focusRevision, revision);
      expect(
          canvas.bottomInset,
          closeTo(
              tester.getSize(find.byType(CampusMapPlaceDetails)).height, 1));
      expect(
          tester.getRect(find.byKey(const ValueKey('map-canvas'))).bottom, 844);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('only search results resize during keyboard transitions',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetPadding);
    await tester.pumpWidget(MaterialApp(home: map()));
    await tester.pumpAndSettle();
    final mapRect = tester.getRect(find.byKey(const ValueKey('map-canvas')));
    await tester.enterText(find.byType(TextField), '楼');
    await tester.pumpAndSettle();
    expect(canvas.active, isFalse);
    final updates = canvasUpdates.length;

    for (final inset in [100.0, 200.0, 300.0, 200.0, 100.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      tester.view.padding = FakeViewPadding(bottom: inset > 0 ? 0 : 34);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getRect(find.byKey(const ValueKey('map-canvas'))), mapRect);
      expect(
          tester
              .getRect(find.byKey(const ValueKey('campus-map-search-results')))
              .bottom,
          closeTo(844 - inset, 1));
      expect(canvasUpdates, hasLength(updates));
    }
    expect(tester.takeException(), isNull);
  });

  for (final query in ['', '不存在的地点xyz', 'D5']) {
    testWidgets('blank tap closes search and keyboard for "$query"',
        (tester) async {
      await tester.pumpWidget(MaterialApp(home: map()));
      await tester.pumpAndSettle();
      if (query.isEmpty) {
        await tester.tap(find.byType(TextField));
      } else {
        await tester.enterText(find.byType(TextField), query);
      }
      await tester.pumpAndSettle();
      expect(canvas.active, isFalse);
      final search = tester
          .getRect(find.byKey(const ValueKey('campus-map-search-results')));
      await tester.tapAt(search.bottomCenter - const Offset(0, 24));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('campus-map-search-results')),
          findsNothing);
      expect(find.byTooltip('定位到我的位置'), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasFocus, isFalse);
      expect(field.controller!.text, isEmpty);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(canvas.active, isTrue);
      expect(canvas.selectedPlaceId, isNull);
      expect(find.byType(CampusMapPage), findsOneWidget);
    });
  }

  testWidgets('blank tap also closes search after the keyboard loses focus',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: map()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'D5');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isFalse);
    expect(find.widgetWithText(ListTile, 'D5 楼（文学院）'), findsOneWidget);

    await tester.tap(find.textContaining('共找到'));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('campus-map-search-results')), findsNothing);
    expect(canvas.active, isTrue);
    expect(canvas.selectedPlaceId, isNull);
  });

  testWidgets('result taps survive pointer down while the keyboard is open',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: map()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'D5');
    await tester.pumpAndSettle();
    final result = find.widgetWithText(ListTile, 'D5 楼（文学院）');
    final press = await tester.startGesture(tester.getCenter(result));
    await tester.pump(const Duration(milliseconds: 100));
    expect(result, findsOneWidget);
    expect(canvas.active, isFalse);
    await press.up();
    await tester.pumpAndSettle();

    expect(canvas.selectedPlaceId, 'place_baoshan_building-d5');
    expect(canvas.active, isTrue);
    expect(canvas.bottomInset, greaterThan(0));
    expect(tester.testTextInput.isVisible, isFalse);
    expect(
        find.byKey(const ValueKey('campus-map-search-results')), findsNothing);
  });

  testWidgets(
      'scrolling search results dismisses the keyboard and keeps results',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: map()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '楼');
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('campus-map-search-results')),
        findsOneWidget);
    expect(canvas.active, isFalse);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '楼');
    expect(field.focusNode!.hasFocus, isFalse);
    expect(canvas.selectedPlaceId, isNull);
  });

  testWidgets('editing and clearing the query do not count as outside taps',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: map()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'D5');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'D5 楼（文学院）'), findsOneWidget);
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pumpAndSettle();

    expect(find.text('输入地点或学院名称查找'), findsOneWidget);
    expect(canvas.active, isFalse);
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue);
  });

  testWidgets(
      'opening the campus picker exits search before switching campuses',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: map()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'D5');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('campus-map-search-results')), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.tap(find.text('嘉定校区').last);
    await tester.pumpAndSettle();
    expect(canvas.campus.id, 'jiading');
    expect(canvas.active, isTrue);
  });

  testWidgets('detail height stays stable while the selection keyboard closes',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    tester.view.padding = const FakeViewPadding(bottom: 0);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetPadding);
    await tester.pumpWidget(MaterialApp(home: map()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'D5');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'D5 楼（文学院）'));
    await tester.pumpAndSettle();
    final panel = tester.getRect(find.byType(CampusMapPlaceDetails));
    final mapRect = tester.getRect(find.byKey(const ValueKey('map-canvas')));
    final inset = canvas.bottomInset;
    for (final keyboard in [200.0, 100.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      tester.view.padding = FakeViewPadding(bottom: keyboard > 0 ? 0 : 34);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getRect(find.byType(CampusMapPlaceDetails)), panel);
      expect(tester.getRect(find.byKey(const ValueKey('map-canvas'))), mapRect);
      expect(canvas.bottomInset, inset);
    }
    expect(canvas.active, isTrue);
    expect(canvas.selectedPlaceId, 'place_baoshan_building-d5');
    expect(tester.takeException(), isNull);
  });

  for (final dismiss in ['background', 'close', 'back', 'another building']) {
    testWidgets('search does not return after selecting a result and $dismiss',
        (tester) async {
      await tester.pumpWidget(MaterialApp(home: map()));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '文学院');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'D5 楼（文学院）'));
      await tester.pumpAndSettle();

      switch (dismiss) {
        case 'background':
          final map = tester.getRect(find.byKey(const ValueKey('map-canvas')));
          await tester.tapAt(map.topLeft + const Offset(20, 20));
        case 'close':
          await tester.tap(find.byTooltip('关闭地点详情'));
        case 'back':
          await tester.tap(find.byTooltip('返回'));
        case 'another building':
          selectOnMap('place_baoshan_building-d4');
          await tester.pumpAndSettle();
          expect(canvas.selectedPlaceId, 'place_baoshan_building-d4');
          await tester.tap(find.byTooltip('关闭地点详情'));
      }
      await tester.pumpAndSettle();
      expect(canvas.selectedPlaceId, isNull);
      expect(find.byType(CampusMapPlaceDetails), findsNothing);
      expect(find.textContaining('共找到'), findsNothing);
      expect(find.byTooltip('清空搜索'), findsNothing);
      expect(find.byTooltip('关闭搜索'), findsNothing);
      expect(find.byTooltip('定位到我的位置'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final bottomPadding in [0.0, 24.0, 34.0, 48.0]) {
    testWidgets(
        'detail background reaches screen bottom with inset $bottomPadding',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.padding = FakeViewPadding(bottom: bottomPadding);
      tester.view.viewPadding = FakeViewPadding(bottom: bottomPadding);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);

      await tester.pumpWidget(MaterialApp(home: map()));
      await tester.pumpAndSettle();
      expect(
          tester.getRect(find.byKey(const ValueKey('map-canvas'))).bottom, 844);
      expect(tester.getRect(find.byTooltip('定位到我的位置')).bottom,
          lessThanOrEqualTo(844 - bottomPadding - 16));
      selectOnMap('place_baoshan_building-d5');
      await tester.pumpAndSettle();

      final panel = tester.getRect(find.byType(CampusMapPlaceDetails));
      final navigation =
          tester.getRect(find.widgetWithText(FilledButton, '导航到这里'));
      expect(panel.bottom, 844);
      expect(canvas.bottomInset, closeTo(panel.height, 1));
      expect(panel.bottom - navigation.bottom, closeTo(bottomPadding + 16, 1));
      final background = find
          .descendant(
            of: find.byType(CampusMapPlaceDetails),
            matching: find.byType(Material),
          )
          .first;
      expect(tester.getRect(background).bottom, 844);
      expect(
          tester.widget<Material>(background).color, isNot(Colors.transparent));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('map controls and building details use the revised layout',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: map()));
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField)).decoration!.hintText,
        '搜索全部校区');
    expect(
        tester
            .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
            .borderRadius,
        BorderRadius.zero);
    expect(find.byTooltip('恢复全图'), findsNothing);
    expect(find.textContaining('离线'), findsNothing);

    selectOnMap('place_baoshan_building-d5');
    await tester.pumpAndSettle();
    expect(find.text('D5 楼（文学院）'), findsOneWidget);
    expect(find.text('位置'), findsOneWidget);
    final panel = tester.getRect(find.byType(CampusMapPlaceDetails));
    final navigation =
        tester.getRect(find.widgetWithText(FilledButton, '导航到这里'));
    expect(panel.bottom - navigation.bottom, lessThan(32));
    expect(canvas.bottomInset, closeTo(panel.height, 1));

    selectOnMap('place_baoshan_building-d4');
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('D5 楼（文学院）'), findsOneWidget);
    expect(find.text('D4 楼（法学院）'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('D5 楼（文学院）'), findsNothing);
    expect(find.text('D4 楼（法学院）'), findsOneWidget);
    expect(canvas.selectedPlaceId, 'place_baoshan_building-d4');
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('department search opens the corresponding building',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: map()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '文学院');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'D5 楼（文学院）'));
    await tester.pumpAndSettle();
    expect(canvas.selectedPlaceId, 'place_baoshan_building-d5');
    expect(canvas.campus.id, 'baoshan');
  });

  testWidgets(
      'detail action stays fixed while switching and scrolling information',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: map()));
    await tester.pumpAndSettle();
    selectOnMap('place_baoshan_building-d5');
    await tester.pumpAndSettle();
    final shortHeight =
        tester.getSize(find.byType(CampusMapPlaceDetails)).height;
    expect(shortHeight, lessThan(300));
    expect(
        find.descendant(
            of: find.byType(CampusMapPlaceDetails),
            matching: find.byType(Divider)),
        findsNothing);
    final buttonRect =
        tester.getRect(find.widgetWithText(FilledButton, '导航到这里'));

    selectOnMap('place_baoshan_main-library');
    await tester.pump(const Duration(milliseconds: 80));
    expect(
        tester.getRect(find.widgetWithText(FilledButton, '导航到这里')), buttonRect);
    await tester.pumpAndSettle();
    final longHeight =
        tester.getSize(find.byType(CampusMapPlaceDetails)).height;
    expect(longHeight, greaterThan(shortHeight));
    expect(canvas.bottomInset, closeTo(longHeight, 1));
    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('导航到这里').hitTestable(), findsOneWidget);
    expect(
        tester.getRect(find.widgetWithText(FilledButton, '导航到这里')), buttonRect);
    expect(find.text('校图书馆').hitTestable(), findsOneWidget);

    selectOnMap('place_baoshan_building-d5');
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(CampusMapPlaceDetails)).height,
        closeTo(shortHeight, 1));
    expect(canvas.bottomInset, closeTo(shortHeight, 1));
    expect(
        tester.getRect(find.widgetWithText(FilledButton, '导航到这里')), buttonRect);
    expect(tester.takeException(), isNull);
  });

  testWidgets('debug view is only printed to the console every three seconds',
      (tester) async {
    final messages = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message?.startsWith('[CAMPUS_MAP_VIEW]') == true) {
        messages.add(message!);
      }
    };
    addTearDown(() => debugPrint = originalDebugPrint);
    await tester.pumpWidget(MaterialApp(home: map(initialCampus: '嘉定校区')));
    await tester.pumpAndSettle();
    const view =
        CampusMapView(center: CampusMapPoint(212.25, 193.75), zoom: 2.375);
    canvas.onViewChanged!(view);
    await tester.pumpAndSettle();
    expect(find.textContaining('视图调试'), findsNothing);
    expect(find.textContaining('212.25, 193.75'), findsNothing);
    expect(find.text('复制当前视图'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(messages, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(messages, hasLength(1));
    expect(
        messages.single, startsWith('[CAMPUS_MAP_VIEW] jiading initialView='));
    expect(
        jsonDecode(messages.single.split('initialView=').last), view.toJson());
    const updated = CampusMapView(center: CampusMapPoint(220, 180), zoom: 1.5);
    canvas.onViewChanged!(updated);
    await tester.pump(const Duration(seconds: 3));
    expect(messages, hasLength(2));
    expect(
        jsonDecode(messages.last.split('initialView=').last), updated.toJson());
    expect(location.calls, 0);
    debugPrint = originalDebugPrint;
  });

  for (final brightness in Brightness.values) {
    testWidgets(
        'page follows the app theme while only the canvas matches the SVG in $brightness',
        (tester) async {
      final pageColor = brightness == Brightness.dark
          ? const Color(0xff101820)
          : const Color(0xfffafafa);
      final toolbarColor = brightness == Brightness.dark
          ? const Color(0xff182129)
          : const Color(0xfff5f7fa);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
          brightness: brightness,
          scaffoldBackgroundColor: pageColor,
          appBarTheme: AppBarTheme(backgroundColor: toolbarColor),
        ),
        home: map(),
      ));
      await tester.pumpAndSettle();
      final pageMaterial = find
          .descendant(
              of: find.byType(Scaffold), matching: find.byType(Material))
          .first;
      final toolbarMaterial = find
          .descendant(of: find.byType(AppBar), matching: find.byType(Material))
          .first;
      expect(tester.widget<Material>(pageMaterial).color, pageColor);
      expect(tester.widget<Material>(toolbarMaterial).color, toolbarColor);
      expect(canvas.backgroundColor, const Color(0xffeaeadf));
      expect(canvas.campus.backgroundColor, '#EAEADF');
    });
  }

  testWidgets('long building details fit a narrow phone without blank padding',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(home: map()));
    await tester.pumpAndSettle();
    selectOnMap('place_baoshan_building-d6');
    await tester.pumpAndSettle();
    expect(find.text('D6 楼（中欧工程技术学院）'), findsOneWidget);
    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(find.text('导航到这里').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'location is opt in, focuses the correct campus and stops on background',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: map(initialCampus: '嘉定校区')));
    await tester.pumpAndSettle();
    expect(canvas.campus.id, 'jiading');
    expect(location.calls, 0);

    await tester.tap(find.byTooltip('定位到我的位置'));
    await tester.pumpAndSettle();
    expect(location.calls, 1);
    expect(canvas.campus.id, 'baoshan');
    expect(canvas.location, isNotNull);
    expect(canvas.focusPoint, isNotNull);
    expect(location.controller.hasListener, isTrue);

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(location.controller.hasListener, isFalse);
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(location.controller.hasListener, isTrue);
    expect(canvas.location, isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(location.controller.hasListener, isFalse);
  });

  testWidgets('denying location leaves offline search usable', (tester) async {
    location.failure = const CampusMapLocationException('未获得定位权限，仍可浏览和搜索地图');
    await tester.pumpWidget(MaterialApp(home: map()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('定位到我的位置'));
    await tester.pumpAndSettle();
    expect(find.text('未获得定位权限，仍可浏览和搜索地图'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'A楼');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'A 楼'), findsWidgets);
    expect(location.controller.hasListener, isFalse);
  });

  testWidgets('back closes search and keyboard together before leaving the map',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => map())),
            child: const Text('打开地图'),
          ),
        );
      }),
    ));
    await tester.tap(find.text('打开地图'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'A楼');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'A 楼'), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(find.byType(CampusMapPage), findsOneWidget);
    expect(find.byTooltip('定位到我的位置'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.byType(CampusMapPage), findsNothing);
  });
}

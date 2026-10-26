import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/campus_map.dart';
import 'package:shuyo/data/repositories/campus_map_repository.dart';
import 'package:shuyo/data/services/campus_map_location_service.dart';
import 'package:shuyo/data/services/campus_map_navigation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CampusMapData data;

  setUpAll(() async {
    data = await CampusMapRepository().load();
  });

  test('all bundled places and footprints resolve to offline campus assets',
      () async {
    expect(
        data.campuses.map((campus) => campus.name), ['宝山校区', '延长校区', '嘉定校区']);
    expect(data.places.length, greaterThan(200));
    final repository = CampusMapRepository();
    for (final campus in data.campuses) {
      final svg = await repository.loadSvg(campus);
      final ids = RegExp(r'\bid="([^"]+)"')
          .allMatches(svg)
          .map((match) => match.group(1))
          .toSet();
      expect(
          svg, contains('viewBox="${campus.viewBox.map(_compact).join(' ')}"'));
      expect(svg, isNot(contains('<script')));
      expect(svg, isNot(contains('<image')));
      expect(svg.toLowerCase(),
          contains('fill: ${campus.backgroundColor.toLowerCase()}'));
      for (final place
          in data.places.where((place) => place.campusId == campus.id)) {
        expect(place.featureIds.isNotEmpty || place.point != null, isTrue,
            reason: '${place.name} must be visible on the map');
        for (final id in place.featureIds) {
          expect(ids, contains(id), reason: '${place.name}: $id');
        }
        expect(place.facts.any((fact) => fact.value.contains('测试')), isFalse);
      }
    }
    final html = File('assets/campus_map/canvas.html').readAsStringSync();
    expect(html, contains("connect-src 'none'"));
    expect(html, isNot(contains('fetch(')));
    expect(html, isNot(contains('XMLHttpRequest')));
    expect(html, isNot(contains('<script src=')));
  });

  test('each campus supports an independent initial center and zoom', () {
    final json =
        jsonDecode(File('assets/campus_map/map_data.json').readAsStringSync())
            as Map<String, dynamic>;
    final campuses = json['campuses'] as List;
    campuses[0]['initialView'] = {
      'zoom': 1.7,
      'center': {'x': 420.5, 'y': 535.25}
    };
    campuses[1]['initialView'] = {
      'zoom': 2.4,
      'center': {'x': 702.0, 'y': 610.0}
    };
    final modified = CampusMapData.fromJson(json);
    expect(modified.campuses[0].initialView.zoom, 1.7);
    expect(modified.campuses[0].initialView.center.x, 420.5);
    expect(modified.campuses[1].initialView.zoom, 2.4);
    expect(modified.campuses[1].initialView.center.y, 610);
    expect(modified.campuses[2].initialView.zoom,
        data.campuses[2].initialView.zoom);
    campuses[0]['initialView']['zoom'] = 0;
    expect(() => CampusMapData.fromJson(json), throwsFormatException);
  });

  test('search handles spaces, case and fullwidth input without a server', () {
    for (final query in ['A楼', ' a 楼 ', 'Ａ楼']) {
      expect(data.search(query).first.id, 'place_baoshan_building-a');
    }
    expect(data.search('一食堂').map((place) => place.campusId).toSet(),
        containsAll(['baoshan', 'jiading']));
    expect(data.search('一食堂', preferredCampusId: 'jiading').first.campusId,
        'jiading');
    expect(data.search('不存在的校园地点xyz'), isEmpty);
    expect(data.search('   '), isEmpty);
    expect(data.initialCampus('嘉定校区').id, 'jiading');
    expect(data.initialCampus('unknown').id, 'baoshan');
  });

  test('search includes full building labels and department names', () {
    const buildings = {
      '文学院': 'place_baoshan_building-d5',
      '法学院': 'place_baoshan_building-d4',
      '中欧工程技术学院': 'place_baoshan_building-d6',
      '校出版社': 'place_baoshan_building-d3',
      '社会科学学部': 'place_baoshan_building-d2',
      '计算机楼': 'place_baoshan_building-d15',
    };
    for (final entry in buildings.entries) {
      expect(data.search(entry.key).map((place) => place.id),
          contains(entry.value));
    }
    for (final query in ['D5楼', 'd5', 'Ｄ５ 楼', 'D5楼(文学院)', 'D5楼文学院']) {
      expect(data.search(query).first.id, 'place_baoshan_building-d5');
    }
    expect(data.placeById['place_baoshan_building-d5']!.name, 'D5 楼（文学院）');
  });

  test('device coordinates agree with upstream WGS84 to GCJ02 conversion', () {
    final coordinate = campusMapWgs84ToGcj02(121.3915, 31.3162);
    expect(coordinate.longitude, closeTo(121.3961560860805, 1e-10));
    expect(coordinate.latitude, closeTo(31.314398322418484, 1e-10));
    expect(data.campusAt(coordinate)?.id, 'baoshan');
    final overseas = campusMapWgs84ToGcj02(-74, 40.7);
    expect(overseas.longitude, -74);
    expect(overseas.latitude, 40.7);
    expect(data.campusAt(overseas), isNull);
    expect(() => campusMapWgs84ToGcj02(double.nan, 31), throwsFormatException);
    final location =
        CampusMapLocation(longitude: 121.3915, latitude: 31.3162, accuracy: 20);
    expect(location.forCampus(data.campusById['baoshan']!), isNotNull);
    expect(location.forCampus(data.campusById['jiading']!), isNull);
  });

  test('bundle rejects unknown formats and non-local asset paths', () {
    final json = jsonDecode(
      File('assets/campus_map/map_data.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    json['schemaVersion'] = 2;
    expect(() => CampusMapData.fromJson(json), throwsFormatException);
    json['schemaVersion'] = 1;
    (json['campuses'] as List).first['asset'] = 'https://example.com/map.svg';
    expect(() => CampusMapData.fromJson(json), throwsFormatException);
  });

  test('navigation keeps GCJ02 coordinates and requests walking routes', () {
    final place = data.placeById['place_baoshan_building-a']!;
    for (final provider in CampusMapNavigationProvider.values) {
      for (final isIOS in [true, false]) {
        final uri =
            CampusMapNavigationService.nativeUri(provider, place, isIOS: isIOS);
        expect(uri.toString(), contains(Uri.encodeComponent(place.name)));
        switch (provider) {
          case CampusMapNavigationProvider.amap:
            expect(uri.queryParameters['t'], '2');
            expect(uri.queryParameters['dev'], '0');
            expect(
                uri.queryParameters['dlat'], '${place.navigation!.latitude}');
          case CampusMapNavigationProvider.baidu:
            expect(uri.queryParameters['mode'], 'walking');
            expect(uri.queryParameters['coord_type'], 'gcj02');
          case CampusMapNavigationProvider.tencent:
            expect(uri.queryParameters['type'], 'walk');
            expect(uri.queryParameters['tocoord'],
                '${place.navigation!.latitude},${place.navigation!.longitude}');
        }
      }
      final web = CampusMapNavigationService.webUri(provider, place);
      expect(web.scheme, 'https');
      expect(web.toString(), isNot(contains('driv')));
    }
  });

  test('navigation tries the native app before the external web fallback',
      () async {
    final urls = <Uri>[];
    final service = CampusMapNavigationService(
      isIOS: false,
      launcher: (uri) async {
        urls.add(uri);
        return uri.scheme == 'https';
      },
    );
    await service.open(CampusMapNavigationProvider.amap,
        data.placeById['place_baoshan_building-a']!);
    expect(urls.map((uri) => uri.scheme), ['androidamap', 'https']);

    final noCoordinates = data.places.firstWhere((p) => p.navigation == null);
    urls.clear();
    await expectLater(
        () => service.open(CampusMapNavigationProvider.amap, noCoordinates),
        throwsA(isA<CampusMapNavigationException>()));
    expect(urls, isEmpty);
  });

  test('unavailable external navigation reports a recoverable error', () async {
    final service = CampusMapNavigationService(launcher: (_) async => false);
    await expectLater(
      () => service.open(CampusMapNavigationProvider.baidu,
          data.placeById['place_baoshan_building-a']!),
      throwsA(isA<CampusMapNavigationException>()),
    );
  });
}

String _compact(double value) =>
    value == value.roundToDouble() ? value.toInt().toString() : '$value';

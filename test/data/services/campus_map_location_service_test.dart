import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
import 'package:shuyo/data/services/campus_map_location_service.dart';

class _FakeGeolocatorPlatform extends GeolocatorPlatform {
  bool serviceEnabled = true;
  LocationPermission permission = LocationPermission.whileInUse;
  LocationPermission? requestedPermission;
  Object? getCurrentPositionError;
  bool openedAppSettings = false;
  bool openedLocationSettings = false;
  final streamController = StreamController<Position>.broadcast();

  @override
  Future<bool> isLocationServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async =>
      requestedPermission ?? permission;

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    if (getCurrentPositionError != null) {
      throw getCurrentPositionError!;
    }
    return Position(
      longitude: 121.3915,
      latitude: 31.3162,
      timestamp: DateTime(2026),
      accuracy: 12,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
  }

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      streamController.stream;

  @override
  Future<bool> openAppSettings() async {
    openedAppSettings = true;
    return true;
  }

  @override
  Future<bool> openLocationSettings() async {
    openedLocationSettings = true;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('work.shuyo.app/campus_map_location');
  const eventChannel = EventChannel('work.shuyo.app/campus_map_location/events');

  group('CampusMapLocationService (iOS native)', () {
    const service = CampusMapLocationService(
      platformOverride: TargetPlatform.iOS,
    );

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, null);
    });

    test('locate parses native coordinates', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        expect(call.method, 'locate');
        return {'longitude': 121.3915, 'latitude': 31.3162, 'accuracy': 8.5};
      });

      final location = await service.locate();
      expect(location.longitude, 121.3915);
      expect(location.latitude, 31.3162);
      expect(location.accuracy, 8.5);
    });

    test('locate rejects null, malformed, non-finite, and out-of-range payloads',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (_) async => null);
      await expectLater(
        service.locate(),
        throwsA(
          isA<CampusMapLocationException>()
              .having((e) => e.message, 'message', '暂未获取到位置，请到开阔处重试'),
        ),
      );

      final badPayloads = <Map<String, Object?>>[
        {'longitude': 'bad', 'latitude': 31.3, 'accuracy': 10},
        {'longitude': double.nan, 'latitude': 31.3, 'accuracy': 10},
        {'longitude': 121.3, 'latitude': 95.0, 'accuracy': 10},
        {'longitude': 181.0, 'latitude': 31.3, 'accuracy': 10},
        {'longitude': 121.3, 'latitude': 31.3, 'accuracy': -1.0},
        {'longitude': 121.3, 'latitude': 31.3, 'accuracy': double.infinity},
      ];
      for (final payload in badPayloads) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodChannel, (_) async => payload);
        await expectLater(service.locate(), throwsFormatException);
      }
    });

    test('locate maps native error codes and rethrows unknown codes', () async {
      final cases = <(String, String, CampusMapLocationAction?)>[
        (
          'location_services_disabled',
          '请先开启系统定位服务',
          CampusMapLocationAction.locationSettings,
        ),
        (
          'permission_denied_forever',
          '定位权限已关闭，可在系统设置中开启',
          CampusMapLocationAction.appSettings,
        ),
        ('permission_denied', '未获得定位权限，仍可浏览和搜索地图', null),
        ('timeout', '暂未获取到位置，请到开阔处重试', null),
        ('location_unavailable', '暂未获取到位置，请到开阔处重试', null),
      ];

      for (final (code, message, action) in cases) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodChannel, (_) async {
          throw PlatformException(code: code);
        });
        await expectLater(
          service.locate(),
          throwsA(
            isA<CampusMapLocationException>()
                .having((e) => e.message, 'message', message)
                .having((e) => e.action, 'action', action),
          ),
        );
      }

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (_) async {
        throw PlatformException(code: 'unexpected_native_error');
      });
      await expectLater(
        service.locate(),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'unexpected_native_error'),
        ),
      );
    });

    test('canWatch and openSettings forward to native channel cleanly',
        () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        calls.add(call);
        return true;
      });

      expect(await service.canWatch(), isTrue);
      expect(
        await service.openSettings(CampusMapLocationAction.appSettings),
        isTrue,
      );
      expect(calls.map((c) => c.method), ['canWatch', 'openSettings']);
      expect(calls[1].arguments, isNull);
    });

    test('watch streams native location updates and rejects malformed events',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(
          onListen: (arguments, events) {
            events.success({
              'longitude': 121.392,
              'latitude': 31.317,
              'accuracy': 10,
            });
          },
        ),
      );

      final first = await service.watch().first;
      expect(first.longitude, 121.392);
      expect(first.latitude, 31.317);
      expect(first.accuracy, 10);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(
          onListen: (arguments, events) {
            events.success('invalid-event');
          },
        ),
      );

      await expectLater(service.watch().first, throwsFormatException);
    });
  });

  group('CampusMapLocationService (Android geolocator)', () {
    late GeolocatorPlatform originalPlatform;
    late _FakeGeolocatorPlatform fakePlatform;
    const service = CampusMapLocationService(
      platformOverride: TargetPlatform.android,
    );

    setUp(() {
      originalPlatform = GeolocatorPlatform.instance;
      fakePlatform = _FakeGeolocatorPlatform();
      GeolocatorPlatform.instance = fakePlatform;
    });

    tearDown(() async {
      GeolocatorPlatform.instance = originalPlatform;
      await fakePlatform.streamController.close();
    });

    test('locate, canWatch, watch and openSettings delegate to GeolocatorPlatform',
        () async {
      final loc = await service.locate();
      expect(loc.longitude, 121.3915);
      expect(loc.latitude, 31.3162);
      expect(await service.canWatch(), isTrue);

      final streamedFuture = service.watch().first;
      fakePlatform.streamController.add(
        Position(
          longitude: 121.393,
          latitude: 31.318,
          timestamp: DateTime(2026),
          accuracy: 9,
          altitude: 0,
          altitudeAccuracy: 0,
          heading: 0,
          headingAccuracy: 0,
          speed: 0,
          speedAccuracy: 0,
        ),
      );
      final streamed = await streamedFuture;
      expect(streamed.longitude, 121.393);
      expect(streamed.latitude, 31.318);

      expect(
        await service.openSettings(CampusMapLocationAction.appSettings),
        isTrue,
      );
      expect(
        await service.openSettings(CampusMapLocationAction.locationSettings),
        isTrue,
      );
      expect(fakePlatform.openedAppSettings, isTrue);
      expect(fakePlatform.openedLocationSettings, isTrue);
    });

    test('maps Android service disabled, permissions, and runtime exceptions',
        () async {
      fakePlatform.serviceEnabled = false;
      expect(await service.canWatch(), isFalse);
      await expectLater(
        service.locate(),
        throwsA(
          isA<CampusMapLocationException>().having(
            (e) => e.action,
            'action',
            CampusMapLocationAction.locationSettings,
          ),
        ),
      );

      fakePlatform.serviceEnabled = true;
      fakePlatform.permission = LocationPermission.denied;
      fakePlatform.requestedPermission = LocationPermission.deniedForever;
      await expectLater(
        service.locate(),
        throwsA(
          isA<CampusMapLocationException>().having(
            (e) => e.action,
            'action',
            CampusMapLocationAction.appSettings,
          ),
        ),
      );

      fakePlatform.requestedPermission = LocationPermission.denied;
      await expectLater(
        service.locate(),
        throwsA(
          isA<CampusMapLocationException>()
              .having((e) => e.message, 'message', '未获得定位权限，仍可浏览和搜索地图'),
        ),
      );

      fakePlatform.permission = LocationPermission.whileInUse;
      fakePlatform.getCurrentPositionError = TimeoutException('timeout');
      await expectLater(
        service.locate(),
        throwsA(
          isA<CampusMapLocationException>()
              .having((e) => e.message, 'message', '暂未获取到位置，请到开阔处重试'),
        ),
      );

      fakePlatform.getCurrentPositionError =
          const LocationServiceDisabledException();
      await expectLater(
        service.locate(),
        throwsA(
          isA<CampusMapLocationException>().having(
            (e) => e.action,
            'action',
            CampusMapLocationAction.locationSettings,
          ),
        ),
      );

      fakePlatform.getCurrentPositionError =
          const PermissionDeniedException('denied');
      await expectLater(
        service.locate(),
        throwsA(
          isA<CampusMapLocationException>()
              .having((e) => e.message, 'message', '未获得定位权限，仍可浏览和搜索地图'),
        ),
      );
    });
  });
}

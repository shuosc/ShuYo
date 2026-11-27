import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';

import '../models/campus_map.dart';

enum CampusMapLocationAction { appSettings, locationSettings }

class CampusMapLocationException implements Exception {
  const CampusMapLocationException(this.message, {this.action});

  final String message;
  final CampusMapLocationAction? action;
}

class CampusMapLocation {
  const CampusMapLocation({
    required this.longitude,
    required this.latitude,
    required this.accuracy,
  });

  final double longitude;
  final double latitude;
  final double accuracy;

  CampusMapCoordinate get coordinate =>
      campusMapWgs84ToGcj02(longitude, latitude);

  Map<String, dynamic>? forCampus(CampusMapCampus campus) {
    final point = campus.project(coordinate);
    if (!campus.contains(point)) return null;
    return {
      ...point.toJson(),
      'accuracy': accuracy.isFinite && accuracy > 0
          ? accuracy / campus.metersPerMapUnit
          : 0,
    };
  }

  factory CampusMapLocation.fromPosition(Position position) =>
      CampusMapLocation(
        longitude: position.longitude,
        latitude: position.latitude,
        accuracy: position.accuracy,
      );

  factory CampusMapLocation.fromMap(Map<Object?, Object?> raw) {
    final longitude = raw['longitude'];
    final latitude = raw['latitude'];
    final accuracy = raw['accuracy'];
    if (longitude is! num || latitude is! num || accuracy is! num) {
      throw const FormatException('Invalid location payload');
    }
    final lon = longitude.toDouble();
    final lat = latitude.toDouble();
    final acc = accuracy.toDouble();
    if (!lon.isFinite ||
        !lat.isFinite ||
        !acc.isFinite ||
        lat < -90 ||
        lat > 90 ||
        lon < -180 ||
        lon > 180 ||
        acc < 0) {
      throw const FormatException('Invalid location values');
    }
    return CampusMapLocation(
      longitude: lon,
      latitude: lat,
      accuracy: acc,
    );
  }
}

class CampusMapLocationService {
  const CampusMapLocationService({
    TargetPlatform? platformOverride,
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _platformOverride = platformOverride,
        _methodChannel = methodChannel ?? _defaultMethodChannel,
        _eventChannel = eventChannel ?? _defaultEventChannel;

  static const _defaultMethodChannel =
      MethodChannel('work.shuyo.app/campus_map_location');
  static const _defaultEventChannel =
      EventChannel('work.shuyo.app/campus_map_location/events');

  final TargetPlatform? _platformOverride;
  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  bool get _useIOSNative =>
      (_platformOverride ?? defaultTargetPlatform) == TargetPlatform.iOS;

  GeolocatorPlatform get _geolocator => GeolocatorPlatform.instance;

  LocationSettings _settings({bool once = false}) => LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
        timeLimit: once ? const Duration(seconds: 15) : null,
      );

  Future<CampusMapLocation> locate() async {
    if (_useIOSNative) {
      return _locateIOS();
    }
    if (!await _geolocator.isLocationServiceEnabled()) {
      throw const CampusMapLocationException(
        '请先开启系统定位服务',
        action: CampusMapLocationAction.locationSettings,
      );
    }
    var permission = await _geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await _geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw const CampusMapLocationException(
        '定位权限已关闭，可在系统设置中开启',
        action: CampusMapLocationAction.appSettings,
      );
    }
    if (permission != LocationPermission.whileInUse &&
        permission != LocationPermission.always) {
      throw const CampusMapLocationException('未获得定位权限，仍可浏览和搜索地图');
    }
    try {
      return CampusMapLocation.fromPosition(
        await _geolocator.getCurrentPosition(
          locationSettings: _settings(once: true),
        ),
      );
    } on TimeoutException {
      throw const CampusMapLocationException('暂未获取到位置，请到开阔处重试');
    } on LocationServiceDisabledException {
      throw const CampusMapLocationException(
        '系统定位服务已关闭',
        action: CampusMapLocationAction.locationSettings,
      );
    } on PermissionDeniedException {
      throw const CampusMapLocationException('未获得定位权限，仍可浏览和搜索地图');
    }
  }

  Future<CampusMapLocation> _locateIOS() async {
    try {
      final raw = await _methodChannel
          .invokeMapMethod<Object?, Object?>('locate');
      if (raw == null) {
        throw const CampusMapLocationException('暂未获取到位置，请到开阔处重试');
      }
      return CampusMapLocation.fromMap(raw);
    } on PlatformException catch (error) {
      switch (error.code) {
        case 'location_services_disabled':
          throw const CampusMapLocationException(
            '请先开启系统定位服务',
            action: CampusMapLocationAction.locationSettings,
          );
        case 'permission_denied_forever':
          throw const CampusMapLocationException(
            '定位权限已关闭，可在系统设置中开启',
            action: CampusMapLocationAction.appSettings,
          );
        case 'permission_denied':
          throw const CampusMapLocationException('未获得定位权限，仍可浏览和搜索地图');
        case 'timeout':
        case 'location_unavailable':
          throw const CampusMapLocationException('暂未获取到位置，请到开阔处重试');
        default:
          rethrow;
      }
    }
  }

  /// Used on resume without displaying another permission prompt.
  Future<bool> canWatch() async {
    if (_useIOSNative) {
      return await _methodChannel.invokeMethod<bool>('canWatch') ?? false;
    }
    if (!await _geolocator.isLocationServiceEnabled()) return false;
    final permission = await _geolocator.checkPermission();
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  Stream<CampusMapLocation> watch() {
    if (_useIOSNative) {
      return _eventChannel.receiveBroadcastStream().map((event) {
        if (event is! Map<Object?, Object?>) {
          throw const FormatException('Invalid location event');
        }
        return CampusMapLocation.fromMap(event);
      });
    }
    return _geolocator
        .getPositionStream(locationSettings: _settings())
        .map(CampusMapLocation.fromPosition);
  }

  Future<bool> openSettings(CampusMapLocationAction action) async {
    if (_useIOSNative) {
      return await _methodChannel.invokeMethod<bool>('openSettings') ?? false;
    }
    return action == CampusMapLocationAction.appSettings
        ? _geolocator.openAppSettings()
        : _geolocator.openLocationSettings();
  }
}

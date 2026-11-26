import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/campus_map.dart';

enum CampusMapNavigationProvider {
  apple('苹果地图'),
  amap('高德地图'),
  baidu('百度地图'),
  tencent('腾讯地图'),
  google('Google 地图');

  const CampusMapNavigationProvider(this.label);

  final String label;
}

class CampusMapNavigationException implements Exception {
  const CampusMapNavigationException(this.message);

  final String message;
}

class CampusMapNavigationService {
  CampusMapNavigationService({
    Future<bool> Function(Uri)? launcher,
    Future<bool> Function(Uri)? canLaunch,
    bool? isIOS,
  })  : _launcher = launcher ?? _launchExternal,
        _canLaunch = canLaunch ?? canLaunchUrl,
        _isIOS = isIOS ?? defaultTargetPlatform == TargetPlatform.iOS;

  final Future<bool> Function(Uri) _launcher;
  final Future<bool> Function(Uri) _canLaunch;
  final bool _isIOS;

  static Future<bool> _launchExternal(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  /// Returns only the map apps currently installed on this device, in platform
  /// display order (Apple Maps is only queried on iOS).
  Future<List<CampusMapNavigationProvider>> availableProviders() async {
    final candidates = _isIOS
        ? CampusMapNavigationProvider.values
        : CampusMapNavigationProvider.values
            .where((provider) => provider != CampusMapNavigationProvider.apple)
            .toList(growable: false);
    final checks = await Future.wait(
      candidates.map((provider) async {
        final probe = probeUri(provider, isIOS: _isIOS);
        if (probe == null) return false;
        try {
          return await _canLaunch(probe);
        } catch (_) {
          return false;
        }
      }),
    );
    return [
      for (var i = 0; i < candidates.length; i++)
        if (checks[i]) candidates[i],
    ];
  }

  /// Scheme + host/path probe URI used with [canLaunchUrl] to check if the
  /// map app itself is installed (matching Android IntentFilter host/path
  /// requirements without matching generic web browsers).
  static Uri? probeUri(
    CampusMapNavigationProvider provider, {
    required bool isIOS,
  }) =>
      switch (provider) {
        CampusMapNavigationProvider.apple =>
          isIOS ? Uri(scheme: 'maps', host: '') : null,
        CampusMapNavigationProvider.amap => Uri(
            scheme: isIOS ? 'iosamap' : 'androidamap',
            host: isIOS ? 'path' : 'route',
          ),
        CampusMapNavigationProvider.baidu =>
          Uri(scheme: 'baidumap', host: 'map', path: '/direction'),
        CampusMapNavigationProvider.tencent =>
          Uri(scheme: 'qqmap', host: 'map', path: '/routeplan'),
        CampusMapNavigationProvider.google => isIOS
            ? Uri(scheme: 'comgooglemaps', host: '')
            : Uri.parse('google.navigation:q=0,0&mode=w'),
      };

  Future<void> open(
    CampusMapNavigationProvider provider,
    CampusMapPlace place,
  ) async {
    if (place.navigation == null) {
      throw const CampusMapNavigationException('该地点暂未提供导航坐标');
    }
    for (final uri in [
      nativeUri(provider, place, isIOS: _isIOS),
      webUri(provider, place),
    ]) {
      try {
        if (await _launcher(uri)) return;
      } catch (_) {
        // A missing native application can throw instead of returning false.
        // Try its HTTPS route in the external browser next.
      }
    }
    throw const CampusMapNavigationException('无法打开地图应用，请检查是否已安装');
  }

  static Uri nativeUri(
    CampusMapNavigationProvider provider,
    CampusMapPlace place, {
    required bool isIOS,
  }) {
    final point = place.navigation!;
    return switch (provider) {
      CampusMapNavigationProvider.apple => _appUri(
          scheme: 'maps',
          host: '',
          queryParameters: {
            'daddr': '${point.latitude},${point.longitude}',
            'dirflg': 'w',
          },
        ),
      CampusMapNavigationProvider.amap => _appUri(
          scheme: isIOS ? 'iosamap' : 'androidamap',
          host: isIOS ? 'path' : 'route',
          queryParameters: {
            'sourceApplication': 'ShuYo',
            'dlat': '${point.latitude}',
            'dlon': '${point.longitude}',
            'dname': place.name,
            'dev': '0',
            't': '2',
          },
        ),
      CampusMapNavigationProvider.baidu => _appUri(
          scheme: 'baidumap',
          host: 'map',
          path: '/direction',
          queryParameters: {
            'destination':
                'latlng:${point.latitude},${point.longitude}|name:${place.name}',
            'mode': 'walking',
            'coord_type': 'gcj02',
            'src': 'work.shuyo.app',
          },
        ),
      CampusMapNavigationProvider.tencent => _appUri(
          scheme: 'qqmap',
          host: 'map',
          path: '/routeplan',
          queryParameters: {
            'type': 'walk',
            'to': place.name,
            'tocoord': '${point.latitude},${point.longitude}',
            'referer': 'ShuYo',
          },
        ),
      CampusMapNavigationProvider.google => isIOS
          ? _appUri(
              scheme: 'comgooglemaps',
              host: '',
              queryParameters: {
                'daddr': '${point.latitude},${point.longitude}',
                'directionsmode': 'walking',
              },
            )
          : Uri.parse(
              'google.navigation:q=${point.latitude},${point.longitude}&mode=w',
            ),
    };
  }

  // Custom map URL schemes do not consistently decode form-style '+' spaces.
  // Encode every query component with percent escapes instead.
  static Uri _appUri({
    required String scheme,
    required String host,
    String? path,
    required Map<String, String> queryParameters,
  }) =>
      Uri(
        scheme: scheme,
        host: host,
        path: path,
        query: queryParameters.entries
            .map((entry) =>
                '${Uri.encodeComponent(entry.key)}=${Uri.encodeComponent(entry.value)}')
            .join('&'),
      );

  static Uri webUri(
    CampusMapNavigationProvider provider,
    CampusMapPlace place,
  ) {
    final point = place.navigation!;
    return switch (provider) {
      CampusMapNavigationProvider.apple => Uri.https(
          'maps.apple.com',
          '/',
          {
            'daddr': '${point.latitude},${point.longitude}',
            'dirflg': 'w',
          },
        ),
      CampusMapNavigationProvider.amap => Uri.https(
          'uri.amap.com',
          '/navigation',
          {
            'to': '${point.longitude},${point.latitude},${place.name}',
            'mode': 'walk',
            'coordinate': 'gaode',
            'callnative': '1',
            'src': 'ShuYo',
          },
        ),
      CampusMapNavigationProvider.baidu => Uri.https(
          'api.map.baidu.com',
          '/direction',
          {
            'destination':
                'latlng:${point.latitude},${point.longitude}|name:${place.name}',
            'mode': 'walking',
            'coord_type': 'gcj02',
            'output': 'html',
            'src': 'work.shuyo.app',
          },
        ),
      CampusMapNavigationProvider.tencent => Uri.https(
          'apis.map.qq.com',
          '/uri/v1/routeplan',
          {
            'type': 'walk',
            'to': place.name,
            'tocoord': '${point.latitude},${point.longitude}',
            'referer': 'ShuYo',
          },
        ),
      CampusMapNavigationProvider.google => Uri.https(
          'www.google.com',
          '/maps/dir/',
          {
            'api': '1',
            'destination': '${point.latitude},${point.longitude}',
            'travelmode': 'walking',
          },
        ),
    };
  }
}

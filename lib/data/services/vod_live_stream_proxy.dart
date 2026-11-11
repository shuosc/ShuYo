import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/vod_url_resolver.dart';

class VodLiveStreamProxy {
  VodLiveStreamProxy(
      {required this.useWebVpn,
      required this.headersLoader,
      this.mediaUrlResolver});

  final bool useWebVpn;
  final Future<Map<String, String>> Function(Uri) headersLoader;
  final Uri Function(Uri)? mediaUrlResolver;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final _targets = <String, Uri>{};
  final _paths = <Uri, String>{};
  final _diagnostics = <String>{};
  final _firstByteKinds = <String>{};
  HttpServer? _server;
  bool _disposed = false;
  Future<HttpServer>? _starting;

  Future<Uri> open(Uri source) async {
    if (_disposed) throw StateError('播放器已关闭');
    final target = _resolve(source);
    final server = _server ??=
        await (_starting ??= HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    if (_disposed) {
      await server.close(force: true);
      throw StateError('播放器已关闭');
    }
    if (_targets.isEmpty) {
      server.listen((request) => unawaited(_serve(request)));
    }
    return _register(target);
  }

  Uri _register(Uri target) {
    final safe = _resolve(target);
    final entry = _paths[safe] ?? '${_targets.length + 1}${_safeSuffix(safe)}';
    _targets[entry] = safe;
    _paths[safe] = entry;
    return Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: _server!.port,
        path: '/$entry');
  }

  Uri _resolve(Uri target) =>
      mediaUrlResolver?.call(target) ??
      VodUrlResolver.resolveMediaUrl(target.toString(), useWebVpn: useWebVpn);

  String _safeSuffix(Uri uri) {
    final path = uri.path.toLowerCase();
    for (final suffix in const [
      '.m3u8',
      '.m3u',
      '.ts',
      '.m4s',
      '.mp4',
      '.m4a',
      '.aac',
      '.key',
      '.flv',
      '.mp3',
      '.webm',
      '.vtt',
      '.bin',
    ]) {
      if (path.endsWith(suffix)) return suffix;
    }
    return '';
  }

  String _mediaKind(Uri uri) {
    final suffix = _safeSuffix(uri);
    if (suffix == '.m3u8' || suffix == '.m3u') return 'playlist';
    if (suffix == '.flv') return 'flv';
    if (suffix == '.key') return 'key';
    return 'media';
  }

  void _diagnose(String event) {
    // A playlist may refresh every few seconds. Log each kind of event once
    // per proxy and never include source URLs, paths, tokens, or exception text.
    if (_diagnostics.length < 64 && _diagnostics.add(event)) {
      debugPrint('ShuYoVOD relay: $event');
    }
  }

  Stream<List<int>> _observeBytes(
      Stream<List<int>> stream, String kind, Stopwatch requestTime) {
    var received = false;
    return stream.map((bytes) {
      if (!received && bytes.isNotEmpty) {
        received = true;
        if (_firstByteKinds.add(kind)) {
          _diagnose(
              'kind=$kind first-byte elapsedMs=${requestTime.elapsedMilliseconds}');
        }
      }
      return bytes;
    });
  }

  Future<void> _serve(HttpRequest request) async {
    var kind = 'unknown';
    final requestTime = Stopwatch()..start();
    try {
      final target = _targets[request.uri.path.substring(1)];
      if (_disposed ||
          target == null ||
          !['GET', 'HEAD'].contains(request.method)) {
        request.response.statusCode = HttpStatus.notFound;
        return;
      }
      var current = target;
      kind = _mediaKind(target);
      HttpClientResponse? upstream;
      for (var redirects = 0; redirects < 4; redirects++) {
        final outbound = await _client
            .openUrl(request.method, current)
            .timeout(const Duration(seconds: 20));
        outbound.followRedirects = false;
        final headers = await headersLoader(current);
        for (final entry in headers.entries) {
          if (!['authorization', 'jwt-token', 'host']
              .contains(entry.key.toLowerCase())) {
            outbound.headers.set(entry.key, entry.value);
          }
        }
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null && !current.path.toLowerCase().endsWith('.m3u8')) {
          outbound.headers.set(HttpHeaders.rangeHeader, range);
        }
        upstream = await outbound.close().timeout(const Duration(seconds: 20));
        _diagnose('kind=$kind status=${upstream.statusCode}');
        if (![301, 302, 303, 307, 308].contains(upstream.statusCode)) break;
        final location = upstream.headers.value(HttpHeaders.locationHeader);
        final redirectHost = location == null
            ? 'missing'
            : Uri.tryParse(location)?.host ?? 'invalid';
        _diagnose('kind=$kind redirect host=$redirectHost');
        await upstream.drain<void>();
        if (location == null) throw const FormatException('播放资源跳转不完整');
        current = _resolve(current.resolve(location));
        upstream = null;
      }
      if (upstream == null) throw const FormatException('播放资源跳转次数过多');
      request.response.statusCode = upstream.statusCode;
      final type = upstream.headers.contentType?.mimeType ?? '';
      final path = current.path.toLowerCase();
      final transportStream = path.endsWith('.ts');
      final binaryMedia = transportStream ||
          const ['.m4s', '.mp4', '.m4a', '.aac', '.key', '.flv']
              .any(path.endsWith);
      final playlist = path.endsWith('.m3u8') ||
          path.endsWith('.m3u') ||
          (!binaryMedia && type.toLowerCase().contains('mpegurl'));
      if (playlist &&
          upstream.statusCode == HttpStatus.ok &&
          request.method != 'HEAD') {
        final contents = await utf8.decoder
            .bind(_observeBytes(upstream.timeout(const Duration(seconds: 20)),
                kind, requestTime))
            .join();
        if (!contents.trimLeft().startsWith('#EXTM3U')) {
          throw const FormatException('直播列表无效');
        }
        if (kDebugMode) {
          final targetDuration =
              RegExp(r'#EXT-X-TARGETDURATION:(\d+)').firstMatch(contents)?[1];
          final segmentCount = RegExp(r'#EXTINF:').allMatches(contents).length;
          _diagnose(
              'playlist targetDuration=$targetDuration segments=$segmentCount');
        }
        final rewritten = contents.split('\n').map((line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) return line;
          if (!trimmed.startsWith('#')) {
            return _register(current.resolve(trimmed)).toString();
          }
          return line.replaceAllMapped(RegExp('URI="([^"]+)"'),
              (match) => 'URI="${_register(current.resolve(match[1]!))}"');
        }).join('\n');
        request.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        request.response.headers
            .set(HttpHeaders.cacheControlHeader, 'no-store');
        request.response.write(rewritten);
      } else {
        for (final name in [
          HttpHeaders.contentTypeHeader,
          HttpHeaders.contentRangeHeader,
          HttpHeaders.acceptRangesHeader,
        ]) {
          final value = upstream.headers.value(name);
          if (value != null) request.response.headers.set(name, value);
        }
        if (transportStream) {
          request.response.headers.contentType = ContentType('video', 'mp2t');
        } else if (path.endsWith('.flv')) {
          request.response.headers.contentType = ContentType('video', 'x-flv');
          request.response.bufferOutput = false;
        }
        await request.response.addStream(_observeBytes(
            upstream.timeout(const Duration(seconds: 30)), kind, requestTime));
      }
    } on Object catch (error) {
      _diagnose('kind=$kind exception=${error.runtimeType}');
      try {
        request.response.statusCode = HttpStatus.badGateway;
      } on Object {
        request.response.done.ignore();
      }
    } finally {
      try {
        await request.response.close();
      } on Object {
        request.response.done.ignore();
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _client.close(force: true);
    await _server?.close(force: true);
    _targets.clear();
    _paths.clear();
    _diagnostics.clear();
    _firstByteKinds.clear();
  }
}

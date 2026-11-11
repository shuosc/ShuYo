import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'http_timeout.dart';

class ImageSaver {
  const ImageSaver._();

  static const _channel = MethodChannel('work.shuyo.app/image_saver');

  static Future<void> saveNetworkImage(
    String url, {
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse(url);
    final response = await _download(uri, headers: headers);
    final mimeType = response.mimeType ?? _mimeTypeFromPath(uri.path);
    final filename = _filenameFor(uri, mimeType);
    await _channel.invokeMethod<void>('saveImage', {
      'bytes': response.bytes,
      'filename': filename,
      'mimeType': mimeType,
    });
  }

  static Future<_DownloadedImage> _download(
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    final client = HttpClient();
    try {
      client.connectionTimeout = HttpTimeout.connect;
      return await _downloadWithClient(client, uri, headers: headers).timeout(
        HttpTimeout.transfer,
        onTimeout: () {
          client.close(force: true);
          throw TimeoutException('图片下载超时', HttpTimeout.transfer);
        },
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<_DownloadedImage> _downloadWithClient(
    HttpClient client,
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    final request = await client.getUrl(uri).timeout(HttpTimeout.connect);
    headers?.forEach(request.headers.set);
    final response = await request.close().timeout(HttpTimeout.normal);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('图片下载失败 (${response.statusCode})');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(HttpTimeout.streamIdle)) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.isEmpty) {
      throw Exception('图片内容为空');
    }
    return _DownloadedImage(
      bytes: bytes,
      mimeType: response.headers.contentType?.mimeType,
    );
  }

  static String _filenameFor(Uri uri, String mimeType) {
    final raw = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    final sanitized =
        raw.split('?').first.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (sanitized.isNotEmpty &&
        RegExp(r'\.[a-zA-Z0-9]{2,5}$').hasMatch(sanitized)) {
      return sanitized;
    }
    return 'shuyo_${DateTime.now().millisecondsSinceEpoch}${_extensionForMime(mimeType)}';
  }

  static String _mimeTypeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    return 'image/jpeg';
  }

  static String _extensionForMime(String mimeType) {
    return switch (mimeType) {
      'image/png' => '.png',
      'image/gif' => '.gif',
      'image/webp' => '.webp',
      _ => '.jpg',
    };
  }
}

class _DownloadedImage {
  const _DownloadedImage({
    required this.bytes,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String? mimeType;
}

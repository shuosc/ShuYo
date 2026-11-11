import 'dart:convert';

import '../../core/library_constants.dart';

/// 超星认证站 `/OAuth2/shu/index` 回调页里内嵌的登录参数。
class LibraryCallbackPage {
  const LibraryCallbackPage({
    required this.loginPath,
    required this.data,
    required this.time,
    required this.enc,
    required this.displayName,
    required this.userRole,
    this.firstReferer,
  });

  final String loginPath;
  final String data;
  final String time;
  final String enc;
  final String displayName;
  final String userRole;
  final String? firstReferer;
}

class LibraryJwt {
  const LibraryJwt({required this.jwt, required this.header});

  final String jwt;
  final String header;
}

/// 解析认证链路中的 JS 页面与凭据，全部是纯函数，便于脱离网络测试。
class LibraryAuthParser {
  const LibraryAuthParser._();

  static final _jsRedirect = RegExp(
    r'^[ \t]*window\.location(?:\.href)?\s*=\s*"((?:[^"\\]|\\.)*)"',
    multiLine: true,
  );
  static final _jwtShape =
      RegExp(r'^[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+$');
  static final _headerShape = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]{1,100}$");

  /// 取出页面里未被注释的 `window.location = "…"` 目标。
  static Uri? parseJsRedirect(String html, Uri base) {
    final raw = _jsRedirect.firstMatch(html)?.group(1);
    if (raw == null) return null;
    final value = _unescapeJs(raw);
    if (value == null || value.isEmpty) return null;
    return base.resolve(value);
  }

  static LibraryCallbackPage? parseCallbackPage(String html) {
    final loginPath = _jsString(html, r'var\s+url\s*=\s*');
    final time = RegExp(r'\btime:\s*(\d+)').firstMatch(html)?.group(1);
    final enc = RegExp(r'\benc:\s*"([^"]*)"').firstMatch(html)?.group(1);
    if (loginPath == null || time == null || enc == null) return null;
    final data = RegExp(r'\bdata:\s*"([^"]*)"').firstMatch(html)?.group(1);
    final displayName =
        RegExp(r'\bdisplayName:\s*"([^"]*)"').firstMatch(html)?.group(1);
    final userRole = RegExp(r'\buserRole:\s*(\d+)').firstMatch(html)?.group(1);
    return LibraryCallbackPage(
      loginPath: loginPath,
      data: data ?? '',
      time: time,
      enc: enc,
      displayName: displayName ?? '',
      userRole: userRole ?? '3',
      firstReferer: _jsString(html, r'var\s+firstReferer\s*=\s*'),
    );
  }

  /// 在跳转地址、页面脚本或 Cookie 值中找图书馆前端使用的 `jwt` 与请求头名。
  ///
  /// 前端接受三种形态：`#/页面?jwt=…&jwtHeader=…`、`loginExternal/:jwt/:jwtHeader`
  /// 以及同名 Cookie。没给请求头名时回落到 [LibraryConstants.defaultJwtHeader]。
  static LibraryJwt? extractJwt(String text) {
    final decoded = _tryDecode(text);
    for (final source in {text, decoded}) {
      final external = RegExp(
        r'loginExternal/([A-Za-z0-9_\-.]+)/([A-Za-z0-9_\-.]+)',
      ).firstMatch(source);
      if (external != null && looksLikeJwt(external.group(1)!)) {
        return _build(external.group(1)!, external.group(2));
      }
      final jwt = RegExp(r'(?<![A-Za-z])jwt=([A-Za-z0-9_\-.]+)')
          .firstMatch(source)
          ?.group(1);
      if (jwt != null && looksLikeJwt(jwt)) {
        final header = RegExp(r'jwtHeader=([A-Za-z0-9_\-.]+)')
            .firstMatch(source)
            ?.group(1);
        return _build(jwt, header);
      }
    }
    return null;
  }

  static LibraryJwt _build(String jwt, String? header) => LibraryJwt(
        jwt: jwt,
        header: header != null && isValidJwtHeader(header)
            ? header
            : LibraryConstants.defaultJwtHeader,
      );

  static bool looksLikeJwt(String value) => _jwtShape.hasMatch(value);

  static bool isValidJwtHeader(String value) => _headerShape.hasMatch(value);

  /// 解析 JWT Payload 内容，无法解析时返回 null。
  static Map<String, Object?>? jwtPayload(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final payload =
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final json = jsonDecode(payload);
      if (json is Map) {
        return json.cast<String, Object?>();
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  /// 提取 JWT Payload 中的学号或主体（`sub` 字段）。
  static String? jwtSubject(String jwt) {
    final payload = jwtPayload(jwt);
    final sub = payload?['sub'];
    return sub is String && sub.isNotEmpty ? sub : null;
  }

  /// 服务端签发的 24 小时 `exp`（秒）。无法解析时返回 null，由调用方当作未知。
  static DateTime? jwtExpiry(String jwt) {
    final payload = jwtPayload(jwt);
    final exp = payload?['exp'];
    if (exp is num) {
      return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000);
    }
    return null;
  }

  static String? _jsString(String html, String prefix) {
    final raw =
        RegExp('$prefix"((?:[^"\\\\]|\\\\.)*)"').firstMatch(html)?.group(1);
    if (raw == null) return null;
    final value = _unescapeJs(raw);
    return value == null || value.isEmpty ? null : value;
  }

  static String? _unescapeJs(String raw) {
    try {
      final value = jsonDecode('"$raw"');
      return value is String ? value : null;
    } on FormatException {
      return null;
    }
  }

  static String _tryDecode(String value) {
    try {
      return Uri.decodeFull(value);
    } on ArgumentError {
      return value;
    }
  }
}

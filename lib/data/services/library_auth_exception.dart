class LibraryAuthException implements Exception {
  const LibraryAuthException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 无法连接图书馆或认证服务
class LibraryAuthUnavailableException extends LibraryAuthException {
  const LibraryAuthUnavailableException([String? message])
      : super(message ?? '暂时无法连接图书馆认证服务，请检查网络后重试');
}

/// 校园统一身份认证已失效或未登录
class LibraryCampusAuthRequiredException extends LibraryAuthException {
  const LibraryCampusAuthRequiredException({this.ssoExpired = false})
      : super(ssoExpired ? '校园账户登录已失效，请重新登录' : '请先登录校园账户');

  final bool ssoExpired;
}

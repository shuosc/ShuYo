class VodAuthException implements Exception {
  const VodAuthException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The recording service could not be reached; the saved login has not been
/// rejected. Allows an existing account to use its cached recording links.
class VodAuthUnavailableException extends VodAuthException {
  const VodAuthUnavailableException() : super('暂时无法确认录播登录状态，请稍后重试');
}

/// Campus authentication is the sole interactive login for recordings.
class VodCampusAuthRequiredException extends VodAuthException {
  const VodCampusAuthRequiredException({this.ssoExpired = false})
      : super(ssoExpired ? '校园账户登录已失效，请重新登录' : '请先登录校园账户');

  final bool ssoExpired;
}
